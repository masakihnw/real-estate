-- Notification state: track the last time each notification channel
-- was successfully sent. Replaces previous_slack.json file-based state.

CREATE TABLE IF NOT EXISTS notification_state (
    id TEXT PRIMARY KEY,
    last_notified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO notification_state (id, last_notified_at)
VALUES ('slack', NOW())
ON CONFLICT (id) DO NOTHING;

-- Indexes to speed up event queries filtered by occurred_at
CREATE INDEX IF NOT EXISTS idx_listing_events_occurred_at
    ON listing_events(occurred_at);
CREATE INDEX IF NOT EXISTS idx_listing_events_type_occurred
    ON listing_events(event_type, occurred_at);
