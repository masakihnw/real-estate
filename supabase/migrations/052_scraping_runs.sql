-- Scraping Runs: サイト別・ラン別の sync 挿入件数トラッキング
--
-- 目的: 「パースは成功しているのに sync 側で真新規の挿入が止まる」サイレント回帰
-- （例: suumo が 6/17 以降 真新規ゼロ・他サイトは挿入継続のため合算 new_listings_24h
-- では検知できなかった事故）を、サイト別の真新規挿入数の履歴として永続化し検知する。
--
-- 既存の監視との役割分担:
--   - scraper_metrics.json   : パース層（parsed/parse_failures/媒体全損）
--   - health_check_pipeline_freshness() の new_listings_24h : 全サイト合算の鮮度
--   - このテーブル            : sync 層・サイト別の真新規挿入数（本ファイルが埋める穴）

CREATE TABLE IF NOT EXISTS scraping_runs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- 1回のパイプライン実行を束ねる ID（GHA は run-attempt 単位、ローカルは timestamp）
    run_id TEXT NOT NULL,
    source TEXT NOT NULL,
    property_type TEXT NOT NULL DEFAULT 'chuko',
    new_count INT NOT NULL DEFAULT 0,
    reappeared_count INT NOT NULL DEFAULT 0,
    updated_count INT NOT NULL DEFAULT 0,
    removed_count INT NOT NULL DEFAULT 0,
    unchanged_count INT NOT NULL DEFAULT 0,
    run_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 同一ラン・同一ソースの再実行（リトライ）は上書きする
    UNIQUE (run_id, source, property_type)
);

CREATE INDEX IF NOT EXISTS idx_scraping_runs_run_at
    ON scraping_runs (run_at);
CREATE INDEX IF NOT EXISTS idx_scraping_runs_source_run_at
    ON scraping_runs (source, property_type, run_at);

ALTER TABLE scraping_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS scraping_runs_service_all ON scraping_runs;
CREATE POLICY scraping_runs_service_all ON scraping_runs
    FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS scraping_runs_read ON scraping_runs;
CREATE POLICY scraping_runs_read ON scraping_runs
    FOR SELECT USING (true);

-- detect_source_insertion_anomalies:
-- 「直近 p_recent_hours で真新規（new + reappeared）がゼロ」かつ
-- 「基準期間（p_recent_hours 〜 p_baseline_days 前）では productive だった」ソースを返す。
-- 1ラン単位の new=0 は通常運転（その時間帯に新着が無いだけ）なので、
-- 「直近に複数回走っているのに連続ゼロ」かつ「以前は挿入していた」で誤検知を避ける。
CREATE OR REPLACE FUNCTION detect_source_insertion_anomalies(
    p_recent_hours INT DEFAULT 72,
    p_baseline_days INT DEFAULT 10,
    p_min_baseline_total INT DEFAULT 5,
    p_min_recent_runs INT DEFAULT 3
) RETURNS TABLE (
    source TEXT,
    property_type TEXT,
    recent_inserts BIGINT,
    recent_runs BIGINT,
    baseline_inserts BIGINT,
    baseline_runs BIGINT
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH recent AS (
        SELECT sr.source, sr.property_type,
               SUM(sr.new_count + sr.reappeared_count) AS inserts,
               COUNT(*) AS runs
        FROM scraping_runs sr
        WHERE sr.run_at >= now() - make_interval(hours => p_recent_hours)
        GROUP BY sr.source, sr.property_type
    ),
    baseline AS (
        SELECT sr.source, sr.property_type,
               SUM(sr.new_count + sr.reappeared_count) AS inserts,
               COUNT(*) AS runs
        FROM scraping_runs sr
        WHERE sr.run_at <  now() - make_interval(hours => p_recent_hours)
          AND sr.run_at >= now() - make_interval(days => p_baseline_days)
        GROUP BY sr.source, sr.property_type
    )
    SELECT r.source, r.property_type,
           r.inserts AS recent_inserts,
           r.runs AS recent_runs,
           COALESCE(b.inserts, 0) AS baseline_inserts,
           COALESCE(b.runs, 0) AS baseline_runs
    FROM recent r
    JOIN baseline b ON b.source = r.source AND b.property_type = r.property_type
    WHERE r.runs >= p_min_recent_runs
      AND r.inserts = 0
      AND b.inserts >= p_min_baseline_total
    ORDER BY b.inserts DESC;
$$;
