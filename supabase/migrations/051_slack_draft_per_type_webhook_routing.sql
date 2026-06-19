-- pg_cron の Slack ドラフト送信に per-type webhook ルーティングを追加する。
--
-- 背景: notification_drafts は GHA(slack_notify.py) と pg_cron(send_pending_slack_drafts)
-- の両経路から送信されうる。GHA 側は WEBHOOK_OVERRIDES で pipeline_health_report を
-- SLACK_HEALTH_WEBHOOK_URL へ振り分けるが、pg_cron 側（migration 050）は Vault の単一
-- secret 'slack_webhook_url' に全ドラフトを送っており、pipeline_health_report が
-- 健全性アラートと別チャンネル（=既定）に出ていた。
--
-- 対策: pg_cron 経路でも GHA と同等の per-type ルーティングを行う。
--   - notification_type = 'pipeline_health_report' → Vault 'slack_health_webhook_url'
--   - それ以外、または health secret 未設定時 → Vault 'slack_webhook_url'（従来どおり）
--
-- 運用メモ（本ファイルには秘密情報を含めない）:
--   Vault に 'slack_health_webhook_url' を登録すると有効化される。値は GHA Secret
--   SLACK_HEALTH_WEBHOOK_URL と同一の Incoming Webhook URL を使う。
--     SELECT vault.create_secret('<webhook_url>', 'slack_health_webhook_url', '...');
--   未登録の場合は安全に 'slack_webhook_url' へフォールバックする（挙動は変わらない）。

CREATE OR REPLACE FUNCTION public.send_pending_slack_drafts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_default text;
  v_health  text;
  v_draft   record;
  v_target  text;
  v_sent    integer := 0;
BEGIN
  SELECT decrypted_secret INTO v_default
  FROM vault.decrypted_secrets WHERE name = 'slack_webhook_url' LIMIT 1;

  SELECT decrypted_secret INTO v_health
  FROM vault.decrypted_secrets WHERE name = 'slack_health_webhook_url' LIMIT 1;

  IF v_default IS NULL OR btrim(v_default) = '' THEN
    RAISE LOG 'send_pending_slack_drafts: vault secret slack_webhook_url 未設定のためスキップ';
    RETURN 0;
  END IF;

  FOR v_draft IN
    WITH claimed AS (
      UPDATE public.notification_drafts
      SET status = 'sent', sent_at = now(), updated_at = now(),
          error_message = 'async_dispatched_by_pg_cron'
      WHERE channel = 'slack' AND status = 'pending' AND draft_date >= CURRENT_DATE - 1
      RETURNING id, notification_type, message_text
    )
    SELECT id, notification_type, message_text FROM claimed ORDER BY id
  LOOP
    -- per-type ルーティング: health 系は health webhook、無ければ既定にフォールバック
    IF v_draft.notification_type = 'pipeline_health_report'
       AND v_health IS NOT NULL AND btrim(v_health) <> '' THEN
      v_target := v_health;
    ELSE
      v_target := v_default;
    END IF;

    PERFORM net.http_post(
      url := v_target,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object('text', v_draft.message_text),
      timeout_milliseconds := 30000
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$function$;
