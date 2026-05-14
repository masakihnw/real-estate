-- Supabase Storage バケット: 物件画像（間取り図・外観・室内写真）
-- public=TRUE: iOS アプリから認証なしで画像を読み込む

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'listing-images',
  'listing-images',
  TRUE,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp']
)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "listing_images_public_read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'listing-images');

CREATE POLICY "listing_images_service_upload"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'listing-images');

CREATE POLICY "listing_images_service_update"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'listing-images');
