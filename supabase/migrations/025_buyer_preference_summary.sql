-- buyer_preference_summaries: Routine 2で生成される好みの傾向サマリー
CREATE TABLE IF NOT EXISTS buyer_preference_summaries (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id TEXT NOT NULL DEFAULT 'default',
  summary_lines TEXT[] NOT NULL,
  liked_count INT NOT NULL DEFAULT 0,
  noped_count INT NOT NULL DEFAULT 0,
  preference_hash TEXT,
  ai_model TEXT,
  ai_calculated_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id)
);

COMMENT ON TABLE buyer_preference_summaries IS 'Routine 2で生成される好みの傾向サマリー。iOS DashboardViewが読み取る';
COMMENT ON COLUMN buyer_preference_summaries.summary_lines IS '3-5行の箇条書き配列（各行「・」で始まる）';
COMMENT ON COLUMN buyer_preference_summaries.preference_hash IS 'いいね/見送り状態のハッシュ（変更検知用）';
