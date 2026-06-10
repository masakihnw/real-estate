-- 044: apply_spec_exclusions のオーバーロード曖昧性を解消
--
-- 問題: 038 のパラメータ版（全引数 DEFAULT 付き）と 039 のパラメータなし版が共存し、
-- PostgREST の引数なし RPC 呼び出し（supabase_sync.py）が PGRST203
-- "Could not choose the best candidate function" で 039 導入以降ずっと失敗していた。
--
-- 対応: パラメータ版（038）を削除する。
-- スクレイピング条件の正は scraping_config テーブル（パラメータなし版が参照）であり、
-- パラメータ版を呼ぶコードはリポジトリに存在しない。

DROP FUNCTION IF EXISTS apply_spec_exclusions(INT, INT, NUMERIC, NUMERIC);
