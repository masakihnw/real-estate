-- 033: 軽量ビュー listings_feed_light + 詳細取得 RPC
--
-- 背景: listings_feed の重い JSONB カラムと相関サブクエリ (price_history_json,
-- alt_sources_json) がタイムアウトの原因。iOS アプリのリスト/マップ表示には
-- コアフィールドとスカラー enrichment のみ必要。
--
-- 方針:
--   1. listings_feed_light: コアフィールド + スカラー enrichment (JSONB 除外)
--   2. get_listings_since_light: 差分同期用 (light 版)
--   3. get_listing_detail: 個別物件の全 enrichment 取得 (lazy load 用)
-- 既存の listings_feed / get_listings_since は他モジュール (AI pipeline 等) が
-- 使用するため変更しない。

-- ============================================================
-- 1. listings_feed_light ビュー
-- ============================================================
CREATE VIEW listings_feed_light AS
SELECT
    l.id,
    l.identity_key,
    l.name,
    l.normalized_name,
    l.address,
    l.ss_address,
    l.layout,
    l.area_m2,
    l.area_max_m2,
    l.built_year,
    l.built_str,
    l.station_line,
    l.walk_min,
    l.total_units,
    l.floor_position,
    l.floor_total,
    l.floor_structure,
    l.ownership,
    l.management_fee,
    l.repair_reserve_fund,
    l.repair_fund_onetime,
    l.direction,
    l.balcony_area_m2,
    l.parking,
    l.constructor,
    l.zoning,
    l.property_type,
    l.developer_name,
    l.developer_brokerage,
    l.list_ward_roman,
    l.delivery_date,
    l.duplicate_count,
    l.latitude,
    l.longitude,
    l.feature_tags,
    l.is_active,
    l.is_new,
    l.is_new_building,
    l.first_seen_at,
    l.first_seen_source,
    l.geocode_confidence,
    l.geocode_fixed,
    l.alt_urls,
    l.created_at,
    l.updated_at,
    -- listing_sources (最新のアクティブソース)
    ls.source,
    ls.url,
    ls.price_man,
    ls.price_max_man,
    ls.listing_agent,
    ls.is_motodzuke,
    -- enrichments: スカラー値のみ (大きな JSONB は除外)
    e.ss_lookup_status,
    e.ss_profit_pct,
    e.ss_oki_price_70m2,
    e.ss_m2_discount,
    e.ss_value_judgment,
    e.ss_station_rank,
    e.ss_ward_rank,
    e.ss_sumai_surfin_url,
    e.ss_appreciation_rate,
    e.ss_favorite_count,
    e.ss_purchase_judgment,
    e.ss_sim_best_5yr,
    e.ss_sim_best_10yr,
    e.ss_sim_standard_5yr,
    e.ss_sim_standard_10yr,
    e.ss_sim_worst_5yr,
    e.ss_sim_worst_10yr,
    e.ss_loan_balance_5yr,
    e.ss_loan_balance_10yr,
    e.ss_sim_base_price,
    e.ss_new_m2_price,
    e.ss_forecast_m2_price,
    e.ss_forecast_change_rate,
    e.price_fairness_score,
    e.resale_liquidity_score,
    e.competing_listings_count,
    e.listing_score,
    e.ai_recommendation_score,
    e.highlight_badge,
    e.best_thumbnail_url,
    e.dedup_confidence,
    e.key_strengths,
    e.key_risks,
    e.is_cheapest_in_building,
    e.competing_price_range,
    e.near_miss,
    e.near_miss_reasons
    -- 以下は除外（タイムアウトの主因）:
    --   ss_radar_data, ss_past_market_trends, ss_surrounding_properties, ss_price_judgments,
    --   hazard_info, commute_info, commute_info_v2,
    --   reinfolib_market_data, mansion_review_data, estat_population_data,
    --   investment_summary, extracted_features, image_categories, dedup_candidates,
    --   floor_plan_images, suumo_images, alt_sources,
    --   ai_recommendation_summary, ai_recommendation_flags, ai_recommendation_action,
    --   ai_recommendation_scenarios,
    --   alt_sources_json (相関サブクエリ), price_history_json (相関サブクエリ)
FROM listings l
LEFT JOIN LATERAL (
    SELECT * FROM listing_sources s
    WHERE s.listing_id = l.id AND s.is_active
    ORDER BY s.last_seen_at DESC LIMIT 1
) ls ON TRUE
LEFT JOIN enrichments e ON e.listing_id = l.id;

-- ============================================================
-- 2. get_listings_since_light: 差分同期用
-- ============================================================
CREATE OR REPLACE FUNCTION get_listings_since_light(since_ts TIMESTAMPTZ)
RETURNS SETOF listings_feed_light AS $$
    SELECT * FROM listings_feed_light WHERE updated_at > since_ts;
$$ LANGUAGE sql;

-- ============================================================
-- 3. get_listing_detail: 個別物件の全データ取得
--    listings_feed (フル) を 1 行だけ返す。
--    単一行なので price_history / alt_sources のサブクエリも高速。
-- ============================================================
CREATE OR REPLACE FUNCTION get_listing_detail(p_identity_key TEXT)
RETURNS SETOF listings_feed AS $$
    SELECT * FROM listings_feed WHERE identity_key = p_identity_key LIMIT 1;
$$ LANGUAGE sql;

-- ============================================================
-- 4. statement_timeout (Supabase REST 経由のクエリに安全網)
-- ============================================================
-- 既存ビュー (listings_feed) を使う get_listings_since にタイムアウトを設定。
-- Light 版は高速なので不要だが、フル版が AI pipeline 等で使われる場合の保護。
ALTER FUNCTION get_listings_since(TIMESTAMPTZ) SET statement_timeout = '60s';
ALTER FUNCTION get_listing_detail(TEXT) SET statement_timeout = '30s';
ALTER FUNCTION get_listings_since_light(TIMESTAMPTZ) SET statement_timeout = '30s';
