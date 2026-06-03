-- 全テーブルの主要カラムにCOMMENTを付与
-- AIがスキーマ取得時に各フィールドの意味を自動理解するため

-- ============================================================
-- listings
-- ============================================================
COMMENT ON TABLE listings IS '物件基本情報。不動産ポータル（SUUMO/HOMES等）からスクレイピングした中古・新築マンションデータ';

COMMENT ON COLUMN listings.identity_key IS '物件一意キー。マンション名+間取り+面積+住所+築年のハッシュ';
COMMENT ON COLUMN listings.name IS 'マンション名（広告装飾を除去済み）';
COMMENT ON COLUMN listings.normalized_name IS '正規化マンション名（同一建物の別部屋を判定するため棟名・階数を除去）';
COMMENT ON COLUMN listings.address IS '住所（区名レベル。例：東京都墨田区太平4丁目）';
COMMENT ON COLUMN listings.ss_address IS '住まいサーフィンから取得した番地レベルの詳細住所';
COMMENT ON COLUMN listings.layout IS '間取り（例：3LDK, 2LDK+S）';
COMMENT ON COLUMN listings.area_m2 IS '専有面積（㎡、壁芯）';
COMMENT ON COLUMN listings.area_max_m2 IS '専有面積上限（㎡）。新築物件で面積レンジがある場合のみ';
COMMENT ON COLUMN listings.built_year IS '築年（西暦）';
COMMENT ON COLUMN listings.built_str IS '築年月の元テキスト（例：2015年3月）';
COMMENT ON COLUMN listings.station_line IS '最寄り駅情報（例：JR総武線「錦糸町」徒歩5分）';
COMMENT ON COLUMN listings.walk_min IS '最寄り駅徒歩分数';
COMMENT ON COLUMN listings.total_units IS 'マンション総戸数。100戸以上は大規模で流動性が高い傾向';
COMMENT ON COLUMN listings.floor_position IS '所在階';
COMMENT ON COLUMN listings.floor_total IS '建物総階数';
COMMENT ON COLUMN listings.floor_structure IS '構造（RC=鉄筋コンクリート, SRC=鉄骨鉄筋コンクリート等）';
COMMENT ON COLUMN listings.ownership IS '土地権利（所有権 or 借地権）。所有権が資産性で有利';
COMMENT ON COLUMN listings.management_fee IS '管理費（円/月）';
COMMENT ON COLUMN listings.repair_reserve_fund IS '修繕積立金（円/月）';
COMMENT ON COLUMN listings.repair_fund_onetime IS '修繕積立基金（円）。購入時一時金';
COMMENT ON COLUMN listings.direction IS '向き/方角（例：南, 北西）';
COMMENT ON COLUMN listings.balcony_area_m2 IS 'バルコニー面積（㎡）';
COMMENT ON COLUMN listings.parking IS '駐車場情報（例：空有 月額20,000円〜25,000円）';
COMMENT ON COLUMN listings.constructor IS '施工会社（例：大林組）';
COMMENT ON COLUMN listings.zoning IS '用途地域（例：商業地域）';
COMMENT ON COLUMN listings.property_type IS '物件種別。chuko=中古マンション, shinchiku=新築マンション';
COMMENT ON COLUMN listings.developer_name IS 'デベロッパー（売主）';
COMMENT ON COLUMN listings.developer_brokerage IS '仲介会社';
COMMENT ON COLUMN listings.list_ward_roman IS '区名ローマ字（フィルター用。例：sumida）';
COMMENT ON COLUMN listings.delivery_date IS '引渡予定日';
COMMENT ON COLUMN listings.duplicate_count IS '同一マンション内で検出された掲載部屋数';
COMMENT ON COLUMN listings.latitude IS '緯度（ジオコーディング済み）';
COMMENT ON COLUMN listings.longitude IS '経度（ジオコーディング済み）';
COMMENT ON COLUMN listings.feature_tags IS '物件特徴タグ配列（JSONB。例：["駅徒歩5分以内","2沿線以上利用可"]）';
COMMENT ON COLUMN listings.is_active IS '掲載中ならtrue。ポータルサイトから消えた物件はfalse';
COMMENT ON COLUMN listings.is_new IS '直近のスクレイピングで初めて検出された新着物件';
COMMENT ON COLUMN listings.is_new_building IS '新築マンション（shinchiku）フラグ';
COMMENT ON COLUMN listings.first_seen_at IS '最初に検出された日時';
COMMENT ON COLUMN listings.first_seen_source IS '最初に検出されたソース（suumo, homes等）';
COMMENT ON COLUMN listings.geocode_confidence IS 'ジオコード精度（high/medium/low）';
COMMENT ON COLUMN listings.geocode_fixed IS 'ジオコードを手動修正済みならtrue';
COMMENT ON COLUMN listings.alt_urls IS '代替URL群（JSONB）';

