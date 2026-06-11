# 買い手条件（AI 相談プロンプト用）

> **このファイルは自動生成です。手で編集しないこと。**
>
> 正準ソース（編集点）:
> - `scraping-tool/config/buyer_profile.json` … 買い手プロフィール（事実データ）
> - `scraping-tool/config/purchase_strategy.md` … 購入戦略（全AIモジュール共有）
> - `scraping-tool/config/prompts/<module>.md` … モジュール別タスク定義
>
> 再生成: `cd scraping-tool && python3 scripts/generate_buyer_context.py --write`
> 実運用データは Supabase（`buyer_profiles` / `ai_prompts`）。反映は `out/*.sql` を適用する。

## 基本プロフィール

| 項目 | 内容 |
|---|---|
| 家族構成 | 夫（YYYY年生まれ）・妻（YYYY年生まれ）、子ども○人 |
| 子ども計画 | 子ども計画の説明（人数・想定時期・教育方針など） |
| 世帯年収 | ○○○○万円 |
| 現在の住居 | 賃貸 / 持ち家 など |
| 自己資金 | ○○○万円（または「なし（フルローン）」） |
| 借入予定 | 借入方針の説明（例: 諸費用＋物件価格全額、ペア借入の有無など） |
| 金利タイプ | 変動 または 固定 |
| 想定金利 | ○.○% |
| 返済期間 | ○○年 |
| 月額上限 | 月返済・月総額の上限や制約条件の説明 |
| 働き方・通勤 | 夫：勤務形態 妻：勤務形態（勤務地は環境変数/Supabaseで管理） |
| 通勤の質 | 通勤に関する希望の説明 |
| 重視する点 | 優先順位（資産性・間取り・広さ・エリア等） |
| 住み替え理由 | 住み替え理由の説明 |
| 出口方針 | 売却前提 / 賃貸化 など |
| 購入時期 | 購入時期の目安 |
| リスク許容度 | リスク許容度の説明 |

## 予算シナリオ（二段構え）

| 区分 | 値 | 補足 |
|---|---|---|
| 探索上限 | ○.○億円 | 値下げ待ちでマークする上限（具体額は Supabase buyer_profiles が正） |
| 実質アンカー | ○.○億円前後 | 月返済上限以内で成立する安心圏 |
| 月返済上限 | ○○万円/月以内 | 金利1.5%想定。管理費・修繕積立金・固定資産税込みの総額制約は別途 |

## 戦略ポリシー（築年・価格判断）

AI分析の判断軸は `scraping-tool/config/purchase_strategy.md` が正準。予算は二段構え（探索上限／実質アンカー／月返済上限）で、具体額は上記の予算シナリオ（実値は Supabase `buyer_profiles` が正）を参照する。築年は立地・管理を本質とし築30年程度まで許容（長期修繕計画・総会議事録・修繕積立金の確認必須）。

## データソースの優先順位

1. **Supabase `buyer_profiles` / `ai_prompts`** — 実運用の正（Routine / iOS が参照）
2. **`scraping-tool/config/buyer_profile.json` / `purchase_strategy.md` / `prompts/*.md`** — リポジトリ正準（Supabase 不通時フォールバック＆反映元）
3. **`BuyerProfile.swift` preset** — iOS 新規インストール時のデフォルト（手動同期）
