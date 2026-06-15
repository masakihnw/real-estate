#!/usr/bin/env python3
"""買い手コンテキストの単一ソースから派生物を生成・同期する。

正準ソース（編集点）:
- scraping-tool/config/buyer_profile.json        … 買い手プロフィール（事実データ）
- scraping-tool/config/purchase_strategy.md      … 購入戦略（全AIモジュール共有の判断ポリシー）
- scraping-tool/config/prompts/<module>.md       … モジュール別タスク定義（出力形式・評価手順）

このスクリプトが生成する派生物:
- docs/BUYER_PROFILE.md                               … 人間用リファレンス（全文生成）
- scraping-tool/out/buyer_profiles_upsert.sql         … Supabase buyer_profiles 反映SQL
- scraping-tool/out/ai_prompts_<module>.sql           … Supabase ai_prompts 反映SQL（戦略＋タスク合成）

system_prompt は「購入戦略 → タスク定義」の順で合成する
（claude_investment_summarizer.build_fallback_system_prompt と同一構成）。

使い方:
    python3 scripts/generate_buyer_context.py --check   # 同期検証（CI / テスト用、非0で失敗）
    python3 scripts/generate_buyer_context.py --write   # 派生物を再生成

Supabase への適用は本スクリプトでは行わない。生成した out/*.sql をレビューし適用する。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

SCRAPING_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[2]

BUYER_PROFILE_PATH = SCRAPING_ROOT / "config" / "buyer_profile.json"
STRATEGY_PATH = SCRAPING_ROOT / "config" / "purchase_strategy.md"
PROMPTS_DIR = SCRAPING_ROOT / "config" / "prompts"
DOC_PATH = ROOT / "docs" / "BUYER_PROFILE.md"
OUT_DIR = SCRAPING_ROOT / "out"
BUYER_PROFILES_SQL_PATH = OUT_DIR / "buyer_profiles_upsert.sql"

# Supabase 反映パラメータ。実 user_id はリポジトリにハードコードせず環境変数で注入する。
# 未設定時はプレースホルダを出力する（生成 SQL は適用前にレビューする運用）。
BUYER_USER_ID = os.environ.get("BUYER_PROFILE_USER_ID", "<BUYER_PROFILE_USER_ID>")

_SUMMARY_OUTPUT_SCHEMA = (
    '{"type": "object", "required": ["score", "conclusion", "flags", "scenarios", "action"], '
    '"properties": {"flags": {"type": "array", "items": {"type": "string"}}, '
    '"score": {"type": "integer", "maximum": 5, "minimum": 1}, '
    '"action": {"type": "string"}, '
    '"scenarios": {"type": "array", "items": {"type": "object", '
    '"required": ["name", "fit", "livable_years", "exit_simulation", "risk"]}}, '
    '"conclusion": {"type": "string"}}}'
)


@dataclass(frozen=True)
class PromptSpec:
    """ai_prompts 1モジュール分の反映仕様。

    version は動的採番（本番 max(version)+1）のためフィールドとして持たない。
    同一コンテンツが既存の場合は idempotent パスで is_active=true に戻すだけ。
    output_schema / config は本番アクティブ版を踏襲する（rescore 設定等を退行させない）。
    """

    module: str
    user_prompt_template: str
    output_schema: str | None
    config: str
    notes: str


_AI_PROMPT_NOTES = (
    "2026/6/15 1階を絶対NG（強制グレードD）から『重めに減点（足切りではない）』へ格下げ。"
    "買い手の実意向（絶対NGではなく総合評価で重めに減点）と整合。北向きのみ・総戸数20戸以下も同区分。"
    "戦略変更によりsystem_prompt再合成で全再分析トリガー"
)

PROMPT_SPECS: tuple[PromptSpec, ...] = (
    PromptSpec(
        module="investment_summary",
        user_prompt_template="## 買い手プロファイル\n{buyer_profile}\n\n## 物件情報\n{listing_data}",
        output_schema=_SUMMARY_OUTPUT_SCHEMA,
        config='{"max_tokens": 2048, "rescore_interval": "1 day", "max_items_per_run": 50, "rescore_min_score": 4}',
        notes=_AI_PROMPT_NOTES,
    ),
    PromptSpec(
        module="ai_scoring",
        user_prompt_template="## バイヤープロファイル\n{buyer_profile}\n\n## 物件情報\n{listing_data}",
        output_schema=None,
        config='{"max_tokens": 1024, "rescore_interval": "1 day", "max_items_per_run": 100, "rescore_min_score": 65}',
        notes=_AI_PROMPT_NOTES,
    ),
)


# ─────────────────────── 入力ロード ───────────────────────
def load_buyer_profile() -> dict:
    return json.loads(BUYER_PROFILE_PATH.read_text(encoding="utf-8"))


def load_strategy() -> str:
    return STRATEGY_PATH.read_text(encoding="utf-8").rstrip("\n")


def load_task_prompt(module: str) -> str:
    return (PROMPTS_DIR / f"{module}.md").read_text(encoding="utf-8").rstrip("\n")


def compose_system_prompt(module: str) -> str:
    """戦略＋タスク定義を合成する（summarizer のフォールバック合成と同一）。"""
    return f"## 購入戦略コンテキスト\n{load_strategy()}\n\n{load_task_prompt(module)}"


# ─────────────────────── BUYER_PROFILE.md 生成 ───────────────────────
_FIELD_LABELS: list[tuple[str, str]] = [
    ("family_composition", "家族構成"),
    ("child_plan", "子ども計画"),
    ("household_income", "世帯年収"),
    ("current_housing", "現在の住居"),
    ("self_funds", "自己資金"),
    ("planned_borrowing", "借入予定"),
    ("interest_type", "金利タイプ"),
    ("estimated_rate", "想定金利"),
    ("repayment_years", "返済期間"),
    ("monthly_payment_limit", "月額上限"),
    ("work_style", "働き方・通勤"),
    ("commute_quality", "通勤の質"),
    ("priorities", "重視する点"),
    ("relocation_reason", "住み替え理由"),
    ("post_sale_strategy", "出口方針"),
    ("timeline", "購入時期"),
    ("risk_tolerance", "リスク許容度"),
]


def generate_buyer_profile_md() -> str:
    profile = load_buyer_profile()
    lines: list[str] = []
    lines.append("# 買い手条件（AI 相談プロンプト用）")
    lines.append("")
    lines.append("> **このファイルは自動生成です。手で編集しないこと。**")
    lines.append(">")
    lines.append("> 正準ソース（編集点）:")
    lines.append("> - `scraping-tool/config/buyer_profile.json` … 買い手プロフィール（事実データ）")
    lines.append("> - `scraping-tool/config/purchase_strategy.md` … 購入戦略（全AIモジュール共有）")
    lines.append("> - `scraping-tool/config/prompts/<module>.md` … モジュール別タスク定義")
    lines.append(">")
    lines.append("> 再生成: `cd scraping-tool && python3 scripts/generate_buyer_context.py --write`")
    lines.append("> 実運用データは Supabase（`buyer_profiles` / `ai_prompts`）。反映は `out/*.sql` を適用する。")
    lines.append("")
    lines.append("## 基本プロフィール")
    lines.append("")
    lines.append("| 項目 | 内容 |")
    lines.append("|---|---|")
    for key, label in _FIELD_LABELS:
        val = str(profile.get(key, "") or "").strip()
        if val:
            lines.append(f"| {label} | {val} |")
    lines.append("")

    budget = profile.get("budget_scenarios") or []
    if budget:
        lines.append("## 予算シナリオ（二段構え）")
        lines.append("")
        lines.append("| 区分 | 値 | 補足 |")
        lines.append("|---|---|---|")
        for s in budget:
            label = str(s.get("label", "")).strip()
            value = str(s.get("value", "")).strip()
            note = str(s.get("note", "")).strip()
            lines.append(f"| {label} | {value} | {note} |")
        lines.append("")

    areas = profile.get("preferred_areas") or []
    if areas:
        lines.append("## 希望エリア")
        lines.append("")
        lines.append("、".join(str(a) for a in areas))
        lines.append("")

    features = profile.get("must_have_features") or []
    if features:
        lines.append("## 必須設備")
        lines.append("")
        lines.append("、".join(str(f) for f in features))
        lines.append("")

    lines.append("## 戦略ポリシー（築年・価格判断）")
    lines.append("")
    lines.append(
        "AI分析の判断軸は `scraping-tool/config/purchase_strategy.md` が正準。"
        "予算は二段構え（探索上限／実質アンカー／月返済上限）で、具体額は上記の予算シナリオ"
        "（実値は Supabase `buyer_profiles` が正）を参照する。"
        "築年は立地・管理を本質とし築30年程度まで許容（長期修繕計画・総会議事録・修繕積立金の確認必須）。"
    )
    lines.append("")
    lines.append("## データソースの優先順位")
    lines.append("")
    lines.append("1. **Supabase `buyer_profiles` / `ai_prompts`** — 実運用の正（Routine / iOS が参照）")
    lines.append(
        "2. **`scraping-tool/config/buyer_profile.json` / `purchase_strategy.md` / `prompts/*.md`** — "
        "リポジトリ正準（Supabase 不通時フォールバック＆反映元）"
    )
    lines.append("3. **`BuyerProfile.swift` preset** — iOS 新規インストール時のデフォルト（手動同期）")
    lines.append("")
    return "\n".join(lines)


# ─────────────────────── Supabase SQL 生成 ───────────────────────
def _dollar_quote(text: str, tag: str) -> str:
    marker = f"${tag}$"
    if marker in text:
        raise ValueError(f"dollar-quote タグ {marker} が本文に出現しています。タグを変更してください。")
    return f"{marker}{text}{marker}"


def generate_buyer_profiles_sql() -> str:
    profile = load_buyer_profile()
    # 決定論のため sort_keys。upsert_buyer_profile は profile->>'key' で参照するためキー順は無関係。
    profile_json = json.dumps(profile, ensure_ascii=False, sort_keys=True, indent=2)
    body = _dollar_quote(profile_json, "profile")
    return (
        "-- 自動生成: scripts/generate_buyer_context.py --write\n"
        "-- buyer_profiles を buyer_profile.json で更新する（migration 020 の RPC を使用）。\n"
        "-- 適用前にレビューすること。\n"
        "BEGIN;\n"
        f"SELECT upsert_buyer_profile('{BUYER_USER_ID}', {body}::jsonb);\n"
        "COMMIT;\n"
    )


def generate_ai_prompts_sql(spec: PromptSpec) -> str:
    """idempotent な ai_prompts INSERT/UPDATE SQL を生成する。

    同一コンテンツ（system_prompt + user_prompt_template）が既存なら is_active に戻すだけ。
    新コンテンツなら動的 version（本番 max+1）で INSERT し is_active=true にする。
    同一タグを複数の SQL 句で参照するため枝番（1/2/3）で個別タグを生成する。
    """
    system_prompt = compose_system_prompt(spec.module)
    sys1 = _dollar_quote(system_prompt, f"{spec.module}_sys1")
    sys2 = _dollar_quote(system_prompt, f"{spec.module}_sys2")
    sys3 = _dollar_quote(system_prompt, f"{spec.module}_sys3")
    tpl1 = _dollar_quote(spec.user_prompt_template, f"{spec.module}_tpl1")
    tpl2 = _dollar_quote(spec.user_prompt_template, f"{spec.module}_tpl2")
    tpl3 = _dollar_quote(spec.user_prompt_template, f"{spec.module}_tpl3")
    notes1 = _dollar_quote(spec.notes, f"{spec.module}_notes1")
    notes2 = _dollar_quote(spec.notes, f"{spec.module}_notes2")
    schema_sql = f"'{spec.output_schema}'::jsonb" if spec.output_schema else "NULL"
    return (
        "-- 自動生成: scripts/generate_buyer_context.py --write\n"
        f"-- module={spec.module} を idempotent に更新する（動的 version 採番）。\n"
        "-- prompt_hash はトリガー ai_prompts_compute_hash が自動計算する。\n"
        "-- 注意: 本文変更により全 enrichment が再分析対象になる（prompt_hash 比較）。\n"
        "-- max_items_per_run でバッチ制御される。必ずトランザクション内で実行する。\n"
        "BEGIN;\n"
        "\n"
        "-- Step 1: 全バージョンを非アクティブ化\n"
        f"UPDATE ai_prompts SET is_active = false WHERE module = '{spec.module}';\n"
        "\n"
        "-- Step 2: 同一コンテンツが既にあれば is_active=true に戻す（idempotent パス）。\n"
        "-- config/notes 単独変更がサイレント無視されないよう、このパスでも最新値で上書きする\n"
        "-- （prompt_hash は本文由来のため再分析はトリガーされない）。\n"
        f"UPDATE ai_prompts SET is_active = true, config = '{spec.config}'::jsonb, notes = {notes2}\n"
        f"WHERE module = '{spec.module}'\n"
        f"  AND system_prompt = {sys1}\n"
        f"  AND user_prompt_template = {tpl1}\n"
        f"  AND id = (\n"
        f"    SELECT id FROM ai_prompts\n"
        f"    WHERE module = '{spec.module}'\n"
        f"      AND system_prompt = {sys2}\n"
        f"      AND user_prompt_template = {tpl2}\n"
        f"    ORDER BY version DESC LIMIT 1\n"
        f"  );\n"
        "\n"
        "-- Step 3: 存在しなければ新バージョンを挿入して is_active=true\n"
        "INSERT INTO ai_prompts\n"
        "  (module, version, is_active, system_prompt, user_prompt_template, output_schema, config, notes)\n"
        "SELECT\n"
        f"  '{spec.module}',\n"
        f"  (SELECT COALESCE(MAX(version), 0) + 1 FROM ai_prompts WHERE module = '{spec.module}'),\n"
        "  true,\n"
        f"  {sys3},\n"
        f"  {tpl3},\n"
        f"  {schema_sql},\n"
        f"  '{spec.config}'::jsonb,\n"
        f"  {notes1}\n"
        "WHERE NOT EXISTS (\n"
        f"  SELECT 1 FROM ai_prompts\n"
        f"  WHERE module = '{spec.module}'\n"
        f"    AND system_prompt = {sys1}\n"
        f"    AND user_prompt_template = {tpl1}\n"
        ");\n"
        "\n"
        "COMMIT;\n"
    )


def ai_prompts_sql_path(module: str) -> Path:
    return OUT_DIR / f"ai_prompts_{module}.sql"


# ─────────────────────── write / check ───────────────────────
def _targets() -> list[tuple[Path, str]]:
    targets: list[tuple[Path, str]] = [
        (DOC_PATH, generate_buyer_profile_md()),
        (BUYER_PROFILES_SQL_PATH, generate_buyer_profiles_sql()),
    ]
    for spec in PROMPT_SPECS:
        targets.append((ai_prompts_sql_path(spec.module), generate_ai_prompts_sql(spec)))
    return targets


def write() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for path, content in _targets():
        path.write_text(content, encoding="utf-8")
        print(f"wrote: {path.relative_to(ROOT)}")


def check() -> int:
    """コミット対象の docs/BUYER_PROFILE.md の同期のみ検証する。

    out/*.sql は gitignore（PII を含む Supabase 適用用の生成物）のため検証対象外。
    """
    expected = generate_buyer_profile_md()
    current = DOC_PATH.read_text(encoding="utf-8") if DOC_PATH.exists() else None
    if current != expected:
        print(f"OUT OF SYNC（--write で再生成してください）: {DOC_PATH.relative_to(ROOT)}")
        return 1
    print("buyer context: docs/BUYER_PROFILE.md は同期済み")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="買い手コンテキスト派生物の生成/検証")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true", help="派生物を再生成する")
    group.add_argument("--check", action="store_true", help="同期を検証する（非0で失敗）")
    args = parser.parse_args()
    if args.write:
        write()
    else:
        sys.exit(check())


if __name__ == "__main__":
    main()
