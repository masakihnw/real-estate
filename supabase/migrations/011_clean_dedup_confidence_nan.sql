-- Clean NaN from dedup_confidence (REAL column missed by migration 010).
-- This is likely the cause of "JSON could not be generated" errors
-- in the final sync step.

UPDATE enrichments SET dedup_confidence = NULL
WHERE dedup_confidence = 'NaN'::real;

DO $$ BEGIN
    ALTER TABLE enrichments ADD CONSTRAINT chk_enrichments_no_nan_dedup
        CHECK (dedup_confidence IS NULL OR dedup_confidence = dedup_confidence);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
