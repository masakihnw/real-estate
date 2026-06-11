# iOS アプリ パフォーマンス調査レポート

**日付**: 2026-06-03
**対象**: real-estate-ios（SwiftUI アプリ）
**症状**: like/nope 操作のリアクション遅延、画面遷移の遅さ、全体的なもっさり感

---

## 調査対象ファイル

| ファイル | 役割 |
|----------|------|
| `SwipeSessionView.swift` | スワイプ画面のメインUI・ジェスチャー制御 |
| `SwipeSessionViewModel.swift` | スワイプセッションのビジネスロジック |
| `SwipeCardView.swift` | カード表示・画像カルーセル |
| `SwipeActionBar.swift` | Like/Nope/Skip ボタン |
| `BuildingPreferenceStore.swift` | Like/Nope 設定の永続化（Supabase） |
| `SupabaseListingStore.swift` | 物件データの取得・同期 |
| `ListingDetailView.swift` | 物件詳細画面 |
| `ListingListView.swift` | 物件一覧画面（フィルタ・ソート） |
| `TrimmedAsyncImage.swift` | 画像読込（メモリ+ディスクキャッシュ付き） |
| `Listing.swift` | 物件モデル（JSON パース・computed property） |

---

## 問題 1: スワイプ後の固定遅延 350ms（体感影響: 最大）

### 箇所

`SwipeSessionView.swift:195-211`

```swift
private func commitWithAnimation(_ decision: SwipeDecision, translation: CGSize) {
    isExiting = true
    let exitAnimation: Animation = reduceMotion
        ? .easeOut(duration: 0.2)
        : .spring(response: 0.35, dampingFraction: 0.75)

    withAnimation(exitAnimation) {
        exitOffset = translation
    }

    // ★ 問題: 固定時間待ちでアニメーション完了を推定
    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : 0.35)) {
        viewModel.commitSwipe(decision)
        dragOffset = .zero
        exitOffset = .zero
        isExiting = false  // ← ここまで操作ロック
    }
}
```

### 問題の詳細

- `DispatchQueue.main.asyncAfter` でアニメーション完了を**推定**している
- アニメーション完了と `asyncAfter` のタイミングにズレが生じうる
- 350ms 間 `isExiting = true` でジェスチャーを完全ブロック → 連続スワイプ不可
- spring アニメーションは実際にはもっと早く「見かけ上完了」するが、350ms 固定で待つ

### 提案する修正

**案A: `withAnimation` の completion（iOS 17+）を使う**

```swift
private func commitWithAnimation(_ decision: SwipeDecision, translation: CGSize) {
    isExiting = true
    let exitAnimation: Animation = reduceMotion
        ? .easeOut(duration: 0.2)
        : .spring(response: 0.35, dampingFraction: 0.75)

    withAnimation(exitAnimation) {
        exitOffset = translation
    } completion: {
        viewModel.commitSwipe(decision)
        dragOffset = .zero
        exitOffset = .zero
        isExiting = false
    }
}
```

利点: アニメーション実完了に同期するため、ズレがなくなる。spring が早く収束すれば早く次へ進む。

**案B: 遅延を短縮し、UI更新を先行させる**

```swift
// commitSwipe（データ更新）を即座に実行し、アニメーションと並行
viewModel.commitSwipe(decision)

withAnimation(exitAnimation) {
    exitOffset = translation
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
    dragOffset = .zero
    exitOffset = .zero
    isExiting = false
}
```

利点: データ更新が即座に反映され、体感がさらに速くなる。

---

## 問題 2: スワイプ画面の初期ロードが全件 enrichment 取得でブロック（体感影響: 大）

### 箇所

`SwipeSessionView.swift:50-54`

```swift
.task {
    viewModel.loadCards(from: listings)
    await prefetchEnrichment()      // ← 全件完了まで待つ
    isLoadingEnrichment = false     // ← ここでやっとカード表示
}
```

`prefetchEnrichment()` (行 215-228):

```swift
private func prefetchEnrichment() async {
    let store = SupabaseListingStore.shared
    let needsFetch = viewModel.cards.filter { $0.enrichmentFetchedAt == nil }
    await withTaskGroup(of: Void.self) { group in
        for listing in needsFetch {
            group.addTask {
                try? await store.fetchDetail(
                    identityKey: listing.identityKey,
                    modelContext: modelContext
                )
            }
        }
    }
}
```

### 問題の詳細

- enrichment 未取得カードが50件あれば、50件の Supabase RPC が**全て完了**するまでスピナー表示
- 各 RPC は `get_listing_detail` で個別物件の全 enrichment を取得（JSONB 含む重いレスポンス）
- TaskGroup に並列数の上限がないため、同時にN件のHTTPリクエストが走り Supabase のレート制限に到達する可能性もある
- ユーザーはカードを1枚ずつ見るのに、全件フェッチを待つ必要がある

### 提案する修正

カード表示を即座に行い、enrichment はバックグラウンドで段階的にフェッチする。

