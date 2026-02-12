//
//  RadarChartView.swift
//  RealEstateApp
//
//  住まいサーフィン評価のレーダーチャート（6軸、偏差値ベース）。
//  本物件 = 青塗り、行政区平均(偏差値50) = グレー破線。
//

import SwiftUI

/// 6軸レーダーチャート: 本物件の偏差値 vs 行政区平均（偏差値50）
struct RadarChartView: View {
    /// 6軸の偏差値データ（0〜100, 50 = 平均）
    let data: Listing.RadarData

    /// チャート描画の正規化範囲（偏差値 20〜80 を 0〜1 にマッピング）
    private let minVal: Double = 20
    private let maxVal: Double = 80

    /// グリッド段数（外枠含む）
    private let gridLevels = 3

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: size / 2)
                let radius = size * 0.38

                ZStack {
                    // グリッド（六角形）
                    ForEach(1...gridLevels, id: \.self) { level in
                        let fraction = Double(level) / Double(gridLevels)
                        hexagonPath(center: center, radius: radius * fraction)
                            .stroke(Color.gray.opacity(level == gridLevels ? 0.3 : 0.15), lineWidth: level == gridLevels ? 0.8 : 0.5)
                    }

                    // 軸線
                    ForEach(0..<6, id: \.self) { i in
                        Path { path in
                            path.move(to: center)
                            path.addLine(to: point(for: i, value: 1.0, center: center, radius: radius))
                        }
                        .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
                    }

                    // 行政区平均（偏差値50 = グレー破線）
                    let avgFraction = normalize(50)
                    polygonPath(values: Array(repeating: avgFraction, count: 6), center: center, radius: radius)
                        .fill(Color.gray.opacity(0.04))
                    polygonPath(values: Array(repeating: avgFraction, count: 6), center: center, radius: radius)
                        .stroke(Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    // 本物件（アクセントカラー = #007AFF）
                    let listingColor = Color.accentColor
                    let normalized = data.values.map { normalize($0) }
                    polygonPath(values: normalized, center: center, radius: radius)
                        .fill(listingColor.opacity(0.12))
                    polygonPath(values: normalized, center: center, radius: radius)
                        .stroke(listingColor.opacity(0.7), lineWidth: 1.5)

                    // 軸ラベル
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
            .aspectRatio(1.15, contentMode: .fit) // やや横長（ラベル領域を含む）

            // 凡例
            HStack(spacing: 20) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.accentColor.opacity(0.7), lineWidth: 0.8)
                        )
                        .frame(width: 16, height: 8)
                    Text("本物件")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                        )
                        .frame(width: 16, height: 8)
                    Text("行政区平均(偏差値50)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - ヘルパー

    /// 偏差値を 0〜1 に正規化
    private func normalize(_ value: Double) -> Double {
        min(1, max(0, (value - minVal) / (maxVal - minVal)))
    }

    /// 軸 index (0〜5) と正規化値から座標を計算（上が 0）
    private func point(for index: Int, value: Double, center: CGPoint, radius: Double) -> CGPoint {
        let angle = Angle.degrees(Double(index) * 60 - 90).radians
        return CGPoint(
            x: center.x + cos(angle) * radius * value,
            y: center.y + sin(angle) * radius * value
        )
    }

    /// 正六角形のパス
    private func hexagonPath(center: CGPoint, radius: Double) -> Path {
        Path { path in
            for i in 0..<6 {
                let p = point(for: i, value: 1.0, center: center, radius: radius)
                if i == 0 { path.move(to: p) }
                else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }

    /// 6つの値からポリゴンパスを生成
    private func polygonPath(values: [Double], center: CGPoint, radius: Double) -> Path {
        Path { path in
            for (i, val) in values.enumerated() {
                let p = point(for: i, value: val, center: center, radius: radius)
                if i == 0 { path.move(to: p) }
                else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }
}

#Preview {
    VStack {
        RadarChartView(data: Listing.RadarData(
            okiPriceM2: 65,
            buildAge: 52,
            favorites: 58,
            walkMin: 60,
            appreciationRate: 68,
            totalUnits: 55
        ))
        .frame(maxWidth: 260)
    }
    .padding()
}
