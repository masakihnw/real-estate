import SwiftUI

/// 複数物件のレーダーチャート重ね描き（ポートフォリオ比較）。
///
/// 比較中の物件の住まいサーフィン6軸偏差値を1枚のチャートに重ね、
/// 候補間の強み・弱みのバランスを一目で比較できるようにする。
/// 単一物件版は RadarChartView（詳細画面用）。
struct MultiRadarChartView: View {
    struct Entry: Identifiable {
        let id: String      // listing.url
        let name: String
        let data: Listing.RadarData
        let color: Color
    }

    let entries: [Entry]

    /// 重ね描きで判別可能な色パレット（最大4件）
    static let palette: [Color] = [.blue, .orange, .green, .purple]

    /// 比較対象の Listing 配列から radar データを持つものだけ Entry 化する
    static func entries(from listings: [Listing]) -> [Entry] {
        listings
            .compactMap { listing -> (Listing, Listing.RadarData)? in
                guard let radar = listing.parsedRadarData else { return nil }
                return (listing, radar)
            }
            .prefix(palette.count)
            .enumerated()
            .map { idx, pair in
                Entry(
                    id: pair.0.url,
                    name: pair.0.nameWithFloor,
                    data: pair.1,
                    color: palette[idx]
                )
            }
    }

    private let minVal: Double = 20
    private let maxVal: Double = 80
    private let gridLevels = 3

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: size / 2)
                let radius = size * 0.38

                ZStack {
                    ForEach(1...gridLevels, id: \.self) { level in
                        let fraction = Double(level) / Double(gridLevels)
                        hexagonPath(center: center, radius: radius * fraction)
                            .stroke(Color.gray.opacity(level == gridLevels ? 0.3 : 0.15),
                                    lineWidth: level == gridLevels ? 0.8 : 0.5)
                    }

                    // 行政区平均（偏差値50）
                    let avgFraction = normalize(50)
                    polygonPath(values: Array(repeating: avgFraction, count: 6), center: center, radius: radius)
                        .stroke(Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    // 各物件
                    ForEach(entries) { entry in
                        let normalized = entry.data.values.map { normalize($0) }
                        polygonPath(values: normalized, center: center, radius: radius)
                            .fill(entry.color.opacity(0.08))
                        polygonPath(values: normalized, center: center, radius: radius)
                            .stroke(entry.color.opacity(0.8), lineWidth: 1.5)
                    }

                    ForEach(0..<6, id: \.self) { i in
                        let labelOffset = radius + size * 0.13
                        let pos = point(for: i, value: 1.0, center: center, radius: labelOffset)
                        Text(Listing.RadarData.labels[i])
                            .font(.system(size: 9))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.gray)
                            .position(pos)
                    }
                }
            }
            .aspectRatio(1.15, contentMode: .fit)

            // 凡例
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(entry.color.opacity(0.8))
                            .frame(width: 14, height: 3)
                        Text(entry.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 14, height: 1)
                    Text("行政区平均（偏差値50）")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 描画ヘルパー（RadarChartView と同じ座標系）

    private func normalize(_ value: Double) -> Double {
        min(max((value - minVal) / (maxVal - minVal), 0), 1)
    }

    private func point(for index: Int, value: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (Double(index) / 6.0) * 2 * .pi - .pi / 2
        return CGPoint(
            x: center.x + radius * CGFloat(value) * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(value) * CGFloat(sin(angle))
        )
    }

    private func hexagonPath(center: CGPoint, radius: CGFloat) -> Path {
        polygonPath(values: Array(repeating: 1.0, count: 6), center: center, radius: radius)
    }

    private func polygonPath(values: [Double], center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for (i, value) in values.enumerated() {
            let pt = point(for: i, value: value, center: center, radius: radius)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}
