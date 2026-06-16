import Foundation
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "BuildingPreference")

@MainActor @Observable
final class BuildingPreferenceStore {
    static let shared = BuildingPreferenceStore()

    private(set) var nopedKeys: Set<String> = []
    private(set) var likedKeys: Set<String> = []
    private let client = SupabaseClient.shared

    // 既読(like/nope)のローカルキャッシュ。サーバー fetch は非同期のため、
    // これが無いと起動直後は既読が未ロードで「今日」タブの絞り込み・未評価件数がズレ、
    // fetch 完了後に正しくなるチラつきが出る。ローカルに保存して起動時に同期ロードする。
    private let defaults: UserDefaults
    private static let nopedDefaultsKey = "BuildingPreference.nopedKeys"
    private static let likedDefaultsKey = "BuildingPreference.likedKeys"

    /// 本番は `shared`（UserDefaults.standard）。テストは独立した suite を注入する。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nopedKeys = Set(defaults.stringArray(forKey: Self.nopedDefaultsKey) ?? [])
        likedKeys = Set(defaults.stringArray(forKey: Self.likedDefaultsKey) ?? [])
    }

    /// 現在の like/nope をローカルに保存する（変更・fetch のたびに呼ぶ）。
    private func persistLocal() {
        defaults.set(Array(nopedKeys), forKey: Self.nopedDefaultsKey)
        defaults.set(Array(likedKeys), forKey: Self.likedDefaultsKey)
    }

    func fetch() async {
        // PostgREST はデフォルトで最大1000行しか返さないため、range で全件をページ取得する。
        // 単発 select だと like/nope の合計が1000件を超えた時点で末尾（最近の判定）が欠落し、
        // 「nope済みが再表示される」「未評価件数が0にならない」不具合になる。
        let pageSize = 1000
        var noped = Set<String>()
        var liked = Set<String>()
        var offset = 0
        do {
            while true {
                let (data, _) = try await client.select(
                    from: "user_building_preferences",
                    columns: "identity_key,preference",
                    range: offset...(offset + pageSize - 1)
                )
                let rows = try JSONDecoder().decode([[String: String]].self, from: data)
                for row in rows {
                    guard let key = row["identity_key"], let pref = row["preference"] else { continue }
                    switch pref {
                    case "nope": noped.insert(key)
                    case "like": liked.insert(key)
                    default: break
                    }
                }
                if rows.count < pageSize { break }
                offset += pageSize
            }
            nopedKeys = noped
            likedKeys = liked
            logger.info("Preferences loaded: nope=\(noped.count) like=\(liked.count)")
            persistLocal()
        } catch {
            logger.error("Preferences fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setPreference(_ identityKey: String, preference: Preference) async {
        // 失敗時に正確に巻き戻すため、変更前の所属を記録する
        // （like→nope の変更失敗で元の like が消える不整合を防ぐ。ローカルキャッシュにも永続化されるため重要）。
        let wasLiked = likedKeys.contains(identityKey)
        let wasNoped = nopedKeys.contains(identityKey)

        switch preference {
        case .nope:
            nopedKeys.insert(identityKey)
            likedKeys.remove(identityKey)
        case .like:
            likedKeys.insert(identityKey)
            nopedKeys.remove(identityKey)
        }

        do {
            let body: [[String: Any]] = [["identity_key": identityKey, "preference": preference.rawValue]]
            _ = try await client.upsert(into: "user_building_preferences", body: body, onConflict: "identity_key")
            logger.info("Set \(preference.rawValue, privacy: .public) for \(identityKey, privacy: .public)")
        } catch {
            // 変更前の状態へ正確に復元する
            if wasLiked { likedKeys.insert(identityKey) } else { likedKeys.remove(identityKey) }
            if wasNoped { nopedKeys.insert(identityKey) } else { nopedKeys.remove(identityKey) }
            logger.error("Failed to set preference: \(error.localizedDescription, privacy: .public)")
        }
        persistLocal()
    }

    func removePreference(_ identityKey: String) async {
        let wasNoped = nopedKeys.remove(identityKey) != nil
        let wasLiked = likedKeys.remove(identityKey) != nil

        do {
            try await client.delete(
                from: "user_building_preferences",
                filters: [("identity_key", "eq.\(identityKey)")]
            )
            logger.info("Removed preference for \(identityKey, privacy: .public)")
        } catch {
            if wasNoped { nopedKeys.insert(identityKey) }
            if wasLiked { likedKeys.insert(identityKey) }
            logger.error("Failed to remove preference: \(error.localizedDescription, privacy: .public)")
        }
        persistLocal()
    }

    /// 複数キーの一括解除（Nope一括解除用）。
    /// チャンクごとに1リクエストで削除し、失敗したチャンクはローカル状態を巻き戻す。
    /// - Returns: 削除に失敗したキー数（0 なら全件成功）
    @discardableResult
    func removePreferences(_ identityKeys: [String]) async -> Int {
        let chunkSize = 50
        var failedCount = 0
        for chunkStart in stride(from: 0, to: identityKeys.count, by: chunkSize) {
            let chunk = Array(identityKeys[chunkStart..<min(chunkStart + chunkSize, identityKeys.count)])
            let removedNoped = chunk.filter { nopedKeys.remove($0) != nil }
            let removedLiked = chunk.filter { likedKeys.remove($0) != nil }

            do {
                // PostgREST in 句。建物名にカンマが含まれ得るため各値をダブルクオートし、
                // 値中の \ と " は PostgREST 仕様に従いバックスラッシュでエスケープする
                let quoted = chunk
                    .map { key in
                        let escaped = key
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                        return "\"\(escaped)\""
                    }
                    .joined(separator: ",")
                try await client.delete(
                    from: "user_building_preferences",
                    filters: [("identity_key", "in.(\(quoted))")]
                )
                logger.info("Bulk removed \(chunk.count) preferences")
            } catch {
                removedNoped.forEach { nopedKeys.insert($0) }
                removedLiked.forEach { likedKeys.insert($0) }
                failedCount += chunk.count
                logger.error("Bulk remove failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        persistLocal()
        return failedCount
    }

    func isNoped(_ identityKey: String) -> Bool {
        nopedKeys.contains(identityKey)
    }

    func isLiked(_ identityKey: String) -> Bool {
        likedKeys.contains(identityKey)
    }

    /// like/nope済み建物の名前セット（preferenceKeyの先頭要素）。
    /// 同一マンション別住戸やstaleキー（レイアウト変更等）でも建物名で除外可能。
    var reviewedBuildingNames: Set<String> {
        Set(
            likedKeys.union(nopedKeys).map { key in
                String(key.prefix(while: { $0 != "|" }))
            }
        )
    }

    func isBuildingReviewed(_ listing: Listing) -> Bool {
        let name = String(listing.preferenceKey.prefix(while: { $0 != "|" }))
        return reviewedBuildingNames.contains(name)
    }

    enum Preference: String {
        case nope
        case like
    }

    // MARK: - Test Helpers

    #if DEBUG
    func setLocalOnly(_ identityKey: String, preference: Preference) {
        switch preference {
        case .nope:
            nopedKeys.insert(identityKey)
            likedKeys.remove(identityKey)
        case .like:
            likedKeys.insert(identityKey)
            nopedKeys.remove(identityKey)
        }
    }

    /// 現在の in-memory 状態を注入 defaults に保存する（ローカルキャッシュの round-trip テスト用）。
    func saveLocalForTesting() {
        persistLocal()
    }

    func removeLocalOnly(_ identityKey: String) {
        likedKeys.remove(identityKey)
        nopedKeys.remove(identityKey)
    }
    #endif
}
