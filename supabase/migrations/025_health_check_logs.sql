-- ============================================================
-- 025: health_check_logs テーブル + RPC
-- Routine 3 のヘルスチェック結果を DB に保存し、
-- Routine 1/2 が参照して自律的に修正アクションを取る
-- ============================================================

CREATE TABLE IF NOT EXISTS health_check_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_date DATE NOT NULL DEFAULT CURRENT_DATE UNIQUE,
    coverage JSONB NOT NULL DEFAULT '{}',
    freshness JSONB NOT NULL DEFAULT '{}',
    data_quality JSONB NOT NULL DEFAULT '{}',
    anomalies JSONB NOT NULL DEFAULT '{}',
    alert_count INT NOT NULL DEFAULT 0,
    alerts JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE health_check_logs IS 'Routine 3 が書き込むヘルスチェック結果。Routine 1/2 が参照して自律修正に利用';
COMMENT ON COLUMN health_check_logs.coverage IS 'エンリッチメントカバレッジ結果 (field_name → {total, non_null, pct, threshold, ok})';
COMMENT ON COLUMN health_check_logs.freshness IS 'パイプライン鮮度結果 (metric → {value, detail, ok})';
COMMENT ON COLUMN health_check_logs.data_quality IS 'データ品質結果 (check_name → {count, detail, ok})';
COMMENT ON COLUMN health_check_logs.anomalies IS 'アノマリ検出結果 (anomaly_type → {value, threshold, is_alert, detail})';
COMMENT ON COLUMN health_check_logs.alerts IS '検出されたアラートのサマリー配列';

ALTER TABLE health_check_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "health_check_logs_service_all" ON health_check_logs
    FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "health_check_logs_read" ON health_check_logs
    FOR SELECT USING (true);

CREATE TRIGGER health_check_logs_updated_at
    BEFORE UPDATE ON health_check_logs
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- RPC: ヘルスチェック結果の書き込み（冪等）
-- ============================================================

CREATE OR REPLACE FUNCTION upsert_health_check_log(
    p_coverage JSONB,
    p_freshness JSONB,
    p_data_quality JSONB,
    p_anomalies JSONB,
    p_alert_count INT DEFAULT 0,
    p_alerts JSONB DEFAULT '[]',
    p_check_date DATE DEFAULT CURRENT_DATE
) RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO health_check_logs (check_date, coverage, freshness, data_quality, anomalies, alert_count, alerts)
    VALUES (p_check_date, p_coverage, p_freshness, p_data_quality, p_anomalies, p_alert_count, p_alerts)
    ON CONFLICT (check_date)
    DO UPDATE SET
        coverage = EXCLUDED.coverage,
        freshness = EXCLUDED.freshness,
        data_quality = EXCLUDED.data_quality,
        anomalies = EXCLUDED.anomalies,
        alert_count = EXCLUDED.alert_count,
        alerts = EXCLUDED.alerts,
        updated_at = now()
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION upsert_health_check_log IS 'Routine 3 からヘルスチェック結果を冪等に書き込む。同日は上書き';

-- ============================================================
-- RPC: 最新のヘルスチェック結果取得（Routine 1/2 参照用）
-- ============================================================

CREATE OR REPLACE FUNCTION get_latest_health_check()
RETURNS TABLE (
    check_date DATE,
    coverage JSONB,
    freshness JSONB,
    data_quality JSONB,
    anomalies JSONB,
    alert_count INT,
    alerts JSONB,
    created_at TIMESTAMPTZ
) AS $$
    SELECT h.check_date, h.coverage, h.freshness, h.data_quality,
           h.anomalies, h.alert_count, h.alerts, h.created_at
    FROM health_check_logs h
    ORDER BY h.check_date DESC
    LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER;

COMMENT ON FUNCTION get_latest_health_check IS 'Routine 1/2 が直近のヘルスチェック結果を参照し自律修正に利用';
