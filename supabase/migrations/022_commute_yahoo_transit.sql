-- Yahoo Transit Edge Function 用: 通勤時間が未取得または信頼ソースでない物件を取得
CREATE OR REPLACE FUNCTION get_commute_targets(p_limit int DEFAULT 20)
RETURNS TABLE (id bigint, ss_address text, name text)
LANGUAGE sql STABLE
AS $$
  SELECT l.id, l.ss_address, l.name
  FROM listings l
  LEFT JOIN enrichments e ON e.listing_id = l.id
  WHERE l.is_active = true
    AND l.ss_address IS NOT NULL
    AND (
      e.commute_info IS NULL
      OR jsonb_typeof(e.commute_info) = 'string'
      OR COALESCE(
        CASE WHEN jsonb_typeof(e.commute_info) = 'object'
             THEN e.commute_info->'playground'->>'source'
        END, ''
      ) NOT IN ('gmaps', 'yahoo_transit')
    )
  ORDER BY l.updated_at DESC
  LIMIT p_limit;
$$;

-- 二重エンコードされた commute_info を修復
UPDATE enrichments
SET commute_info = (commute_info #>> '{}')::jsonb
WHERE jsonb_typeof(commute_info) = 'string'
  AND commute_info IS NOT NULL;

-- pg_net + pg_cron 拡張を有効化
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

-- 毎日 18:00 UTC (= JST 3:00 AM) に Edge Function を呼び出す
SELECT cron.schedule(
  'commute-yahoo-transit-daily',
  '0 18 * * *',
  $$
  SELECT net.http_post(
    url := 'https://dzhcumdmzskkvusynmyw.supabase.co/functions/v1/commute-yahoo-transit',
    body := '{"batch_size": 10}'::jsonb,
    headers := '{"Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImR6aGN1bWRtenNra3Z1c3lubXl3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc2MTgwMjgsImV4cCI6MjA5MzE5NDAyOH0.YZEe0enWZmmtJ0vz8lyjF8UGy42RVXCUFDfbuGoURsw", "Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
