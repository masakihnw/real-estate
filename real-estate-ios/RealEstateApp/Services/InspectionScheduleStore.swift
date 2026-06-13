import Foundation

/// 「内見予定」フラグの永続化（提案 §5.6）。
///
/// like/nope（BuildingPreferenceStore の排他 preference）とは独立させる。
/// いいね済みの物件も内見予定にできる必要があるため。identityKey 単位で
/// UserDefaults に保持し、SwiftData スキーマは変更しない。
@MainActor @Observable
final class InspectionScheduleStore {
    static let shared = InspectionScheduleStore()

    private let defaults: UserDefaults
    private let storageKey = "inspection.scheduledKeys"

    private(set) var scheduledKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scheduledKeys = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func isScheduled(_ listing: Listing) -> Bool {
        scheduledKeys.contains(listing.identityKey)
    }

    func isScheduled(key: String) -> Bool {
        scheduledKeys.contains(key)
    }

    func setScheduled(_ scheduled: Bool, for listing: Listing) {
        let key = listing.identityKey
        if scheduled {
            guard !scheduledKeys.contains(key) else { return }
            scheduledKeys.insert(key)
        } else {
            guard scheduledKeys.contains(key) else { return }
            scheduledKeys.remove(key)
        }
        persist()
    }

    func toggle(_ listing: Listing) {
        setScheduled(!isScheduled(listing), for: listing)
    }

    private func persist() {
        defaults.set(Array(scheduledKeys), forKey: storageKey)
    }
}
