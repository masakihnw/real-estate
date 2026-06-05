-- 039: スクレイピング条件の一元管理
--
-- 既存の scraping_config テーブル (id, config JSONB, updated_at) に初期データを投入し、
-- apply_spec_exclusions をこのテーブルから設定を読む方式に更新する。

INSERT INTO scraping_config (id, config) VALUES ('default', '{
  "priceMinMan": 7500,
  "priceMaxMan": 12000,
  "areaMinM2": 60,
  "areaMaxM2": null,
  "areaMinToshinM2": 55,
  "walkMinMax": 10,
  "builtYearMinOffsetYears": 20,
  "totalUnitsMin": 30,
  "layoutPrefixOk": ["2", "3"],
  "allowedLineKeywords": [],
  "allowedStations": [],
  "toshinWards": ["港区", "中央区", "千代田区"],
  "waterfrontKeywords": ["豊洲", "勝どき", "晴海", "月島", "有明", "東雲"]
}'::jsonb)
ON CONFLICT (id) DO UPDATE SET config = EXCLUDED.config, updated_at = NOW();

-- apply_spec_exclusions を scraping_config 参照版に更新（パラメータなし版）
CREATE OR REPLACE FUNCTION apply_spec_exclusions()
RETURNS TABLE(excluded_count INT, restored_count INT) AS $$
DECLARE
  cfg JSONB;
  v_price_max INT;
  v_price_min INT;
  v_area_min INT;
  v_area_min_toshin INT;
  v_excluded INT;
  v_restored INT;
BEGIN
  SELECT config INTO cfg FROM scraping_config WHERE id = 'default';
  v_price_max := (cfg->>'priceMaxMan')::INT;
  v_price_min := (cfg->>'priceMinMan')::INT;
  v_area_min := (cfg->>'areaMinM2')::INT;
  v_area_min_toshin := (cfg->>'areaMinToshinM2')::INT;

  WITH to_exclude AS (
    SELECT l.id,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN ls.price_man IS NOT NULL AND ls.price_man > v_price_max
             THEN 'price_over_' || v_price_max END,
        CASE WHEN ls.price_man IS NOT NULL AND ls.price_man < v_price_min
             THEN 'price_under_' || v_price_min END,
        CASE WHEN l.area_m2 IS NOT NULL AND l.area_m2 < v_area_min_toshin
             THEN 'area_under_' || v_area_min_toshin END,
        CASE WHEN l.area_m2 IS NOT NULL
                  AND l.area_m2 >= v_area_min_toshin
                  AND l.area_m2 < v_area_min
                  AND NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(cfg->'toshinWards') w WHERE l.address LIKE '%' || w.value || '%'
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements_text(cfg->'waterfrontKeywords') w WHERE l.address LIKE '%' || w.value || '%'
                  )
             THEN 'area_under_' || v_area_min || '_non_toshin' END
      ], NULL) AS reasons
    FROM listings l
    LEFT JOIN LATERAL (
      SELECT * FROM listing_sources s WHERE s.listing_id = l.id AND s.is_active
      ORDER BY s.last_seen_at DESC LIMIT 1
    ) ls ON TRUE
    WHERE NOT l.spec_excluded AND l.is_active = true
  )
  UPDATE listings SET spec_excluded = true, spec_exclusion_reasons = te.reasons, updated_at = NOW()
  FROM to_exclude te WHERE listings.id = te.id AND array_length(te.reasons, 1) > 0;
  GET DIAGNOSTICS v_excluded = ROW_COUNT;

  WITH to_restore AS (
    SELECT l.id FROM listings l
    LEFT JOIN LATERAL (
      SELECT * FROM listing_sources s WHERE s.listing_id = l.id AND s.is_active
      ORDER BY s.last_seen_at DESC LIMIT 1
    ) ls ON TRUE
    WHERE l.spec_excluded AND l.is_active = true
      AND (ls.price_man IS NULL OR (ls.price_man >= v_price_min AND ls.price_man <= v_price_max))
      AND (
        l.area_m2 IS NULL
        OR l.area_m2 >= v_area_min
        OR (l.area_m2 >= v_area_min_toshin AND (
          EXISTS (SELECT 1 FROM jsonb_array_elements_text(cfg->'toshinWards') w WHERE l.address LIKE '%' || w.value || '%')
          OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(cfg->'waterfrontKeywords') w WHERE l.address LIKE '%' || w.value || '%')
        ))
      )
  )
  UPDATE listings SET spec_excluded = false, spec_exclusion_reasons = '{}', updated_at = NOW()
  FROM to_restore tr
  WHERE listings.id = tr.id;
  GET DIAGNOSTICS v_restored = ROW_COUNT;

  RETURN QUERY SELECT v_excluded, v_restored;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';
