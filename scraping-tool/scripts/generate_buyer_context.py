#!/usr/bin/env python3
"""買い手コンテキストの単一ソースから派生物を生成・同期する。

正準ソース（編集点）:
- scraping-tool/config/buyer_profile.json          … 買い手プロフィール（事実データ）
- scraping-tool/config/investment_strategy_prompt.md … AI購入戦略プロンプト（分析ポリシー）

このスクリプトが生成する派生物:
- docs/BUYER_PROFILE.md                              … 人間用リファレンス（全文生成）
- scraping-tool/out/buyer_profiles_upsert.sql        … Supabase buyer_profiles 反映SQL
- scraping-tool/out/ai_prompts_investment_summary.sql … Supabase ai_prompts 反映SQL（version+1）

使い方:
    python3 scripts/generate_buyer_context.py --check   # 同期検証（CI / テスト用、非0で失敗）
    python3 scripts/generate_buyer_context.py --write   # 派生物を再生成

Supabase への適用は本スクリプトでは行わない。生成した out/*.sql をユーザーがレビューし適用する。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRAPING_ROOT = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[2]

BUYER_PROFILE_PATH = SCRAPING_ROOT / "config" / "buyer_profile.json"
STRATEGY_PROMPT_PATH = SCRAPING_ROOT / "config" / "investment_strategy_prompt.md"
DOC_PATH = ROOT / "docs" / "BUYER_PROFILE.md"
OUT_DIR = SCRAPING_ROOT / "out"
BUYER_PROFILES_SQL_PATH = OUT_DIR / "buyer_profiles_upsert.sql"
AI_PROMPTS_SQL_PATH = OUT_DIR / "ai_prompts_investment_summary.sql"

# Supabase 反映パラメータ
BUYER_USER_ID = "[USER_ID]"
AI_PROMPT_MODULE = "investment_summary"
AI_PROMPT_VERSION = 2  # migration 023 の seed が version=1。MTG反映を version=2 として投入する。
USER_PROMPT_TEMPLATE = "## 買い手プロファイル\n{buyer_profile}\n\n## 物件情報\n{listing_data}"
OUTPUT_SCHEMA = (
    '{"type":"object","required":["score","conclusion","flags","scenarios","action"],'
    '"properties":{"score":{"type":"integer","minimum":1,"maximum":5},'
    '"conclusion":{"type":"string"},"flags":{"type":"array","items":{"type":"string"}},'
    '"scenarios":{"type":"array","items":{"type":"object",'
    '"required":["name","fit","livable_years","exit_simulation","risk"]}},'
    '"action":{"type":"string"}}}'
)
AI_PROMPT_CONFIG = '{"max_items_per_run":80,"max_tokens":2048}'


# ─────────────────────── 入力ロード ───────────────────────
def load_buyer_profile() -> dict:
    return json.loads(BUYER_PROFILE_PATH.read_text(encoding="utf-8"))


def load_strategy_prompt() -> str:
    return STRATEGY_PROMPT_PATH.read_text(encoding="utf-8").rstrip("\n")


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
    lines.append("> - `scraping-tool/config/investment_strategy_prompt.md` … AI購入戦略プロンプト")
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
        "AI分析の判断軸は `scraping-tool/config/investment_strategy_prompt.md` が正準。"
        "予算は二段構え（探索上限1.3億／実質アンカー物件1.1億前後・月返済30万円以内）、"
        "築年は立地・管理を本質とし築30年程度まで許容（長期修繕計画・総会議事録・修繕積立金の確認必須）。"
    )
    lines.append("")
    lines.append("## データソースの優先順位")
    lines.append("")
    lines.append("1. **Supabase `buyer_profiles` / `ai_prompts`** — 実運用の正（Routine / iOS が参照）")
    lines.append("2. **`scraping-tool/config/buyer_profile.json` / `investment_strategy_prompt.md`** — リポジトリ正準（Supabase 不通時フォールバック＆反映元）")
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


AI_PROMPT_NOTES = (
    "2026/6/8 仲介MTG反映: 予算二段構え（探索1.3億/実質1.1億・月返済30万）"
    "・築年緩和（築30年許容/管理重視）・値下げ待ち交渉"
)


def generate_ai_prompts_sql() -> str:
    system_prompt = load_strategy_prompt()
    sys_q = _dollar_quote(system_prompt, "strategy_v2")
    tpl_q = _dollar_quote(USER_PROMPT_TEMPLATE, "tpl_v2")
    notes_q = _dollar_quote(AI_PROMPT_NOTES, "notes_v2")
    return (
        "-- 自動生成: scripts/generate_buyer_context.py --write\n"
        f"-- ai_prompts module={AI_PROMPT_MODULE} を version={AI_PROMPT_VERSION} として投入し、旧versionを無効化する。\n"
        "-- prompt_hash はトリガー ai_prompts_compute_hash が自動計算する。\n"
        "-- 注意: 本文変更により全 enrichment が再分析対象になる（get_listings_for_ai の ai_prompt_hash 比較）。\n"
        "-- max_items_per_run でバッチ制御される。必ずトランザクション内で INSERT→UPDATE の順に実行する。\n"
        "BEGIN;\n"
        "INSERT INTO ai_prompts (module, version, is_active, system_prompt, user_prompt_template, output_schema, config, notes)\n"
        "VALUES (\n"
        f"  '{AI_PROMPT_MODULE}', {AI_PROMPT_VERSION}, true,\n"
        f"  {sys_q},\n"
        f"  {tpl_q},\n"
        f"  '{OUTPUT_SCHEMA}'::jsonb,\n"
        f"  '{AI_PROMPT_CONFIG}'::jsonb,\n"
        f"  {notes_q}\n"
        ");\n"
        f"UPDATE ai_prompts SET is_active = false WHERE module = '{AI_PROMPT_MODULE}' AND version <> {AI_PROMPT_VERSION};\n"
        "COMMIT;\n"
    )


# ─────────────────────── write / check ───────────────────────
def _targets() -> list[tuple[Path, str]]:
    return [
        (DOC_PATH, generate_buyer_profile_md()),
        (BUYER_PROFILES_SQL_PATH, generate_buyer_profiles_sql()),
        (AI_PROMPTS_SQL_PATH, generate_ai_prompts_sql()),
    ]


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