```swift
.task {
    viewModel.loadCards(from: listings)
    isLoadingEnrichment = false  // ← 即座にカード表示

    // 先頭3枚を優先フェッチ（表示中のカード）
    await prefetchEnrichment(range: 0..<min(3, viewModel.cards.count))

    // 残りをバックグラウンドで段階的にフェッチ（並列数制限付き）
    await prefetchEnrichment(range: 3..<viewModel.cards.count, maxConcurrency: 5)
}
```

enrichment がなくてもカード表示は可能（名前・価格・面積等は軽量ビューで取得済み）。
詳細画面を開いた時に enrichment がなければ、そこで lazy load すれば良い（既存ロジックがある）。

---

## 問題 3: SwipeCardView の AsyncImage にキャッシュなし（体感影響: 大）

### 箇所

`SwipeCardView.swift:66-78`

```swift
AsyncImage(url: images[imageIndex].url) { phase in
    switch phase {
    case .success(let image):
        image.resizable().aspectRatio(contentMode: .fill)...
    default:
        placeholder...
    }
}
.id(imageIndex)
```

### 問題の詳細

- システムの `AsyncImage` はメモリキャッシュのみ（URLSession のデフォルト HTTP キャッシュ依存）
- 一方、リスト表示の `TrimmedAsyncImage` はメモリ（NSCache 200件）+ ディスクキャッシュ（SHA256 ハッシュ）付き
- カード切り替え時、前のカードの画像が破棄され、undo で戻った場合に再フェッチが走る
- 画像の白余白トリミングも行われないため、SUUMO 画像のパディングがそのまま表示される

### 提案する修正

**案A: `TrimmedAsyncImage` を SwipeCardView にも適用**

```swift
TrimmedAsyncImage(url: images[imageIndex].url, width: w, height: h)
```

**案B: カード画像のプリフェッチ**

現在のカード + 次の2枚の画像を事前にダウンロードしてキャッシュに入れておく。

```swift
private func prefetchImages(for indices: [Int]) {
    for index in indices {
        guard index < viewModel.cards.count else { continue }
        let card = viewModel.cards[index]
        if let url = card.thumbnailURL {
            Task { try? await URLSession.shared.data(from: url) }
        }
    }
}
```

---

## 問題 4: ListingListView の onChange 連鎖（体感影響: 中）

### 箇所

`ListingListView.swift:560-567`

```swift
.onChange(of: BuildingPreferenceStore.shared.nopedKeys.count) { _, _ in
    if delistFilter == .noped { loadPrefListings() }
    recomputeFiltered(animated: true)       // ← 1回目
}
.onChange(of: BuildingPreferenceStore.shared.likedKeys.count) { _, _ in
    if delistFilter == .liked { loadPrefListings() }
    recomputeFiltered()                     // ← 2回目
}
```

### 問題の詳細

- 1回の like 操作で `likedKeys.insert()` + `nopedKeys.remove()` が同時に起きる（`setPreference` 内）
- 結果として **2つの onChange** が発火 → `recomputeFiltered()` が2回走る
- `recomputeFiltered()` 内で `computeFilteredAndSorted()`（40以上のソートケース、800件以上の配列操作）が MainActor で実行
- Task キャンセルで2回目が1回目をキャンセルするが、1回目の計算途中までのCPU消費は無駄
- `availableLayouts/Wards/RouteStations/Directions/NumericFields` の再計算（行 424-428）も毎回走る

### 提案する修正

**案A: onChange を統合**

```swift
// nopedKeys と likedKeys の変更を1つのトリガーにまとめる
.onChange(of: BuildingPreferenceStore.shared.nopedKeys.count
           + BuildingPreferenceStore.shared.likedKeys.count) { _, _ in
    if delistFilter == .noped { loadPrefListings() }
    if delistFilter == .liked { loadPrefListings() }
    recomputeFiltered(animated: true)
}
```

**案B: debounce 的な遅延統合**

```swift
private var preferenceDebounceTask: Task<Void, Never>?

// onChange で直接 recompute せず debounce
.onChange(of: BuildingPreferenceStore.shared.nopedKeys.count) { _, _ in
    schedulePreferenceRecompute()
}
.onChange(of: BuildingPreferenceStore.shared.likedKeys.count) { _, _ in
    schedulePreferenceRecompute()
}

private func schedulePreferenceRecompute() {
    preferenceDebounceTask?.cancel()
    preferenceDebounceTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        if delistFilter == .noped || delistFilter == .liked { loadPrefListings() }
        recomputeFiltered(animated: true)
    }
}
```

**案C: `computeFilteredAndSorted()` をバックグラウンドスレッドで実行**

フィルタ・ソート処理は純粋な計算なので `nonisolated` で実行可能。
結果だけ MainActor に戻す。

```swift
private func recomputeFiltered(animated: Bool = false) {
    filterTask?.cancel()
    filterTask = Task {
        let base = await baseList
        let filter = await filterStore.filter
        let noped = await BuildingPreferenceStore.shared.nopedKeys
        let searchText = await self.searchText

        // バックグラウンドで計算
        let result = Self.computeFilteredAndSorted(base, filter: filter, noped: noped, searchText: searchText, sortOrder: sortOrder)
        let grouped = Self.computeGrouped(from: result)

        guard !Task.isCancelled else { return }

        await MainActor.run {
            if animated {
                withAnimation(.easeInOut(duration: 0.3)) {
                    cachedFiltered = result
                    cachedGrouped = grouped
                }
            } else {
                cachedFiltered = result
                cachedGrouped = grouped
            }
        }
    }
}
```

