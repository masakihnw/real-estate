-- Migration: 032_improve_dedup_matching
-- Purpose: Fix get_listings_for_ai('dedup') to catch dash-variant duplicates
-- Changes:
--   1. group_members: TRANSLATE-based dash normalization instead of exact normalized_name match
--   2. Remove duplicate_count > 1 filter (valid candidates with count=1 were excluded)

CREATE OR REPLACE FUNCTION get_listings_for_ai(
  p_module TEXT,
  p_config JSONB DEFAULT NULL
) RETURNS TABLE (
  listing_id BIGINT,
  listing_data JSONB
) AS $$
DECLARE
  v_config JSONB;
BEGIN
  IF p_config IS NULL OR p_config = '{}'::jsonb THEN
    SELECT ap.config INTO v_config
    FROM ai_prompts ap
    WHERE ap.module = p_module AND ap.is_active = true
    LIMIT 1;
    v_config := COALESCE(v_config, '{}'::jsonb);
  ELSE
    v_config := p_config;
  END IF;
  CASE p_module
    WHEN 'investment_summary' THEN
      RETURN QUERY
        SELECT lf.id, jsonb_build_object(
          'id', lf.id, 'name', lf.name, 'address', lf.address,
          'layout', lf.layout, 'area_m2', lf.area_m2, 'built_year', lf.built_year,
          'floor_position', lf.floor_position, 'floor_total', lf.floor_total,
          'total_units', lf.total_units, 'ownership', lf.ownership,
          'management_fee', lf.management_fee, 'repair_reserve_fund', lf.repair_reserve_fund,
          'direction', lf.direction, 'parking', lf.parking,
          'station_line', lf.station_line, 'walk_min', lf.walk_min,
          'price_man', lf.price_man, 'feature_tags', lf.feature_tags,
          'ss_profit_pct', lf.ss_profit_pct, 'ss_m2_discount', lf.ss_m2_discount,
          'ss_value_judgment', lf.ss_value_judgment, 'ss_purchase_judgment', lf.ss_purchase_judgment,
          'commute_info', lf.commute_info, 'commute_info_v2', lf.commute_info_v2,
          'hazard_info', lf.hazard_info,
          'listing_score', lf.listing_score, 'price_fairness_score', lf.price_fairness_score,
          'resale_liquidity_score', lf.resale_liquidity_score,
          'extracted_features', lf.extracted_features,
          'key_strengths', lf.key_strengths, 'key_risks', lf.key_risks
        )
        FROM listings_feed lf
        LEFT JOIN enrichments e ON e.listing_id = lf.id
        WHERE lf.is_active = true
          AND (
            e.ai_recommendation_score IS NULL
            OR e.investment_summary_prompt_hash IS DISTINCT FROM (
              SELECT ap.prompt_hash FROM ai_prompts ap
              WHERE ap.module = 'investment_summary' AND ap.is_active = true LIMIT 1
            )
            OR (
              e.ai_recommendation_score >= COALESCE((v_config->>'rescore_min_score')::int, 4)
              AND e.ai_calculated_at < now() - COALESCE(
                (v_config->>'rescore_interval')::interval,
                interval '1 day'
              )
            )
          )
        ORDER BY
          CASE WHEN e.ai_recommendation_score IS NULL THEN 0 ELSE 1 END,
          lf.created_at DESC
        LIMIT COALESCE((v_config->>'max_items_per_run')::int, 20);

    WHEN 'text_enricher' THEN
      RETURN QUERY
        SELECT lf.id, jsonb_build_object(
          'id', lf.id, 'name', lf.name, 'address', lf.address,
          'layout', lf.layout, 'area_m2', lf.area_m2, 'built_year', lf.built_year,
          'floor_position', lf.floor_position, 'floor_total', lf.floor_total,
          'total_units', lf.total_units, 'ownership', lf.ownership,
          'management_fee', lf.management_fee, 'repair_reserve_fund', lf.repair_reserve_fund,
          'direction', lf.direction, 'parking', lf.parking,
          'station_line', lf.station_line, 'walk_min', lf.walk_min,
          'price_man', lf.price_man, 'feature_tags', lf.feature_tags,
          'key_strengths', lf.key_strengths, 'key_risks', lf.key_risks
        )
        FROM listings_feed lf
        LEFT JOIN enrichments e ON e.listing_id = lf.id
        WHERE lf.is_active = true
          AND lf.feature_tags IS NOT NULL
          AND (
            lf.extracted_features IS NULL
            OR e.text_enricher_prompt_hash IS DISTINCT FROM (
              SELECT ap.prompt_hash FROM ai_prompts ap
              WHERE ap.module = 'text_enricher' AND ap.is_active = true LIMIT 1
            )
          )
        ORDER BY
          CASE WHEN lf.extracted_features IS NULL THEN 0 ELSE 1 END,
          lf.created_at DESC
        LIMIT COALESCE((v_config->>'max_items_per_run')::int, 50);

    WHEN 'dedup' THEN
      RETURN QUERY
        SELECT l.id::bigint AS listing_id,
          jsonb_build_object(
            'id', l.id,
            'name', l.name,
            'normalized_name', l.normalized_name,
            'identity_key', l.identity_key,
            'address', l.address,
            'layout', l.layout,
            'area_m2', l.area_m2,
            'floor_position', l.floor_position,
            'floor_total', l.floor_total,
            'built_year', l.built_year,
            'total_units', l.total_units,
            'station_line', l.station_line,
            'walk_min', l.walk_min,
            'duplicate_count', l.duplicate_count,
            'source', l.first_seen_source,
            'price_man', (SELECT ls.price_man FROM listing_sources ls WHERE ls.listing_id = l.id AND ls.is_active = true ORDER BY ls.price_man DESC NULLS LAST LIMIT 1),
            'group_key', COALESCE(NULLIF(l.normalized_name, ''), l.address),
            'group_members', (
              SELECT jsonb_agg(jsonb_build_object(
                'id', l2.id,
                'name', l2.name,
                'normalized_name', l2.normalized_name,
                'layout', l2.layout,
                'area_m2', l2.area_m2,
                'floor_position', l2.floor_position,
                'floor_total', l2.floor_total,
                'built_year', l2.built_year,
                'total_units', l2.total_units,
                'source', l2.first_seen_source,
                'price_man', (SELECT ls2.price_man FROM listing_sources ls2 WHERE ls2.listing_id = l2.id AND ls2.is_active = true ORDER BY ls2.price_man DESC NULLS LAST LIMIT 1)
              ))
              FROM listings l2
              WHERE l2.is_active = true
                AND l2.id != l.id
                AND (
                  -- Fix 1: dash-normalized matching instead of exact normalized_name
                  (TRANSLATE(l2.normalized_name, 'ー－‐–—', '-----') = TRANSLATE(l.normalized_name, 'ー－‐–—', '-----')
                   AND l.normalized_name != '' AND l.normalized_name IS NOT NULL)
                  OR (l2.floor_total = l.floor_total AND l2.total_units = l.total_units AND l2.address LIKE '%' || SUBSTRING(l.address FROM '[^0-9]{2,}[0-9]+') || '%' AND l.floor_total IS NOT NULL)
                )
            )
          ) AS listing_data
        FROM listings l
        JOIN enrichments e ON e.listing_id = l.id
        WHERE l.is_active = true
          -- Fix 2: removed duplicate_count > 1 filter
          AND e.dedup_confidence IS NULL
        ORDER BY l.created_at DESC
        LIMIT COALESCE((v_config->>'max_items_per_run')::int, 30);

    WHEN 'image_analyzer' THEN
      RETURN QUERY
        SELECT lf.id, jsonb_build_object(
          'id', lf.id,
          'name', lf.name,
          'suumo_images', lf.suumo_images
        )
        FROM listings_feed lf
        WHERE lf.is_active = true
          AND lf.image_categories IS NULL
          AND lf.suumo_images IS NOT NULL
          AND jsonb_array_length(lf.suumo_images) > 0
        ORDER BY lf.created_at DESC
        LIMIT COALESCE((v_config->>'max_items_per_run')::int, 100);

    WHEN 'ai_scoring' THEN
      RETURN QUERY
        SELECT sub.id, sub.listing_data
        FROM (
          SELECT DISTINCT ON (COALESCE(NULLIF(lf.normalized_name, ''), lf.id::text))
            lf.id,
            jsonb_build_object(
              'id', lf.id, 'name', lf.name, 'address', lf.address,
              'layout', lf.layout, 'area_m2', lf.area_m2, 'built_year', lf.built_year,
              'floor_position', lf.floor_position, 'floor_total', lf.floor_total,
              'total_units', lf.total_units, 'ownership', lf.ownership,
              'management_fee', lf.management_fee, 'repair_reserve_fund', lf.repair_reserve_fund,
              'direction', lf.direction, 'parking', lf.parking,
              'station_line', lf.station_line, 'walk_min', lf.walk_min,
              'price_man', lf.price_man, 'feature_tags', lf.feature_tags,
              'ss_profit_pct', lf.ss_profit_pct, 'ss_m2_discount', lf.ss_m2_discount,
              'ss_value_judgment', lf.ss_value_judgment, 'ss_purchase_judgment', lf.ss_purchase_judgment,
              'commute_info', lf.commute_info, 'commute_info_v2', lf.commute_info_v2,
              'hazard_info', lf.hazard_info,
              'listing_score', lf.listing_score, 'price_fairness_score', lf.price_fairness_score,
              'resale_liquidity_score', lf.resale_liquidity_score,
              'extracted_features', lf.extracted_features,
              'key_strengths', lf.key_strengths, 'key_risks', lf.key_risks
            ) AS listing_data,
            CASE WHEN e.ai_listing_score IS NULL THEN 0 ELSE 1 END AS null_priority
          FROM listings_feed lf
          LEFT JOIN enrichments e ON e.listing_id = lf.id
          WHERE lf.is_active = true
            AND (
              e.ai_listing_score IS NULL
              OR e.ai_scoring_prompt_hash IS DISTINCT FROM (
                SELECT ap.prompt_hash FROM ai_prompts ap
                WHERE ap.module = 'ai_scoring' AND ap.is_active = true LIMIT 1
              )
              OR (
                e.ai_listing_score >= COALESCE((v_config->>'rescore_min_score')::int, 65)
                AND e.ai_calculated_at < now() - COALESCE(
                  (v_config->>'rescore_interval')::interval,
                  interval '1 day'
                )
              )
            )
          ORDER BY COALESCE(NULLIF(lf.normalized_name, ''), lf.id::text), lf.listing_score DESC NULLS LAST
        ) sub
        ORDER BY sub.null_priority, sub.id
        LIMIT COALESCE((v_config->>'max_items_per_run')::int, 40);

    ELSE
      RETURN;
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_listings_for_ai IS 'Routine 用: module ごとに AI 分析が必要な物件を取得。モジュール別 prompt_hash で正確な再処理判定。未分析物件を優先的に返す。dedup: ダッシュ正規化マッチング対応';
