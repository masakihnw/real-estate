-- Supabase tables for transaction data (previously JSON-only via transactions.json).
-- Source: reinfolib API (国土交通省 成約価格情報)

CREATE TABLE IF NOT EXISTS transactions (
    id TEXT PRIMARY KEY,
    prefecture TEXT NOT NULL,
    ward TEXT NOT NULL,
    district TEXT NOT NULL,
    district_code TEXT NOT NULL DEFAULT '',
    price_man INTEGER NOT NULL,
    area_m2 REAL NOT NULL,
    m2_price INTEGER NOT NULL,
    layout TEXT NOT NULL,
    built_year INTEGER NOT NULL,
    structure TEXT NOT NULL,
    trade_period TEXT NOT NULL,
    nearest_station TEXT,
    estimated_walk_min INTEGER,
    latitude REAL,
    longitude REAL,
    building_group_id TEXT,
    estimated_building_name TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS building_groups (
    group_id TEXT PRIMARY KEY,
    prefecture TEXT NOT NULL,
    ward TEXT NOT NULL,
    district TEXT NOT NULL,
    built_year INTEGER NOT NULL,
    structure TEXT NOT NULL,
    nearest_station TEXT,
    estimated_walk_min INTEGER,
    latitude REAL,
    longitude REAL,
    transaction_count INTEGER NOT NULL,
    price_range_man JSONB NOT NULL,
    avg_m2_price INTEGER NOT NULL,
    periods JSONB NOT NULL,
    latest_period TEXT,
    estimated_building_name TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transaction_metadata (
    id TEXT PRIMARY KEY DEFAULT 'default',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    periods_covered JSONB NOT NULL DEFAULT '[]',
    data_source TEXT NOT NULL DEFAULT '',
    transaction_count INTEGER NOT NULL DEFAULT 0,
    building_group_count INTEGER NOT NULL DEFAULT 0,
    scope TEXT NOT NULL DEFAULT ''
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_transactions_ward ON transactions(ward);
CREATE INDEX IF NOT EXISTS idx_transactions_trade_period ON transactions(trade_period);
CREATE INDEX IF NOT EXISTS idx_transactions_building_group ON transactions(building_group_id);
CREATE INDEX IF NOT EXISTS idx_building_groups_ward ON building_groups(ward);

-- Triggers
CREATE TRIGGER update_transactions_updated_at
    BEFORE UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER update_building_groups_updated_at
    BEFORE UPDATE ON building_groups
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- RLS
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE building_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_metadata ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_read_transactions" ON transactions FOR SELECT TO anon USING (true);
CREATE POLICY "anon_read_building_groups" ON building_groups FOR SELECT TO anon USING (true);
CREATE POLICY "anon_read_transaction_metadata" ON transaction_metadata FOR SELECT TO anon USING (true);

-- RPC for iOS incremental sync
CREATE OR REPLACE FUNCTION get_transaction_feed()
RETURNS JSON AS $$
    SELECT JSON_BUILD_OBJECT(
        'transactions', COALESCE((SELECT JSON_AGG(t) FROM transactions t), '[]'::json),
        'building_groups', COALESCE((SELECT JSON_AGG(bg) FROM building_groups bg), '[]'::json),
        'metadata', (SELECT ROW_TO_JSON(m) FROM transaction_metadata m WHERE m.id = 'default')
    );
$$ LANGUAGE sql;
