import Foundation

struct PreferenceProfile {
    let summaryLines: [String]
    let recommendations: [RecommendedListing]
    let isActive: Bool

    var claudeSummaryLines: [String]?
    var claudeSummaryState: ClaudeSummaryState = .idle

    enum ClaudeSummaryState: Equatable {
        case idle, loading, loaded, failed
    }

    var displaySummaryLines: [String] {
        claudeSummaryLines ?? summaryLines
    }

    var isClaudeSummaryActive: Bool {
        claudeSummaryLines != nil
    }

    struct RecommendedListing: Identifiable {
        let listing: Listing
        let score: Double
        var id: String { listing.url }
    }

    static let inactive = PreferenceProfile(summaryLines: [], recommendations: [], isActive: false)
}

enum PreferenceAnalyzer {
    static let requiredLikes = 20
    static let requiredNopes = 20
    private static let recommendationCount = 10
    private static let continuousImportanceThreshold = 0.3
    private static let categoricalImportanceThreshold = 0.1

    static func analyze(
        allListings: [Listing],
        likedKeys: Set<String>,
        nopedKeys: Set<String>
    ) -> PreferenceProfile {
        guard likedKeys.count >= requiredLikes, nopedKeys.count >= requiredNopes else {
            return .inactive
        }

        var likedReps: [String: Listing] = [:]
        var nopedReps: [String: Listing] = [:]
        var candidates: [Listing] = []

        for listing in allListings {
            let key = listing.identityKey
            if likedKeys.contains(key) {
                if likedReps[key] == nil { likedReps[key] = listing }
            } else if nopedKeys.contains(key) {
                if nopedReps[key] == nil { nopedReps[key] = listing }
            } else {
                candidates.append(listing)
            }
        }

        let liked = Array(likedReps.values)
        let noped = Array(nopedReps.values)
        guard liked.count >= 5, noped.count >= 5 else { return .inactive }

        let features = analyzeFeatures(liked: liked, noped: noped)
        let summaryLines = generateSummary(features: features)
        let scored = scoreCandidates(candidates, features: features)

        return PreferenceProfile(
            summaryLines: summaryLines,
            recommendations: scored,
            isActive: true
        )
    }

    // MARK: - Feature Types

    private struct ContinuousFeature {
        let name: String
        let label: String
        let likedMean: Double
        let nopedMean: Double
        let likedStd: Double
        let importance: Double
        let formatter: (Double) -> String
    }

    private struct CategoricalFeature {
        let name: String
        let label: String
        let likedDist: [String: Double]
        let nopedDist: [String: Double]
        let importance: Double
    }

    private struct FeatureSet {
        let continuous: [ContinuousFeature]
        let categorical: [CategoricalFeature]
    }

    // MARK: - Analysis

    private static func analyzeFeatures(liked: [Listing], noped: [Listing]) -> FeatureSet {
        let currentYear = Calendar.current.component(.year, from: Date())

        let continuousDefs: [(String, String, (Listing) -> Double?, (Double) -> String)] = [
            ("price", "価格帯", { $0.priceMan.map(Double.init) }, formatPrice),
            ("area", "広さ", { $0.areaM2 }, { String(format: "%.0f㎡", $0) }),
            ("walk", "駅徒歩", { $0.walkMin.map(Double.init) }, { String(format: "%.0f分", $0) }),
            ("age", "築年数", { $0.builtYear.map { Double(currentYear - $0) } }, { String(format: "築%.0f年", $0) }),
            ("floor", "階数", { $0.floorPosition.map(Double.init) }, { String(format: "%.0f階", $0) }),
            ("units", "総戸数", { $0.totalUnits.map(Double.init) }, { String(format: "%.0f戸", $0) }),
        ]

        var continuous: [ContinuousFeature] = []
        for (name, label, extractor, formatter) in continuousDefs {
            let lVals = liked.compactMap(extractor)
            let nVals = noped.compactMap(extractor)
            guard lVals.count >= 5, nVals.count >= 5 else { continue }

            let lMean = mean(lVals)
            let nMean = mean(nVals)
            let lStd = stddev(lVals, mean: lMean)
            let nStd = stddev(nVals, mean: nMean)
            let pooled = sqrt((lStd * lStd + nStd * nStd) / 2)
            let importance = pooled > 0 ? abs(lMean - nMean) / pooled : 0

            continuous.append(ContinuousFeature(
                name: name, label: label,
                likedMean: lMean, nopedMean: nMean,
                likedStd: lStd, importance: importance,
                formatter: formatter
            ))
        }

        let categoricalDefs: [(String, String, (Listing) -> String?)] = [
            ("layout", "間取り", { $0.layout }),
            ("ward", "エリア", { extractWard($0.address) }),
            ("direction", "向き", { $0.direction }),
        ]

        var categorical: [CategoricalFeature] = []
        for (name, label, extractor) in categoricalDefs {
            let lVals = liked.compactMap(extractor)
            let nVals = noped.compactMap(extractor)
            guard lVals.count >= 5, nVals.count >= 5 else { continue }

            let lDist = distribution(lVals)
            let nDist = distribution(nVals)
            let importance = jsDivergence(lDist, nDist)

            categorical.append(CategoricalFeature(
                name: name, label: label,
                likedDist: lDist, nopedDist: nDist,
                importance: importance
            ))
        }

        return FeatureSet(
            continuous: continuous.sorted { $0.importance > $1.importance },
            categorical: categorical.sorted { $0.importance > $1.importance }
        )
    }

