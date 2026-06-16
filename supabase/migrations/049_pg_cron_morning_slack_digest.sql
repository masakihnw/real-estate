-- 049_pg_cron_morning_slack_digest.sql
--
-- 「午前中に1回」確実に Slack 通知するための定時送信。
--
-- 背景:
--   Slack 通知ドラフト（notification_drafts）の送信は GHA(run_finalize / notification-watchdog)
--   経由だが、GitHub Actions の cron は実測4〜5h遅延し、朝に作られた new_listing_digest 等が
--   午後にずれて届く。Desktop の routine② / ③（JST 4:00 / 5:30, 定時・遅延なし）が朝6時頃までに
--   ドラフトを作るので、Supabase 側 pg_cron で JST 8:00 に確実送信し「午前中に1回」を保証する。
--
-- 設計:
--   - Slack webhook URL は vault の 'slack_webhook_url' から取得する（秘密はコードに置かない）。
--     未登録のうちは安全に no-op（RAISE NOTICE のみ）。登録された翌朝から自動的に送信が始まる。
--       登録方法（ユーザーが1回だけ実行）:
--       select vault.create_secret('https://hooks.slack.com/services/XXX', 'slack_webhook_url', 'morning digest webhook');
--   - channel='slack' かつ status='pending' のドラフトのみ送信し、送信後 status='sent' に更新する。
--     GHA 側の送信も status='pending' を条件にするため、先に走った方が送り、もう一方はスキップ＝
--     二重送信を防止。pg_cron(JST8:00) は GHA(遅延でJST13頃) より先に走るため朝送信を担う。
--   - net.http_post は非同期のため送信完了を待たず status='sent' にする（楽観的）。Slack webhook の
--     失敗は稀で、日次ダイジェストは翌日分で更新されるため許容。配送保証が必要なら将来 net._http_response
--     を確認する follow-up を足す。
--   - メッセージは incoming webhook の text フィールドで送る。Block Kit の 3000 字/ブロック制限とは別枠で
--     比較的長文も許容されるが、極端に長い場合は Slack 側で切り詰められうる点に留意。

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.send_pending_slack_drafts()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
    RAISE NOTICE 'send_pending_slack_drafts: vault secret slack_webhook_url 未設定のためスキップ';
    RETURN 0;
  END IF;

  FOR v_draft IN
    SELECT id, message_text
    FROM public.notification_drafts
    WHERE channel = 'slack' AND status = 'pending'
    ORDER BY id
  LOOP
    PERFORM net.http_post(
      url := v_webhook,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('text', v_draft.message_text),
      timeout_milliseconds := 30000
    );
    UPDATE public.notification_drafts
    SET status = 'sent', sent_at = now(), updated_at = now()
    WHERE id = v_draft.id;
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$$;

-- 既存の同名ジョブがあれば解除（冪等な再適用のため）
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'send-morning-slack-drafts';

-- 毎日 UTC 23:00 (= JST 8:00) に pending な Slack ドラフトを送信
SELECT cron.schedule(
  'send-morning-slack-drafts',
  '0 23 * * *',
  $$ SELECT public.send_pending_slack_drafts(); $$
);
