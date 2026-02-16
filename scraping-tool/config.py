"""
10年住み替え前提・中古マンション購入条件に基づくフィルタ設定。

【条件の参照】
- 詳細・厳格化の考え方: ../docs/10year-index-mansion-conditions-draft.md
- 初回ヒアリングの希望条件: ../docs/initial-consultation.md

【厳格化適用済み】徒歩10分・築15年以内・専有55㎡以上（上限なし）・総戸数50戸以上・路線限定（山手線・メジャー私鉄など）。価格・総戸数は一覧で取れる範囲で反映。
"""

import datetime

# 検索地域: 東京23区以内
AREA_LABEL = "東京23区"
# 23区の区名（住所フィルタ用。SUUMO 東京都一覧から23区のみ残す）
TOKYO_23_WARDS = (
    "千代田区", "中央区", "港区", "新宿区", "文京区", "台東区", "墨田区", "江東区",
    "品川区", "目黒区", "大田区", "世田谷区", "渋谷区", "中野区", "杉並区", "豊島区",
    "北区", "荒川区", "板橋区", "練馬区", "足立区", "葛飾区", "江戸川区",
)
# SUUMO URL で東京23区以外と判定する都県パス（/ms/chuko/kanagawa/ 等）
NON_TOKYO_23_URL_PATHS = ("/kanagawa/", "/chiba/", "/saitama/", "/ibaraki/", "/tochigi/", "/gunma/")

# 価格帯（万円）: 9,000万〜1.2億
PRICE_MIN_MAN = 9000
PRICE_MAX_MAN = 12000

# 専有面積（㎡）: 55以上、上限なし
AREA_MIN_M2 = 55
AREA_MAX_M2 = None  # None のときは上限チェックなし（AREA_MIN_M2 以上のみ）

# 間取り: 2LDK〜3LDK 中心（2LDK, 3LDK, 2DK, 3DK など含む）
LAYOUT_PREFIX_OK = ("2", "3")  # 2LDK, 3LDK, 2DK, 3DK

# 築年: 築15年以内（実行年の15年前以降の竣工）
BUILT_YEAR_MIN = datetime.date.today().year - 15

# 駅徒歩: 8分以内
WALK_MIN_MAX = 8

# 総戸数: 50戸以上（一覧で取得できればフィルタに組み込む）
TOTAL_UNITS_MIN = 50

# 路線: 山手線・メジャー私鉄などに限定。空のときは路線フィルタなし。
# 最寄り路線名（station_line）にいずれかが含まれる物件のみ通過。
ALLOWED_LINE_KEYWORDS = (
    "ＪＲ", "東京メトロ", "都営",
    "東急", "京急", "京成", "東武", "西武", "小田急", "京王", "相鉄",
    "つくばエクスプレス", "モノレール", "舎人ライナー",
    "ゆりかもめ", "りんかい",
)

# 駅乗降客数: 1日あたりこの値以上の駅のみ通過。0 のときはフィルタなし。
# data/station_passengers.json を scripts/fetch_station_passengers.py で1回取得してから有効になる。
STATION_PASSENGERS_MIN = 0

# SUUMO 23区のローマ字コード（区ごと一覧取得・23区判定で使用）
SUUMO_23_WARD_ROMAN = (
    "chiyoda", "chuo", "minato", "shinjuku", "bunkyo", "shibuya",
    "taito", "sumida", "koto", "arakawa", "adachi", "katsushika", "edogawa",
    "shinagawa", "meguro", "ota", "setagaya",
    "nakano", "suginami", "nerima",
    "toshima", "kita", "itabashi",
)

# リクエスト間隔（秒）: 負荷軽減のため
REQUEST_DELAY_SEC = 2
# HOME'S 専用のリクエスト間隔（秒）: AWS WAF ボット検知対策のため長めに設定
HOMES_REQUEST_DELAY_SEC = 5

# リクエストタイムアウト（秒）: 全ページ取得時は回数が増えるため余裕を持たせる
REQUEST_TIMEOUT_SEC = 60
# タイムアウト・接続エラー時のリトライ回数
REQUEST_RETRIES = 3

# User-Agent: 明示的にブラウザ相当を指定
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
