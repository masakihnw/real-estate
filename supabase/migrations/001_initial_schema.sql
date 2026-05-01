-- Supabase schema for real-estate DB-first migration
-- Run in SQL Editor: Step 1 (tables) then Step 2 (indexes/triggers/views/RLS)
-- Already applied to project: dzhcumdmzskkvusynmyw

-- ===== TABLES =====

CREATE TABLE IF NOT EXISTS listings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    identity_key TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,
    address TEXT,
    ss_address TEXT,
    layout TEXT,
    area_m2 REAL,
    area_max_m2 REAL,
    built_year INTEGER,
    built_str TEXT,
    station_line TEXT,
    walk_min INTEGER,
    total_units INTEGER,
    floor_position INTEGER,
    floor_total INTEGER,
    floor_structure TEXT,
    ownership TEXT,
    management_fee INTEGER,
    repair_reserve_fund INTEGER,
    repair_fund_onetime INTEGER,
    direction TEXT,
    balcony_area_m2 REAL,
    parking TEXT,
    constructor TEXT,
    zoning TEXT,
    property_type TEXT NOT NULL DEFAULT 'chuko',
    developer_name TEXT,
    developer_brokerage TEXT,
    list_ward_roman TEXT,
    delivery_date TEXT,
    duplicate_count INTEGER DEFAULT 1,
    latitude REAL,
    longitude REAL,
    feature_tags JSONB,
    is_active BOOLEAN DEFAULT TRUE,
    is_new BOOLEAN DEFAULT FALSE,
    is_new_building BOOLEAN DEFAULT FALSE,
    first_seen_at TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS listing_sources (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id BIGINT NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    url TEXT NOT NULL,
    price_man INTEGER,
    management_fee INTEGER,
    repair_reserve_fund INTEGER,
    listing_agent TEXT,
    is_motodzuke BOOLEAN,
    first_seen_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE,
    UNIQUE(listing_id, source)
);

