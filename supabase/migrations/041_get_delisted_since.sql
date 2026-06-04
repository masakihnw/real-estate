-- 差分同期で掲載終了を検知するための RPC
-- listings_feed_light ビューは全ソースが inactive になった物件を除外するため、
-- 差分同期 (get_listings_since_light) では掲載終了を検知できない。
-- この RPC は listings テーブルを直接クエリして、指定時刻以降に
-- inactive になった物件の identity_key を返す。

CREATE OR REPLACE FUNCTION get_delisted_since(since_ts TIMESTAMPTZ)
RETURNS TABLE(identity_key TEXT) AS $$
    SELECT l.identity_key
    FROM listings l
    WHERE l.is_active = false
      AND l.updated_at > since_ts
      AND l.identity_key IS NOT NULL;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

ALTER FUNCTION get_delisted_since(TIMESTAMPTZ) SET statement_timeout = '30s';
