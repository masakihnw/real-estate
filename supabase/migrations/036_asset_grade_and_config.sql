-- 036: asset_grade カラム追加 + 閾値設定テーブル + upsert_ai_enrichment 更新
--
-- ルールベースの asset_rank を廃止し、AI スコアリング (ai_scoring) に一本化。
-- listing_score (0-100) から asset_grade (S/A/B/C/D) を導出。
-- 閾値は app_config テーブルで管理し、iOS が動的に読み込む。

-- ============================================================
-- 1. enrichments テーブルに asset_grade + reasoning カラム追加
-- ============================================================
ALTER TABLE enrichments
  ADD COLUMN IF NOT EXISTS asset_grade TEXT,
  ADD COLUMN IF NOT EXISTS asset_grade_override_reason TEXT,
  ADD COLUMN IF NOT EXISTS ai_scoring_reasoning JSONB;

COMMENT ON COLUMN enrichments.asset_grade IS 'AI スコアリングが出力するグレード (S/A/B/C/D)。listing_score + 閾値から導出。不適合条件で強制降格あり';
COMMENT ON COLUMN enrichments.asset_grade_override_reason IS '閾値通りでないグレードの理由（不適合条件該当時等）。NULL = 閾値通り';
COMMENT ON COLUMN enrichments.ai_scoring_reasoning IS 'AI スコアリングの5軸別スコア+ノート (JSONB)。{budget, living, location, building, exit, strengths, weaknesses}';

-- ============================================================
-- 2. app_config テーブル（汎用設定キーバリューストア）
-- ============================================================
CREATE TABLE IF NOT EXISTS app_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  description TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE app_config IS '汎用設定テーブル。iOS アプリや Routine が動的に参照する閾値・設定を格納';

ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated_read_only" ON app_config FOR SELECT USING (auth.role() = 'authenticated');

INSERT INTO app_config (key, value, description) VALUES
  ('grade_thresholds', '{"S": 80, "A": 65, "B": 50, "C": 35}', 'listing_score → asset_grade の閾値。S≥80, A≥65, B≥50, C≥35, D<35')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();

-- RPC: iOS が閾値を取得
CREATE OR REPLACE FUNCTION get_app_config(p_key TEXT)
RETURNS JSONB
LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT value FROM app_config WHERE key = p_key;
$$;

COMMENT ON FUNCTION get_app_config IS 'app_config テーブルから設定値を取得。iOS が grade_thresholds 等を動的に読み込む';

