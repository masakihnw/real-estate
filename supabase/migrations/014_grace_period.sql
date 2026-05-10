-- Grace period for listing removal: track consecutive misses before marking
-- a listing source as inactive. Prevents notification noise from flapping
-- listings that temporarily disappear from a scraping source.

ALTER TABLE listing_sources
  ADD COLUMN IF NOT EXISTS consecutive_misses INTEGER DEFAULT 0;
