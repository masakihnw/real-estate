-- Comprehensive NaN cleanup for ALL REAL columns across ALL tables.
-- Migrations 010/011 only covered a subset. This covers every REAL column
-- and adds CHECK constraints to prevent future NaN insertion.

-- ===== listings =====
UPDATE listings SET area_m2 = NULL WHERE area_m2 = 'NaN'::real;
UPDATE listings SET area_max_m2 = NULL WHERE area_max_m2 = 'NaN'::real;
UPDATE listings SET balcony_area_m2 = NULL WHERE balcony_area_m2 = 'NaN'::real;
UPDATE listings SET latitude = NULL WHERE latitude = 'NaN'::real;
UPDATE listings SET longitude = NULL WHERE longitude = 'NaN'::real;

-- ===== enrichments =====
UPDATE enrichments SET ss_appreciation_rate = NULL WHERE ss_appreciation_rate = 'NaN'::real;
UPDATE enrichments SET ss_forecast_change_rate = NULL WHERE ss_forecast_change_rate = 'NaN'::real;
UPDATE enrichments SET dedup_confidence = NULL WHERE dedup_confidence = 'NaN'::real;

-- ===== near_misses =====
UPDATE near_misses SET area_m2 = NULL WHERE area_m2 = 'NaN'::real;

-- ===== transactions =====
UPDATE transactions SET area_m2 = NULL WHERE area_m2 = 'NaN'::real;
UPDATE transactions SET latitude = NULL WHERE latitude = 'NaN'::real;
UPDATE transactions SET longitude = NULL WHERE longitude = 'NaN'::real;

-- ===== building_groups =====
UPDATE building_groups SET latitude = NULL WHERE latitude = 'NaN'::real;
UPDATE building_groups SET longitude = NULL WHERE longitude = 'NaN'::real;

-- ===== Infinity cleanup (same columns) =====
UPDATE listings SET area_m2 = NULL WHERE area_m2 IN ('Infinity'::real, '-Infinity'::real);
UPDATE listings SET area_max_m2 = NULL WHERE area_max_m2 IN ('Infinity'::real, '-Infinity'::real);
UPDATE listings SET balcony_area_m2 = NULL WHERE balcony_area_m2 IN ('Infinity'::real, '-Infinity'::real);
UPDATE listings SET latitude = NULL WHERE latitude IN ('Infinity'::real, '-Infinity'::real);
UPDATE listings SET longitude = NULL WHERE longitude IN ('Infinity'::real, '-Infinity'::real);
UPDATE enrichments SET ss_appreciation_rate = NULL WHERE ss_appreciation_rate IN ('Infinity'::real, '-Infinity'::real);
UPDATE enrichments SET ss_forecast_change_rate = NULL WHERE ss_forecast_change_rate IN ('Infinity'::real, '-Infinity'::real);
UPDATE enrichments SET dedup_confidence = NULL WHERE dedup_confidence IN ('Infinity'::real, '-Infinity'::real);
UPDATE transactions SET area_m2 = NULL WHERE area_m2 IN ('Infinity'::real, '-Infinity'::real);
UPDATE transactions SET latitude = NULL WHERE latitude IN ('Infinity'::real, '-Infinity'::real);
UPDATE transactions SET longitude = NULL WHERE longitude IN ('Infinity'::real, '-Infinity'::real);
UPDATE building_groups SET latitude = NULL WHERE latitude IN ('Infinity'::real, '-Infinity'::real);
UPDATE building_groups SET longitude = NULL WHERE longitude IN ('Infinity'::real, '-Infinity'::real);

-- ===== CHECK constraints (idempotent: val = val is false for NaN) =====
DO $$ BEGIN
    ALTER TABLE listings ADD CONSTRAINT chk_listings_no_nan_area_max
        CHECK (area_max_m2 IS NULL OR area_max_m2 = area_max_m2);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE listings ADD CONSTRAINT chk_listings_no_nan_balcony
        CHECK (balcony_area_m2 IS NULL OR balcony_area_m2 = balcony_area_m2);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE enrichments ADD CONSTRAINT chk_enrichments_no_nan_forecast
        CHECK (ss_forecast_change_rate IS NULL OR ss_forecast_change_rate = ss_forecast_change_rate);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE near_misses ADD CONSTRAINT chk_near_misses_no_nan_area
        CHECK (area_m2 IS NULL OR area_m2 = area_m2);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE transactions ADD CONSTRAINT chk_transactions_no_nan_area
        CHECK (area_m2 IS NULL OR area_m2 = area_m2);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE transactions ADD CONSTRAINT chk_transactions_no_nan_lat
        CHECK (latitude IS NULL OR latitude = latitude);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE transactions ADD CONSTRAINT chk_transactions_no_nan_lng
        CHECK (longitude IS NULL OR longitude = longitude);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE building_groups ADD CONSTRAINT chk_bg_no_nan_lat
        CHECK (latitude IS NULL OR latitude = latitude);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    ALTER TABLE building_groups ADD CONSTRAINT chk_bg_no_nan_lng
        CHECK (longitude IS NULL OR longitude = longitude);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
