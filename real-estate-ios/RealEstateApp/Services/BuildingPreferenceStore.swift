import Foundation
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "BuildingPreference")

@MainActor @Observable
final class BuildingPreferenceStore {
    static let shared = BuildingPreferenceStore()

    private(set) var nopedBuildings: Set<String> = []
    private(set) var likedBuildings: Set<String> = []
    private let client = SupabaseClient.shared

    private init() {}

    func fetch() async {
        do {
            let (data, _) = try await client.select(
                from: "user_building_preferences",
                columns: "normalized_name,preference"
            )
            let rows = try JSONDecoder().decode([[String: String]].self, from: data)
            var noped = Set<String>()
            var liked = Set<String>()
            for row in rows {
                guard let name = row["normalized_name"], let pref = row["preference"] else { continue }
                switch pref {
                case "nope": noped.insert(name)
                case "like": liked.insert(name)
                default: break
                }
            }
            nopedBuildings = noped
            likedBuildings = liked
            logger.info("Building preferences loaded: nope=\(noped.count) like=\(liked.count)")
        } catch {
            logger.error("Building preferences fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setPreference(_ normalizedName: String, preference: Preference) async {
        switch preference {
        case .nope:
            nopedBuildings.insert(normalizedName)
            likedBuildings.remove(normalizedName)
        case .like:
            likedBuildings.insert(normalizedName)
            nopedBuildings.remove(normalizedName)
        }

        do {
            let body: [[String: Any]] = [["normalized_name": normalizedName, "preference": preference.rawValue]]
            _ = try await client.upsert(into: "user_building_preferences", body: body, onConflict: "normalized_name")
            logger.info("Set \(preference.rawValue, privacy: .public) for \(normalizedName, privacy: .public)")
        } catch {
            switch preference {
            case .nope:
                nopedBuildings.remove(normalizedName)
            case .like:
                likedBuildings.remove(normalizedName)
            }
            logger.error("Failed to set preference: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removePreference(_ normalizedName: String) async {
        let wasNoped = nopedBuildings.remove(normalizedName) != nil
        let wasLiked = likedBuildings.remove(normalizedName) != nil

        do {
            try await client.delete(
                from: "user_building_preferences",
                filters: [("normalized_name", "eq.\(normalizedName)")]
            )
            logger.info("Removed preference for \(normalizedName, privacy: .public)")
        } catch {
            if wasNoped { nopedBuildings.insert(normalizedName) }
            if wasLiked { likedBuildings.insert(normalizedName) }
            logger.error("Failed to remove preference: \(error.localizedDescription, privacy: .public)")
        }
    }

    func isNoped(_ normalizedName: String?) -> Bool {
        guard let name = normalizedName else { return false }
        return nopedBuildings.contains(name)
    }

    func isLiked(_ normalizedName: String?) -> Bool {
        guard let name = normalizedName else { return false }
        return likedBuildings.contains(name)
    }

    enum Preference: String {
        case nope
        case like
    }
}
