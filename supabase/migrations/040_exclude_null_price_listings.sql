-- 040: 価格NULLの物件をフィードから除外
--
-- 価格未定（price_man IS NULL）の物件がフィルタをすり抜けてアプリに
-- 表示されていた問題を修正する。
-- 1. 既存のNULL価格物件を spec_excluded に設定
-- 2. apply_spec_exclusions の両バージョン（パラメータあり/なし）で NULL価格も除外対象に追加
-- 3. listings_feed_light に price_man IS NOT NULL の防御的ガードを追加

-- 1. 既存のNULL価格物件を除外マーク
-- アクティブなソースのうち最新のものが price_man=NULL の物件を対象にする
UPDATE listings SET
  spec_excluded = true,
  spec_exclusion_reasons = ARRAY['price_null'],
  updated_at = NOW()
WHERE NOT spec_excluded
  AND is_active = true
  AND EXISTS (
    SELECT 1 FROM listing_sources s
    WHERE s.listing_id = listings.id AND s.is_active
  )
  AND NOT EXISTS (
    SELECT 1 FROM listing_sources s
    WHERE s.listing_id = listings.id
      AND s.is_active
      AND s.price_man IS NOT NULL
  );

-- 2. listings_feed_light を再作成
-- spec_excluded フラグが除外の主要メカニズム。
-- ls.price_man IS NOT NULL はスクレイパー側フィルタ漏れに対する防御的ガード。
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
    e.near_miss_reasons
FROM listings l
LEFT JOIN LATERAL (
    SELECT * FROM listing_sources s
    WHERE s.listing_id = l.id AND s.is_active
    ORDER BY s.last_seen_at DESC LIMIT 1
) ls ON TRUE
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE NOT l.spec_excluded
  AND ls.price_man IS NOT NULL;

-- 3. 依存 RPC を再作成
CREATE OR REPLACE FUNCTION get_listings_since_light(since_ts TIMESTAMPTZ)
RETURNS SETOF listings_feed_light AS $$
    SELECT * FROM listings_feed_light WHERE updated_at > since_ts;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

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

-- 4. apply_spec_exclusions パラメータなし版を更新（039 で作成、price_null 除外を追加）
CREATE OR REPLACE FUNCTION apply_spec_exclusions()
RETURNS TABLE(excluded_count INT, restored_count INT) AS $$
DECLARE
  cfg JSONB;
  v_price_max INT;
  v_price_min INT;
  v_area_min INT;
  v_area_min_toshin INT;
  v_excluded INT;
  v_restored INT;
BEGIN
  SELECT config INTO cfg FROM scraping_config WHERE id = 'default';
  v_price_max := (cfg->>'priceMaxMan')::INT;
  v_price_min := (cfg->>'priceMinMan')::INT;
  v_area_min := (cfg->>'areaMinM2')::INT;
  v_area_min_toshin := (cfg->>'areaMinToshinM2')::INT;

  WITH to_exclude AS (
    SELECT l.id,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN ls.price_man IS NULL
             THEN 'price_null' END,
        CASE WHEN ls.price_man IS NOT NULL AND ls.price_man > v_price_max
             THEN 'price_over_' || v_price_max END,
        CASE WHEN ls.price_man IS NOT NULL AND ls.price_man < v_price_min
             THEN 'price_under_' || v_price_min END,
        CASE WHEN l.area_m2 IS NOT NULL AND l.area_m2 < v_area_min_toshin
             THEN 'area_under_' || v_area_min_toshin END,
        CASE WHEN l.area_m2 IS NOT NULL
                  AND l.area_m2 >= v_area_min_toshin
                  AND l.area_m2 < v_area_min
                  AND NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(cfg->'toshinWards') w WHERE l.address LIKE '%' || w.value || '%'
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(cfg->'waterfrontKeywords') w WHERE l.address LIKE '%' || w.value || '%'
                  )
             THEN 'area_under_' || v_area_min || '_non_toshin' END
      ], NULL) AS reasons
    FROM listings l
    LEFT JOIN LATERAL (
      SELECT * FROM listing_sources s WHERE s.listing_id = l.id AND s.is_active
      ORDER BY s.last_seen_at DESC LIMIT 1
    ) ls ON TRUE
    WHERE NOT l.spec_excluded AND l.is_active = true
  )
  UPDATE listings SET spec_excluded = true, spec_exclusion_reasons = te.reasons, updated_at = NOW()
  FROM to_exclude te WHERE listings.id = te.id AND array_length(te.reasons, 1) > 0;
  GET DIAGNOSTICS v_excluded = ROW_COUNT;

  WITH to_restore AS (
    SELECT l.id FROM listings l
    LEFT JOIN LATERAL (
      SELECT * FROM listing_sources s WHERE s.listing_id = l.id AND s.is_active
      ORDER BY s.last_seen_at DESC LIMIT 1
    ) ls ON TRUE
    WHERE l.spec_excluded AND l.is_active = true
      AND ls.price_man IS NOT NULL
      AND ls.price_man >= v_price_min AND ls.price_man <= v_price_max
      AND (
        l.area_m2 IS NULL
        OR l.area_m2 >= v_area_min
        OR (l.area_m2 >= v_area_min_toshin AND (
          EXISTS (SELECT 1 FROM jsonb_array_elements_text(cfg->'toshinWards') w WHERE l.address LIKE '%' || w.value || '%')
          OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(cfg->'waterfrontKeywords') w WHERE l.address LIKE '%' || w.value || '%')
        ))
      )
  )
  UPDATE listings SET spec_excluded = false, spec_exclusion_reasons = '{}', updated_at = NOW()
  FROM to_restore tr
  WHERE listings.id = tr.id;
  GET DIAGNOSTICS v_restored = ROW_COUNT;

  RETURN QUERY SELECT v_excluded, v_restored;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. apply_spec_exclusions パラメータあり版も更新（038 で作成）
