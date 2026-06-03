-- Fix: upsert_notification_draft が送信済みドラフトを pending にリセットしてしまう問題
-- Routine 2 が1日複数回実行される場合に同じ通知が再送される原因だった

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
    WHERE notification_drafts.status NOT IN ('sent', 'skipped')
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
        SELECT nd.id INTO v_id
        FROM notification_drafts nd
        WHERE nd.channel = p_channel
          AND nd.notification_type = p_notification_type
          AND nd.draft_date = p_draft_date;
    END IF;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION upsert_notification_draft IS 'Routine から通知下書きを冪等に書き込む。同日同タイプで既に sent/skipped なら上書きしない';