CREATE TABLE IF NOT EXISTS price_history (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id BIGINT NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    price_man INTEGER NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS listing_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id BIGINT NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
    source TEXT,
    event_type TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    occurred_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS enrichments (
    listing_id BIGINT PRIMARY KEY REFERENCES listings(id) ON DELETE CASCADE,
    ss_lookup_status TEXT,
    ss_profit_pct INTEGER,
    ss_oki_price_70m2 INTEGER,
    ss_m2_discount INTEGER,
    ss_value_judgment TEXT,
    ss_station_rank TEXT,
    ss_ward_rank TEXT,
    ss_sumai_surfin_url TEXT,
    ss_appreciation_rate REAL,
    ss_favorite_count INTEGER,
    ss_purchase_judgment TEXT,
    ss_radar_data JSONB,
    ss_past_market_trends JSONB,
    ss_surrounding_properties JSONB,
    ss_price_judgments JSONB,
    ss_sim_best_5yr INTEGER,
    ss_sim_best_10yr INTEGER,
    ss_sim_standard_5yr INTEGER,
    ss_sim_standard_10yr INTEGER,
    ss_sim_worst_5yr INTEGER,
    ss_sim_worst_10yr INTEGER,
    ss_loan_balance_5yr INTEGER,
    ss_loan_balance_10yr INTEGER,
    ss_sim_base_price INTEGER,
    ss_new_m2_price INTEGER,
    ss_forecast_m2_price INTEGER,
    ss_forecast_change_rate REAL,
    hazard_info JSONB,
    commute_info JSONB,
    commute_info_v2 JSONB,
    reinfolib_market_data JSONB,
    mansion_review_data JSONB,
    estat_population_data JSONB,
    price_fairness_score INTEGER,
    resale_liquidity_score INTEGER,
    competing_listings_count INTEGER,
    listing_score INTEGER,
    floor_plan_images JSONB,
    suumo_images JSONB,
    near_miss BOOLEAN DEFAULT FALSE,
    near_miss_reasons TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_annotations (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id TEXT NOT NULL,
    listing_identity_key TEXT NOT NULL,
    is_liked BOOLEAN DEFAULT FALSE,
    memo TEXT,
    comments JSONB,
    checklist JSONB,
    photos JSONB,
    viewed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, listing_identity_key)
);

CREATE TABLE IF NOT EXISTS scraping_config (
    id TEXT PRIMARY KEY DEFAULT 'default',
    config JSONB NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS near_misses (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    identity_key TEXT NOT NULL,
    name TEXT,
    source TEXT,
    url TEXT,
    price_man INTEGER,
    address TEXT,
    layout TEXT,
    area_m2 REAL,
    reasons TEXT NOT NULL,
    detected_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===== INDEXES =====

CREATE INDEX IF NOT EXISTS idx_listings_identity_key ON listings(identity_key);
CREATE INDEX IF NOT EXISTS idx_listings_active_type ON listings(is_active, property_type);
CREATE INDEX IF NOT EXISTS idx_listings_updated_at ON listings(updated_at);
CREATE INDEX IF NOT EXISTS idx_listing_sources_listing_id ON listing_sources(listing_id);
CREATE INDEX IF NOT EXISTS idx_price_history_listing_id ON price_history(listing_id);
CREATE INDEX IF NOT EXISTS idx_listing_events_listing_id ON listing_events(listing_id);
CREATE INDEX IF NOT EXISTS idx_user_annotations_user_listing ON user_annotations(user_id, listing_identity_key);

-- ===== TRIGGERS =====

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER listings_updated_at BEFORE UPDATE ON listings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER enrichments_updated_at BEFORE UPDATE ON enrichments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER annotations_updated_at BEFORE UPDATE ON user_annotations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ===== RLS =====

ALTER TABLE listings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read listings" ON listings FOR SELECT USING (true);
CREATE POLICY "Service write listings" ON listings FOR ALL
    USING (current_setting('role') = 'service_role');

ALTER TABLE listing_sources ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read sources" ON listing_sources FOR SELECT USING (true);
CREATE POLICY "Service write sources" ON listing_sources FOR ALL
    USING (current_setting('role') = 'service_role');

ALTER TABLE price_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read history" ON price_history FOR SELECT USING (true);
CREATE POLICY "Service write history" ON price_history FOR ALL
    USING (current_setting('role') = 'service_role');

ALTER TABLE listing_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read events" ON listing_events FOR SELECT USING (true);
CREATE POLICY "Service write events" ON listing_events FOR ALL
    USING (current_setting('role') = 'service_role');

ALTER TABLE enrichments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read enrichments" ON enrichments FOR SELECT USING (true);
CREATE POLICY "Service write enrichments" ON enrichments FOR ALL
    USING (current_setting('role') = 'service_role');

ALTER TABLE user_annotations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own annotations" ON user_annotations
    FOR ALL USING (auth.uid()::text = user_id);

ALTER TABLE scraping_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read config" ON scraping_config FOR SELECT USING (true);
CREATE POLICY "Service write config" ON scraping_config FOR ALL
    USING (current_setting('role') = 'service_role');

ALTER TABLE near_misses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read near_misses" ON near_misses FOR SELECT USING (true);
CREATE POLICY "Service write near_misses" ON near_misses FOR ALL
    USING (current_setting('role') = 'service_role');

-- ===== VIEW =====

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

-- ===== RPC =====

CREATE OR REPLACE FUNCTION get_listings_since(since_ts TIMESTAMPTZ)
RETURNS SETOF listings_feed AS $$
    SELECT * FROM listings_feed WHERE updated_at > since_ts;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION get_removed_since(since_ts TIMESTAMPTZ)
RETURNS TABLE(identity_key TEXT, removed_at TIMESTAMPTZ) AS $$
    SELECT l.identity_key, le.occurred_at
    FROM listing_events le JOIN listings l ON l.id = le.listing_id
    WHERE le.event_type = 'removed' AND le.occurred_at > since_ts;
$$ LANGUAGE sql;
