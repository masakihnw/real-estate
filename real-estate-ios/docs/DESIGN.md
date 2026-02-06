# デザイン指針（HIG・OOUI・Liquid Glass）

本アプリは Apple の **Human Interface Guidelines（HIG）** と **OOUI（Object-Oriented User Interface）** に厳密に則り、**iOS 26 の Liquid Glass** デザインシステムに対応する。iOS 17–25 では既存のシステムスタイル（Material 等）にフォールバックする。

---

## 1. Human Interface Guidelines（HIG）

- **レイアウト**: セーフエリアを尊重。リストは `.listStyle(.plain)` と適切な `listRowInsets` で余白を統一（`DesignSystem.listRowVerticalPadding` / `listRowHorizontalPadding`）。
- **タイポグラフィ**: システムフォントを前提に、`ListingObjectStyle` で階層を定義（title / subtitle / caption / detailValue / detailLabel）。Dynamic Type に対応するため、カスタムフォントサイズは極力使わない。
- **色**: セマンティックカラー（`.primary` / `.secondary` / `.tertiary`）を優先。アクセントは `.accentColor`（システムの tint）。
- **フィードバック**: 更新中は `ProgressView` と `.ultraThinMaterial` のオーバーレイ。エラーはツールバーに短く表示し、設定で詳細を確認できるようにする。
- **アクセシビリティ**: 一覧行に `accessibilityLabel`（物件名・価格・面積・徒歩）と `accessibilityHint`（タップで詳細）。並び順メニューに「並び順」ラベル。詳細の「詳細を開く」リンクにもラベルを付与。

---

## 2. OOUI（Object-Oriented User Interface）

- **オブジェクト**: 中心となるオブジェクトは **物件（Listing）**。一覧は「物件の集合」、詳細は「1 つの物件の属性」として表現する。
- **名詞→動詞**: まずオブジェクトを選択（一覧で物件をタップ）し、その後にアクション（詳細を見る・ブラウザで開く）。HIG の「オブジェクトベースの操作」に沿う。
- **一貫したオブジェクト表現**: 一覧行では「名前・価格・面積・徒歩・路線」でオブジェクトを要約。詳細では同じ属性をラベル付きで展開。オブジェクトの「何であるか」が画面間で一貫する。

---

## 3. Liquid Glass（iOS 26）とフォールバック（iOS 17–25）

- **iOS 26**: Apple の Liquid Glass は、半透明のガラス質感で深度と動きを与えるデザイン。SwiftUI では `.glassEffect(in: .rect(cornerRadius:))` で適用する。
- **本アプリでの適用箇所**:
  - 一覧の行背景: 行ごとのカードにガラス／マテリアルを適用（iOS 26 では `.glassEffect`、それ以前は `.ultraThinMaterial`）。
  - 詳細の属性カード（`DetailItem`）: `listingGlassBackground()` で Material を適用。iOS 26 SDK でビルドする場合は `DesignSystem.swift` のコメントに従い `.glassEffect(in: .rect(cornerRadius:))` に差し替え可能。
  - タブバー: システムが iOS 26 で自動的に Liquid Glass を適用するため、アプリ側の追加対応は不要。
- **フォールバック**: iOS 17–25 では `RoundedRectangle` + `.ultraThinMaterial` で同等の「軽いガラス風」を実現。角丸は `DesignSystem.cornerRadius` で統一。

---

## 4. 実装上の注意

- **DesignSystem.swift**: 余白・角丸・フォントスタイルを一元管理。Liquid Glass 用の拡張 `listingGlassBackground()` は現状 Material フォールバックのみ。Xcode が iOS 26 SDK を提供するようになったら、`#available(iOS 26, *)` で `.glassEffect(in: .rect(cornerRadius: DesignSystem.cornerRadius))` を呼ぶ分岐を追加する。
- **リスト行**: `listRowBackground` で行ごとに角丸の Material を当て、行間は padding で調整。スクロール性能を保つため、行ビューは軽量に保つ（画像は使わない、テキストと SF Symbol のみ）。
