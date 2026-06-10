-- 045: カードサムネのフォールバック + 画像更新の差分同期反映
--
-- 問題1: 一覧カードのサムネは best_thumbnail_url（Claude Routine② が毎日 JST4:00 に設定）
--   にのみ依存しており、日中に入った新着物件は最大約24時間プレースホルダ表示になる
--   （実測: homes はアクティブ238件中 best_thumbnail_url ありが1件のみ）。
--   → listings_feed_light に suumo_images からのフォールバック first_image_url を追加。
--     優先順は iOS の thumbnailURL と同じ「外観/エントランス → 先頭画像」。
--
-- 問題2: 画像は enrichments への upsert でのみ書かれ listings 行に触れないため、
--   listings.updated_at が進まず get_listings_since_light の差分同期に乗らない。
--   バックフィルで入った画像がアプリに反映されるのは次の全件 sync 後（最大半日）。
--   037 で ai_scoring_reasoning に対して単発バンプした問題の画像版。
--   → enrichments の画像関連カラム変更時に listings.updated_at を進めるトリガで恒久対応。

-- ============================================================
-- 1. listings_feed_light ビュー再作成（042 + first_image_url）
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
-- 2. CASCADE で削除された依存 RPC を再作成（042 と同一）
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
-- 3. 画像更新 → listings.updated_at バンプのトリガ（差分同期に乗せる）
-- ============================================================
CREATE OR REPLACE FUNCTION bump_listing_on_image_change()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT' AND (
            NEW.suumo_images IS NOT NULL
            OR NEW.floor_plan_images IS NOT NULL
            OR NEW.best_thumbnail_url IS NOT NULL))
       OR (TG_OP = 'UPDATE' AND (
            NEW.suumo_images IS DISTINCT FROM OLD.suumo_images
            OR NEW.floor_plan_images IS DISTINCT FROM OLD.floor_plan_images
            OR NEW.best_thumbnail_url IS DISTINCT FROM OLD.best_thumbnail_url
            OR NEW.image_categories IS DISTINCT FROM OLD.image_categories)) THEN
        UPDATE listings SET updated_at = NOW() WHERE id = NEW.listing_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS enrichments_image_change_bumps_listing ON enrichments;
CREATE TRIGGER enrichments_image_change_bumps_listing
AFTER INSERT OR UPDATE ON enrichments
FOR EACH ROW EXECUTE FUNCTION bump_listing_on_image_change();

-- ============================================================
-- 4. 単発バンプ: 画像があるのにサムネ未設定のアクティブ物件を差分同期に乗せる
--    （既存クライアントへ first_image_url を行ごと届けるため。037 と同じ手法）
-- ============================================================
UPDATE listings l
SET updated_at = NOW()
FROM enrichments e
WHERE e.listing_id = l.id
  AND l.is_active
  AND e.best_thumbnail_url IS NULL
  AND COALESCE(jsonb_array_length(e.suumo_images), 0) > 0;

-- PostgREST スキーマキャッシュをリロード
NOTIFY pgrst, 'reload schema';
