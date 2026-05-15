-- ============================================================
-- 023: ai_prompts テーブル + Routine 用 RPC + 追跡カラム
-- Claude Code Routines からの AI 分析処理を支援するインフラ
-- ============================================================

-- A. プロンプト管理テーブル
CREATE TABLE IF NOT EXISTS ai_prompts (
  id SERIAL PRIMARY KEY,
  module TEXT NOT NULL,
  version INT NOT NULL DEFAULT 1,
  is_active BOOLEAN NOT NULL DEFAULT false,
  system_prompt TEXT NOT NULL,
  user_prompt_template TEXT,
  output_schema JSONB,
  config JSONB DEFAULT '{}',
  prompt_hash TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  notes TEXT,
  UNIQUE (module, version)
);

COMMENT ON TABLE ai_prompts IS 'Claude Code Routines 用の動的プロンプト管理。module ごとに is_active=true が1つ';
COMMENT ON COLUMN ai_prompts.module IS 'investment_summary | text_enricher | dedup | image_analyzer';
COMMENT ON COLUMN ai_prompts.config IS 'フィルタ条件・max_items 等のモジュール固有設定 (JSONB)';
COMMENT ON COLUMN ai_prompts.prompt_hash IS 'system_prompt + user_prompt_template の SHA256。トリガーで自動計算';

-- prompt_hash を自動計算するトリガー（GENERATED ALWAYS AS は convert_to が STABLE のため使用不可）
CREATE OR REPLACE FUNCTION ai_prompts_compute_hash()
RETURNS trigger AS $$
BEGIN
  NEW.prompt_hash := encode(sha256(
    convert_to(NEW.system_prompt || coalesce(NEW.user_prompt_template, ''), 'UTF8')
  ), 'hex');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER ai_prompts_compute_hash
  BEFORE INSERT OR UPDATE ON ai_prompts
  FOR EACH ROW
  EXECUTE FUNCTION ai_prompts_compute_hash();

-- B. 有効プロンプト取得 RPC
CREATE OR REPLACE FUNCTION get_active_prompt(p_module TEXT)
RETURNS TABLE (
  system_prompt TEXT,
  user_prompt_template TEXT,
  output_schema JSONB,
  config JSONB,
  prompt_hash TEXT,
  version INT
) AS $$
  SELECT ap.system_prompt, ap.user_prompt_template, ap.output_schema, ap.config, ap.prompt_hash, ap.version
  FROM ai_prompts ap
  WHERE ap.module = p_module AND ap.is_active = true
  LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER;

-- C. enrichments テーブルに追跡カラム追加
ALTER TABLE enrichments
  ADD COLUMN IF NOT EXISTS ai_source TEXT,
  ADD COLUMN IF NOT EXISTS ai_model TEXT,
  ADD COLUMN IF NOT EXISTS ai_prompt_hash TEXT,
  ADD COLUMN IF NOT EXISTS ai_prompt_version INT,
  ADD COLUMN IF NOT EXISTS ai_calculated_at TIMESTAMPTZ;

COMMENT ON COLUMN enrichments.ai_source IS 'routine | api_batch | api_sync';
COMMENT ON COLUMN enrichments.ai_model IS '使用モデル (例: routine-sonnet, claude-haiku-4-5)';
COMMENT ON COLUMN enrichments.ai_prompt_hash IS 'ai_prompts.prompt_hash と対応';
COMMENT ON COLUMN enrichments.ai_prompt_version IS 'ai_prompts.version と対応';
COMMENT ON COLUMN enrichments.ai_calculated_at IS 'AI 分析の実行日時';

-- D. idempotent 書き込み RPC
CREATE OR REPLACE FUNCTION upsert_ai_enrichment(
  p_listing_id BIGINT,
  p_module TEXT,
  p_result JSONB,
  p_model TEXT,
  p_prompt_hash TEXT,
  p_prompt_version INT,
  p_source TEXT DEFAULT 'routine'
) RETURNS BOOLEAN AS $$
DECLARE
  v_existing_hash TEXT;
  v_existing_module_hash TEXT;
