-- 034: get_liked_inactive_listings を listings_feed_light ベースに変更
--
-- 問題: 初回フルフェッチ時に get_liked_inactive_listings が重い listings_feed
-- ビューを使用しており、2層データ取得の高速化を打ち消していた。
-- コアフィールドのみ返せば十分であり、enrichment は詳細画面で lazy load する。

DROP FUNCTION IF EXISTS get_liked_inactive_listings();

CREATE FUNCTION get_liked_inactive_listings()
RETURNS SETOF listings_feed_light AS $$
  SELECT lf.*
  FROM listings_feed_light lf
  JOIN user_building_preferences ubp
    ON lf.identity_key LIKE ubp.identity_key || '|%'
  WHERE lf.is_active = false
    AND ubp.preference = 'like';
$$ LANGUAGE sql STABLE;

ALTER FUNCTION get_liked_inactive_listings() SET statement_timeout = '30s';
