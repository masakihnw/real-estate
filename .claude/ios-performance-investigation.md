# iOSアプリ パフォーマンス調査レポート

日付: 2026-06-03
対象: real-estate-ios（SwiftUIアプリ）
症状: like/nope操作のリアクション遅延、画面遷移の遅さ、全体的なもっさり感

本書のコード引用と行番号は、調査した2026-06-03時点のものである。現在の対応状況は次の表のとおりで、2026-10-02にコードとgit logで確認した。

| 問題 | 状態 | 確認した実装 |
|------|------|-------------|
| 問題 1: スワイプ後の固定遅延 350ms | 対応済み | `SwipeSessionView.swift` の `commitWithAnimation` が `withAnimation` の `completion` を使う（案A） |
| 問題 2: 初期ロードが全件enrichment取得でブロック | 対応済み | PR #77 で上限付き並列化、PR #86 で先頭ウィンドウ限定にした。起動時に待つのは先頭8件（`leadingPrefetchCount`）で、並列数の上限は6 |
| 問題 3: SwipeCardViewのAsyncImageにキャッシュなし | 対応済み | `SwipeCardView.swift` が `TrimmedAsyncImage` を使う（案A）。案Bのプリフェッチは実装していない（`prefetchImages` はコード内に無い） |
| 問題 4: ListingListViewのonChange連鎖 | 対応済み | `ListingListView.swift` の `schedulePreferenceRecompute` が50msのdebounceで1回にまとめる（案B）。案Cのバックグラウンド計算は採用していない |
| 問題 5: 詳細画面の逐次ロード | 対応済み | `ListingDetailView.swift` の `.task` が類似物件と近隣成約のローカル検索を先に実行し、`loadEnrichmentIfNeeded()` を最後にawaitする |
| 問題 6: DTOデコードの二重シリアライズ | 未対応 | `SupabaseListingStore.decodeDTOs` は同じ二重シリアライズを行い、`Task.detached` も使っていない |

---

## 調査対象ファイル

| ファイル | 役割 |
|----------|------|
| `SwipeSessionView.swift` | スワイプ画面のメインUI・ジェスチャー制御 |
| `SwipeSessionViewModel.swift` | スワイプセッションのビジネスロジック |
| `SwipeCardView.swift` | カード表示・画像カルーセル |
| `SwipeActionBar.swift` | Like/Nope/Skipボタン |
| `BuildingPreferenceStore.swift` | Like/Nope設定の永続化（Supabase） |
| `SupabaseListingStore.swift` | 物件データの取得・同期 |
| `ListingDetailView.swift` | 物件詳細画面 |
| `ListingListView.swift` | 物件一覧画面（フィルタ・ソート） |
| `TrimmedAsyncImage.swift` | 画像読込（メモリ+ディスクキャッシュ付き） |
| `Listing.swift` | 物件モデル（JSONパース・computed property） |

---

## 問題 1: スワイプ後の固定遅延 350ms（体感影響: 最大）

