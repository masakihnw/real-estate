# ChatGPT リファクタ指示の妥当性評価

このメモは、プロンプト「リファクタリング指示（Cursor用）: scraping-tool Pythonコードの構造改善」を扱います。
指摘の妥当性と実施の優先度を整理しています。

セクション1から4は、リファクタを実施する前（初版は2026-02-02のコミット）のコードベースに対する評価です。実施後の状態は、次の「更新」の節に書きました。2つが食い違う場合は、「更新」の節を優先します。

---

## 更新（リファクタ実施後の状態）

次の改善は実施済みで、2026-10-02時点のコードで確認しました。

- 差分検出の修正: `identity_key`（価格を含まない）を新設し、`compare_listings` と `check_changes.py` が突合に使う。価格だけが変わった場合はupdatedに分類される。
- テスト追加: `tests/test_report_utils.py` が、pytestで次の仕様を固定している。
  対象は `normalize_listing_name`、`identity_key`、`listing_key`、`compare_listings`、フォーマット系である。
- optional依存の集約: `optional_features.py` を新設した。asset_score、loan_calc、commute、price_predictorなどは、ここで一括ロードする。
  `generate_report.py` と `slack_notify.py` から、optional依存に関する try/except ImportError を撤去した。optional依存は `optional_features` 経由に統一した。
  `generate_report.py` には、`config` のimport失敗に備えた try/except ImportError が別に残っている。
- 依存の逆転: `get_three_scenario_columns` を `optional_features` に移した。`slack_notify.py` は `generate_report.py` をimportしない。
- load_jsonの統一: `report_utils.load_json(path, *, missing_ok=False, default=None)` に仕様をそろえた。`slack_notify.py` は `missing_ok=True, default=[]` で呼び出す。

次の項目は実施していません。
`scraping-tool/` に `domain/`、`io/`、`integrations/`、`render/` のディレクトリはありません。
フルパッケージ化、dataclass化、CLI統合も行っていません。

---

## 1. 診断（1から5）の妥当性

### 1) 責務の混在: 一部妥当。すでに改善済み

- 事実: `generate_report.py` に、次の処理が同居している。
  CLI（argparse）、Markdownの組み立て、資産性B以上のフィルタ、検索条件表の生成、price_predictorの呼び出しである。
- 当時の状態: 差分判定、キー、フォーマットは `report_utils` に集約済みだった。行の組み立ては `_listing_cells` と `_link_from_group` で共通化済みだった。
- 評価: 責務の混在はあるが、プロンプトが想定するほどひどくはない。「レポート生成」という1つの責務の中で整理するにとどめる。パッケージ分割まで行うかどうかは、規模に応じて決める。

### 2) 重複と二重実装: ほぼ解消済み。残りは意図的

事実（当時）は次の2点です。
- `load_json`: `report_utils` に1つある（存在チェックなし）。`generate_report` と `check_changes` が使う。`slack_notify` だけが、「pathが無ければ `[]`」という別仕様の自前実装を持っていた。
- 差分判定: `report_utils.compare_listings` に集約済み。`check_changes` は自前でキーを比較しているが、ロジックは同じ（price_manの差分でupdated）。

評価: 重複はほぼ解消済み。`slack_notify.load_json` は「存在しなければ `[]`」という仕様差があるため、`io/json_store.load_json(path, missing_ok=True)` のようにオプションで統一する案には意味がある。この案は、`report_utils.load_json` の `missing_ok` で実現済み。

### 3) 依存関係の歪み: 妥当。解消するとよい

- 事実（当時）: `slack_notify.py` が `generate_report.get_three_scenario_columns` をimportしていた。通知がレポート生成に依存する形になっていた。
- 評価: 指摘のとおり。`get_three_scenario_columns` はprice_predictorを使う予測ロジックである。
  `report_utils` か `integrations/optional_features`（または専用のprice_predictorラッパー）に移すとよい。`generate_report` と `slack_notify` の両方がそこを参照すれば、依存が一方向になる。
  実施する価値がある。この項目は `optional_features` への移動で実施済み。

### 4) オプショナル依存の扱い: 妥当。改善の余地あり

- 事実（当時）: `generate_report.py` と `slack_notify.py` の両方に、try/except ImportError とダミー関数が複数あった。
  対象は、asset_score、asset_simulation、loan_calc、commute、price_predictorである。
- 評価: 指摘のとおりで、可読性と保守性を損なっていた。`integrations/optional_features.py` で一括ロードし、`features.get_asset_score_and_rank(...)` のように呼ぶ形にすれば、両ファイルの try/except が減る。妥当な改善で、`optional_features.py` として実施済み（`integrations/` ディレクトリは作らず、`scraping-tool/` 直下に置いた）。

### 5) sys.path hack: 事実だが、パッケージ化しないなら許容範囲

- 事実: `main.py` が `sys.path.insert(0, str(Path(__file__).resolve().parent))` を実行している。`evaluate.py` と `scripts/build_units_cache.py` も同様。
- 評価: 「パッケージ設計の欠如」という指摘は事実。ただし、実行は `cd scraping-tool` が前提で、GitHub Actionsの `working-directory: scraping-tool` とも一致している。パッケージ化（`scraping_tool/` と `pip install -e .`）をするなら sys.path は不要になる。パッケージ化しないなら、この程度の sys.path は多くのスクリプトで使われている現実的な方法である。必須の改善ではない。

---

## 2. 目標アーキテクチャの評価

### 良い点