-- ============================================================
-- listing_sources
-- ============================================================
COMMENT ON TABLE listing_sources IS '物件×ソース紐付け。同一物件の複数ポータル掲載情報';

COMMENT ON COLUMN listing_sources.listing_id IS '紐付く物件のID（listings.id）';
COMMENT ON COLUMN listing_sources.source IS 'ソース名（suumo, homes, athome, nomucom, rehouse, stepon, livable）';
COMMENT ON COLUMN listing_sources.url IS '物件掲載ページURL';
COMMENT ON COLUMN listing_sources.price_man IS '掲載価格（万円）';
COMMENT ON COLUMN listing_sources.price_max_man IS '価格上限（万円）。新築で価格帯がある場合';
COMMENT ON COLUMN listing_sources.management_fee IS 'ソース別管理費（円/月）';
COMMENT ON COLUMN listing_sources.repair_reserve_fund IS 'ソース別修繕積立金（円/月）';
COMMENT ON COLUMN listing_sources.listing_agent IS '掲載不動産会社名';
COMMENT ON COLUMN listing_sources.is_motodzuke IS '売主直販（元付）ならtrue。仲介手数料不要の可能性';
COMMENT ON COLUMN listing_sources.first_seen_at IS 'このソースで最初に検出された日時';
COMMENT ON COLUMN listing_sources.last_seen_at IS 'このソースで最後に検出された日時';
COMMENT ON COLUMN listing_sources.is_active IS 'このソースで現在掲載中ならtrue';
COMMENT ON COLUMN listing_sources.consecutive_misses IS '連続未検出回数（grace period判定用）';

-- ============================================================
-- enrichments（事実データ系のみ詳細コメント）
-- ============================================================
COMMENT ON TABLE enrichments IS '物件の外部データ・分析結果。第三者データ（通勤・災害・市場・人口）と自前分析を含む';

COMMENT ON COLUMN enrichments.listing_id IS '紐付く物件のID（listings.id）';
COMMENT ON COLUMN enrichments.commute_info IS '通勤時間情報（JSONB）。{勤務先名: {minutes, summary, source}}。Google Maps/駅マスター計測値';
COMMENT ON COLUMN enrichments.commute_info_v2 IS '通勤時間v2（JSONB）。複数通勤先対応版';
COMMENT ON COLUMN enrichments.hazard_info IS 'ハザードマップ情報（JSONB）。{flood, sediment, storm_surge, tsunami, liquefaction, building_collapse, fire, combined}。国土地理院+東京都データ';
COMMENT ON COLUMN enrichments.reinfolib_market_data IS '不動産情報ライブラリ市場データ（JSONB）。国交省の成約統計。{ward_median_m2_price, sample_count, price_ratio, quarterly_m2_prices[], same_building_transactions[]}';
COMMENT ON COLUMN enrichments.mansion_review_data IS 'マンションレビューサイト評価（JSONB）。住民による管理・建物・共用部の5点満点評価';
COMMENT ON COLUMN enrichments.estat_population_data IS 'e-Stat人口動態統計（JSONB）。{latest_population, pop_change_1yr_pct, pop_change_5yr_pct, latest_aging_rate, population_history[]}';

