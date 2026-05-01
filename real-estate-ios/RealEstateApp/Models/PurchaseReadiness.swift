import Foundation

enum PreApprovalStatus: String, Codable, CaseIterable {
    case notStarted = "未着手"
    case applied = "申請中"
    case approved = "承認済"
    case expired = "期限切れ"

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .notStarted: return "circle"
        case .applied: return "clock"
        case .approved: return "checkmark.circle.fill"
        case .expired: return "exclamationmark.triangle"
        }
    }
}

struct RequiredDocument: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isCompleted: Bool

    static var defaultList: [RequiredDocument] {
        [
            RequiredDocument(id: UUID(), name: "本人確認書類（運転免許証等）", isCompleted: false),
            RequiredDocument(id: UUID(), name: "住民票", isCompleted: false),
            RequiredDocument(id: UUID(), name: "印鑑証明書", isCompleted: false),
            RequiredDocument(id: UUID(), name: "収入証明（源泉徴収票）", isCompleted: false),
            RequiredDocument(id: UUID(), name: "課税証明書", isCompleted: false),
            RequiredDocument(id: UUID(), name: "実印", isCompleted: false),
            RequiredDocument(id: UUID(), name: "銀行口座情報", isCompleted: false),
        ]
    }
}

struct PurchaseReadiness: Codable, Equatable {
    var preApprovalStatus: PreApprovalStatus = .notStarted
    var preApprovalAmount: Int? = nil    // 万円
    var preApprovalBank: String? = nil
    var preApprovalExpiry: Date? = nil
    var requiredDocs: [RequiredDocument] = RequiredDocument.defaultList

    var completedDocCount: Int {
        requiredDocs.filter(\.isCompleted).count
    }

    var isReady: Bool {
        preApprovalStatus == .approved && completedDocCount == requiredDocs.count
    }

    var readinessPercentage: Double {
        let docProgress = requiredDocs.isEmpty ? 0 : Double(completedDocCount) / Double(requiredDocs.count)
        let approvalProgress: Double = preApprovalStatus == .approved ? 1.0 : 0.0
        return (docProgress + approvalProgress) / 2.0
    }
}
