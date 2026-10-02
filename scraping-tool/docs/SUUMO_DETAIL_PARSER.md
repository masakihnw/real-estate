# SUUMO詳細ページHTMLパーサー

`suumo_scraper.parse_suumo_detail_html()` は、物件詳細ページのHTMLから総戸数、所在階、階建などの物件属性を取得します。この関数はHTTPリクエストを行いません。保存したページなど、手元のHTMLを渡して使います。

## 使い方

```python
from suumo_scraper import parse_suumo_detail_html

html = open("path/to/suumo_detail.html", encoding="utf-8").read()
result = parse_suumo_detail_html(html)

# result["total_units"]     → 総戸数（例: 38）
# result["floor_position"]  → 所在階（例: 12）
# result["floor_total"]     → 建物階数（例: 13）
# result["floor_structure"] → 表示用の構造・階建文字列（例: "RC13階地下1階建"）
```

`report_utils.format_floor` に `floor_position` と `floor_structure` を渡すと、「12階/RC13階地下1階建」の形式になります。

戻り値のdictが持つ、上の4項目以外のキーは次のとおりです。

- `ownership`（権利形態）、`management_fee`、`repair_reserve_fund`
- `direction`、`balcony_area_m2`、`parking`、`constructor`、`zoning`
- `repair_fund_onetime`、`delivery_date`
- `feature_tags`（ページ内のJavaScriptオブジェクト `gapSuumoPcForKr` から取得）
- `floor_plan_images`、`suumo_images`

該当する項目がHTMLに無い場合や、パースできなかった場合は `None` になります。掲載終了ページのマーカーがHTMLに含まれる場合は、`{"delisted": True}` だけを返します。

## 想定しているHTML構造

`docs/suumo.html` をサンプルにした、SUUMO詳細ページの表構造です。

| 項目 | thの内容 | tdの例 |
|------|-----------|---------|
| 総戸数 | 「総戸数」を含むth（`<div class="fl">総戸数</div>` など） | `38戸` |
| 所在階と階建 | 「所在階」または「所在階/構造・階建」を含むth | `12階` または `12階/RC13階地下1階建` |
| 構造・階建て | 「構造・階建て」を含むth | `RC13階地下1階建` |

- 総戸数は、直後の `td` のテキストから「数字+戸」を正規表現で取得します（例: `38戸` なら38）。
- 所在階は、同じ `td` の先頭にある「数字+階」を使います（例: `12階/RC13階…` なら12）。
- 建物階数は、`RC13階地下1階建` や `12階/RC13階地下1階建` の「数字+階」の部分から取得します（例: 13）。

ページによっては、「所在階」の行が `12階`、「総戸数」の行が `38戸`、「構造・階建て」の行が `RC13階地下1階建` のように別々になっています。どのレイアウトでも、上記のthラベルと直後のtdを走査してパースします。

## 注意

- この関数は詳細ページを取得しません。HTMLは事前に保存したファイルなどで用意してください。
- SUUMOのHTML構造が変わると、パースできなくなる可能性があります。その場合は `suumo_scraper.parse_suumo_detail_html` の正規表現とthの判定を調整してください。