-- 住まいサーフィン
COMMENT ON COLUMN enrichments.ss_lookup_status IS '住まいサーフィンデータ取得状態（found/not_found/parse_failed）';
COMMENT ON COLUMN enrichments.ss_profit_pct IS '儲かる確率（%）。住まいサーフィン算出';
COMMENT ON COLUMN enrichments.ss_oki_price_70m2 IS '沖式時価（70㎡換算、万円）。住まいサーフィン独自の適正価格指標';
COMMENT ON COLUMN enrichments.ss_m2_discount IS '㎡単価ディスカウント率。マイナスが割安方向';
COMMENT ON COLUMN enrichments.ss_value_judgment IS '住まいサーフィンの価値判断（割安/やや割安/適正/やや割高/割高）';
COMMENT ON COLUMN enrichments.ss_station_rank IS '駅内ランキング（住まいサーフィン）';
COMMENT ON COLUMN enrichments.ss_ward_rank IS '区内ランキング（住まいサーフィン）';
COMMENT ON COLUMN enrichments.ss_sumai_surfin_url IS '住まいサーフィンの物件ページURL';
COMMENT ON COLUMN enrichments.ss_appreciation_rate IS '値上がり率（%）。住まいサーフィン予測';
COMMENT ON COLUMN enrichments.ss_favorite_count IS '住まいサーフィンでのお気に入り登録数。人気の指標';
COMMENT ON COLUMN enrichments.ss_purchase_judgment IS '住まいサーフィンの購入判断文言';
COMMENT ON COLUMN enrichments.ss_radar_data IS 'レーダーチャートデータ（JSONB）。5軸評価スコア（0-100）';
COMMENT ON COLUMN enrichments.ss_past_market_trends IS '過去の市場動向（JSONB配列）。[{period, price_man, area_m2, unit_price_man}]';
COMMENT ON COLUMN enrichments.ss_surrounding_properties IS '周辺比較物件（JSONB配列）。[{name, url, appreciation_rate, oki_price_70m2}]';
COMMENT ON COLUMN enrichments.ss_price_judgments IS '階段別価格判定（JSONB配列）。[{unit, judgment}]';
COMMENT ON COLUMN enrichments.ss_sim_best_5yr IS '5年後売却シミュレーション楽観（万円）。住まいサーフィン算出';
COMMENT ON COLUMN enrichments.ss_sim_best_10yr IS '10年後売却シミュレーション楽観（万円）';
COMMENT ON COLUMN enrichments.ss_sim_standard_5yr IS '5年後売却シミュレーション標準（万円）';
COMMENT ON COLUMN enrichments.ss_sim_standard_10yr IS '10年後売却シミュレーション標準（万円）';
COMMENT ON COLUMN enrichments.ss_sim_worst_5yr IS '5年後売却シミュレーション悲観（万円）';
COMMENT ON COLUMN enrichments.ss_sim_worst_10yr IS '10年後売却シミュレーション悲観（万円）';
COMMENT ON COLUMN enrichments.ss_loan_balance_5yr IS '5年後ローン残債予測（万円）';
COMMENT ON COLUMN enrichments.ss_loan_balance_10yr IS '10年後ローン残債予測（万円）';
COMMENT ON COLUMN enrichments.ss_sim_base_price IS 'シミュレーション基準価格（万円）';
COMMENT ON COLUMN enrichments.ss_new_m2_price IS '新築㎡単価（万円/㎡）';
COMMENT ON COLUMN enrichments.ss_forecast_m2_price IS '予測㎡単価（万円/㎡）';
COMMENT ON COLUMN enrichments.ss_forecast_change_rate IS '予測変化率（%）';

-- 画像
COMMENT ON COLUMN enrichments.floor_plan_images IS '間取り図画像URL配列（JSONB）';
COMMENT ON COLUMN enrichments.suumo_images IS 'SUUMO物件写真（JSONB）。カテゴリ付き';

