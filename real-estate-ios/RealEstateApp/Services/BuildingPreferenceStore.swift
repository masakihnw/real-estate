import Foundation
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "BuildingPreference")

@MainActor @Observable
final class BuildingPreferenceStore {
    static let shared = BuildingPreferenceStore()

    private(set) var nopedKeys: Set<String> = []
    private(set) var likedKeys: Set<String> = []
    private let client = SupabaseClient.shared

    private init() {}

    func fetch() async {
        do {
            let (data, _) = try await client.select(
                from: "user_building_preferences",
                columns: "identity_key,preference"
            )
            let rows = try JSONDecoder().decode([[String: String]].self, from: data)
            var noped = Set<String>()
            var liked = Set<String>()
            for row in rows {
                guard let key = row["identity_key"], let pref = row["preference"] else { continue }
                switch pref {
                case "nope": noped.insert(key)
                case "like": liked.insert(key)
                default: break
                }
            }
            nopedKeys = noped
            likedKeys = liked
            logger.info("Preferences loaded: nope=\(noped.count) like=\(liked.count)")
        } catch {
            logger.error("Preferences fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setPreference(_ identityKey: String, preference: Preference) async {
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
            switch preference {
            case .nope:
                nopedKeys.remove(identityKey)
            case .like:
                likedKeys.remove(identityKey)
            }
            logger.error("Failed to set preference: \(error.localizedDescription, privacy: .public)")
        }
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
        return failedCount
    }

    func isNoped(_ identityKey: String) -> Bool {
        nopedKeys.contains(identityKey)
    }

    func isLiked(_ identityKey: String) -> Bool {
        likedKeys.contains(identityKey)
    }

    /// like/nope済み建物の名前セット（identityKeyの先頭要素）。
    /// 同一マンション別住戸やstaleキー（レイアウト変更等）でも建物名で除外可能。
    var reviewedBuildingNames: Set<String> {
        Set(
            likedKeys.union(nopedKeys).map { key in
                String(key.prefix(while: { $0 != "|" }))
            }
        )
    }

    func isBuildingReviewed(_ listing: Listing) -> Bool {
        let name = String(listing.identityKey.prefix(while: { $0 != "|" }))
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

    func removeLocalOnly(_ identityKey: String) {
        likedKeys.remove(identityKey)
        nopedKeys.remove(identityKey)
    }
    #endif
}
