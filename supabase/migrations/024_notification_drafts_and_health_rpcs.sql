-- ============================================================
-- 024: notification_drafts テーブル + buyer_daily_briefs 正式化
--      + ヘルスチェック RPC + 通知支援 RPC
-- Phase 2: Routine → notification_drafts → GHA Slack 連携
-- ============================================================

-- ============================================================
-- A. notification_drafts テーブル
-- ============================================================

CREATE TABLE IF NOT EXISTS notification_drafts (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel TEXT NOT NULL DEFAULT 'slack',
    notification_type TEXT NOT NULL,
    draft_date DATE NOT NULL DEFAULT CURRENT_DATE,
    message_text TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'sent', 'skipped', 'failed')),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    sent_at TIMESTAMPTZ,
    error_message TEXT,
    UNIQUE (channel, notification_type, draft_date)
);

COMMENT ON TABLE notification_drafts IS 'Routine が下書きし GHA が送信する通知キュー。channel+type+date で冪等';
COMMENT ON COLUMN notification_drafts.notification_type IS 'daily_brief | price_alert | new_highlight | health_report';
COMMENT ON COLUMN notification_drafts.status IS 'pending=未送信, sent=送信済, skipped=対象なし, failed=送信失敗';

CREATE INDEX IF NOT EXISTS idx_notification_drafts_pending
    ON notification_drafts(status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_notification_drafts_date_type
    ON notification_drafts(draft_date, notification_type);

ALTER TABLE notification_drafts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "notification_drafts_service_all" ON notification_drafts
    FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "notification_drafts_read" ON notification_drafts
    FOR SELECT USING (true);

CREATE TRIGGER notification_drafts_updated_at
    BEFORE UPDATE ON notification_drafts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- B. buyer_daily_briefs テーブル（Routine 2 で使用中、正式化）
-- ============================================================

CREATE TABLE IF NOT EXISTS buyer_daily_briefs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id TEXT NOT NULL,
    brief_date DATE NOT NULL DEFAULT CURRENT_DATE,
    summary_text TEXT,
    recommended_listings JSONB,
    market_insights TEXT,
    ai_model TEXT,
    ai_prompt_hash TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (user_id, brief_date)
);

COMMENT ON TABLE buyer_daily_briefs IS 'Routine 2 が生成するバイヤー向けデイリーブリーフ';

ALTER TABLE buyer_daily_briefs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "service_role_full_access" ON buyer_daily_briefs;
DROP POLICY IF EXISTS "buyer_daily_briefs_service_all" ON buyer_daily_briefs;
CREATE POLICY "buyer_daily_briefs_service_all" ON buyer_daily_briefs
    FOR ALL USING (auth.role() = 'service_role');
DROP POLICY IF EXISTS "buyer_daily_briefs_read" ON buyer_daily_briefs;
CREATE POLICY "buyer_daily_briefs_read" ON buyer_daily_briefs
    FOR SELECT USING (true);

-- ============================================================
-- C. notification_drafts 書き込み RPC（Routine 用）
-- ============================================================

CREATE OR REPLACE FUNCTION upsert_notification_draft(
    p_channel TEXT,
    p_notification_type TEXT,
    p_message_text TEXT,
    p_metadata JSONB DEFAULT '{}',
    p_draft_date DATE DEFAULT CURRENT_DATE
) RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO notification_drafts (channel, notification_type, draft_date, message_text, metadata, status)
    VALUES (p_channel, p_notification_type, p_draft_date, p_message_text, p_metadata, 'pending')
    ON CONFLICT (channel, notification_type, draft_date)
    DO UPDATE SET
        message_text = EXCLUDED.message_text,
        metadata = EXCLUDED.metadata,
        status = 'pending',
        updated_at = now(),
        sent_at = NULL,
        error_message = NULL
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION upsert_notification_draft IS 'Routine から通知下書きを冪等に書き込む。同日同タイプは上書き';

-- skipped ステータスで保存する関数（対象0件のとき用）
CREATE OR REPLACE FUNCTION skip_notification_draft(
    p_channel TEXT,
    p_notification_type TEXT,
    p_draft_date DATE DEFAULT CURRENT_DATE
) RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO notification_drafts (channel, notification_type, draft_date, message_text, metadata, status)
    VALUES (p_channel, p_notification_type, p_draft_date, '', '{}', 'skipped')
    ON CONFLICT (channel, notification_type, draft_date)
    DO UPDATE SET
        status = 'skipped',
        updated_at = now()
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- D. notification_drafts 読み出し + 送信済みマーク RPC（GHA 用）
-- ============================================================

