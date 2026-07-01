-- ============================================================
-- 053: 無料プラン運用の補強 RPC
--      A. list_backup_tables()      … データバックアップ対象の列挙
--      B. health_check_cron_jobs()  … pg_cron ジョブの死活監視
--
-- 背景: Supabase を無料プランへ変更した。無料プランには自動バックアップ/PITR が
--       無く、また無操作が続くとプロジェクトが一時停止され pg_cron も止まる。
--       - A は scripts/backup_supabase.py が全テーブルを退避する際の対象列挙に使う。
--       - B は .github/workflows/cron-watchdog.yml が日次で死活監視する際に使う。
-- いずれも冪等（CREATE OR REPLACE）。
-- ============================================================

-- ============================================================
-- A. バックアップ対象テーブルの列挙
--    public スキーマの実テーブル（ビュー・外部表を除く）のみを返す。
-- ============================================================
CREATE OR REPLACE FUNCTION list_backup_tables()
RETURNS TABLE (table_name TEXT) AS $$
    SELECT c.relname::TEXT
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'          -- 通常テーブルのみ（r=ordinary table）
    ORDER BY c.relname;
$$ LANGUAGE sql SECURITY DEFINER;

COMMENT ON FUNCTION list_backup_tables IS
    'public スキーマの実テーブル名一覧。backup_supabase.py のバックアップ対象列挙用';

-- ============================================================
-- B. pg_cron ジョブの死活監視
--    各アクティブジョブについて、直近の実行状態・最終成功からの経過時間を返し、
--    「一度も成功していない / 最終成功が古すぎる / 直近実行が失敗」のいずれかを
--    is_alert=true で通知する。全ジョブが日次のため既定しきい値は 26 時間
--    （日次 + GHA/実行ゆらぎ 2 時間の猶予）。
-- ============================================================
CREATE OR REPLACE FUNCTION health_check_cron_jobs(
    p_max_age_hours NUMERIC DEFAULT 26
) RETURNS TABLE (
    jobid BIGINT,
    jobname TEXT,
    schedule TEXT,
    active BOOLEAN,
    last_run TIMESTAMPTZ,
    last_status TEXT,
    last_success TIMESTAMPTZ,
    hours_since_success NUMERIC,
    is_alert BOOLEAN,
    detail TEXT
) AS $$
    WITH last_run AS (
        SELECT DISTINCT ON (d.jobid) d.jobid, d.start_time, d.status
        FROM cron.job_run_details d
        ORDER BY d.jobid, d.start_time DESC
    ),
    last_ok AS (
        SELECT d.jobid, MAX(d.start_time) AS success_time
        FROM cron.job_run_details d
        WHERE d.status = 'succeeded'
        GROUP BY d.jobid
    )
    SELECT
        j.jobid,
        j.jobname::TEXT,
        j.schedule::TEXT,
        j.active,
        lr.start_time,
        lr.status::TEXT,
        lo.success_time,
        ROUND(EXTRACT(EPOCH FROM (now() - lo.success_time)) / 3600.0, 1),
        (
            j.active AND (
                lo.success_time IS NULL
                OR lo.success_time < now() - (p_max_age_hours * interval '1 hour')
                OR lr.status IS DISTINCT FROM 'succeeded'
            )
        ) AS is_alert,
        format(
            'last_run=%s status=%s last_success=%s',
            COALESCE(lr.start_time::TEXT, 'never'),
            COALESCE(lr.status, 'n/a'),
            COALESCE(lo.success_time::TEXT, 'never')
        )::TEXT
    FROM cron.job j
    LEFT JOIN last_run lr ON lr.jobid = j.jobid
    LEFT JOIN last_ok  lo ON lo.jobid = j.jobid
    ORDER BY j.jobid;
$$ LANGUAGE sql SECURITY DEFINER;

COMMENT ON FUNCTION health_check_cron_jobs IS
    'pg_cron 各ジョブの死活監視。is_alert=true は未成功/失効/直近失敗。cron-watchdog.yml 用';
