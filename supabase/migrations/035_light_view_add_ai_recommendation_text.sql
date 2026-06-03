-- 035: listings_feed_light に AI 推奨テキストカラムを追加
--
-- 033 で軽量ビューから除外された ai_recommendation_summary / flags / action は
-- データサイズが小さく（各 1-2 文 + 短い配列）、一覧画面での表示に必要。
-- scenarios は詳細画面専用のため引き続き除外。

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
    -- listing_sources (最新のアクティブソース)
    ls.source,
    ls.url,
    ls.price_man,
    ls.price_max_man,
    ls.listing_agent,
    ls.is_motodzuke,
    -- enrichments: スカラー値 + AI 推奨テキスト
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
    -- 以下は除外（タイムアウトの主因）:
    --   ss_radar_data, ss_past_market_trends, ss_surrounding_properties, ss_price_judgments,
    --   hazard_info, commute_info, commute_info_v2,
    --   reinfolib_market_data, mansion_review_data, estat_population_data,
    --   investment_summary, extracted_features, image_categories, dedup_candidates,
    --   floor_plan_images, suumo_images, alt_sources,
    --   ai_recommendation_scenarios,
    --   alt_sources_json (相関サブクエリ), price_history_json (相関サブクエリ)
FROM listings l
LEFT JOIN LATERAL (
    SELECT * FROM listing_sources s
    WHERE s.listing_id = l.id AND s.is_active
    ORDER BY s.last_seen_at DESC LIMIT 1
) ls ON TRUE
LEFT JOIN enrichments e ON e.listing_id = l.id;

-- get_listings_since_light は SETOF listings_feed_light を返すため、
-- CASCADE で削除された後に再作成が必要。
-- enrichments の更新 (AI 分析追加等) も差分同期で検知できるよう
-- ai_calculated_at も条件に含める。
CREATE OR REPLACE FUNCTION get_listings_since_light(since_ts TIMESTAMPTZ)
RETURNS SETOF listings_feed_light AS $$
    SELECT lfl.*
    FROM listings_feed_light lfl
    LEFT JOIN enrichments e ON e.listing_id = lfl.id
    WHERE lfl.updated_at > since_ts
       OR e.ai_calculated_at > since_ts;
$$ LANGUAGE sql;

ALTER FUNCTION get_listings_since_light(TIMESTAMPTZ) SET statement_timeout = '30s';

-- get_liked_inactive_listings も SETOF listings_feed_light を返すため再作成
CREATE FUNCTION get_liked_inactive_listings()
RETURNS SETOF listings_feed_light AS $$
  SELECT lf.*
  FROM listings_feed_light lf
  JOIN user_building_preferences ubp
    ON lf.identity_key LIKE ubp.identity_key || '|%'
  WHERE lf.is_active = false
    AND ubp.preference = 'like';
$$ LANGUAGE sql STABLE;

ALTER FUNCTION get_liked_inactive_listings() SET statement_timeout = '30s';

-- PostgREST スキーマキャッシュをリロード
NOTIFY pgrst, 'reload schema';