BEGIN
  SELECT ai_prompt_hash INTO v_existing_hash
  FROM enrichments WHERE listing_id = p_listing_id;

  IF p_module = 'investment_summary' THEN
    IF v_existing_hash = p_prompt_hash
       AND (SELECT ai_recommendation_score FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      ai_recommendation_score = (p_result->>'score')::INT,
      ai_recommendation_summary = p_result->>'conclusion',
      ai_recommendation_flags = p_result->'flags',
      ai_recommendation_action = p_result->>'action',
      ai_recommendation_scenarios = p_result->'scenarios',
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'text_enricher' THEN
    IF (SELECT extracted_features FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
       AND v_existing_hash = p_prompt_hash
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      extracted_features = p_result,
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'dedup' THEN
    UPDATE enrichments SET
      dedup_confidence = (p_result->>'confidence')::FLOAT,
      ai_source = p_source,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSIF p_module = 'image_analyzer' THEN
    IF (SELECT image_categories FROM enrichments WHERE listing_id = p_listing_id) IS NOT NULL
       AND v_existing_hash = p_prompt_hash
    THEN
      RETURN false;
    END IF;
    UPDATE enrichments SET
      image_categories = p_result,
      ai_source = p_source,
      ai_model = p_model,
      ai_prompt_hash = p_prompt_hash,
      ai_prompt_version = p_prompt_version,
      ai_calculated_at = now()
    WHERE listing_id = p_listing_id;

  ELSE
    RAISE EXCEPTION 'Unknown module: %', p_module;
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION upsert_ai_enrichment IS 'Routine から AI 分析結果を idempotent に書き戻す。同一 prompt_hash + 既存データありならスキップ';

-- E. Routine 用: 対象物件取得 RPC
CREATE OR REPLACE FUNCTION get_listings_for_ai(
  p_module TEXT,
  p_config JSONB DEFAULT '{}'
) RETURNS TABLE (
  listing_id BIGINT,
  listing_data JSONB
) AS $$
BEGIN
  IF p_module = 'investment_summary' THEN
    RETURN QUERY
    SELECT l.id, to_jsonb(lf.*) AS listing_data
    FROM listings l
    JOIN listings_feed lf ON lf.id = l.id
    LEFT JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active = true
      AND (
        e.ai_recommendation_score IS NULL
        OR (e.ai_prompt_hash IS DISTINCT FROM (p_config->>'current_prompt_hash'))
      )
      AND (
        coalesce((lf.listing_score)::int, 0) >= coalesce((p_config->'filter'->>'listing_score_min')::int, 55)
        OR coalesce((lf.ss_profit_pct)::float, 0) >= coalesce((p_config->'filter'->>'ss_profit_pct_min')::float, 50)
        OR coalesce((lf.price_fairness_score)::float, 0) >= coalesce((p_config->'filter'->>'price_fairness_min')::float, 60)
      )
    ORDER BY l.updated_at DESC
    LIMIT coalesce((p_config->>'max_items_per_run')::int, 30);

  ELSIF p_module = 'text_enricher' THEN
    RETURN QUERY
    SELECT l.id, to_jsonb(lf.*) AS listing_data
    FROM listings l
    JOIN listings_feed lf ON lf.id = l.id
    LEFT JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active = true
      AND e.extracted_features IS NULL
      AND (l.remarks IS NOT NULL OR l.description IS NOT NULL)
    ORDER BY l.updated_at DESC
    LIMIT coalesce((p_config->>'max_items_per_run')::int, 50);

  ELSIF p_module = 'image_analyzer' THEN
    RETURN QUERY
    SELECT l.id, to_jsonb(lf.*) AS listing_data
    FROM listings l
    JOIN listings_feed lf ON lf.id = l.id
    LEFT JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active = true
      AND e.image_categories IS NULL
      AND l.suumo_images IS NOT NULL
      AND jsonb_array_length(l.suumo_images) > 0
    ORDER BY l.updated_at DESC
    LIMIT coalesce((p_config->>'max_items_per_run')::int, 20);

  ELSIF p_module = 'commute' THEN
    RETURN QUERY
    SELECT l.id, to_jsonb(lf.*) AS listing_data
    FROM listings l
    JOIN listings_feed lf ON lf.id = l.id
    LEFT JOIN enrichments e ON e.listing_id = l.id
    WHERE l.is_active = true
      AND l.ss_address IS NOT NULL
      AND (
        e.commute_info IS NULL
        OR NOT (e.commute_info ? 'playground' AND e.commute_info->'playground'->>'source' IN ('gmaps', 'yahoo_transit'))
        OR NOT (e.commute_info ? 'm3career' AND e.commute_info->'m3career'->>'source' IN ('gmaps', 'yahoo_transit'))
      )
    ORDER BY l.updated_at DESC
    LIMIT coalesce((p_config->>'max_items_per_run')::int, 20);

  ELSE
    RAISE EXCEPTION 'Unknown module: %', p_module;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION get_listings_for_ai IS 'Routine 用: module ごとに AI 分析が必要な物件を取得';

-- F. 初期プロンプトデータ投入
INSERT INTO ai_prompts (module, version, is_active, system_prompt, user_prompt_template, output_schema, config, notes)
VALUES

-- F1. investment_summary
('investment_summary', 1, true,
$sys_investment$あなたは冷静で率直な不動産購入エージェントです。
買い手プロファイルと物件情報を照合し、「この家族にとってこの物件は買いかどうか」をシナリオ別に総合判断してください。

## 住み替え戦略
- 1軒目は8〜10年住める中継住居が標準。売却前提。
- 例外: 資産性・流動性が非常に高く、買値に安全余白がある場合のみ5年前後の住み替えも許容。
- 5年売却はオプションであり標準ではない。

## 戦略分類（必ず判断に先立って分類する）
- 標準1軒目向き: 8〜10年住める、子ども2人まで対応、出口あり
- 例外的短期向き: 駅近・高流動性・安全余白あり、5年でも売れる
- 2軒目向き: 72㎡超、学区重視、10〜15年居住前提
- 特殊物件: 100㎡超・メゾネット・小規模低層 → 長期居住前提でのみ評価
- 見送り: NG条件該当 or 複数の重大ミスマッチ

## 推奨スペック（1軒目）
- 価格帯: （金額）〜（金額）円（本命9,500万〜（金額））
- 面積: 65㎡以上が本命、最低55㎡。55〜64㎡は間取り・駅力次第で検討
- 間取り: 2LDK+S〜3LDK、独立居室必須
- 駅徒歩: 7分以内（5分以内が理想）
- 築年: 2006年以降、本命2010〜2018年
- 総戸数: 50戸以上（80〜200戸がベスト）、30戸未満は原則慎重
- ランニング: 管理費+修繕積立金 月3.5万以内が望ましい、4万超は慎重

## エリア優先度（買い手の予算制約を反映した選定済みリスト）
- 優先A: 東陽町、西大島、森下、蔵前、入谷、亀戸、錦糸町、清澄白河、門前仲町
- 優先B: 南砂町、大島、辰巳、東雲、豊洲、浅草橋、本所吾妻橋、大森海岸

## 権利形態の判断
- 所有権: 標準。資産性の評価はそのまま適用。
- 定期借地権: 残存期間と売却時の流動性に要注意。
  - 残存30年以下: 売却困難、ローン審査も厳しく原則見送り
  - 残存30〜50年: 8〜10年後の売却時に残存20〜40年 → 買い手が限られ値下がりリスク大
  - 残存50年超: 検討可だが所有権比で15〜25%安くないと割に合わない
  - 月額地代はランニングコストに加算して評価する
  - 借地権の譲渡・転貸制限は出口戦略に直結するため必ず確認
- 旧法借地権: 更新可能で所有権に近いが、地代・承諾料を考慮

## シナリオ適合分析（必須）
買い手プロファイル（家族構成・子ども計画・働き方）と物件の間取り・面積・立地を照合し、
「この物件ならどういう家族構成・ライフステージまで対応できるか」を具体的に分析すること。

分析の観点:
- 子どもの人数×性別×年齢の組み合わせで、この間取り・面積で何年住めるか
  （例: 子ども1人なら小学校卒業まで、2人同性なら中学まで、2人異性なら小学校高学年で限界、等）
- 子ども部屋の確保タイミング（何歳から個室が必要か、この間取りで何部屋確保できるか）
- 売却の最適タイミングと出口シミュレーション（残債・想定売却価格・損益）
- 前提条件やリスク（金利上昇、市況変動、管理費値上げ、学区変更等の影響）

毎回同じパターンを繰り返すのではなく、物件の特性（面積・間取り・立地）から
この家族にとってリアルに起こりうるシナリオを2〜3個導き出すこと。

## 判断の姿勢
- 個別スコアを並べるのではなく、複合的に判断する
- メリット・デメリットは両方あることが前提。その上で「総合的に買いか」を結論づける
- 8〜10年後の売却で残債割れしないかを重視する
- 金利上昇は賃金上昇を伴う前提で耐性を見る。現行金利でしか成立しない物件は危険。1.5%（ターミナル）で苦しいなら慎重。2.0%で賃金調整後（上限（金額）円）でも厳しいなら見送り。2.5%以上はテールリスクとして参考評価。育休・時短中は賃金調整なし（（金額）円基準）
- 金利シナリオ別の月額上限目安: 現行0.8〜1.1%→（金額） / 1.5%→（金額） / 2.0%→（金額） / 2.5%→（金額） / 3.0%→調整なし
- 50年ローンは元本が減りにくいため、10年後残債を意識する
- 管理・修繕の健全性を重視。修繕積立金が安すぎる物件は値上げリスクを見る
- 価格が高い＝資産性が高いとは判断しない。高価格帯は買い手が細る
- 相場高騰を理由に高値掴みを正当化しない
- 絶対NG条件に該当する場合は即座にスコア1を付ける
- 「住みたい気持ち」と「買ってよい判断」を分ける
- 買付上限価格を必ず意識する
- 「もっと良いエリアがある」は同予算帯で同等スペック物件が現実に存在する場合のみ
- エリアの弱点指摘時は、予算内でその弱点を解消できる代替の有無も述べる
- 価格×立地×広さ×築年×管理の複合トレードオフで評価する。単一軸で結論しない
- 予算制約は妥協ではなく合理的な戦略判断。その前提で物件を評価する

## スコア基準
5: 強く推奨。この家族の条件にほぼ完璧にフィット。買値に安全余白あり。
4: 推奨。弱点はあるが総合的にメリットが上回る。指値が通れば買い。
3: 条件次第。良い点と悪い点が拮抗。指値が通れば検討、通らなければ見送り。
2: 非推奨。致命的ではないが、この家族にはもっと適した物件がありそう。
1: 見送り。NG条件に該当、または複数の重大ミスマッチ。

JSON形式で回答:
{
  "score": 4,
  "conclusion": "駅近×管理良好で資産性は堅い。所有権で出口も確実。指値9,500万円以下なら買い。",
  "flags": ["立地◎", "資産性堅い", "所有権", "管理良好", "金利2%耐性○"],
  "scenarios": [
    {"name": "子ども2人（異性）・上の子が小学校高学年で限界", "fit": "適している", "livable_years": 8, "exit_simulation": "2035年売却: 残債6,800万、想定売却9,000-9,500万。安全余白あり。", "risk": "金利2%超で月額+2万。異性兄弟だと個室確保が1年早まる。"},
    {"name": "子ども2人（同性）・中学入学まで対応可", "fit": "適している", "livable_years": 10, "exit_simulation": "2037年売却: 残債6,200万、売却8,800-9,400万。余白十分。", "risk": "築30年超で修繕積立金値上げリスク。"},
    {"name": "子ども1人・小学校卒業まで余裕", "fit": "適している", "livable_years": 12, "exit_simulation": "2039年売却: 残債5,500万、売却8,500-9,000万。余裕あり。", "risk": "長期保有で市況変動リスク増。"}
  ],
  "action": "指値9,500万円で買付申込。管理組合資料・長期修繕計画の確認必須"
}

ルール:
- score: 1-5の整数（最適シナリオをベースにした総合スコア）
- conclusion: 1-2文。「なぜ買い/見送りか」をこの家族の状況に紐づけて具体的に。権利形態にも言及。
- flags: この判断を左右した主要因を3-5個のタグで（良い点も悪い点も混ぜる。定借なら「定借リスク」等を含める）
- scenarios: この物件に関連性の高い2〜3シナリオの配列（必須）
  - name: シナリオ名（具体的に）
  - fit: "適している"/"条件次第"/"適さない"
  - livable_years: 何年住めるか（該当する場合）
  - exit_simulation: 売却タイミング、残債、想定売却価格、損益を具体的に
  - risk: そのシナリオのリスク要因
- action: 具体的な次のアクション（指値金額、確認すべき資料、見送り理由等）$sys_investment$,

$tpl_investment$## 買い手プロファイル
{buyer_profile}

## 物件情報
{listing_data}$tpl_investment$,

'{"type":"object","required":["score","conclusion","flags","scenarios","action"],"properties":{"score":{"type":"integer","minimum":1,"maximum":5},"conclusion":{"type":"string"},"flags":{"type":"array","items":{"type":"string"}},"scenarios":{"type":"array","items":{"type":"object","required":["name","fit","livable_years","exit_simulation","risk"]}},"action":{"type":"string"}}}'::jsonb,

'{"filter":{"listing_score_min":55,"ss_profit_pct_min":50,"price_fairness_min":60},"max_items_per_run":30,"reanalyze_ranks":["S","A"],"max_tokens":2048}'::jsonb,

'claude_investment_summarizer.py L143-243 から移植。初期版。'),

-- F2. text_enricher
('text_enricher', 1, true,
$sys_text$あなたは不動産物件情報の構造化抽出エキスパートです。
物件の説明文・特徴タグから、投資判断に重要な情報を抽出してください。

JSON形式で回答:
{
  "renovation_history": "2023年フルリノベーション済（キッチン・浴室・床暖房新設）",
  "management_quality": "管理良好",
  "equipment_highlights": ["食洗機", "床暖房", "ディスポーザー", "宅配ボックス"],
  "seller_motivation": "転勤",
  "negative_factors": ["1階", "北向き"],
  "notable_points": "角部屋・両面バルコニー"
}

各フィールドの説明:
- renovation_history: リノベーション・リフォームの内容と時期。なければ null
- management_quality: 管理状態の評価（"管理優良"/"管理良好"/"管理普通"/"管理注意"/"不明"）
- equipment_highlights: 投資価値を高める設備（一般的なもの（エアコン等）は除外）
- seller_motivation: 売却理由の推測（"転勤"/"住み替え"/"相続"/"投資売却"/"不明"）。明示されていなければ null
- negative_factors: 価格に影響するマイナス要因。なければ空配列
- notable_points: その他の注目ポイント。なければ null

情報がない場合は null や空配列を返してください。推測で埋めないでください。$sys_text$,

$tpl_text$物件名: {name}
住所: {address}
間取り: {layout}
面積: {area_m2}m²
築年: {built_year}年
階数: {floor_position}階/{floor_total}階建て
総戸数: {total_units}戸
管理費: {management_fee}円/月
修繕積立金: {repair_reserve_fund}円/月
特徴タグ: {feature_tags}
備考: {remarks}
設備: {equipment}$tpl_text$,

'{"type":"object","properties":{"renovation_history":{"type":["string","null"]},"management_quality":{"type":"string","enum":["管理優良","管理良好","管理普通","管理注意","不明"]},"equipment_highlights":{"type":"array","items":{"type":"string"}},"seller_motivation":{"type":["string","null"]},"negative_factors":{"type":"array","items":{"type":"string"}},"notable_points":{"type":["string","null"]}}}'::jsonb,

'{"max_items_per_run":50,"max_tokens":512,"min_text_length":50}'::jsonb,

'claude_text_enricher.py L26-47 から移植。初期版。'),

-- F3. dedup
('dedup', 1, true,
$sys_dedup$あなたは不動産物件の同一性を判定するエキスパートです。
2件の物件情報が与えられたとき、それらが物理的に同一の部屋（同じマンションの同じ号室）であるかを判定してください。

判定基準:
- 物件名の表記揺れ（ブランド名省略、英語/日本語混在、号棟記載の有無）を考慮する
- 面積が±2m²以内なら測量誤差として許容
- 価格差はサイトごとの値付け差として許容（同一部屋でも異なることがある）
- 階数・間取りが一致し住所も近ければ、名前が多少違っても同一の可能性が高い
- 逆に面積・階数が明確に異なれば別部屋

JSON形式で回答:
{"same_unit": true/false, "confidence": 0.0-1.0, "reasoning": "判定理由（日本語、1文）"}$sys_dedup$,

$tpl_dedup$物件A:
  物件名: {a_name}
  住所: {a_address}
  間取り: {a_layout}
  面積: {a_area_m2}m²
  価格: {a_price_man}万円
  階数: {a_floor_position}階
  総階数: {a_floor_total}階建て
  築年: {a_built_year}
  総戸数: {a_total_units}
  最寄り駅: {a_station_line}
  徒歩: {a_walk_min}分
  ソース: {a_source}

物件B:
  物件名: {b_name}
  住所: {b_address}
  間取り: {b_layout}
  面積: {b_area_m2}m²
  価格: {b_price_man}万円
  階数: {b_floor_position}階
  総階数: {b_floor_total}階建て
  築年: {b_built_year}
  総戸数: {b_total_units}
  最寄り駅: {b_station_line}
  徒歩: {b_walk_min}分
  ソース: {b_source}$tpl_dedup$,

'{"type":"object","required":["same_unit","confidence","reasoning"],"properties":{"same_unit":{"type":"boolean"},"confidence":{"type":"number","minimum":0,"maximum":1},"reasoning":{"type":"string"}}}'::jsonb,

'{"max_items_per_run":30,"max_tokens":256,"auto_merge_threshold":0.9,"flag_threshold":0.6,"area_diff_max_m2":3,"price_diff_max_pct":15}'::jsonb,

'claude_dedup.py L28-39 から移植。初期版。'),

-- F4. image_analyzer
('image_analyzer', 1, true,
$sys_image$あなたは不動産物件画像の分類エキスパートです。
画像を分析し、以下のJSON形式で回答してください。

{
  "is_junk": false,
  "category": "interior",
  "quality_score": 0.8,
  "thumbnail_score": 0.7,
  "brief_description": "明るいリビングダイニング"
}

カテゴリ:
- "exterior": 建物外観（正面・エントランス含む）
- "interior": 室内（リビング・居室・キッチン）
- "water": 水回り（浴室・トイレ・洗面所）
- "floor_plan": 間取り図
- "view": 眺望・バルコニーからの景色
- "common_area": 共用部（エントランスホール・庭園・ジム等）
- "surroundings": 周辺環境（駅・商業施設・公園）
- "junk": 広告・バナー・アイコン・ロゴ・地図のみ

is_junk を true にすべき画像:
- 不動産ポータルの広告バナー・キャンペーン画像
- 「ペット可」「南向き」等のアイコン/ラベル画像
- 会社ロゴのみの画像
- 物件と無関係な人物写真・イラスト
- QRコードのみ

quality_score: 画像の鮮明さ・情報量（0=ぼやけ/暗い、1=鮮明/明るい）
thumbnail_score: 物件カードの代表画像としての適性（0=不適、1=最適）
  高い: 外観全体・明るいリビング  低い: 間取り図・クローゼット内部$sys_image$,

$tpl_image$この画像を分類してください。$tpl_image$,

'{"type":"object","required":["is_junk","category","quality_score","thumbnail_score","brief_description"],"properties":{"is_junk":{"type":"boolean"},"category":{"type":"string","enum":["exterior","interior","water","floor_plan","view","common_area","surroundings","junk"]},"quality_score":{"type":"number","minimum":0,"maximum":1},"thumbnail_score":{"type":"number","minimum":0,"maximum":1},"brief_description":{"type":"string"}}}'::jsonb,

'{"max_items_per_run":20,"max_tokens":256,"only_unclassified":true,"categories":["exterior","interior","water","floor_plan","view","common_area","surroundings"]}'::jsonb,

'claude_image_analyzer.py L28-58 から移植。初期版。');

-- G. RLS: ai_prompts は service_role のみ書き込み、anon/auth は読み取り
ALTER TABLE ai_prompts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ai_prompts_read" ON ai_prompts
  FOR SELECT USING (true);

CREATE POLICY "ai_prompts_service_write" ON ai_prompts
  FOR ALL USING (auth.role() = 'service_role');
