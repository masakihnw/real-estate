-- 046: 重複統合の tombstone 機構
--
-- 背景: 重複統合で is_active=false にした物件が、スクレイパー同期の
-- 「identity_key 完全一致なら inactive でも再アクティブ化」ロジック
-- (supabase_sync.py _resolve_identity_key) により毎朝蘇生していた。
-- 掲載元がプロモーション名でページを掲載し続ける限り、同じ junk
-- identity_key が再計算されるため、無効化だけでは統合が維持できない。
--
-- 対策: merged_into 列で統合先を指す tombstone を導入。スクレイパーは
-- merged_into 付きレコードに一致した掲載を再アクティブ化せず、統合先へ
-- リダイレクトする（supabase_sync.py 側の対応とセットで機能する）。
--
-- ⚠️ tombstone の identity_key / normalized_name は変更しないこと。
--    スクレイパーが再計算する identity_key と一致し続けることで
--    リダイレクトが成立する（名前を「修正」すると重複が再作成される）。

-- ON DELETE RESTRICT: 統合先を誤って削除すると tombstone が孤立し、
-- 蘇生防止がサイレントに無効化されるため、参照されている間は削除を拒否する。
-- （スクレイパーの fuzzy 統合削除は、削除前に merged_into を新統合先へ
--  付け替えるため RESTRICT に抵触しない）
ALTER TABLE listings
  ADD COLUMN merged_into BIGINT REFERENCES listings(id) ON DELETE RESTRICT;

CREATE INDEX idx_listings_merged_into
  ON listings (merged_into)
  WHERE merged_into IS NOT NULL;

COMMENT ON COLUMN listings.merged_into IS
  '重複統合先の listings.id。セット済みレコード（tombstone）はスクレイパー同期で再アクティブ化されず、掲載確認は統合先に転送される。identity_key は再照合のため変更禁止。';

-- 既知の統合済みレコードをバックフィル（統合先が存在する場合のみ）
UPDATE listings SET merged_into = 6438,   is_active = FALSE
  WHERE id = 30279  AND EXISTS (SELECT 1 FROM listings WHERE id = 6438);
UPDATE listings SET merged_into = 173994, is_active = FALSE
  WHERE id = 174013 AND EXISTS (SELECT 1 FROM listings WHERE id = 173994);
UPDATE listings SET merged_into = 173967, is_active = FALSE
  WHERE id = 177517 AND EXISTS (SELECT 1 FROM listings WHERE id = 173967);
UPDATE listings SET merged_into = 174710, is_active = FALSE
  WHERE id = 189865 AND EXISTS (SELECT 1 FROM listings WHERE id = 174710);
UPDATE listings SET merged_into = 6778,   is_active = FALSE
  WHERE id = 154156 AND EXISTS (SELECT 1 FROM listings WHERE id = 6778);
-- 174073 / 174206 はどちらも練馬桜台ガーデンハウス (174059) の重複
UPDATE listings SET merged_into = 174059, is_active = FALSE
  WHERE id IN (174073, 174206) AND EXISTS (SELECT 1 FROM listings WHERE id = 174059);
