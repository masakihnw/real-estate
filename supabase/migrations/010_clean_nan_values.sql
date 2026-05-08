-- Clean NaN values from REAL/FLOAT columns that break PostgREST JSON serialization.
-- PostgreSQL REAL can store NaN, but JSON (RFC 7159) does not support it.
-- PostgREST returns 400 "JSON could not be generated" when encountering NaN.

-- listings table: REAL columns
UPDATE listings SET area_m2 = NULL WHERE area_m2 = 'NaN'::real;
UPDATE listings SET area_max_m2 = NULL WHERE area_max_m2 = 'NaN'::real;
UPDATE listings SET balcony_area_m2 = NULL WHERE balcony_area_m2 = 'NaN'::real;
UPDATE listings SET latitude = NULL WHERE latitude = 'NaN'::real;
UPDATE listings SET longitude = NULL WHERE longitude = 'NaN'::real;

-- enrichments table: REAL columns
UPDATE enrichments SET ss_appreciation_rate = NULL WHERE ss_appreciation_rate = 'NaN'::real;
UPDATE enrichments SET ss_forecast_change_rate = NULL WHERE ss_forecast_change_rate = 'NaN'::real;

-- listing_sources table: check price columns
UPDATE listing_sources SET price_man = NULL WHERE price_man = 'NaN'::real;

-- Add CHECK constraints to prevent future NaN insertion
DO $$ BEGIN
    ALTER TABLE listings ADD CONSTRAINT chk_listings_no_nan_area
        CHECK (area_m2 IS NULL OR area_m2 = area_m2);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE listings ADD CONSTRAINT chk_listings_no_nan_lat
        CHECK (latitude IS NULL OR latitude = latitude);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE listings ADD CONSTRAINT chk_listings_no_nan_lng
        CHECK (longitude IS NULL OR longitude = longitude);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE enrichments ADD CONSTRAINT chk_enrichments_no_nan_rate
        CHECK (ss_appreciation_rate IS NULL OR ss_appreciation_rate = ss_appreciation_rate);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