CREATE OR REPLACE FUNCTION get_pending_notification_drafts(
    p_channel TEXT DEFAULT 'slack'
) RETURNS TABLE (
    id BIGINT,
    notification_type TEXT,
    draft_date DATE,
    message_text TEXT,
    metadata JSONB
) AS $$
    SELECT nd.id, nd.notification_type, nd.draft_date, nd.message_text, nd.metadata
    FROM notification_drafts nd
    WHERE nd.channel = p_channel
      AND nd.status = 'pending'
    ORDER BY nd.draft_date, nd.created_at;
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION mark_notification_sent(
    p_id BIGINT,
    p_status TEXT DEFAULT 'sent',
    p_error TEXT DEFAULT NULL
) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE notification_drafts
    SET status = p_status,
        sent_at = CASE WHEN p_status = 'sent' THEN now() ELSE sent_at END,
        error_message = p_error,
        updated_at = now()
    WHERE id = p_id AND status = 'pending';
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- E. ヘルスチェック RPC 群（Routine 3 用）
-- ============================================================

-- E1. エンリッチメントカバレッジ
CREATE OR REPLACE FUNCTION health_check_enrichment_coverage()
RETURNS TABLE (
    field_name TEXT,
    total_active INT,
    non_null_count INT,
    coverage_pct NUMERIC(5,2)
) AS $$
    WITH active_count AS (
        SELECT COUNT(*)::INT AS cnt FROM listings WHERE is_active = true
    ),
    fields AS (
        SELECT 'listing_score' AS fname, COUNT(e.listing_score)::INT AS nn
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'ai_recommendation_score', COUNT(e.ai_recommendation_score)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'extracted_features', COUNT(e.extracted_features)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'image_categories', COUNT(e.image_categories)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'commute_info', COUNT(e.commute_info)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'price_fairness_score', COUNT(e.price_fairness_score)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'hazard_info', COUNT(e.hazard_info)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'ss_lookup_status', COUNT(e.ss_lookup_status)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'ai_listing_score', COUNT(e.ai_listing_score)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
        UNION ALL
        SELECT 'ai_price_fairness_score', COUNT(e.ai_price_fairness_score)::INT
        FROM listings l JOIN enrichments e ON e.listing_id = l.id WHERE l.is_active
    )
    SELECT f.fname, ac.cnt, f.nn,
           ROUND(f.nn::NUMERIC / GREATEST(ac.cnt, 1) * 100, 2)
    FROM fields f, active_count ac;
$$ LANGUAGE sql SECURITY DEFINER;

-- E2. パイプライン鮮度
CREATE OR REPLACE FUNCTION health_check_pipeline_freshness()
RETURNS TABLE (
    metric TEXT,
    value INT,
    detail TEXT
) AS $$
    SELECT 'new_listings_24h'::TEXT,
           COUNT(*)::INT,
           '過去24時間の新規物件数'::TEXT
    FROM listings WHERE created_at > now() - interval '24 hours' AND is_active
    UNION ALL
    SELECT 'ai_analyzed_24h',
           COUNT(*)::INT,
           '過去24時間のAI分析数'
    FROM enrichments WHERE ai_calculated_at > now() - interval '24 hours'
    UNION ALL
    SELECT 'stale_ai_7d',
           COUNT(*)::INT,
           'AI分析が7日以上古い物件数'
    FROM listings l
    JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active AND e.ai_calculated_at IS NOT NULL
      AND e.ai_calculated_at < now() - interval '7 days'
    UNION ALL
    SELECT 'never_ai_analyzed',
           COUNT(*)::INT,
           'アクティブだがAI未分析の物件数'
    FROM listings l
    JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active AND e.ai_calculated_at IS NULL
    UNION ALL
    SELECT 'no_enrichment_48h',
           COUNT(*)::INT,
           '48時間以上経過しenrichmentなし'
    FROM listings l
    LEFT JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active
      AND l.created_at < now() - interval '48 hours'
      AND (e.listing_id IS NULL OR (
          e.listing_score IS NULL AND e.commute_info IS NULL AND e.hazard_info IS NULL
      ));
$$ LANGUAGE sql SECURITY DEFINER;

-- E3. データ品質
CREATE OR REPLACE FUNCTION health_check_data_quality()
RETURNS TABLE (
    check_name TEXT,
    count INT,
    detail TEXT
) AS $$
    SELECT 'score_mismatch_ls_no_ai'::TEXT,
           COUNT(*)::INT,
           'listing_score有 だが ai_recommendation_score無'::TEXT
    FROM listings l
    JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active AND e.listing_score IS NOT NULL AND e.ai_recommendation_score IS NULL
    UNION ALL
    SELECT 'images_no_categories',
           COUNT(*)::INT,
           'suumo_images有 だが image_categories無'
    FROM listings l
    JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active
      AND e.suumo_images IS NOT NULL
      AND jsonb_array_length(e.suumo_images) > 0
      AND e.image_categories IS NULL
    UNION ALL
    SELECT 'duplicate_active',
           COUNT(*)::INT,
           '同一identity_keyで複数is_active=true'
    FROM (
        SELECT identity_key FROM listings
        WHERE is_active = true
        GROUP BY identity_key HAVING COUNT(*) > 1
    ) dup;
$$ LANGUAGE sql SECURITY DEFINER;

