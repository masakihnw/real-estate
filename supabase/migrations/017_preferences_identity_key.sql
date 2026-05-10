-- Nope/Like を物件単位 (identity_key) に変更
-- テーブルは空なので DROP + 再作成

DROP TABLE IF EXISTS user_building_preferences CASCADE;

CREATE TABLE user_building_preferences (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    identity_key TEXT NOT NULL UNIQUE,
    preference TEXT NOT NULL CHECK (preference IN ('nope', 'like')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_ubp_preference ON user_building_preferences(preference);

ALTER TABLE user_building_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "allow_all_for_anon" ON user_building_preferences
    FOR ALL USING (true) WITH CHECK (true);
