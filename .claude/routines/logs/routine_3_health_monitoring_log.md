## 2026-05-19 05:00 JST - ルーティン③ 実行ログ

### Step 1: エンリッチメントカバレッジ（全10項目 ✅）

| フィールド | カバレッジ | 基準 | 判定 |
|---|---|---|---|
| listing_score | 98.60% | 70% | ✅ |
| ai_recommendation_score | 65.41% | 50% | ✅ |
| commute_info | 99.86% | 60% | ✅ |
| hazard_info | 51.12% | 35% | ✅ |
| price_fairness_score | 43.56% | 20% | ✅ |
| ai_listing_score | 38.94% | 10% | ✅ |
| ai_price_fairness_score | 38.94% | 10% | ✅ |
| extracted_features | 92.44% | 30% | ✅ |
| image_categories | 58.82% | 30% | ✅ |
| ss_lookup_status | 59.52% | 30% | ✅ |

### Step 2: パイプライン鮮度
- new_listings_24h: 29件 ✅
- ai_analyzed_24h: 201件 ✅
- stale_ai_7d: 0件 ✅
- never_ai_analyzed: 114件 ⚠️
- no_enrichment_48h: 0件 ✅

### Step 3: データ品質
- score_mismatch_ls_no_ai: 246件 ⚠️
- images_no_categories: 0件 ✅
- duplicate_active: 0件 ✅

### Step 4: アノマリ検出
- active_count_drop: 714件（is_alert=false） ✅
- score_contradiction: 0件 ✅

### Step 5: health_check_logs 保存
- ID: 8、alert_count: 2

### Step 6: pipeline_issues
- upsert: never_ai_analyzed(high)、score_mismatch(medium)、log_files_large(low)
- 自動解決: 1件

### Step 7: notification_drafts
- pipeline_health_report = pending（ID: 36、open 3件）

### Step 8: ログローテーション
- routine_1: 1171→200行
- routine_2: 628→199行
- routine_3: 277→200行
