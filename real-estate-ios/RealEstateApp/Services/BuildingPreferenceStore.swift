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

    func isNoped(_ identityKey: String) -> Bool {
        nopedKeys.contains(identityKey)
    }

    func isLiked(_ identityKey: String) -> Bool {
        likedKeys.contains(identityKey)
    }

    enum Preference: String {
        case nope
        case like
    }
}
