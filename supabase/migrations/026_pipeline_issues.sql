-- Pipeline Issues: パイプライン健全性の課題トラッキング
-- Routine 3 が検出した問題を永続化し、Slack 通知 + 人間による修正指示を支援する

CREATE TABLE IF NOT EXISTS pipeline_issues (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issue_key TEXT NOT NULL UNIQUE,
    severity TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
    category TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    current_value JSONB DEFAULT '{}',
    suggested_fix TEXT,
    fix_type TEXT NOT NULL DEFAULT 'manual'
        CHECK (fix_type IN ('auto_fixable', 'manual', 'monitoring_only')),
    status TEXT NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'in_progress', 'resolved', 'wont_fix', 'monitoring')),
    first_detected_at TIMESTAMPTZ DEFAULT now(),
    last_detected_at TIMESTAMPTZ DEFAULT now(),
    resolved_at TIMESTAMPTZ,
    detection_count INT NOT NULL DEFAULT 1,
    trend JSONB DEFAULT '[]',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pipeline_issues_status
    ON pipeline_issues (status) WHERE status IN ('open', 'monitoring');

ALTER TABLE pipeline_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY pipeline_issues_service_all ON pipeline_issues
    FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY pipeline_issues_read ON pipeline_issues
    FOR SELECT USING (true);

-- upsert_pipeline_issue: 検出時に upsert（trend 履歴を蓄積、detection_count++）
CREATE OR REPLACE FUNCTION upsert_pipeline_issue(
    p_issue_key TEXT,
    p_severity TEXT,
    p_category TEXT,
    p_title TEXT,
    p_description TEXT,
    p_current_value JSONB DEFAULT '{}',
    p_suggested_fix TEXT DEFAULT NULL,
    p_fix_type TEXT DEFAULT 'manual'
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_id BIGINT;
    v_trend JSONB;
BEGIN
    SELECT id, trend INTO v_id, v_trend
    FROM pipeline_issues
    WHERE issue_key = p_issue_key;

    IF v_id IS NOT NULL THEN
        -- trend に今回の値を追記（最大30件）
        v_trend := COALESCE(v_trend, '[]'::jsonb)
            || jsonb_build_array(jsonb_build_object(
                'date', to_char(now() AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD'),
                'value', p_current_value
            ));
        IF jsonb_array_length(v_trend) > 30 THEN
            v_trend := v_trend - 0;
        END IF;

        UPDATE pipeline_issues SET
            severity = p_severity,
            description = p_description,
            current_value = p_current_value,
            suggested_fix = COALESCE(p_suggested_fix, suggested_fix),
            fix_type = p_fix_type,
            status = CASE WHEN status = 'resolved' THEN 'open' ELSE status END,
            last_detected_at = now(),
            resolved_at = NULL,
            detection_count = detection_count + 1,
            trend = v_trend,
            updated_at = now()
        WHERE id = v_id
        RETURNING id INTO v_id;
    ELSE
        INSERT INTO pipeline_issues (
            issue_key, severity, category, title, description,
            current_value, suggested_fix, fix_type, trend
        ) VALUES (
            p_issue_key, p_severity, p_category, p_title, p_description,
            p_current_value, p_suggested_fix, p_fix_type,
            jsonb_build_array(jsonb_build_object(
                'date', to_char(now() AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD'),
                'value', p_current_value
            ))
        )
        RETURNING id INTO v_id;
    END IF;

    RETURN v_id;
END;
$$;

-- resolve_pipeline_issue: 課題を解決済みにする
CREATE OR REPLACE FUNCTION resolve_pipeline_issue(
    p_issue_key TEXT,
    p_resolution_notes TEXT DEFAULT NULL
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_found BOOLEAN;
BEGIN
    UPDATE pipeline_issues SET
        status = 'resolved',
        resolved_at = now(),
        updated_at = now()
    WHERE issue_key = p_issue_key
      AND status IN ('open', 'monitoring', 'in_progress');

    GET DIAGNOSTICS v_found = ROW_COUNT;
    RETURN v_found > 0;
END;
$$;

-- get_open_pipeline_issues: open/monitoring の全件取得
CREATE OR REPLACE FUNCTION get_open_pipeline_issues()
RETURNS TABLE (
    id BIGINT,
    issue_key TEXT,
    severity TEXT,
    category TEXT,
    title TEXT,
    description TEXT,
    current_value JSONB,
    suggested_fix TEXT,
    fix_type TEXT,
    status TEXT,
    first_detected_at TIMESTAMPTZ,
    last_detected_at TIMESTAMPTZ,
    detection_count INT,
    trend JSONB
)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
    SELECT id, issue_key, severity, category, title, description,
           current_value, suggested_fix, fix_type, status,
           first_detected_at, last_detected_at, detection_count, trend
    FROM pipeline_issues
    WHERE status IN ('open', 'monitoring', 'in_progress')
    ORDER BY
        CASE severity
            WHEN 'critical' THEN 1
            WHEN 'high' THEN 2
            WHEN 'medium' THEN 3
            WHEN 'low' THEN 4
        END,
        last_detected_at DESC;
$$;

-- auto_resolve_stale_issues: 今回未検出の open issue を自動 resolve
CREATE OR REPLACE FUNCTION auto_resolve_stale_issues(
    p_detected_keys TEXT[]
) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_count INT;
BEGIN
    UPDATE pipeline_issues SET
        status = 'resolved',
        resolved_at = now(),
        updated_at = now()
    WHERE status IN ('open', 'monitoring')
      AND issue_key != ALL(p_detected_keys);

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;
