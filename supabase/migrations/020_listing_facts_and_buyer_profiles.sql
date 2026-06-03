-- listing_facts: 事実データのみを公開するビュー（AI分析バイアス防止用）
-- buyer_profiles: 買い手プロフィール（iOS・パイプライン・外部AI共通参照）

-- ============================================================
-- 1. listing_facts ビュー
-- ============================================================
-- listings_feed と同じJOIN構造だが、自前分析カラムを除外。
-- 除外対象: price_fairness_score, resale_liquidity_score, listing_score,
--   competing_*, ai_recommendation_*, investment_summary, highlight_badge,
--   key_strengths, key_risks, extracted_features, image_categories,
--   dedup_*, alt_sources, best_thumbnail_url

CREATE OR REPLACE VIEW listing_facts AS
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
    CASE WHEN l.is_active THEN 'active' ELSE 'removed' END AS status,
    l.is_new,
    l.is_new_building,
    l.first_seen_at,
    l.first_seen_source,
    l.created_at,
    l.updated_at,

    -- listing_sources: 全ソースをJSONB配列に集約
    (SELECT JSONB_AGG(
        JSONB_BUILD_OBJECT(
            'source', s.source,
            'url', s.url,
            'price_man', s.price_man,
            'price_max_man', s.price_max_man,
            'listing_agent', s.listing_agent,
            'is_motodzuke', s.is_motodzuke,
            'is_active', s.is_active,
            'first_seen_at', s.first_seen_at,
            'last_seen_at', s.last_seen_at
        ) ORDER BY s.last_seen_at DESC
     )
     FROM listing_sources s
     WHERE s.listing_id = l.id
    ) AS sources_json,

    -- enrichments: 事実・第三者データのみ
    -- 通勤時間（計測結果）
    e.commute_info,
    e.commute_info_v2,
    -- 災害リスク（行政データ）
    e.hazard_info,
    -- 市場相場（国交省統計）
    e.reinfolib_market_data,
    -- マンションレビュー（第三者評価）
    e.mansion_review_data,
    -- 人口動態（統計局）
    e.estat_population_data,
    -- 住まいサーフィン（第三者統計・予測）
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
    e.ss_radar_data,
    e.ss_past_market_trends,
    e.ss_surrounding_properties,
    e.ss_price_judgments,
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
    -- 画像
    e.floor_plan_images,
    e.suumo_images,
    -- ニアミス
    e.near_miss,
    e.near_miss_reasons,

    -- 価格履歴
    (SELECT JSONB_AGG(
        JSONB_BUILD_OBJECT(
            'date', TO_CHAR(ph.recorded_at, 'YYYY-MM-DD'),
            'price_man', ph.price_man,
            'source', ph.source
        ) ORDER BY ph.recorded_at
     )
     FROM price_history ph
     WHERE ph.listing_id = l.id
    ) AS price_history_json

FROM listings l
LEFT JOIN enrichments e ON e.listing_id = l.id;


-- ============================================================
-- 2. buyer_profiles テーブル
-- ============================================================

