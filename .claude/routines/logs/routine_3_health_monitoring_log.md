2026-05-20 15:00 JST - ルーティン③ 実行ログ
Step 1: エンリッチメントカバレッジ（全10項目中0項目基準未満）
フィールド	カバレッジ	基準	判定
listing_score	99.02%	70%	✅
ai_recommendation_score	66.48%	50%	✅
commute_info	99.86%	60%	✅
hazard_info	51.96%	35%	✅
price_fairness_score	38.83%	20%	✅
ai_listing_score	38.97%	10%	✅
ai_price_fairness_score	38.97%	10%	✅
extracted_features	92.32%	30%	✅
image_categories	59.78%	30%	✅
ss_lookup_status	59.50%	30%	✅
Step 2: パイプライン鮮度
new_listings_24h: 22件 ✅
ai_analyzed_24h: 238件 ✅
stale_ai_7d: 0件 ✅
never_ai_analyzed: 105件 ⚠️
no_enrichment_48h: 0件 ✅
Step 3: データ品質
score_mismatch_ls_no_ai: 239件 ⚠️
images_no_categories: 0件 ✅
duplicate_active: 0件 ✅
Step 4: アノマリ検出
active_count_drop: 716件 ✅
score_contradiction: 0件 ✅
Step 5: health_check_logs 保存
ID: 9、alert_count: 2
Step 6: pipeline_issues
upsert: never_ai_analyzed, score_mismatch
自動解決: 0件
Step 7: notification_drafts
pipeline_health_report = pending（ID: 43）