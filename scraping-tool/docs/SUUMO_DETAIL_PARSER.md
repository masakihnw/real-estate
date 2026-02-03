# SUUMO 詳細ページHTMLパーサー（階・総戸数）

物件詳細ページのHTMLから **総戸数** と **所在階／階建** を取得するためのパーサーです。  
詳細ページの自動スクレイピングは行いません。手元のHTML（保存したページやダウンロードしたHTML）を渡して利用します。

## 使い方

```python
from suumo_scraper import parse_suumo_detail_html

html = open("path/to/suumo_detail.html", encoding="utf-8").read()
result = parse_suumo_detail_html(html)

# result["total_units"]     → 総戸数（例: 38）
# result["floor_position"]  → 所在階（例: 12）
# result["floor_total"]     → 建物階数（例: 13）
# result["floor_structure"] → 表示用「構造・階建」文字列（例: "RC13階地下1階建"）。report_utils.format_floor に渡すと「12階/RC13階地下1階建」形式になる。
```

戻り値は `{"total_units": int|None, "floor_position": int|None, "floor_total": int|None, "floor_structure": str|None}` です。  
該当する項目がHTMLに無い、またはパースできなかった場合は `None` になります。

## 想定しているHTML構造

`docs/suumo.html` をサンプルにした、SUUMO 詳細ページの表構造です。

| 項目 | th の内容 | td の例 |
|------|-----------|---------|
| 総戸数 | 「総戸数」を含む th（`<div class="fl">総戸数</div>` 等） | `38戸` |
| 所在階／階建 | 「所在階」または「所在階/構造・階建」を含む th | `12階` または `12階/RC13階地下1階建` |
| 構造・階建て | 「構造・階建て」を含む th | `RC13階地下1階建` |

- **総戸数**: 直後の `td` のテキストから `数字+戸` を正規表現で取得（例: `38戸` → 38）。
- **所在階**: 同じ `td` の先頭の `数字+階` を所在階として使用（例: `12階/RC13階…` → 12）。
- **階建**: `RC13階地下1階建` や `12階/RC13階地下1階建` から `数字+階` の部分を建物階数として取得（例: 13）。

ページによっては「所在階」単独の行で `12階`、「総戸数」で `38戸`、「構造・階建て」で `RC13階地下1階建` のように別々の行になっている場合もあります。いずれのレイアウトでも、上記の th ラベルと直後の td を走査してパースします。

## 注意

- 詳細ページの取得（HTTP リクエスト）はこのモジュールでは行いません。HTML は事前に保存したファイルや別手段で用意してください。
- SUUMO のHTML構造が変更されるとパースできなくなる可能性があります。その場合は `suumo_scraper.parse_suumo_detail_html` の正規表現や th の判定を調整してください。