CREATE OR REPLACE FUNCTION apply_spec_exclusions(
  p_price_max_man INT DEFAULT 12000,
  p_price_min_man INT DEFAULT 7500,
  p_area_min_m2 NUMERIC DEFAULT 60,
  p_area_min_toshin_m2 NUMERIC DEFAULT 55
)
RETURNS TABLE(excluded_count INT, restored_count INT) AS $$
DECLARE
  v_excluded INT;
  v_restored INT;
BEGIN
  WITH to_exclude AS (
    SELECT l.id,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN ls.price_man IS NULL
             THEN 'price_null' END,
        CASE WHEN ls.price_man IS NOT NULL AND ls.price_man > p_price_max_man
             THEN 'price_over_' || p_price_max_man END,
        CASE WHEN ls.price_man IS NOT NULL AND ls.price_man < p_price_min_man
             THEN 'price_under_' || p_price_min_man END,
        CASE WHEN l.area_m2 IS NOT NULL AND l.area_m2 < p_area_min_toshin_m2
             THEN 'area_under_' || p_area_min_toshin_m2 END,
        CASE WHEN l.area_m2 IS NOT NULL
                  AND l.area_m2 >= p_area_min_toshin_m2
                  AND l.area_m2 < p_area_min_m2
                  AND NOT (l.address LIKE '%港区%' OR l.address LIKE '%中央区%' OR l.address LIKE '%千代田区%'
                           OR l.address LIKE '%豊洲%' OR l.address LIKE '%勝どき%' OR l.address LIKE '%晴海%'
                           OR l.address LIKE '%月島%' OR l.address LIKE '%有明%' OR l.address LIKE '%東雲%')
             THEN 'area_under_' || p_area_min_m2 || '_non_toshin' END
      ], NULL) AS reasons
    FROM listings l
    LEFT JOIN LATERAL (
      SELECT * FROM listing_sources s
      WHERE s.listing_id = l.id AND s.is_active
      ORDER BY s.last_seen_at DESC LIMIT 1
    ) ls ON TRUE
    WHERE NOT l.spec_excluded AND l.is_active = true
  )
  UPDATE listings SET
    spec_excluded = true,
    spec_exclusion_reasons = te.reasons,
    updated_at = NOW()
  FROM to_exclude te
  WHERE listings.id = te.id AND array_length(te.reasons, 1) > 0;
  GET DIAGNOSTICS v_excluded = ROW_COUNT;

  WITH to_restore AS (
    SELECT l.id
    FROM listings l
    LEFT JOIN LATERAL (
      SELECT * FROM listing_sources s
      WHERE s.listing_id = l.id AND s.is_active
      ORDER BY s.last_seen_at DESC LIMIT 1
    ) ls ON TRUE
    WHERE l.spec_excluded
      AND l.is_active = true
      AND ls.price_man IS NOT NULL
      AND ls.price_man >= p_price_min_man
      AND ls.price_man <= p_price_max_man
      AND (
        l.area_m2 IS NULL
        OR l.area_m2 >= p_area_min_m2
        OR (l.area_m2 >= p_area_min_toshin_m2
            AND (l.address LIKE '%港区%' OR l.address LIKE '%中央区%' OR l.address LIKE '%千代田区%'
                 OR l.address LIKE '%豊洲%' OR l.address LIKE '%勝どき%' OR l.address LIKE '%晴海%'
                 OR l.address LIKE '%月島%' OR l.address LIKE '%有明%' OR l.address LIKE '%東雲%'))
      )
  )
  UPDATE listings SET
    spec_excluded = false,
    spec_exclusion_reasons = '{}',
    updated_at = NOW()
  FROM to_restore tr
  WHERE listings.id = tr.id;
  GET DIAGNOSTICS v_restored = ROW_COUNT;

  RETURN QUERY SELECT v_excluded, v_restored;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PostgREST スキーマキャッシュをリロード
NOTIFY pgrst, 'reload schema';
