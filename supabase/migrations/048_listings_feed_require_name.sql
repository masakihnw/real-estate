-- 048_listings_feed_require_name.sql
--
-- listings_feed_light に「物件名が入っているものだけ」ゲートを追加する。
--
-- 背景:
--   HOME'S の匿名掲載など物件名が伏せられた物件（name が NULL/空）は、住所が丁目
--   までしか無く建物特定が困難で、AI スコアリングも未分析（grade なし）のまま残る。
--   方針として「物件名が入っているものだけアプリ表示・Slack通知する」と決定したため、
--   アプリの単一データソースである本ビューで一括除外する。
--
--   後から同一 URL に物件名が付けば source+URL 突合（supabase_sync）が既存 listing の
--   name を更新するため、その時点で本ビューに自動的に再出現する（取得は継続している）。
--
-- 影響:
--   アプリ（get_listings_since_light 等は本ビューを SELECT * する）は無名物件を同期
--   しなくなる。Slack 新着通知側は slack_notify.py で別途 name 非空フィルタを適用する。
--
-- 列の構成・順序は既存定義から一切変更しない（WHERE 条件のみ追加）。

CREATE OR REPLACE VIEW public.listings_feed_light AS
 SELECT l.id,
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
    e.near_miss_reasons,
    COALESCE(e.has_floor_plan_images, false) AS has_floor_plan_images,
    COALESCE(e.has_property_images, false) AS has_property_images,
    COALESCE(jsonb_path_query_first(e.suumo_images, '$[*]?(@."label" like_regex "外観|エントランス")'::jsonpath) ->> 'url'::text, (e.suumo_images -> 0) ->> 'url'::text) AS first_image_url,
    e.building_group_key,
    e.building_units
   FROM listings l
     LEFT JOIN LATERAL ( SELECT s.id,
            s.listing_id,
            s.source,
            s.url,
            s.price_man,
            s.management_fee,
            s.repair_reserve_fund,
            s.listing_agent,
            s.is_motodzuke,
            s.first_seen_at,
            s.last_seen_at,
            s.is_active,
            s.price_max_man,
            s.consecutive_misses
           FROM listing_sources s
          WHERE s.listing_id = l.id AND s.is_active
          ORDER BY s.last_seen_at DESC
         LIMIT 1) ls ON true
     LEFT JOIN enrichments e ON e.listing_id = l.id
  WHERE NOT l.spec_excluded
    AND ls.price_man IS NOT NULL
    AND l.name IS NOT NULL
    AND btrim(l.name) <> '';

-- PostgREST のスキーマキャッシュを再読込（他 migration と同様）
NOTIFY pgrst, 'reload schema';
