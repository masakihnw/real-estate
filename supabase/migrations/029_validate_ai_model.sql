-- 029: upsert_ai_enrichment にモデル名バリデーションを追加
-- 背景: ルーティンセッションが Python スクリプトの出力を 'claude-sonnet-4-6' として記録した問題への対策

CREATE OR REPLACE FUNCTION upsert_ai_enrichment(
  p_listing_id BIGINT,
  p_module TEXT,
  p_result JSONB,
  p_model TEXT,
  p_prompt_hash TEXT,
  p_prompt_version INT,
  p_source TEXT DEFAULT 'routine'
) RETURNS BOOLEAN AS $$
DECLARE
  v_existing_hash TEXT;
  v_existing_module_hash TEXT;
BEGIN
  IF p_model NOT LIKE 'claude-%' THEN
    RAISE EXCEPTION 'Invalid model name: %. Must be a Claude model identifier.', p_model;
  END IF;

  SELECT ai_prompt_hash INTO v_existing_hash
  FROM enrichments WHERE listing_id = p_listing_id;

  IF p_module = 'investment_summary' THEN
    IF v_existing_hash = p_prompt_hash
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
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'text_enricher' THEN
    IF (SELECT extracted_features FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
       AND v_existing_hash = p_prompt_hash
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      extracted_features = p_result,
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'dedup' THEN
    UPDATE enrichments SET
      dedup_confidence = (p_result->>'confidence')::FLOAT,
      ai_source = p_source,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'image_analyzer' THEN
    IF (SELECT image_categories FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
       AND v_existing_hash = p_prompt_hash
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      image_categories = p_result,
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'ai_scoring' THEN
    UPDATE enrichments SET
      listing_score = (p_result->>'listing_score')::INT,
      price_fairness_score = (p_result->>'price_fairness_score')::INT,
      ai_listing_score = (p_result->>'listing_score')::INT,
      ai_price_fairness_score = (p_result->>'price_fairness_score')::INT,
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSE
    RAISE EXCEPTION 'Unknown module: %', p_module;
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