-- 自前分析（除外対象だがコメントは付ける）
COMMENT ON COLUMN enrichments.price_fairness_score IS '[自前分析] 掲載価格妥当性スコア（0-100。50=適正、50超=割安）';
COMMENT ON COLUMN enrichments.resale_liquidity_score IS '[自前分析] 再販流動性スコア（0-100。高い=売りやすい）';
COMMENT ON COLUMN enrichments.listing_score IS '[自前分析] 総合投資スコア（0-100）';
COMMENT ON COLUMN enrichments.competing_listings_count IS '[自前分析] 同一棟内の競合掲載数';
COMMENT ON COLUMN enrichments.is_cheapest_in_building IS '[自前分析] 棟内最安値フラグ';
COMMENT ON COLUMN enrichments.competing_price_range IS '[自前分析] 競合の価格帯';
COMMENT ON COLUMN enrichments.ai_recommendation_score IS '[自前分析] AI購入推奨度（1-5。5=強く推奨）';
COMMENT ON COLUMN enrichments.ai_recommendation_summary IS '[自前分析] AI判断の結論（1-2文）';
COMMENT ON COLUMN enrichments.ai_recommendation_flags IS '[自前分析] 判断キータグ配列（JSONB。例：["立地◎","資産性堅い"]）';
COMMENT ON COLUMN enrichments.ai_recommendation_action IS '[自前分析] 具体的な次のアクション';
COMMENT ON COLUMN enrichments.ai_recommendation_scenarios IS '[自前分析] ライフシナリオ別適合分析（JSONB配列）';
COMMENT ON COLUMN enrichments.investment_summary IS '[自前分析] 投資判断サマリー';
COMMENT ON COLUMN enrichments.highlight_badge IS '[自前分析] UI用バッジ（例：★★★★☆）';
COMMENT ON COLUMN enrichments.key_strengths IS '[自前分析] 主な強み（JSONB配列）';
COMMENT ON COLUMN enrichments.key_risks IS '[自前分析] 主なリスク（JSONB配列）';
COMMENT ON COLUMN enrichments.extracted_features IS '[自前分析] AI抽出した物件特徴（JSONB）';
COMMENT ON COLUMN enrichments.image_categories IS '[自前分析] AI分類した画像カテゴリ（JSONB）';
COMMENT ON COLUMN enrichments.near_miss IS 'ニアミス物件フラグ。検索条件にあと少しで合う物件';
COMMENT ON COLUMN enrichments.near_miss_reasons IS 'ニアミス理由テキスト';

-- ============================================================
-- price_history
-- ============================================================
COMMENT ON TABLE price_history IS '物件の掲載価格変動履歴';

COMMENT ON COLUMN price_history.listing_id IS '紐付く物件のID';
COMMENT ON COLUMN price_history.source IS '価格を検出したソース';
COMMENT ON COLUMN price_history.price_man IS '掲載価格（万円）';
COMMENT ON COLUMN price_history.recorded_at IS '価格が記録された日時';

-- ============================================================
-- listing_events
-- ============================================================
COMMENT ON TABLE listing_events IS '物件のライフサイクルイベント（新規掲載・価格変動・削除・再掲載）';

COMMENT ON COLUMN listing_events.listing_id IS '紐付く物件のID';
COMMENT ON COLUMN listing_events.source IS 'イベント検出元ソース';
COMMENT ON COLUMN listing_events.event_type IS 'イベント種別（appeared/price_changed/removed/reappeared）';
COMMENT ON COLUMN listing_events.old_value IS '変更前の値（price_changedの場合は旧価格）';
COMMENT ON COLUMN listing_events.new_value IS '変更後の値（price_changedの場合は新価格）';
COMMENT ON COLUMN listing_events.occurred_at IS 'イベント発生日時';

-- ============================================================
-- buyer_profiles
-- ============================================================
COMMENT ON TABLE buyer_profiles IS '買い手プロフィール。物件分析の前提条件としてAI（パイプライン・ChatGPT・Claude）が参照する';