状態: 対応済み（上の表を参照）。

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

    // 問題: 固定時間待ちでアニメーション完了を推定
    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : 0.35)) {
        viewModel.commitSwipe(decision)
        dragOffset = .zero
        exitOffset = .zero
        isExiting = false  // ← ここまで操作ロック
    }
}
```

### 問題の詳細

- `DispatchQueue.main.asyncAfter` でアニメーション完了を推定している。
- アニメーションの完了と `asyncAfter` のタイミングがずれる場合がある。
- 350msの間、`isExiting = true` でジェスチャーを受け付けないため、連続スワイプができない。
- springアニメーションは実際にはもっと早く見かけ上完了するが、350ms固定で待っている。

### 提案する修正

案A: `withAnimation` のcompletion（iOS 17+）を使う。

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

利点は、アニメーションの実際の完了に同期するため、ずれがなくなることである。springが早く収束すれば、早く次へ進める。

案B: 遅延を短縮し、UI更新を先行させる。

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

利点は、データ更新が即座に反映され、体感がさらに速くなることである。

---

## 問題 2: スワイプ画面の初期ロードが全件enrichment取得でブロック（体感影響: 大）

状態: 対応済み（上の表を参照）。

### 箇所

`SwipeSessionView.swift:50-54`

```swift
.task {
    viewModel.loadCards(from: listings)
    await prefetchEnrichment()      // ← 全件完了まで待つ
    isLoadingEnrichment = false     // ← ここでやっとカード表示
}
```

`prefetchEnrichment()`（行 215-228）

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

- enrichment未取得のカードが50件あると、50件のSupabase RPCがすべて完了するまでスピナーを表示する。
- 各RPCは `get_listing_detail` で、個別物件のenrichmentを全部取得する（JSONBを含む重いレスポンス）。
- TaskGroupに並列数の上限がないため、同時にN件のHTTPリクエストが走り、Supabaseのレート制限に達する可能性がある。
- ユーザーはカードを1枚ずつ見るのに、全件のフェッチを待つ必要がある。

### 提案する修正

カードを即座に表示し、enrichmentはバックグラウンドで段階的にフェッチする。

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

enrichmentがなくてもカードは表示できる（名前・価格・面積等は軽量ビューで取得済み）。詳細画面を開いたときにenrichmentがなければ、そこでlazy loadすればよい（既存ロジックがある）。

---

## 問題 3: SwipeCardViewのAsyncImageにキャッシュなし（体感影響: 大）

状態: 対応済み（上の表を参照）。

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

- システムの `AsyncImage` はメモリキャッシュだけを持ち、URLSessionのデフォルトHTTPキャッシュに依存する。
- 一方、リスト表示の `TrimmedAsyncImage` は、メモリ（NSCache 200件）とディスクキャッシュ（SHA256ハッシュ）を持つ。
- カードを切り替えると前のカードの画像が破棄され、undoで戻ったときに再フェッチが走る。
- 画像の白余白トリミングも行われないため、SUUMO画像のパディングがそのまま表示される。

### 提案する修正

案A: `TrimmedAsyncImage` をSwipeCardViewにも適用する。

```swift
TrimmedAsyncImage(url: images[imageIndex].url, width: w, height: h)
```

案B: カード画像をプリフェッチする。現在のカードと次の2枚の画像を事前にダウンロードし、キャッシュに入れておく。

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

## 問題 4: ListingListViewのonChange連鎖（体感影響: 中）

状態: 対応済み（上の表を参照）。

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

- 1回のlike操作で、`setPreference` の中で `likedKeys.insert()` と `nopedKeys.remove()` が同時に起きる。
- その結果、2つのonChangeが発火し、`recomputeFiltered()` が2回走る。
- `recomputeFiltered()` の中で、`computeFilteredAndSorted()`（40以上のソートケース、800件以上の配列操作）がMainActorで実行される。
- Taskのキャンセルにより2回目が1回目をキャンセルするが、1回目の計算が途中まで進んだ分のCPU消費は無駄になる。
- `availableLayouts/Wards/RouteStations/Directions/NumericFields` の再計算（行 424-428）も毎回走る。

### 提案する修正

案A: onChangeを統合する。

```swift
// nopedKeys と likedKeys の変更を1つのトリガーにまとめる
.onChange(of: BuildingPreferenceStore.shared.nopedKeys.count
           + BuildingPreferenceStore.shared.likedKeys.count) { _, _ in
    if delistFilter == .noped { loadPrefListings() }
    if delistFilter == .liked { loadPrefListings() }
    recomputeFiltered(animated: true)
}
```

案B: debounceで遅延して統合する。

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

案C: `computeFilteredAndSorted()` をバックグラウンドスレッドで実行する。フィルタ・ソート処理は純粋な計算なので、`nonisolated` で実行できる。結果だけをMainActorに戻す。

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

状態: 対応済み（上の表を参照）。

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

- `loadEnrichmentIfNeeded()` はSupabase RPC（ネットワークIO）である。
- `fetchSimilarListings()` と `fetchNearbyTransactions()` は、ローカルのSwiftDataクエリで、ネットワークを使わない。
- ネットワークの完了を待ってからローカルクエリが始まるため、enrichmentのロードが遅いと全体が遅れる。
- 類似物件と近隣成約は、リスト同期済みの軽量データなので、即座に表示できる。

### 提案する修正

`async let` で並列化する。

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

## 問題 6: DTOデコードの二重シリアライズ（体感影響: 小〜中）

状態: 未対応（上の表を参照）。

### 箇所

`SupabaseListingStore.swift:316-373`

```swift
for i in 0..<jsonArray.count {
    var row = jsonArray[i]
    for key in Self.jsonbStringFields {
        if let val = row[key], !(val is NSNull), !(val is String) {
            // 問題: Object → Data → String
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
    let rowData = try JSONSerialization.data(withJSONObject: row)  // 問題: 再シリアライズ
    let dto = try decoder.decode(ListingDTO.self, from: rowData)
}
```

### 問題の詳細

- JSONBフィールド（13種類）が `[String: Any]` から `Data`、さらに `String` に変換される。
- その後、行全体が `[String: Any]` から `Data`、さらに `ListingDTO` にデコードされる。
- 200件を同期すると、200 × (13回の部分シリアライズ + 1回の全体シリアライズ) = 2,800回のJSONSerialization呼び出しになる。
- この処理は `refresh()` の中で走り、同期中のメインスレッドの応答性に影響する。

### 提案する修正

ListingDTOのJSONBフィールドの型を `String?` から、直接JSONデコードできる型に変更し、二重変換をなくす。ただしListingDTOの変更は影響範囲が大きいため、段階的に対応する。

短期対策として、バッチ処理をバックグラウンドスレッドに移す。

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
| `BuildingPreferenceStore.setPreference()` | Optimistic updateと、失敗時のロールバック | 適切 |
| `SwipeSessionViewModel.commitSwipe()` | DB保存を `Task {}` でバックグラウンド実行 | 適切 |
| `TrimmedAsyncImage` | メモリ+ディスクの2層キャッシュ | 適切 |
| `Listing.parsedSuumoImages` | ソースJSONが変わったときだけ再パース（キャッシュ付き） | 適切 |
| `SupabaseListingStore` | 2層のデータ取得（軽量リスト + 遅延enrichment） | 適切 |
| `recomputeFiltered()` | Taskキャンセルで最新のものだけ実行 | 適切 |
| ETag差分同期 | 変更がなければデータ転送なし | 適切 |

---

## 優先度まとめ

体感改善は5段階で示す。

| 優先度 | 問題 | 修正コスト | 体感改善 | 状態 |
|--------|------|-----------|----------|------|
| P0 | スワイプ後 350ms 固定遅延 | 小（数行変更） | 5 | 対応済み |
| P0 | enrichment全件ブロック | 中（ロード戦略変更） | 5 | 対応済み |
| P1 | AsyncImageキャッシュなし | 小（TrimmedAsyncImage適用） | 4 | 対応済み |
| P1 | onChange連鎖 | 小（統合 or debounce） | 3 | 対応済み |
| P2 | 詳細画面の逐次ロード | 小（async let） | 3 | 対応済み |
| P2 | DTO二重シリアライズ | 中（型変更 or detached） | 2 | 未対応 |