-- ============================================================
-- 3. upsert_ai_enrichment の ai_scoring ブランチを更新
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_ai_enrichment(
  p_listing_id BIGINT,
  p_module TEXT,
  p_result JSONB,
  p_model TEXT DEFAULT 'claude-sonnet-4-6',
  p_prompt_hash TEXT DEFAULT NULL,
  p_prompt_version INT DEFAULT NULL,
  p_source TEXT DEFAULT 'routine'
) RETURNS BOOLEAN AS $$
DECLARE
  v_existing_hash TEXT;
  v_existing_module_hash TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM enrichments WHERE listing_id = p_listing_id) THEN
    INSERT INTO enrichments (listing_id) VALUES (p_listing_id);
  END IF;

  IF p_module = 'investment_summary' THEN
    SELECT investment_summary_prompt_hash INTO v_existing_module_hash
    FROM enrichments WHERE listing_id = p_listing_id;

    IF v_existing_module_hash = p_prompt_hash
       AND (SELECT ai_recommendation_score FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      ai_recommendation_score = (p_result->>'score')::INT,
      ai_recommendation_summary = p_result->>'conclusion',
      ai_recommendation_flags = p_result->'flags',
      ai_recommendation_action = p_result->>'action',
      ai_recommendation_scenarios = p_result->'scenarios',
      investment_summary = p_result,
      highlight_badge = CASE (p_result->>'score')::INT
        WHEN 5 THEN '強く推奨' WHEN 4 THEN '推奨' WHEN 3 THEN '条件次第'
        WHEN 2 THEN '非推奨' ELSE '見送り' END,
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      investment_summary_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'ai_scoring' THEN
    SELECT ai_scoring_prompt_hash INTO v_existing_module_hash
    FROM enrichments WHERE listing_id = p_listing_id;

    IF v_existing_module_hash = p_prompt_hash
       AND (SELECT ai_listing_score FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      listing_score = (p_result->>'listing_score')::INT,
      price_fairness_score = (p_result->>'price_fairness_score')::INT,
      ai_listing_score = (p_result->>'listing_score')::INT,
      ai_price_fairness_score = (p_result->>'price_fairness_score')::INT,
      asset_grade = p_result->>'asset_grade',
      asset_grade_override_reason = p_result->>'grade_override_reason',
      ai_scoring_reasoning = p_result->'reasoning',
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_scoring_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'text_enricher' THEN
    SELECT text_enricher_prompt_hash INTO v_existing_module_hash
    FROM enrichments WHERE listing_id = p_listing_id;

    IF v_existing_module_hash = p_prompt_hash
       AND (SELECT extracted_features FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      extracted_features = p_result,
      key_strengths = p_result->'equipment_highlights',
      key_risks = p_result->'risk_factors',
      ai_source = p_source,
      ai_model = p_model,
      text_enricher_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'dedup' THEN
    UPDATE enrichments SET
      dedup_confidence = (p_result->>'confidence')::NUMERIC,
      dedup_candidates = p_result->'candidates',
      ai_source = p_source,
      ai_model = p_model,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'image_analyzer' THEN
    SELECT image_analyzer_prompt_hash INTO v_existing_module_hash
    FROM enrichments WHERE listing_id = p_listing_id;

    IF v_existing_module_hash = p_prompt_hash
       AND (SELECT image_categories FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      image_categories = p_result,
      best_thumbnail_url = p_result->>'best_thumbnail_url',
      ai_source = p_source,
      ai_model = p_model,
      image_analyzer_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSE
    RAISE EXCEPTION 'Unknown module: %', p_module;
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION upsert_ai_enrichment IS 'Routine から AI 分析結果を idempotent に書き戻す。036: ai_scoring に asset_grade / reasoning を追加';

-- ============================================================
-- 4. listings_feed_light ビューに asset_grade を追加
-- ============================================================
DROP VIEW IF EXISTS listings_feed_light CASCADE;

CREATE VIEW listings_feed_light AS
SELECT
    l.id,
    l.identity_key,
    l.name,
    l.normalized_name,
    l.address,
    l.ss_address,
    l.layout,
    l.area_m2,
    l.area_max_m2,
    l.built_year,
    l.built_str,
    l.station_line,
    l.walk_min,
    l.total_units,
    l.floor_position,
    l.floor_total,
    l.floor_structure,
    l.ownership,
    l.management_fee,
    l.repair_reserve_fund,
    l.repair_fund_onetime,
    l.direction,
    l.balcony_area_m2,
    l.parking,
    l.constructor,
    l.zoning,
    l.property_type,
    l.developer_name,
    l.developer_brokerage,
    l.list_ward_roman,
    l.delivery_date,
    l.duplicate_count,
    l.latitude,
    l.longitude,
    l.feature_tags,
    l.is_active,
    l.is_new,
    l.is_new_building,
    l.first_seen_at,
    l.first_seen_source,
    l.geocode_confidence,
    l.geocode_fixed,
    l.alt_urls,
    l.created_at,
    l.updated_at,
    ls.source,
    ls.url,
    ls.price_man,
    ls.price_max_man,
    ls.listing_agent,
    ls.is_motodzuke,
    e.ss_lookup_status,
    e.ss_profit_pct,
    e.ss_oki_price_70m2,
    e.ss_m2_discount,
    e.ss_value_judgment,
    e.ss_station_rank,
    e.ss_ward_rank,
    e.ss_sumai_surfin_url,
    e.ss_appreciation_rate,
    e.ss_favorite_count,
    e.ss_purchase_judgment,
    e.ss_sim_best_5yr,
    e.ss_sim_best_10yr,
    e.ss_sim_standard_5yr,
    e.ss_sim_standard_10yr,
    e.ss_sim_worst_5yr,
    e.ss_sim_worst_10yr,
    e.ss_loan_balance_5yr,
    e.ss_loan_balance_10yr,
    e.ss_sim_base_price,
    e.ss_new_m2_price,
    e.ss_forecast_m2_price,
    e.ss_forecast_change_rate,
    e.price_fairness_score,
    e.resale_liquidity_score,
    e.competing_listings_count,
    e.listing_score,
    e.asset_grade,
    e.ai_scoring_reasoning,
    e.ai_recommendation_score,
    e.ai_recommendation_summary,
    e.ai_recommendation_flags,
    e.ai_recommendation_action,
    e.highlight_badge,
    e.best_thumbnail_url,
    e.dedup_confidence,
    e.key_strengths,
    e.key_risks,
    e.is_cheapest_in_building,
    e.competing_price_range,
    e.near_miss,
    e.near_miss_reasons
FROM listings l
LEFT JOIN LATERAL (
    SELECT * FROM listing_sources s
    WHERE s.listing_id = l.id AND s.is_active
    ORDER BY s.last_seen_at DESC LIMIT 1
) ls ON TRUE
LEFT JOIN enrichments e ON e.listing_id = l.id;

-- 依存 RPC を再作成
CREATE OR REPLACE FUNCTION get_listings_since_light(since_ts TIMESTAMPTZ)
RETURNS SETOF listings_feed_light AS $$
    SELECT * FROM listings_feed_light WHERE updated_at > since_ts;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION get_liked_inactive_listings(p_listing_ids BIGINT[])
RETURNS SETOF listings_feed_light AS $$
  SELECT lf.* FROM listings_feed_light lf
  WHERE lf.id = ANY(p_listing_ids) AND lf.is_active = false;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ============================================================
-- 5. ai_scoring の config に rescore_interval を追加
-- ============================================================
UPDATE ai_prompts
SET config = config || '{"rescore_interval": "1 day"}'::jsonb
WHERE module = 'ai_scoring' AND is_active = true
  AND NOT (config ? 'rescore_interval');
