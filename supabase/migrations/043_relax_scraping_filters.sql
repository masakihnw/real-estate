-- 043: スクレイピングフィルタ緩和
-- 仲介エージェント提案物件の分析に基づく調整:
--   priceMaxMan:  12000 → 13000 (交渉余地のある物件をカバー)
--   builtYearMinOffsetYears: 20 → 30 (築30年以内。成約の過半数が築20年超)
--   totalUnitsMin: 30 → 20 (小規模優良物件をカバー)
--
-- NOTE: apply_spec_exclusions() は priceMax/priceMin/areaMin のみ評価する。
-- 築年・戸数で除外された既存物件の復活は次回スクレイピング実行時に自動的に行われる。

UPDATE scraping_config
SET config = config
    || '{"priceMaxMan": 13000}'::jsonb
    || '{"builtYearMinOffsetYears": 30}'::jsonb
    || '{"totalUnitsMin": 20}'::jsonb,
    updated_at = NOW()
WHERE id = 'default';