-- E4. アノマリ検出
CREATE OR REPLACE FUNCTION health_check_anomaly_detection()
RETURNS TABLE (
    anomaly_type TEXT,
    value NUMERIC,
    threshold NUMERIC,
    is_alert BOOLEAN,
    detail TEXT
) AS $$
    WITH current_active AS (
        SELECT COUNT(*)::NUMERIC AS cnt FROM listings WHERE is_active
    ),
    avg_7d AS (
        SELECT COALESCE(AVG(daily_count), 0)::NUMERIC AS avg_cnt
        FROM (
            SELECT DATE(occurred_at) AS d, COUNT(*) AS daily_count
            FROM listing_events
            WHERE event_type = 'appeared'
              AND occurred_at > now() - interval '7 days'
            GROUP BY DATE(occurred_at)
        ) daily
    )
    SELECT 'active_count_drop'::TEXT,
           ca.cnt,
           ROUND(a7.avg_cnt * 0.8),
           (a7.avg_cnt > 0 AND ca.cnt < a7.avg_cnt * 0.8) AS is_alert,
           format('現在 %s 件 / 7日平均新着 %s 件/日', ca.cnt::INT, ROUND(a7.avg_cnt)::INT)::TEXT
    FROM current_active ca, avg_7d a7
    UNION ALL
    SELECT 'score_contradiction',
           COUNT(*)::NUMERIC,
           0,
           (COUNT(*) > 0),
           'listing_score 80+ かつ price_fairness_score 20以下'
    FROM listings l
    JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active
      AND e.listing_score >= 80
      AND e.price_fairness_score IS NOT NULL
      AND e.price_fairness_score <= 20;
$$ LANGUAGE sql SECURITY DEFINER;

-- ============================================================
-- F. 価格変動検出 RPC（Routine 2 通知ドラフト用）
-- ============================================================

CREATE OR REPLACE FUNCTION get_significant_price_changes(
    p_since TIMESTAMPTZ DEFAULT now() - interval '24 hours',
    p_min_drop_pct NUMERIC DEFAULT 5.0
) RETURNS TABLE (
    listing_id BIGINT,
    name TEXT,
    old_price_man INT,
    new_price_man INT,
    change_pct NUMERIC,
    changed_at TIMESTAMPTZ
) AS $$
    SELECT le.listing_id,
           l.name,
           le.old_value::INT,
           le.new_value::INT,
           ROUND(((le.old_value::NUMERIC - le.new_value::NUMERIC) / GREATEST(le.old_value::NUMERIC, 1)) * 100, 1),
           le.occurred_at
    FROM listing_events le
    JOIN listings l ON l.id = le.listing_id
    WHERE le.event_type = 'price_changed'
      AND le.occurred_at > p_since
      AND le.old_value IS NOT NULL AND le.new_value IS NOT NULL
      AND le.old_value ~ '^\d+$' AND le.new_value ~ '^\d+$'
      AND le.old_value::NUMERIC > le.new_value::NUMERIC
      AND ((le.old_value::NUMERIC - le.new_value::NUMERIC) / GREATEST(le.old_value::NUMERIC, 1)) * 100 >= p_min_drop_pct
    ORDER BY ((le.old_value::NUMERIC - le.new_value::NUMERIC) / GREATEST(le.old_value::NUMERIC, 1)) DESC;
$$ LANGUAGE sql SECURITY DEFINER;

-- ============================================================
-- G. 高スコア新着物件取得 RPC（Routine 2 通知ドラフト用）
-- ============================================================

CREATE OR REPLACE FUNCTION get_high_score_new_listings(
    p_since TIMESTAMPTZ DEFAULT now() - interval '24 hours',
    p_min_score INT DEFAULT 4
) RETURNS TABLE (
    listing_id BIGINT,
    name TEXT,
    address TEXT,
    price_man INT,
    layout TEXT,
    area_m2 NUMERIC,
    walk_min INT,
    station_line TEXT,
    ai_recommendation_score INT,
    ai_recommendation_summary TEXT,
    listing_score INT,
    first_seen_at TEXT
) AS $$
    SELECT l.id, l.name, l.address,
           ls.price_man,
           l.layout, l.area_m2, l.walk_min, l.station_line,
           e.ai_recommendation_score,
           e.ai_recommendation_summary,
           e.listing_score,
           l.first_seen_at
    FROM listings l
    JOIN enrichments e ON e.listing_id = l.id
    LEFT JOIN LATERAL (
        SELECT s.price_man FROM listing_sources s
        WHERE s.listing_id = l.id AND s.is_active
        ORDER BY s.last_seen_at DESC NULLS LAST LIMIT 1
    ) ls ON TRUE
    WHERE l.is_active
      AND l.created_at > p_since
      AND e.ai_recommendation_score >= p_min_score
    ORDER BY e.ai_recommendation_score DESC, l.created_at DESC;
$$ LANGUAGE sql SECURITY DEFINER;