COMMENT ON COLUMN buyer_profiles.user_id IS 'Firebase Auth UID';
COMMENT ON COLUMN buyer_profiles.family_composition IS '家族構成（例：夫1997年生・妻1996年生、子どもなし）';
COMMENT ON COLUMN buyer_profiles.household_income IS '世帯年収（例：（金額））';
COMMENT ON COLUMN buyer_profiles.work_style IS '働き方（例：夫は基本出社、妻は週1リモート）';
COMMENT ON COLUMN buyer_profiles.child_plan IS '子ども計画（例：今年1人目予定、3人計画）';
COMMENT ON COLUMN buyer_profiles.priorities IS '物件選びで重視する点（優先順位付き）';
COMMENT ON COLUMN buyer_profiles.current_housing IS '現在の住居形態（賃貸/持ち家等）';
COMMENT ON COLUMN buyer_profiles.neighborhood_preference IS '街の雰囲気の好み';
COMMENT ON COLUMN buyer_profiles.school_priority IS '学区・教育方針';
COMMENT ON COLUMN buyer_profiles.commute_quality IS '通勤の質の重視点';
COMMENT ON COLUMN buyer_profiles.weekend_lifestyle IS '休日の過ごし方';
COMMENT ON COLUMN buyer_profiles.community_preference IS 'コミュニティ希望';
COMMENT ON COLUMN buyer_profiles.deal_breakers IS '絶対NG条件';
COMMENT ON COLUMN buyer_profiles.self_funds IS '自己資金';
COMMENT ON COLUMN buyer_profiles.planned_borrowing IS '借入予定額';
COMMENT ON COLUMN buyer_profiles.interest_type IS '金利タイプ（変動/固定/ミックス）';
COMMENT ON COLUMN buyer_profiles.estimated_rate IS '想定金利（例：0.8〜0.9%）';
COMMENT ON COLUMN buyer_profiles.repayment_years IS '返済期間（例：50年）';
COMMENT ON COLUMN buyer_profiles.monthly_payment_limit IS '月額の無理ない上限（管理費込み）';
COMMENT ON COLUMN buyer_profiles.relocation_reason IS '住み替え理由';
COMMENT ON COLUMN buyer_profiles.post_sale_strategy IS '売却後の方針（売却前提/賃貸転用も許容）';
COMMENT ON COLUMN buyer_profiles.timeline IS '購入時期目安（例：1年以内）';
COMMENT ON COLUMN buyer_profiles.risk_tolerance IS 'リスク許容度（保守的/中程度/積極的）';
COMMENT ON COLUMN buyer_profiles.life_scenarios IS 'ライフシナリオ配列（JSONB）。[{name, description, housing_needs}]';
COMMENT ON COLUMN buyer_profiles.budget_scenarios IS '予算シナリオ配列（JSONB）。[{name, interest_rate, monthly_payment, feasible}]';
COMMENT ON COLUMN buyer_profiles.preferred_areas IS '希望エリア配列（JSONB）。例：["墨田区","江東区"]';
COMMENT ON COLUMN buyer_profiles.must_have_features IS '必須設備配列（JSONB）。例：["宅配ボックス","浴室乾燥機"]';

-- ============================================================
-- transactions
-- ============================================================
COMMENT ON TABLE transactions IS '不動産取引実績（国交省 不動産情報ライブラリ）。成約相場の参考データ';

COMMENT ON COLUMN transactions.price_man IS '成約価格（万円）';
COMMENT ON COLUMN transactions.area_m2 IS '専有面積（㎡）';
COMMENT ON COLUMN transactions.m2_price IS '㎡単価（万円/㎡）';
COMMENT ON COLUMN transactions.trade_period IS '取引時期（例：2025Q3）';
COMMENT ON COLUMN transactions.nearest_station IS '最寄り駅';
COMMENT ON COLUMN transactions.estimated_walk_min IS '推定徒歩分数';
