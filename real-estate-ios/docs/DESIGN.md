# デザイン指針（HIG・OOUI・Liquid Glass）

本アプリはAppleのHuman Interface Guidelines（HIG）とOOUI（Object-Oriented User Interface）に従う。iOS 26のLiquid Glassにも対応する。iOS 17〜25では、システムの背景色による塗りにフォールバックする。

---

## 1. Human Interface Guidelines（HIG）

- レイアウト: セーフエリアを尊重する。リストは `.listStyle(.plain)` と適切な `listRowInsets` で余白をそろえる（`DesignSystem.listRowVerticalPadding` / `listRowHorizontalPadding`）。
- タイポグラフィ: システムフォントを前提とする。`ListingObjectStyle` で階層を定義する（title / subtitle / caption / detailValue / detailLabel）。Dynamic Typeに対応するため、カスタムフォントサイズは極力使わない。
- 色: セマンティックカラー（`.primary` / `.secondary` / `.tertiary`）を優先する。アクセントは `.accentColor`（システムのtint）を使う。
- フィードバック: 一覧の更新中は、`ProgressView` を `.regularMaterial` のカプセルに入れて画面下部に重ねる。エラーは同じ位置に短く表示し、タップでメッセージをコピーできる。
- アクセシビリティ: 一覧行に `accessibilityLabel`（物件名・価格・面積・徒歩）と `accessibilityHint`（タップで詳細）を付ける。並び順メニューには「並び順」ラベルを付ける。詳細の「詳細を開く」リンクにもラベルを付ける。

---

## 2. OOUI（Object-Oriented User Interface）

- オブジェクト: 中心となるオブジェクトは物件（Listing）である。一覧は物件の集合、詳細は1つの物件の属性として表現する。
- 名詞から動詞へ: まずオブジェクトを選択する（一覧で物件をタップ）。そのあとにアクションを選ぶ（詳細を見る、ブラウザで開く）。HIGのオブジェクトベースの操作に沿う。
- 一貫したオブジェクト表現: 一覧行では「名前・価格・面積・徒歩・路線」で物件を要約する。詳細では同じ属性をラベル付きで展開する。物件が何であるかが、画面間で一貫する。

---

## 3. Liquid Glass（iOS 26）とフォールバック（iOS 17〜25）

iOS 26のLiquid Glassは、半透明のガラス質感で深度と動きを与えるAppleのデザインである。SwiftUIでは `.glassEffect(in: .rect(cornerRadius:))` で適用する。本アプリでの適用箇所は次の3つである。

- 一覧の行背景: 行ごとのカードに適用する（`ListingListView.swift` の `ListingRowBackground`）。iOS 26では `.glassEffect`、iOS 17〜25では `secondarySystemGroupedBackground` で塗った角丸の矩形を使う。
- 詳細の属性カード: `listingGlassBackground()` で適用する。iOS 26では `.glassEffect`、それ以前は `secondarySystemGroupedBackground` で塗る。
- タブバー: iOS 26ではシステムが自動でLiquid Glassを適用するため、アプリ側の追加対応は不要である。

iOS 17〜25のフォールバックでは、`RoundedRectangle` を `secondarySystemGroupedBackground` で塗る。角丸は `DesignSystem.cornerRadius` で統一する。

---

## 4. 実装上の注意

- `DesignSystem.swift`: 余白・角丸・フォントスタイルを一元管理する。Liquid Glass用の拡張は `listingGlassBackground()`、`listingRowGlassBackground()`、`tintedGlassBackground(tint:)` の3つである。いずれも `#available(iOS 26, *)` で `.glassEffect` とフォールバックを切り替える。新規コードは `DS` 名前空間のトークンを参照する。旧 `DesignSystem` の定数は、既存コードが引き続き使っている。
- リスト行: `listRowBackground` で行ごとに角丸の背景を当て、行間はpaddingで調整する。スクロール性能を保つため、行ビューは軽量に保つ。一覧の行には、`TrimmedAsyncImage` によるサムネイルを1枚表示する。