---

## 問題 5: 詳細画面の逐次ロード（体感影響: 中）

### 箇所

`ListingDetailView.swift:223-227`

```swift
.task {
    await loadEnrichmentIfNeeded()              // ← ネットワーク呼び出し（完了を待つ）
    similarListings = fetchSimilarListings()     // ← DB クエリ（上が完了してから）
    nearbyTransactions = fetchNearbyTransactions() // ← DB クエリ（上が完了してから）
}
```

### 問題の詳細

- `loadEnrichmentIfNeeded()` は Supabase RPC（ネットワーク IO）
- `fetchSimilarListings()` と `fetchNearbyTransactions()` はローカル SwiftData クエリ（ネットワーク不要）
- ネットワーク完了を待ってからローカルクエリが始まるため、enrichment ロードが遅いと全体が遅延
- 類似物件と近隣成約はリスト同期済みの軽量データなので即座に表示可能

### 提案する修正

`async let` で並列化:

```swift
.task {
    async let enrichment: () = loadEnrichmentIfNeeded()
    let similar = fetchSimilarListings()        // ← 即座にローカルDB検索
    let nearby = fetchNearbyTransactions()       // ← 即座にローカルDB検索
    similarListings = similar
    nearbyTransactions = nearby
    await enrichment  // ネットワーク完了を待つのは最後
}
```

---

## 問題 6: DTO デコードの二重シリアライズ（体感影響: 小〜中）

### 箇所

`SupabaseListingStore.swift:316-373`

```swift
for i in 0..<jsonArray.count {
    var row = jsonArray[i]
    for key in Self.jsonbStringFields {
        if let val = row[key], !(val is NSNull), !(val is String) {
            // ★ Object → Data → String
            if let jsonData = try? JSONSerialization.data(withJSONObject: val),
               let str = String(data: jsonData, encoding: .utf8) {
                row[key] = str
            }
        }
    }
    jsonArray[i] = row
}

// さらに row → Data → ListingDTO にデコード
for (i, row) in jsonArray.enumerated() {
    let rowData = try JSONSerialization.data(withJSONObject: row)  // ★ 再シリアライズ
    let dto = try decoder.decode(ListingDTO.self, from: rowData)
}
```

### 問題の詳細

- JSONB フィールド（13種類）が `[String: Any]` → `Data` → `String` に変換される
- その後、行全体が `[String: Any]` → `Data` → `ListingDTO` にデコードされる
- 200件同期時: 200 × (13回の部分シリアライズ + 1回の全体シリアライズ) = 2,800回の JSONSerialization 呼び出し
- この処理は `refresh()` 内で走り、同期中のメインスレッド応答性に影響

### 提案する修正

ListingDTO の JSONB フィールドの型を `String?` から直接 JSON デコード可能な型に変更し、二重変換を排除する。
ただし ListingDTO の変更影響範囲が大きいため、段階的に対応する。

短期対策として、バッチ処理をバックグラウンドスレッドに逃がす:

```swift
static func decodeDTOs(from data: Data) async throws -> [ListingDTO] {
    try await Task.detached(priority: .userInitiated) {
        // 既存のデコード処理（メインスレッドから解放）
    }.value
}
```

---

## 良い設計（変更不要）

| 箇所 | 設計 | 評価 |
|------|------|------|
| `BuildingPreferenceStore.setPreference()` | Optimistic update + 失敗時ロールバック | ✅ 適切 |
| `SwipeSessionViewModel.commitSwipe()` | DB保存を `Task {}` でバックグラウンド実行 | ✅ 適切 |
| `TrimmedAsyncImage` | メモリ+ディスク2層キャッシュ | ✅ 適切 |
| `Listing.parsedSuumoImages` | ソースJSON変更時のみ再パース（キャッシュ付き） | ✅ 適切 |
| `SupabaseListingStore` | 2層データ取得（軽量リスト + 遅延 enrichment） | ✅ 適切 |
| `recomputeFiltered()` | Task キャンセルで最新のみ実行 | ✅ 適切 |
| ETag 差分同期 | 変更がなければデータ転送なし | ✅ 適切 |

---

## 優先度まとめ

| 優先度 | 問題 | 修正コスト | 体感改善 |
|--------|------|-----------|----------|
| P0 | スワイプ後 350ms 固定遅延 | 小（数行変更） | ★★★★★ |
| P0 | enrichment 全件ブロック | 中（ロード戦略変更） | ★★★★★ |
| P1 | AsyncImage キャッシュなし | 小（TrimmedAsyncImage 適用） | ★★★★ |
| P1 | onChange 連鎖 | 小（統合 or debounce） | ★★★ |
| P2 | 詳細画面の逐次ロード | 小（async let） | ★★★ |
| P2 | DTO 二重シリアライズ | 中（型変更 or detached） | ★★ |
