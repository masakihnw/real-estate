# HOME'S 画像未取得問題 — 調査結果と対策案

## 1. 問題概要

iOSアプリで画像が表示されない物件が多数存在する。原因調査の結果、**HOME'S（LIFULL HOME'S）媒体の物件で画像がほぼ取得できていない**ことが判明。

---

## 2. 現状データ（Supabase `listing_facts` テーブル、2026-06-03時点）

### 2a. 媒体別画像カバレッジ（アクティブ物件のみ）

| 媒体 | 物件数 | 画像あり | 画像率 | 間取り率 | 平均画像枚数 |
|------|--------|---------|--------|---------|------------|
| suumo | 388 | 374 | **96.4%** | 96.4% | 23.8枚 |
| homes | 241 | 2 | **0.8%** | 0.8% | 31.5枚(※2件のみ) |
| rehouse | 81 | 81 | **100%** | 100% | 8.8枚 |
| nomucom | 72 | 72 | **100%** | 95.8% | 23.4枚 |
| livable | 50 | 50 | **100%** | 100% | 30.3枚 |

### 2b. 補足データ

- homes の241件は**全て homes 単独掲載**（他媒体との重複ゼロ）→ 他媒体から画像補完不可
- suumo の画像なし14件: マイグレーション初期データ（first_seen_source=null）や古い物件が中心
- 画像なし物件の first_seen_source 分布: homes=226件, null=18件, suumo=9件

---

## 3. 根本原因分析

### 3a. コードレベルの問題

**homes_scraper.py:**
- `HomesListing` dataclass に `suumo_images` / `floor_plan_images` フィールドが存在しない
- 一覧ページからテキスト情報（名前、価格、住所、面積等）のみ取得
- 画像抽出ロジックが一切ない

**floor_plan_enricher.py:**
- homes 詳細ページを訪問して**間取り図（floor_plan_images）のみ**抽出
- 物件写真（suumo_images = 外観・内装・眺望等）は非対応
- ただし HTML取得・WAFハンドリング・キャッシュ機構は完備

**main.py → `_scrape_homes_chuko()`:**
- スクレイピング後にエンリッチメント関数を呼んでいない
- 他の全媒体は `enrich_*_listings()` で詳細ページから画像を取得している

### 3b. 他媒体との比較

| 媒体 | 一覧で画像取得 | 詳細ページenrich | 画像抽出関数 |
|------|--------------|-----------------|------------|
| suumo | ✅ `_extract_images()` | ✅ detail cache 経由 | 一覧+詳細 |
| athome | ✅ `_extract_athome_detail_images()` | ✅ `enrich_athome_listings()` | 詳細ページ |
| rehouse | — | ✅ `enrich_rehouse_listings()` | 詳細ページ |
| nomucom | — | ✅ `enrich_nomucom_listings()` | 詳細ページ |
| livable | — | ✅ `enrich_livable_listings()` | 詳細ページ |
| **homes** | **❌ なし** | **❌ floor_plan のみ** | **❌ 物件写真なし** |

### 3c. なぜ floor_plan_enricher.py だけでは不十分か

`floor_plan_enricher.py` は HOME'S 詳細ページの HTML を取得しているが:
- `parse_homes_floor_plan_images()` は間取り図のみ抽出（alt="間取" / floorplan セクション等）
- 物件写真（外観、内装、リビング、キッチン、バス、眺望等）を無視している
- DB への書き込みも `floor_plan_images` フィールドのみ

---

## 4. 対策案

### 案A: floor_plan_enricher.py を拡張（推奨）

既存の `floor_plan_enricher.py` を拡張して、間取り図に加えて物件写真も抽出する。

**メリット:**
- HTML取得・WAFハンドリング・キャッシュ機構を再利用（既にHOME'S詳細ページのHTMLキャッシュあり）
- 1回の詳細ページ訪問で間取り図+物件写真を同時取得（追加リクエスト不要）
- 変更箇所が少ない

**実装内容:**
1. `parse_homes_property_images(html)` 関数を新規作成
   - HOME'S 詳細ページの物件写真ギャラリーから画像URL+ラベルを抽出
   - 間取り図は除外（floor_plan_enricher が別途処理）
   - サイトUI画像（ロゴ、ボタン、アイコン等）をフィルタリング
2. `main()` を拡張: `suumo_images` も同時に取得・書き込み
3. `enrichment_writer.write_enrichments()` に `suumo_images` を追加

**想定工数:** 中（既存コードの拡張）

### 案B: homes_scraper.py に enrich_homes_listings() を追加

他媒体と同じパターンで、homes_scraper.py 内に `enrich_homes_listings()` を追加し、main.py から呼ぶ。

**メリット:**
- 他媒体と統一されたアーキテクチャ
- main.py のパイプラインフローが一貫する

**デメリット:**
- floor_plan_enricher.py の HTML キャッシュと重複する仕組みを作ることになる
- homes は WAF が厳しいため、一覧スクレイピング直後に詳細ページも叩くとレート制限リスクが高い
- Playwright が必要になる可能性（一覧ページは WAF で Playwright 必須だが、詳細ページは requests でも通る実績あり）

**想定工数:** 大（新規関数+キャッシュ機構+main.py 統合）

### 案C: floor_plan_enricher を homes_image_enricher にリネーム・全面拡張

floor_plan_enricher.py を `homes_image_enricher.py` にリネームし、間取り図+物件写真の両方を取得する汎用エンリッチャーにする。

**メリット:**
- 責務が明確になる（「HOME'S の画像全般」を担当）
- 将来的に homes 固有の画像処理を集約できる

**デメリット:**
- 既存の呼び出し元（パイプライン、ルーティン等）の変更が必要
- floor_plan_enricher という名前で参照している箇所を全て更新する必要あり

**想定工数:** 中〜大

---

## 5. 推奨: 案A（floor_plan_enricher.py 拡張）

### 理由
1. **最小変更で最大効果**: 既存のHTML取得・キャッシュ機構をそのまま活用
2. **追加リクエスト不要**: 既にキャッシュ済みのHTMLから物件写真を抽出するだけ
3. **WAFリスク低**: 新たなHTTPリクエストを増やさない
4. **即効性**: 既存キャッシュがあれば、再スクレイピングなしで画像を取得可能

### 実装ステップ
1. `parse_homes_property_images(html)` を実装（HOME'S 詳細ページの画像ギャラリー解析）
2. `floor_plan_enricher.py` の `main()` を拡張して `suumo_images` も処理
3. `enrichment_writer.py` で `suumo_images` を `listing_facts` に書き込み
4. 既存キャッシュで動作確認 → 新規取得物件でも確認
5. suumo の画像なし14件についても別途調査・対応

### 期待効果
- homes の画像率: 0.8% → 推定80%以上（詳細ページに画像ギャラリーがある前提）
- 全体の画像なし物件: 約253件 → 推定30件以下

---

## 6. suumo 画像なし物件（14件）について

| 件数 | 原因 | 対応 |
|------|------|------|
| 4件 | first_seen_source=null（マイグレーション初期） | 再スクレイピングで自然解消の見込み |
| 5件 | first_seen_source=suumo、created_at が古い | 詳細ページ再取得で解消可能 |
| 5件 | first_seen_source=suumo、最近作成 | 一覧ページで画像未取得の可能性、個別調査必要 |

優先度は homes 対応後で十分。
