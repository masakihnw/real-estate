# 所在階・総戸数・権利形態（所有権）の取得元

Notion に送っている「所在階」「総戸数」「権利形態」がどこまで取れているかのメモ。

## 所在階 (floor_position)

| 取得元 | 状況 |
|--------|------|
| **SUUMO** | 一覧の詳細ブロックで「所在階」「階」ラベルから取得。cassette 形式では本文の「○階」をパース。**詳細ページの HTML をキャッシュからパースした結果も `build_units_cache` → `building_units.json` で `apply_conditions` にマージされる**（一覧で None のときのみ）。 |
| **HOME'S** | 一覧の表・span から「○階」をパースして取得。 |

→ 一覧で取れない場合は**詳細キャッシュ**（後述）で補完される。

---

## 総戸数 (total_units)

| 取得元 | 状況 |
|--------|------|
| **SUUMO** | **一覧には総戸数が出ない。** 詳細ページの HTML に「総戸数○戸」がある。`scripts/build_units_cache.py` で**詳細 HTML を `data/html_cache/` に保存**し、パース結果（総戸数・所在階・階建・権利形態）を `data/building_units.json` に保存。次回は**キャッシュに HTML があれば再取得せずその HTML からパース**する。`apply_conditions` で `r.total_units` などにマージされる。 |
| **HOME'S** | 一覧に「総戸数○戸」の表記があれば `_parse_total_units` で取得。 |

→ 定期実行（`update_listings.sh`）に `build_units_cache.py` が組み込まれており、毎回 latest.json 取得後に**HTML キャッシュ**と **building_units.json** を更新。次回実行時はキャッシュ済み URL は HTTP 取得せずローカル HTML からパースする。

---

## 権利形態（所有権かどうか）(ownership)

| 取得元 | 状況 |
|--------|------|
| **SUUMO** | 一覧の**詳細ブロック**で「権利形態」ラベルから取得（所有権・借地権・底地権等）。cassette 形式の一覧では権利列が無いため None。**詳細ページの「権利形態」「敷地の権利形態」行も `parse_suumo_detail_html` でパースし、詳細キャッシュ経由で `apply_conditions` にマージされる**（一覧で None のときのみ）。 |
| **HOME'S** | 一覧の「権利」「権利形態」セルや本文から `_parse_ownership` で取得。 |

→ 一覧で取れない場合は**詳細キャッシュ**で補完される。Notion では未取得時「不明」として送る。
