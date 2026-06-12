-- 046: 同一建物の売出全戸スペック（building_units）を enrichments + 軽量ビューに追加
--
-- 背景:
--   同一マンションで複数戸が売り出されている場合、AI分析（★/グレード/コメント）は
--   その中の1戸についてしか言及できていなかった。棟内の他戸スペックを保持し、
--   「他の部屋だったらどうか」を踏まえて棟内ベスト戸基準で評価できるようにする。
--   また iOS 側で同一建物をベスト戸代表1行に集約するためのグルーピングキーを提供する。
--
-- 変更:
--   1. enrichments に building_group_key (TEXT) / building_units (JSONB) を追加
--   2. listings_feed_light ビューに2カラムを追加（DROP CASCADE → 再作成）
--   3. CASCADE で削除された依存 RPC を再作成（045 と同一）
--
-- データ仕様（building_units の各要素）:
--   { floor, area_m2, layout, price_man, direction, price_per_m2_man, url, is_current }
--   価格昇順。is_current=true がその行（listing）自身の戸。単戸物件では NULL。

-- ============================================================
-- 1. enrichments に列追加
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
-- 2. listings_feed_light ビュー再作成（045 + building_group_key / building_units）
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
    e.building_group_key,
    e.building_units,
    e.near_miss,
    e.near_miss_reasons,
    -- 画像有無フラグ（軽量ビューで pendingCount フィルタに使用）
    COALESCE(e.has_floor_plan_images, false) AS has_floor_plan_images,
    COALESCE(e.has_property_images, false) AS has_property_images,
    -- カードサムネのフォールバック（best_thumbnail_url 未設定の間に使う）。
    -- iOS の thumbnailURL と同じ優先順: 外観/エントランス → 先頭画像
    COALESCE(
        jsonb_path_query_first(
            e.suumo_images, '$[*] ? (@.label like_regex "外観|エントランス")'
        ) ->> 'url',
        e.suumo_images -> 0 ->> 'url'
    ) AS first_image_url
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
-- 3. CASCADE で削除された依存 RPC を再作成（045 と同一）
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

-- PostgREST スキーマキャッシュをリロード
NOTIFY pgrst, 'reload schema';
