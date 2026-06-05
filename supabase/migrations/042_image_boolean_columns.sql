-- 042: 画像有無の boolean カラム追加 + HOME'S バックフィル新着優先 RPC
--
-- 背景:
--   listings_feed_light に画像 JSONB を含められないため、iOS の pendingCount
--   （スワイプバッジ）が画像なし物件も含んでしまう問題を解決する。
--   enrichments テーブルに generated boolean カラムを追加し、
--   listings_feed_light に含めることで軽量かつ正確なフィルタを実現。
--
-- 変更:
--   1. enrichments に has_floor_plan_images / has_property_images generated column 追加
--   2. listings_feed_light ビューに boolean カラムを追加（DROP CASCADE → 再作成）
--   3. 依存 RPC を再作成
--   4. get_homes_no_images RPC を作成（新着優先 ORDER BY 付き）

-- ============================================================
-- 1. Generated boolean columns
-- ============================================================
ALTER TABLE enrichments
ADD COLUMN has_floor_plan_images BOOLEAN
    GENERATED ALWAYS AS (
        COALESCE(jsonb_array_length(floor_plan_images), 0) > 0
    ) STORED;

ALTER TABLE enrichments
ADD COLUMN has_property_images BOOLEAN
    GENERATED ALWAYS AS (
        COALESCE(jsonb_array_length(suumo_images), 0) > 0
    ) STORED;

-- ============================================================
-- 2. listings_feed_light ビュー再作成
-- ============================================================
DROP VIEW IF EXISTS listings_feed_light CASCADE;

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
    ls.source,
    ls.url,
    ls.price_man,
    ls.price_max_man,
    ls.listing_agent,
    ls.is_motodzuke,
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
    e.asset_grade,
    e.ai_scoring_reasoning,
    e.ai_recommendation_score,
    e.ai_recommendation_summary,
    e.ai_recommendation_flags,
    e.ai_recommendation_action,
    e.highlight_badge,
    e.best_thumbnail_url,
    e.dedup_confidence,
    e.key_strengths,
    e.key_risks,
    e.is_cheapest_in_building,
    e.competing_price_range,
    e.near_miss,
    e.near_miss_reasons,
    -- 画像有無フラグ（軽量ビューで pendingCount フィルタに使用）
    COALESCE(e.has_floor_plan_images, false) AS has_floor_plan_images,
    COALESCE(e.has_property_images, false) AS has_property_images
FROM listings l
LEFT JOIN LATERAL (
    SELECT * FROM listing_sources s
    WHERE s.listing_id = l.id AND s.is_active
    ORDER BY s.last_seen_at DESC LIMIT 1
) ls ON TRUE
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE NOT l.spec_excluded
  AND ls.price_man IS NOT NULL;

-- ============================================================
-- 3. 依存 RPC を再作成（040 と同一 + statement_timeout）
-- ============================================================
CREATE OR REPLACE FUNCTION get_listings_since_light(since_ts TIMESTAMPTZ)
RETURNS SETOF listings_feed_light AS $$
    SELECT * FROM listings_feed_light WHERE updated_at > since_ts;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

ALTER FUNCTION get_listings_since_light(TIMESTAMPTZ) SET statement_timeout = '30s';

CREATE OR REPLACE FUNCTION get_liked_inactive_listings()
RETURNS SETOF listings_feed_light AS $$
  SELECT lf.*
  FROM listings_feed_light lf
  JOIN user_building_preferences ubp
    ON lf.identity_key LIKE ubp.identity_key || '|%'
  WHERE lf.is_active = false
    AND ubp.preference = 'like';
$$ LANGUAGE sql SECURITY DEFINER STABLE;

ALTER FUNCTION get_liked_inactive_listings() SET statement_timeout = '30s';

CREATE OR REPLACE FUNCTION get_liked_inactive_listings(p_listing_ids BIGINT[])
RETURNS SETOF listings_feed_light AS $$
  SELECT lf.* FROM listings_feed_light lf
  WHERE lf.id = ANY(p_listing_ids) AND lf.is_active = false;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ============================================================
-- 4. get_homes_no_images RPC（新着優先 ORDER BY 付き）
-- ============================================================
CREATE OR REPLACE FUNCTION get_homes_no_images()
RETURNS TABLE(id BIGINT, url TEXT) AS $$
    SELECT l.id, ls.url
    FROM listings l
    JOIN listing_sources ls
        ON ls.listing_id = l.id AND ls.is_active AND ls.source = 'homes'
    LEFT JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active
      AND NOT l.spec_excluded
      AND (
        e.suumo_images IS NULL OR jsonb_array_length(e.suumo_images) = 0
        OR e.floor_plan_images IS NULL OR jsonb_array_length(e.floor_plan_images) = 0
      )
    ORDER BY l.first_seen_at DESC NULLS LAST;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

ALTER FUNCTION get_homes_no_images() SET statement_timeout = '30s';

-- PostgREST スキーマキャッシュをリロード
NOTIFY pgrst, 'reload schema';