CREATE TABLE IF NOT EXISTS buyer_profiles (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id TEXT NOT NULL UNIQUE,

    -- 家族・ライフスタイル
    family_composition TEXT,
    household_income TEXT,
    work_style TEXT,
    child_plan TEXT,
    priorities TEXT,
    current_housing TEXT,

    -- エリア・住環境
    neighborhood_preference TEXT,
    school_priority TEXT,
    commute_quality TEXT,
    weekend_lifestyle TEXT,
    community_preference TEXT,
    deal_breakers TEXT,

    -- 資金計画
    self_funds TEXT,
    planned_borrowing TEXT,
    interest_type TEXT DEFAULT '変動' CHECK (interest_type IN ('変動', '固定', 'ミックス')),
    estimated_rate TEXT,
    repayment_years TEXT,
    monthly_payment_limit TEXT,

    -- 将来の計画
    relocation_reason TEXT,
    post_sale_strategy TEXT DEFAULT '売却前提' CHECK (post_sale_strategy IN ('売却前提', '賃貸転用も許容')),
    timeline TEXT,
    risk_tolerance TEXT,

    -- 構造化データ
    life_scenarios JSONB,
    budget_scenarios JSONB,
    preferred_areas JSONB,
    must_have_features JSONB,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER update_buyer_profiles_updated_at
    BEFORE UPDATE ON buyer_profiles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- RLS
ALTER TABLE buyer_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_all" ON buyer_profiles
    FOR ALL USING (current_setting('role') = 'service_role');

CREATE POLICY "anon_read_own" ON buyer_profiles
    FOR SELECT USING (true);


-- ============================================================
-- 3. RPC: buyer_profile 取得・更新
-- ============================================================

CREATE OR REPLACE FUNCTION get_buyer_profile(p_user_id TEXT)
RETURNS SETOF buyer_profiles
LANGUAGE sql SECURITY DEFINER STABLE AS $$
    SELECT * FROM buyer_profiles WHERE user_id = p_user_id;
$$;

CREATE OR REPLACE FUNCTION upsert_buyer_profile(p_user_id TEXT, p_profile JSONB)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO buyer_profiles (
        user_id,
        family_composition, household_income, work_style, child_plan,
        priorities, current_housing,
        neighborhood_preference, school_priority, commute_quality,
        weekend_lifestyle, community_preference, deal_breakers,
        self_funds, planned_borrowing, interest_type, estimated_rate,
        repayment_years, monthly_payment_limit,
        relocation_reason, post_sale_strategy, timeline, risk_tolerance,
        life_scenarios, budget_scenarios, preferred_areas, must_have_features
    ) VALUES (
        p_user_id,
        p_profile->>'family_composition',
        p_profile->>'household_income',
        p_profile->>'work_style',
        p_profile->>'child_plan',
        p_profile->>'priorities',
        p_profile->>'current_housing',
        p_profile->>'neighborhood_preference',
        p_profile->>'school_priority',
        p_profile->>'commute_quality',
        p_profile->>'weekend_lifestyle',
        p_profile->>'community_preference',
        p_profile->>'deal_breakers',
        p_profile->>'self_funds',
        p_profile->>'planned_borrowing',
        p_profile->>'interest_type',
        p_profile->>'estimated_rate',
        p_profile->>'repayment_years',
        p_profile->>'monthly_payment_limit',
        p_profile->>'relocation_reason',
        p_profile->>'post_sale_strategy',
        p_profile->>'timeline',
        p_profile->>'risk_tolerance',
        p_profile->'life_scenarios',
        p_profile->'budget_scenarios',
        p_profile->'preferred_areas',
        p_profile->'must_have_features'
    )
    ON CONFLICT (user_id) DO UPDATE SET
        family_composition     = COALESCE(p_profile->>'family_composition',     buyer_profiles.family_composition),
        household_income       = COALESCE(p_profile->>'household_income',       buyer_profiles.household_income),
        work_style             = COALESCE(p_profile->>'work_style',             buyer_profiles.work_style),
        child_plan             = COALESCE(p_profile->>'child_plan',             buyer_profiles.child_plan),
        priorities             = COALESCE(p_profile->>'priorities',             buyer_profiles.priorities),
        current_housing        = COALESCE(p_profile->>'current_housing',        buyer_profiles.current_housing),
        neighborhood_preference= COALESCE(p_profile->>'neighborhood_preference',buyer_profiles.neighborhood_preference),
        school_priority        = COALESCE(p_profile->>'school_priority',        buyer_profiles.school_priority),
        commute_quality        = COALESCE(p_profile->>'commute_quality',        buyer_profiles.commute_quality),
        weekend_lifestyle      = COALESCE(p_profile->>'weekend_lifestyle',      buyer_profiles.weekend_lifestyle),
        community_preference   = COALESCE(p_profile->>'community_preference',   buyer_profiles.community_preference),
        deal_breakers          = COALESCE(p_profile->>'deal_breakers',          buyer_profiles.deal_breakers),
        self_funds             = COALESCE(p_profile->>'self_funds',             buyer_profiles.self_funds),
        planned_borrowing      = COALESCE(p_profile->>'planned_borrowing',      buyer_profiles.planned_borrowing),
        interest_type          = COALESCE(p_profile->>'interest_type',          buyer_profiles.interest_type),
        estimated_rate         = COALESCE(p_profile->>'estimated_rate',         buyer_profiles.estimated_rate),
        repayment_years        = COALESCE(p_profile->>'repayment_years',        buyer_profiles.repayment_years),
        monthly_payment_limit  = COALESCE(p_profile->>'monthly_payment_limit',  buyer_profiles.monthly_payment_limit),
        relocation_reason      = COALESCE(p_profile->>'relocation_reason',      buyer_profiles.relocation_reason),
        post_sale_strategy     = COALESCE(p_profile->>'post_sale_strategy',     buyer_profiles.post_sale_strategy),
        timeline               = COALESCE(p_profile->>'timeline',               buyer_profiles.timeline),
        risk_tolerance         = COALESCE(p_profile->>'risk_tolerance',         buyer_profiles.risk_tolerance),
        life_scenarios         = COALESCE(p_profile->'life_scenarios',          buyer_profiles.life_scenarios),
        budget_scenarios       = COALESCE(p_profile->'budget_scenarios',        buyer_profiles.budget_scenarios),
        preferred_areas        = COALESCE(p_profile->'preferred_areas',         buyer_profiles.preferred_areas),
        must_have_features     = COALESCE(p_profile->'must_have_features',     buyer_profiles.must_have_features),
        updated_at             = NOW();
END;
$$;