    // MARK: - Summary

    private static func generateSummary(features: FeatureSet) -> [String] {
        var lines: [String] = []

        for f in features.continuous where f.importance > continuousImportanceThreshold {
            let line: String
            switch f.name {
            case "price":
                let low = Int(max(0, f.likedMean - f.likedStd) / 100) * 100
                let high = Int((f.likedMean + f.likedStd) / 100) * 100
                line = "\(f.label): 平均\(f.formatter(f.likedMean))（\(low)〜\(high)万円）"
            case "walk":
                let maxW = Int(f.likedMean + f.likedStd)
                line = "\(f.label): 平均\(f.formatter(f.likedMean))（\(maxW)分以内が中心）"
            case "age":
                let maxAge = Int(f.likedMean + f.likedStd)
                line = "\(f.label): 平均\(f.formatter(f.likedMean))（築\(maxAge)年以内）"
            default:
                line = "\(f.label): 平均\(f.formatter(f.likedMean))"
            }
            lines.append(line)
        }

        for f in features.categorical where f.importance > categoricalImportanceThreshold {
            let top = f.likedDist.sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key)(\(Int($0.value * 100))%)" }
                .joined(separator: "・")
            lines.append("\(f.label): \(top)")
        }

        return lines
    }

    // MARK: - Claude Prompt

    static func buildClaudePrompt(
        allListings: [Listing],
        likedKeys: Set<String>,
        nopedKeys: Set<String>
    ) -> (system: String, user: String)? {
        guard likedKeys.count >= requiredLikes, nopedKeys.count >= requiredNopes else {
            return nil
        }

        var likedReps: [String: Listing] = [:]
        var nopedReps: [String: Listing] = [:]
        for listing in allListings {
            let key = listing.identityKey
            if likedKeys.contains(key) {
                if likedReps[key] == nil { likedReps[key] = listing }
            } else if nopedKeys.contains(key) {
                if nopedReps[key] == nil { nopedReps[key] = listing }
            }
        }

        let liked = Array(likedReps.values)
        let noped = Array(nopedReps.values)
        guard liked.count >= 5, noped.count >= 5 else { return nil }

        let features = analyzeFeatures(liked: liked, noped: noped)
        let ruleBased = generateSummary(features: features)

        let system = """
            あなたは不動産購入のアドバイザーです。\
            ユーザーがマンション物件を「いいね」「パス」に分類した結果から、\
            購入希望の傾向を自然な日本語で要約してください。

            出力ルール:
            - 3〜5行の箇条書き（各行「・」で始める）
            - 統計データと具体的な物件例を組み合わせて、読みやすく解説する
            - 数値は日本の不動産慣習に従う（万円、㎡、徒歩○分、築○年）
            - ユーザーの好みの特徴だけでなく、避けている傾向にも言及する
            - 最後に1行、全体的な好みの傾向を一文でまとめる
            - 丁寧すぎない自然な文体（です・ます調）
            """

        var parts: [String] = []

        parts.append("## ルールベース分析結果")
        parts.append(ruleBased.joined(separator: "\n"))

        parts.append("\n## 統計的特徴量")
        for f in features.continuous where f.importance > continuousImportanceThreshold {
            parts.append(
                "- \(f.label): いいね平均=\(f.formatter(f.likedMean)), " +
                "パス平均=\(f.formatter(f.nopedMean)), " +
                "重要度=\(String(format: "%.2f", f.importance))"
            )
        }
        for f in features.categorical where f.importance > categoricalImportanceThreshold {
            let likedTop = f.likedDist.sorted { $0.value > $1.value }
                .prefix(3).map { "\($0.key)(\(Int($0.value * 100))%)" }.joined(separator: ", ")
            let nopedTop = f.nopedDist.sorted { $0.value > $1.value }
                .prefix(3).map { "\($0.key)(\(Int($0.value * 100))%)" }.joined(separator: ", ")
            parts.append(
                "- \(f.label): いいね=[\(likedTop)], パス=[\(nopedTop)], " +
                "重要度=\(String(format: "%.3f", f.importance))"
            )
        }

        parts.append("\n## いいね物件サンプル（\(liked.count)件中\(min(5, liked.count))件）")
        for listing in liked.prefix(5) {
            parts.append(formatListingSample(listing))
        }

        parts.append("\n## パス物件サンプル（\(noped.count)件中\(min(5, noped.count))件）")
        for listing in noped.prefix(5) {
            parts.append(formatListingSample(listing))
        }

        parts.append("\n上記のデータに基づいて、このユーザーの物件の好みを自然な日本語で要約してください。")

        return (system: system, user: parts.joined(separator: "\n"))
    }

    private static func formatListingSample(_ listing: Listing) -> String {
        var fields: [String] = [listing.name]
        if let price = listing.priceMan { fields.append(formatPrice(Double(price))) }
        if let area = listing.areaM2 { fields.append(String(format: "%.1f㎡", area)) }
        if let layout = listing.layout { fields.append(layout) }
        if let walk = listing.walkMin { fields.append("徒歩\(walk)分") }
        fields.append(listing.builtAgeDisplay)
        if let addr = listing.bestAddress { fields.append(addr) }
        if let dir = listing.direction { fields.append(dir) }
        return "- " + fields.joined(separator: " / ")
    }

    // MARK: - Scoring

    private static func scoreCandidates(
        _ candidates: [Listing],
        features: FeatureSet
    ) -> [PreferenceProfile.RecommendedListing] {
        let currentYear = Calendar.current.component(.year, from: Date())
        let extractors: [String: (Listing) -> Double?] = [
            "price": { $0.priceMan.map(Double.init) },
            "area": { $0.areaM2 },
            "walk": { $0.walkMin.map(Double.init) },
            "age": { $0.builtYear.map { Double(currentYear - $0) } },
            "floor": { $0.floorPosition.map(Double.init) },
            "units": { $0.totalUnits.map(Double.init) },
        ]
        let catExtractors: [String: (Listing) -> String?] = [
            "layout": { $0.layout },
            "ward": { extractWard($0.address) },
            "direction": { $0.direction },
        ]

        var scored: [(Listing, Double)] = []
        for listing in candidates {
            var score = 0.0
            var weight = 0.0

            for f in features.continuous {
                guard let ext = extractors[f.name], let val = ext(listing), f.likedStd > 0 else { continue }
                let z = abs(val - f.likedMean) / f.likedStd
                score += f.importance * exp(-0.5 * z * z)
                weight += f.importance
            }

            for f in features.categorical {
                guard let ext = catExtractors[f.name], let val = ext(listing) else { continue }
                let lFreq = f.likedDist[val] ?? 0
                let nFreq = f.nopedDist[val] ?? 0
                score += f.importance * (lFreq - nFreq + 1) / 2
                weight += f.importance
            }

            let normalized = weight > 0 ? score / weight : 0
            scored.append((listing, normalized))
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(recommendationCount)
            .map { PreferenceProfile.RecommendedListing(listing: $0.0, score: $0.1) }
    }

    // MARK: - Helpers

    private static func mean(_ vals: [Double]) -> Double {
        vals.reduce(0, +) / Double(vals.count)
    }

    private static func stddev(_ vals: [Double], mean m: Double) -> Double {
        guard vals.count > 1 else { return 0 }
        let ss = vals.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return sqrt(ss / Double(vals.count - 1))
    }

    private static func distribution(_ vals: [String]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for v in vals { counts[v, default: 0] += 1 }
        let total = Double(vals.count)
        return counts.mapValues { Double($0) / total }
    }

    private static func jsDivergence(_ p: [String: Double], _ q: [String: Double]) -> Double {
        let keys = Set(p.keys).union(q.keys)
        var div = 0.0
        for k in keys {
            let pv = max(p[k] ?? 0, 0.001)
            let qv = max(q[k] ?? 0, 0.001)
            let m = (pv + qv) / 2
            div += pv * log(pv / m) + qv * log(qv / m)
        }
        return div / 2
    }

    private static func extractWard(_ address: String?) -> String? {
        guard let addr = address,
              let range = addr.range(of: #"(?<=[都道府県市])[^\s都道府県市]+?区"#, options: .regularExpression) else {
            return nil
        }
        return String(addr[range])
    }

    private static func formatPrice(_ val: Double) -> String {
        let man = Int(val)
        if man >= 10000 {
            let oku = man / 10000
            let remainder = (man % 10000) / 1000 * 1000
            return remainder > 0 ? "\(oku)億\(remainder)万円" : "\(oku)億円"
        }
        return "\(man)万円"
    }
}
