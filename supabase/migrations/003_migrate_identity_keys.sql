-- identity_key から station_name を除去するマイグレーション
-- 旧形式: name|layout|area|address|built_year|station_name|floor (7要素)
-- 新形式: name|layout|area|address|built_year|floor (6要素)

-- listings.identity_key: 7要素 → 6要素 (station_name = position 6 を除去)
UPDATE listings
SET identity_key =
    split_part(identity_key, '|', 1) || '|' ||
    split_part(identity_key, '|', 2) || '|' ||
    split_part(identity_key, '|', 3) || '|' ||
    split_part(identity_key, '|', 4) || '|' ||
    split_part(identity_key, '|', 5) || '|' ||
    split_part(identity_key, '|', 7)
WHERE array_length(string_to_array(identity_key, '|'), 1) = 7;

-- user_annotations.listing_identity_key: 6要素 → 5要素 (station_name = position 6 を除去)
-- iOS 側の identityKey は元々 floor を含まないため 6→5 要素
UPDATE user_annotations
SET listing_identity_key =
    split_part(listing_identity_key, '|', 1) || '|' ||
    split_part(listing_identity_key, '|', 2) || '|' ||
    split_part(listing_identity_key, '|', 3) || '|' ||
    split_part(listing_identity_key, '|', 4) || '|' ||
    split_part(listing_identity_key, '|', 5)
WHERE array_length(string_to_array(listing_identity_key, '|'), 1) = 6;

-- 重複排除 (listings): identity_key 変換後に衝突が発生した場合、新しい方を残す
DELETE FROM listings a
USING listings b
WHERE a.id < b.id
  AND a.identity_key = b.identity_key;

-- 重複排除 (user_annotations): 同一ユーザー・同一キーで重複が発生した場合
DELETE FROM user_annotations a
USING user_annotations b
WHERE a.id < b.id
  AND a.user_id = b.user_id
  AND a.listing_identity_key = b.listing_identity_key;
