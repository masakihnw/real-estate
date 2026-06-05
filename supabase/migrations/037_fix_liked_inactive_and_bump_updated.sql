-- 037: get_liked_inactive_listings パラメータなし版を復元 + enrichment 反映のため updated_at バンプ
--
-- 036 で DROP VIEW ... CASCADE により parameterless 版が削除され、
-- iOS アプリの rpc("get_liked_inactive_listings") が 404 (PGRST202) になっていた。
-- また ai_scoring_reasoning が enrichments に追加されたが listings.updated_at が
-- 変わらないため差分取得で反映されない問題も修正。

-- 1. パラメータなし版を復元（パラメータ付き版はそのまま残る = オーバーロード）
CREATE FUNCTION get_liked_inactive_listings()
RETURNS SETOF listings_feed_light AS $$
  SELECT lf.*
  FROM listings_feed_light lf
  JOIN user_building_preferences ubp
    ON lf.identity_key LIKE ubp.identity_key || '|%'
  WHERE lf.is_active = false
    AND ubp.preference = 'like';
$$ LANGUAGE sql SECURITY DEFINER STABLE;

ALTER FUNCTION get_liked_inactive_listings() SET statement_timeout = '30s';

-- 2. ai_scoring_reasoning が入った物件の updated_at をバンプ → 差分取得で反映される
UPDATE listings l
SET updated_at = NOW()
FROM enrichments e
WHERE e.listing_id = l.id
  AND e.ai_scoring_reasoning IS NOT NULL;

-- PostgREST スキーマキャッシュをリロード
NOTIFY pgrst, 'reload schema';
