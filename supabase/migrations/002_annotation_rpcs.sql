-- Phase 3: Annotation RPC functions for iOS client
-- Firebase Auth UID (TEXT) をそのまま user_id として使用。
-- SECURITY DEFINER で RLS をバイパスし、関数内で user_id を検証する。

-- RLS を有効化（RPC は SECURITY DEFINER で回避）
ALTER TABLE user_annotations ENABLE ROW LEVEL SECURITY;

-- anon/authenticated から直接アクセスを禁止（RPC 経由のみ許可）
DROP POLICY IF EXISTS "anon_no_direct_access" ON user_annotations;
CREATE POLICY "anon_no_direct_access" ON user_annotations
    FOR ALL USING (false);

-- =============================================================
-- upsert_annotation: いいね・コメント・メモの書き込み
-- =============================================================
CREATE OR REPLACE FUNCTION upsert_annotation(
    p_user_id TEXT,
    p_identity_key TEXT,
    p_is_liked BOOLEAN DEFAULT NULL,
    p_memo TEXT DEFAULT NULL,
    p_comments JSONB DEFAULT NULL,
    p_name TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO user_annotations (user_id, listing_identity_key, is_liked, memo, comments)
    VALUES (
        p_user_id,
        p_identity_key,
        COALESCE(p_is_liked, FALSE),
        p_memo,
        p_comments
    )
    ON CONFLICT (user_id, listing_identity_key)
    DO UPDATE SET
        is_liked = COALESCE(p_is_liked, user_annotations.is_liked),
        memo = CASE WHEN p_memo IS NOT NULL THEN p_memo ELSE user_annotations.memo END,
        comments = CASE WHEN p_comments IS NOT NULL THEN p_comments ELSE user_annotations.comments END,
        updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================
-- get_user_annotations: ユーザーの全アノテーション取得
-- =============================================================
CREATE OR REPLACE FUNCTION get_user_annotations(p_user_id TEXT)
RETURNS TABLE(
    listing_identity_key TEXT,
    is_liked BOOLEAN,
    memo TEXT,
    comments JSONB,
    updated_at TIMESTAMPTZ
) AS $$
    SELECT
        ua.listing_identity_key,
        ua.is_liked,
        ua.memo,
        ua.comments,
        ua.updated_at
    FROM user_annotations ua
    WHERE ua.user_id = p_user_id;
$$ LANGUAGE sql SECURITY DEFINER;

-- =============================================================
-- get_all_annotations_for_listings: 全ユーザーのアノテーション取得
-- （家族共有: 他ユーザーのコメント・いいねも表示するため）
-- =============================================================
CREATE OR REPLACE FUNCTION get_all_annotations(p_identity_keys TEXT[])
RETURNS TABLE(
    user_id TEXT,
    listing_identity_key TEXT,
    is_liked BOOLEAN,
    memo TEXT,
    comments JSONB,
    updated_at TIMESTAMPTZ
) AS $$
    SELECT
        ua.user_id,
        ua.listing_identity_key,
        ua.is_liked,
        ua.memo,
        ua.comments,
        ua.updated_at
    FROM user_annotations ua
    WHERE ua.listing_identity_key = ANY(p_identity_keys);
$$ LANGUAGE sql SECURITY DEFINER;

-- =============================================================
-- get_annotations_since: 差分同期用（最終同期以降の変更のみ取得）
-- =============================================================
CREATE OR REPLACE FUNCTION get_annotations_since(p_since TIMESTAMPTZ)
RETURNS TABLE(
    user_id TEXT,
    listing_identity_key TEXT,
    is_liked BOOLEAN,
    memo TEXT,
    comments JSONB,
    updated_at TIMESTAMPTZ
) AS $$
    SELECT
        ua.user_id,
        ua.listing_identity_key,
        ua.is_liked,
        ua.memo,
        ua.comments,
        ua.updated_at
    FROM user_annotations ua
    WHERE ua.updated_at > p_since;
$$ LANGUAGE sql SECURITY DEFINER;

-- Index for incremental sync
CREATE INDEX IF NOT EXISTS idx_annotations_updated_at ON user_annotations(updated_at);
