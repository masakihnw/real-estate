-- Add AI recommendation columns to enrichments table
-- and update listings_feed view to expose them.

ALTER TABLE enrichments
    ADD COLUMN IF NOT EXISTS ai_recommendation_score INTEGER,
    ADD COLUMN IF NOT EXISTS ai_recommendation_summary TEXT,
    ADD COLUMN IF NOT EXISTS ai_recommendation_flags JSONB,
    ADD COLUMN IF NOT EXISTS ai_recommendation_action TEXT;

-- Recreate the view to include the new columns
CREATE OR REPLACE VIEW listings_feed AS
SELECT
    l.id,
    l.identity_key,
    l.name,
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
    l.updated_at,
    ls.source,
    ls.url,
    ls.price_man,
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
    e.ss_radar_data,
    e.ss_past_market_trends,
    e.ss_surrounding_properties,
    e.ss_price_judgments,
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
    e.hazard_info,
    e.commute_info,
    e.commute_info_v2,
    e.reinfolib_market_data,
    e.mansion_review_data,
    e.estat_population_data,
    e.price_fairness_score,
    e.resale_liquidity_score,
    e.competing_listings_count,
    e.listing_score,
    e.floor_plan_images,
    e.suumo_images,
    e.ai_recommendation_score,
    e.ai_recommendation_summary,
    e.ai_recommendation_flags,
    e.ai_recommendation_action,
    (SELECT JSONB_AGG(JSONB_BUILD_OBJECT('source', s2.source, 'url', s2.url))
     FROM listing_sources s2
     WHERE s2.listing_id = l.id AND s2.source != ls.source AND s2.is_active
    ) AS alt_sources_json,
    (SELECT JSONB_AGG(JSONB_BUILD_OBJECT('date', ph.recorded_at, 'price_man', ph.price_man) ORDER BY ph.recorded_at)
     FROM price_history ph WHERE ph.listing_id = l.id
    ) AS price_history_json
FROM listings l
LEFT JOIN LATERAL (
    SELECT * FROM listing_sources s
    WHERE s.listing_id = l.id AND s.is_active
    ORDER BY s.last_seen_at DESC LIMIT 1
) ls ON TRUE
LEFT JOIN enrichments e ON e.listing_id = l.id;

-- Recreate dependent RPC
CREATE OR REPLACE FUNCTION get_listings_since(since_ts TIMESTAMPTZ)
RETURNS SETOF listings_feed AS $$
    SELECT * FROM listings_feed WHERE updated_at > since_ts;
$$ LANGUAGE sql;
