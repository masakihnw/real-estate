-- 047: 同一建物の売出全戸スペック（building_units）を enrichments + 軽量ビューに追加
--
-- 背景:
--   同一マンションで複数戸が売り出されている場合、AI分析（★/グレード/コメント）は
--   その中の1戸についてしか言及できていなかった。棟内の他戸スペックを保持し、
--   「他の部屋だったらどうか」を踏まえて棟内ベスト戸基準で評価できるようにする。
--
-- 採番: 本番DBには既に 046（listings_merged_into）が適用済みのため 047 を採用。
--
-- 設計（非破壊）:
--   - enrichments への列追加は ADD COLUMN IF NOT EXISTS（冪等）。
--   - listings_feed_light は DROP CASCADE せず CREATE OR REPLACE VIEW で末尾に2列を追記する。
--     これにより依存 RPC（get_listings_since_light / get_liked_inactive_listings ×2）は
--     再作成不要で、追加列を自動的に取り込む。046 が加えた listings.merged_into 等にも触れない。
--
-- データ仕様（building_units の各要素）:
--   { floor, area_m2, layout, price_man, direction, price_per_m2_man, url, is_current }
--   価格昇順。is_current=true がその行（listing）自身の戸。単戸物件では NULL。

-- ============================================================
-- 1. enrichments に列追加（冪等）
-- ============================================================
ALTER TABLE enrichments
ADD COLUMN IF NOT EXISTS building_group_key TEXT;

ALTER TABLE enrichments
ADD COLUMN IF NOT EXISTS building_units JSONB;

COMMENT ON COLUMN enrichments.building_group_key IS
    '同一建物グルーピング用の安定キー "<正規化物件名>|<区>"。単戸物件では NULL。';
COMMENT ON COLUMN enrichments.building_units IS
    '同一建物で売出中の全戸スペック配列（価格昇順、is_current が自戸）。単戸物件では NULL。';

-- ============================================================
-- 2. listings_feed_light に2列を末尾追記（CREATE OR REPLACE = 非破壊）
--    既存の列順・型はそのまま、building_group_key / building_units を末尾に追加する。
-- ============================================================
CREATE OR REPLACE VIEW listings_feed_light AS
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
    COALESCE(e.has_floor_plan_images, false) AS has_floor_plan_images,
    COALESCE(e.has_property_images, false) AS has_property_images,
    COALESCE(
        jsonb_path_query_first(
            e.suumo_images, '$[*] ? (@.label like_regex "外観|エントランス")'
        ) ->> 'url',
        e.suumo_images -> 0 ->> 'url'
    ) AS first_image_url,
    -- 末尾追記（CREATE OR REPLACE VIEW の制約上、新規列は末尾のみ）
    e.building_group_key,
    e.building_units
FROM listings l
LEFT JOIN LATERAL (
    SELECT * FROM listing_sources s
    WHERE s.listing_id = l.id AND s.is_active
    ORDER BY s.last_seen_at DESC LIMIT 1
) ls ON TRUE
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE NOT l.spec_excluded
  AND ls.price_man IS NOT NULL;

-- PostgREST スキーマキャッシュをリロード
NOTIFY pgrst, 'reload schema';
