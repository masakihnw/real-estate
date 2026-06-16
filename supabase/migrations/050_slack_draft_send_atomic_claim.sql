-- 050_slack_draft_send_atomic_claim.sql
--
-- 049 の send_pending_slack_drafts() を堅牢化する（database-reviewer 指摘対応）。
--
-- 変更点:
--   1. [CRITICAL] 二重送信レースの解消: SELECT→POST→UPDATE の非アトミックな順序だと、
--      pg_cron と GHA(Python _send_notification_drafts) がほぼ同時に pending を読むと
--      両方が POST しうる。POST 前に UPDATE ... RETURNING で status='sent' に「確定（claim）」
--      してから送信することで、claim 済み行は他方が pending として拾えず二重送信が原理的に起きない。
--      （実運用では pg_cron=JST8:00 と GHA=JST13:00頃 で時間差があり同時実行は稀だが、防御的に。）
--   2. search_path に extensions を含める（net.* の解決安定化・Supabase Linter 警告回避）。
--   3. 古い pending を拾わないよう draft_date >= CURRENT_DATE - 1 に限定。
--   4. error_message に追跡マーカーを残す（非同期送信のデバッグ補助）。
--   5. pg_cron 環境ではクライアントに届かない RAISE NOTICE を RAISE LOG に変更。
--
-- 配送失敗のサイレントロストは引き続き許容（net.http_post は非同期・日次ダイジェストは翌日更新）。
-- 配送保証が必要になれば net._http_response を後続確認する follow-up を別途追加する。

CREATE OR REPLACE FUNCTION public.send_pending_slack_drafts()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_webhook text;
  v_draft   record;
  v_sent    integer := 0;
BEGIN
  SELECT decrypted_secret INTO v_webhook
  FROM vault.decrypted_secrets
  WHERE name = 'slack_webhook_url'
  LIMIT 1;

  IF v_webhook IS NULL OR btrim(v_webhook) = '' THEN
    RAISE LOG 'send_pending_slack_drafts: vault secret slack_webhook_url 未設定のためスキップ';
    RETURN 0;
  END IF;

  -- POST 前に status='sent' へ原子的に確定（claim）してから送信する。
  -- claim 済み行は GHA 側 (status='pending' 条件) が拾えないため二重送信が起きない。
  FOR v_draft IN
    WITH claimed AS (
      UPDATE public.notification_drafts
      SET status = 'sent',
          sent_at = now(),
          updated_at = now(),
          error_message = 'async_dispatched_by_pg_cron'
      WHERE channel = 'slack'
        AND status = 'pending'
        AND draft_date >= CURRENT_DATE - 1
      RETURNING id, message_text
    )
    SELECT id, message_text FROM claimed ORDER BY id
  LOOP
    PERFORM net.http_post(
      url := v_webhook,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('text', v_draft.message_text),
      timeout_milliseconds := 30000
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$$;