- domain（listing_key、compare_listings、DiffResult）: 純粋ロジックの切り出しは妥当である。テストもしやすい。
- io（load_json、save_json）: JSONの読み書きを1か所にまとめるのは妥当。`missing_ok` で、slackとreportの仕様差を吸収できる。
- optional依存の集約: 前述のとおり、可読性と保守性の向上に有効。
- 既存スクリプトを薄いラッパーで残す: CLIの互換性と、GitHub Actionsおよび `update_listings.sh` との整合を保てる。

### 要検討、または過剰になりうる点

#### フルパッケージ化（`scraping_tool/` ディレクトリ）
- メリット: パッケージの境界がはっきりし、sys.pathが不要になる。
- デメリット: リポジトリ構成と `pip install -e .` を見直す必要がある。`scripts/update_listings.sh` やActionsの `python3 generate_report.py` などのパスと実行方法も見直す必要がある。規模がまだ小さいため、必須ではない。

#### Listing dataclass
型が明確になる点では有効です。一方、現状はスクレイパー出力からJSON、レポートまでdictで一貫しています。dataclassにすると `from_dict` と `to_dict` が増え、変更範囲が大きくなります。中長期で型を強くしたい場合の選択肢としては妥当ですが、短期のリファクタでは必須ではありません。

#### Configのdataclass化
`config.py` は定数だけで、多くのファイルが `from config import PRICE_MIN_MAN, ...` と書いています。dataclassにするとimportの書き方が変わり、影響範囲が広くなります。定数化のメリットはありますが、優先度は高くありません。

#### CLIのsubcommand統合（scrape / report / notify / check）
既存の4スクリプトを残すなら、「統合コマンド」と「従来コマンド」の二本立てになりやすくなります。互換性を最優先するなら、subcommand統合は後回しでかまいません。

---

## 3. 実装手順（Step AからF）の評価

| Step | 内容 | 評価 | 実施状況（2026-10-02確認） |
|------|------|------|------|
| A: テスト土台 | pytestで listing_key、compare_listings、format系のテストを書く | 妥当。まずここから始める価値が高い | 実施済み |
| B: domain抽出 | report_utilsの純粋ロジックをdomain/へ移し、report_utilsはre-exportする | 妥当。既存のimportを壊さずに移行できる | 未実施 |
| C: io抽出 | load_jsonを io/json_store に統一する | 妥当。slackの「無ければ []」は `missing_ok=True` で吸収できる | `report_utils.load_json` への統一として実施済み（io/ディレクトリは未作成） |
| D: render層 | Markdown生成とSlackメッセージの組み立てをrender/に分離する | 妥当。その際に、`get_three_scenario_columns` をgenerate_reportからdomainかintegrationsへ移し、slack_notifyがgenerate_reportに依存しないようにすると、指摘3が解消する | 依存の逆転だけ実施済み。render/への分離は未実施 |
| E: optional依存の整理 | try/except を integrations/optional_features に集約する | 妥当。実施すると可読性がかなり上がる | `optional_features.py` として実施済み |
| F: CLI統合 | 共通のargparseを作り、既存スクリプトを薄いラッパーにする | 互換性を守るなら可能。パッケージ化しない場合は、後回しでもよい | 未実施 |

---

## 4. まとめ: 何を採用し、何を後回しにするか

### 採用してよい（妥当で効果が大きい）

1. pytestの追加（Step A）: listing_key、compare_listings、format系の境界値テストを書く。
2. optional依存の集約（Step E）: `integrations/optional_features.py` で一括ロードする。generate_reportとslack_notifyの try/except を減らす。
3. 依存の逆転（Step Dの一部）: `get_three_scenario_columns` をreport_utilsか専用モジュールに移す。これで、slack_notifyがgenerate_reportに依存しなくなる。
4. ioの整理（Step C）: `load_json(path, missing_ok=False)` を1か所に定義し、slackは `missing_ok=True` で呼ぶ。既存の `report_utils.load_json` を、その関数への委譲にしてもよい。

上の4項目は、前掲の「更新」の節に書いたとおり実施済みです。

### 検討し、段階的に進めるとよい

5. domainの切り出し（Step B）: 純粋ロジックを `domain/` に移す。report_utilsからre-exportする。テストを書いたあとに行うと安全。
6. renderの切り出し（Step D）: Markdownの組み立てを別モジュールに分ける。Slackメッセージの組み立ても同様に分ける。ファイルが長いので分離のメリットはあるが、まずは `get_three_scenario_columns` の移動とoptional集約を優先するとよい。

### 必須ではない（規模とコストのバランスによる）

7. フルパッケージ化（`scraping_tool/` と `pip install -e .`）: 実施すれば、sys.pathが不要になり、importを一貫して書ける。ただし、ワークフローとドキュメントの変更が伴う。現状の規模では必須ではない。
8. Config dataclass化: 影響範囲が広い。定数を整理する必要が高まってからでよい。
9. Listing dataclass: 型を強くしたい場合の選択肢。dictのままでも現状は運用できる。
10. CLI subcommand統合: 互換性を最優先するなら、既存の4スクリプトをそのまま使い、統合は後回しにする。

---

## 5. この評価の使い方

- ChatGPTに依頼するときは、採用する部分を限定する。例は「StepAとEだけ先にやってほしい」「get_three_scenario_columnsの依存逆転だけやってほしい」である。過剰な変更を避けられる。
- 「診断3と4を解消する」「テストを追加する」と明示すると、妥当で効果の大きい部分だけを実行してもらいやすい。
- パッケージ化とCLI統合は、将来行うかどうかを決めたうえで、別のタスクとして依頼する。
