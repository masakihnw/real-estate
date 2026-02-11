//
//  MapTabView.swift
//  RealEstateApp
//
//  MapKit で物件ピンを表示。ハザードマップ・地域危険度をオーバーレイ。
//  ピンタップ → ポップアップ（概要 + いいね）→ タップで詳細画面。
//
//  MKTileOverlay を使用するため UIViewRepresentable で MKMapView をラップ。
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

// MARK: - Hazard Layer Definitions

/// 国土地理院ハザードマップ WMS タイルレイヤー + 東京都地域危険度
enum HazardLayer: String, CaseIterable, Identifiable {
    // 基本レイヤー
    case flood = "洪水浸水想定"
    case sediment = "土砂災害警戒"
    case stormSurge = "高潮浸水想定"
    case tsunami = "津波浸水想定"
    case liquefaction = "液状化リスク"
    case seismicRisk = "地盤の揺れやすさ"
    // 追加レイヤー
    case inlandWater = "内水浸水想定"
    case floodDuration = "浸水継続時間"
    case buildingCollapse = "家屋倒壊（氾濫流）"
    case bankErosion = "家屋倒壊（河岸侵食）"

    var id: String { rawValue }

    /// 国土地理院タイル URL テンプレート（{z}/{x}/{y}）
    var tileURLTemplate: String? {
        switch self {
        case .flood:
            return "https://disaportaldata.gsi.go.jp/raster/01_flood_l2_shinsuishin_data/{z}/{x}/{y}.png"
        case .sediment:
            return "https://disaportaldata.gsi.go.jp/raster/05_dosekiryukeikaikuiki/{z}/{x}/{y}.png"
        case .stormSurge:
            return "https://disaportaldata.gsi.go.jp/raster/03_hightide_l2_shinsuishin_data/{z}/{x}/{y}.png"
        case .tsunami:
            return "https://disaportaldata.gsi.go.jp/raster/04_tsunami_newlegend_data/{z}/{x}/{y}.png"
        case .liquefaction:
            return "https://disaportaldata.gsi.go.jp/raster/08_liquid/{z}/{x}/{y}.png"
        case .seismicRisk:
            return "https://disaportaldata.gsi.go.jp/raster/13_jibanshindou/{z}/{x}/{y}.png"
        case .inlandWater:
            return "https://disaportaldata.gsi.go.jp/raster/02_naisui_data/{z}/{x}/{y}.png"
        case .floodDuration:
            return "https://disaportaldata.gsi.go.jp/raster/01_flood_l2_keizoku_data/{z}/{x}/{y}.png"
        case .buildingCollapse:
            return "https://disaportaldata.gsi.go.jp/raster/01_flood_l2_kaokutoukai_hanran_data/{z}/{x}/{y}.png"
        case .bankErosion:
            return "https://disaportaldata.gsi.go.jp/raster/01_flood_l2_kaokutoukai_kagan_data/{z}/{x}/{y}.png"
        }
    }

    var systemImage: String {
        switch self {
        case .flood: return "drop.triangle"
        case .sediment: return "mountain.2"
        case .stormSurge: return "water.waves"
        case .tsunami: return "water.waves.and.arrow.up"
        case .liquefaction: return "waveform.path"
        case .seismicRisk: return "exclamationmark.triangle"
        case .inlandWater: return "cloud.rain"
        case .floodDuration: return "clock.arrow.circlepath"
        case .buildingCollapse: return "house.lodge"
        case .bankErosion: return "arrow.left.arrow.right"
        }
    }

    /// レイヤーの説明文
    var explanation: String {
        switch self {
        case .flood:
            return "河川が氾濫した場合に想定される浸水の深さ。想定最大規模の降雨(1000年に1回程度)に基づく。"
        case .inlandWater:
            return "下水道等の排水能力を超える降雨時に、河川氾濫以外で発生する浸水(いわゆる都市型水害)の想定。"
        case .sediment:
            return "土石流・地すべり・急傾斜地の崩壊が発生するおそれがある区域。特別警戒区域(赤)と警戒区域(黄)を表示。"
        case .stormSurge:
            return "台風等による高潮で想定される浸水の深さ。想定最大規模の高潮に基づく。東京湾岸エリアは広範囲で該当。"
        case .tsunami:
            return "最大クラスの津波が発生した場合に想定される浸水の深さ。"
        case .liquefaction:
            return "地震時に地盤が液状化するリスクの程度。埋立地や河川沿いで高リスク。"
        case .seismicRisk:
            return "地盤の揺れやすさ(表層地盤増幅率)。数値が大きいほど地盤が軟弱で揺れが増幅される。"
        case .floodDuration:
            return "河川氾濫による浸水が継続する時間の想定。長期間の浸水はライフライン途絶等に直結。"
        case .buildingCollapse:
            return "河川氾濫流の力により家屋が倒壊するおそれがある区域。流速と水深の積で判定。"
        case .bankErosion:
            return "洪水時の河岸侵食により家屋が倒壊・流出するおそれがある区域。河川沿いの地盤が削られるリスク。"
        }
    }

    /// 凡例カラー（色と説明のペア）
    var legendItems: [(color: Color, label: String)] {
        switch self {
        case .flood:
            return [
                (Color(red: 0.96, green: 0.96, blue: 0.59), "0.5m未満"),
                (Color(red: 0.65, green: 0.87, blue: 0.82), "0.5〜3m"),
                (Color(red: 0.40, green: 0.73, blue: 0.85), "3〜5m"),
                (Color(red: 0.24, green: 0.44, blue: 0.76), "5〜10m"),
                (Color(red: 0.58, green: 0.24, blue: 0.58), "10〜20m"),
            ]
        case .stormSurge:
            return [
                (Color(red: 0.96, green: 0.96, blue: 0.59), "0.5m未満"),
                (Color(red: 0.65, green: 0.87, blue: 0.82), "0.5〜3m"),
                (Color(red: 0.40, green: 0.73, blue: 0.85), "3〜5m"),
                (Color(red: 0.24, green: 0.44, blue: 0.76), "5〜10m"),
                (Color(red: 0.58, green: 0.24, blue: 0.58), "10m以上"),
            ]
        case .tsunami:
            return [
                (Color(red: 0.96, green: 0.96, blue: 0.59), "0.3m未満"),
                (Color(red: 0.65, green: 0.87, blue: 0.82), "0.3〜1m"),
                (Color(red: 0.40, green: 0.73, blue: 0.85), "1〜2m"),
                (Color(red: 0.24, green: 0.44, blue: 0.76), "2〜5m"),
                (Color(red: 0.58, green: 0.24, blue: 0.58), "5m以上"),
            ]
        case .inlandWater:
            return [
                (Color(red: 0.96, green: 0.96, blue: 0.59), "0.5m未満"),
                (Color(red: 0.40, green: 0.73, blue: 0.85), "0.5〜1m"),
                (Color(red: 0.24, green: 0.44, blue: 0.76), "1〜3m"),
                (Color(red: 0.58, green: 0.24, blue: 0.58), "3m以上"),
            ]
        case .sediment:
            return [
                (Color.yellow.opacity(0.7), "警戒区域(イエローゾーン)"),
                (Color.red.opacity(0.7), "特別警戒区域(レッドゾーン)"),
            ]
        case .liquefaction:
            return [
                (Color(red: 0.55, green: 0.82, blue: 0.55), "液状化の可能性 低"),
                (Color(red: 0.96, green: 0.88, blue: 0.40), "液状化の可能性 中"),
                (Color(red: 0.96, green: 0.55, blue: 0.30), "液状化の可能性 高"),
                (Color(red: 0.90, green: 0.20, blue: 0.20), "液状化の可能性 極高"),
            ]
        case .seismicRisk:
            return [
                (Color(red: 0.55, green: 0.82, blue: 0.55), "増幅率 低い"),
                (Color(red: 0.96, green: 0.88, blue: 0.40), "増幅率 やや大"),
                (Color(red: 0.96, green: 0.55, blue: 0.30), "増幅率 大きい"),
                (Color(red: 0.90, green: 0.20, blue: 0.20), "増幅率 非常に大"),
            ]
        case .floodDuration:
            return [
                (Color(red: 0.96, green: 0.96, blue: 0.59), "12時間未満"),
                (Color(red: 0.65, green: 0.87, blue: 0.82), "1日未満"),
                (Color(red: 0.40, green: 0.73, blue: 0.85), "3日未満"),
                (Color(red: 0.24, green: 0.44, blue: 0.76), "1週間未満"),
                (Color(red: 0.58, green: 0.24, blue: 0.58), "2週間以上"),
            ]
        case .buildingCollapse, .bankErosion:
            return [
                (Color(red: 0.90, green: 0.20, blue: 0.20), "倒壊・流出危険区域"),
            ]
        }
    }

    /// 基本ハザードレイヤー（洪水・内水・土砂・高潮・津波・液状化）
    static var basicLayers: [HazardLayer] {
        [.flood, .inlandWater, .sediment, .stormSurge, .tsunami, .liquefaction]
    }

    /// 洪水詳細レイヤー
    static var floodDetailLayers: [HazardLayer] {
        [.floodDuration, .buildingCollapse, .bankErosion]
    }
}

// MARK: - Tokyo Regional Risk Layer

/// 東京都地域危険度レイヤー（GeoJSON ベース）
enum TokyoRiskLayer: String, CaseIterable, Identifiable {
    case buildingCollapse = "建物倒壊危険度"
    case fire = "火災危険度"
    case combined = "総合危険度"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .buildingCollapse: return "building.2.crop.circle"
        case .fire: return "flame"
        case .combined: return "exclamationmark.shield"
        }
    }

    /// GeoJSON ファイル名
    var filename: String {
        switch self {
        case .buildingCollapse: return "building_collapse_risk.geojson"
        case .fire: return "fire_risk.geojson"
        case .combined: return "combined_risk.geojson"
        }
    }

    /// レイヤーの説明文
    var explanation: String {
        switch self {
        case .buildingCollapse:
            return "地震による建物倒壊の危険性。木造建築密集地域や旧耐震基準の建物が多い地域ほどランクが高い。"
        case .fire:
            return "地震後に発生する火災の延焼危険性。木造密集地域や消防車が進入困難な狭い道路が多い地域ほどランクが高い。"
        case .combined:
            return "建物倒壊危険度と火災危険度を総合的に評価した指標。ランク5が最も危険。"
        }
    }
}

/// ランク (1-5) に対応する色
func riskColor(for rank: Int) -> UIColor {
    switch rank {
    case 1: return UIColor.systemGreen.withAlphaComponent(0.35)
    case 2: return UIColor.systemYellow.withAlphaComponent(0.35)
    case 3: return UIColor.systemOrange.withAlphaComponent(0.40)
    case 4: return UIColor(red: 1.0, green: 0.3, blue: 0.0, alpha: 0.45)
    case 5: return UIColor.systemRed.withAlphaComponent(0.50)
    default: return UIColor.systemGray.withAlphaComponent(0.15)
    }
}

/// GeoJSON の Feature → MKPolygon に変換し rank を保持するサブクラス
final class RankedPolygon: MKPolygon {
    var rank: Int = 0
    var riskLayerID: String = ""
}

/// 東京都地域危険度 GeoJSON のフェッチ・パース
@Observable
final class TokyoRiskService {
    static let shared = TokyoRiskService()

    private(set) var isLoading = false
    /// layerID → [RankedPolygon]
    private var cache: [String: [RankedPolygon]] = [:]

    private let defaults = UserDefaults.standard
    private let baseURLKey = "realestate.tokyoRiskBaseURL"

    /// GeoJSON の基底 URL（デフォルト: GitHub raw）
    static let defaultBaseURL = "https://raw.githubusercontent.com/masakihnw/real-estate/main/scraping-tool/results/risk_geojson/"

    /// GeoJSON の基底 URL（空ならデフォルトを使う）
    var baseURL: String {
        get { defaults.string(forKey: baseURLKey) ?? "" }
        set { defaults.set(newValue, forKey: baseURLKey) }
    }

    /// 実際に使用される基底 URL（カスタムが空ならデフォルト）
    var effectiveBaseURL: String {
        let custom = baseURL.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Self.defaultBaseURL : custom
    }

    func polygons(for layer: TokyoRiskLayer) -> [RankedPolygon] {
        cache[layer.id] ?? []
    }

    func fetchIfNeeded(_ layer: TokyoRiskLayer) async {
        guard cache[layer.id] == nil else { return }
        let base = effectiveBaseURL
        guard !base.isEmpty else { return }

        let urlString = base.hasSuffix("/")
            ? "\(base)\(layer.filename)"
            : "\(base)/\(layer.filename)"
        guard let url = URL(string: urlString) else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            // P7: GeoJSON デコードをバックグラウンドで実行（地図 UI のフリーズ防止）
            let geojson = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
            }.value
            let polygons = geojson.features.compactMap { feature -> RankedPolygon? in
                guard let coords = feature.geometry.polygonCoordinates else { return nil }
                let points = coords.compactMap { pair -> CLLocationCoordinate2D? in
                    guard pair.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
                guard !points.isEmpty else { return nil }
                let polygon = RankedPolygon(coordinates: points, count: points.count)
                polygon.rank = feature.properties.rank
                polygon.riskLayerID = layer.id
                return polygon
            }
            cache[layer.id] = polygons
        } catch {
            print("[TokyoRisk] Fetch failed for \(layer.filename): \(error)")
        }
    }

    func clearCache() {
        cache.removeAll()
    }
}

// MARK: - GeoJSON Decoding (Minimal)

private struct GeoJSONFeatureCollection: Codable {
    let type: String
    let features: [GeoJSONFeature]
}

private struct GeoJSONFeature: Codable {
    let type: String
    let properties: GeoJSONProperties
    let geometry: GeoJSONGeometry
}

private struct GeoJSONProperties: Codable {
    let rank: Int
    let label: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case rank, label, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rank = (try? c.decode(Int.self, forKey: .rank)) ?? 0
        label = try? c.decode(String.self, forKey: .label)
        name = try? c.decode(String.self, forKey: .name)
    }
}

private struct GeoJSONGeometry: Codable {
    let type: String
    let coordinates: AnyCodable

    /// Polygon / MultiPolygon の外周座標を返す
    var polygonCoordinates: [[Double]]? {
        switch type {
        case "Polygon":
            // coordinates: [[[lon,lat], ...]]
            if let rings = coordinates.value as? [[[Double]]], let outer = rings.first {
                return outer
            }
        case "MultiPolygon":
            // coordinates: [[[[lon,lat], ...]]]
            if let polys = coordinates.value as? [[[[Double]]]], let first = polys.first, let outer = first.first {
                return outer
            }
        default:
            break
        }
        return nil
    }
}

/// JSON の任意型をデコードするラッパー
private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        // 読み込み専用なので encode は最小実装
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

// MARK: - Geocoding Service

@Observable
final class GeocodingService {
    static let shared = GeocodingService()
    private var isGeocoding = false

    /// 並列バッチジオコーディング（未ジオコーディングの物件をまとめて処理）
    /// Apple Geocoder のレート制限を考慮し、最大2並列で実行する。
    /// - Returns: ジオコーディングに失敗した件数
    func geocodeBatch(_ listings: [Listing], modelContext: ModelContext) async -> Int {
        let toGeocode = listings.filter { !$0.hasCoordinate && $0.address != nil && !($0.address ?? "").isEmpty }
        guard !toGeocode.isEmpty else { return 0 }

        // 最大2並列（Apple Geocoder のレート制限対策）
        let maxConcurrency = 2
        let failureCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            var index = 0
            for listing in toGeocode {
                if index >= maxConcurrency {
                    await group.next()
                }
                index += 1
                group.addTask { @Sendable in
                    guard let address = listing.address else { return false }
                    let geocoder = CLGeocoder()
                    do {
                        let placemarks = try await geocoder.geocodeAddressString(address)
                        if let loc = placemarks.first?.location {
                            await MainActor.run {
                                listing.latitude = loc.coordinate.latitude
                                listing.longitude = loc.coordinate.longitude
                            }
                        }
                        // Apple Geocoder rate limit: ~1 req/sec per geocoder instance
                        try await Task.sleep(for: .milliseconds(300))
                        return false
                    } catch {
                        return true // failure
                    }
                }
            }
            var count = 0
            for await failed in group where failed { count += 1 }
            return count
        }
        await MainActor.run {
            SaveErrorHandler.shared.save(modelContext, source: "Geocoding")
        }
        return failureCount
    }
}

// MARK: - Listing Annotation (for MKMapView)

/// MKAnnotation wrapper for Listing
final class ListingAnnotation: NSObject, MKAnnotation {
    let listing: Listing
    let coordinate: CLLocationCoordinate2D

    init(listing: Listing) {
        self.listing = listing
        self.coordinate = CLLocationCoordinate2D(
            latitude: listing.latitude ?? 0,
            longitude: listing.longitude ?? 0
        )
        super.init()
    }

    var title: String? { listing.name }
    var subtitle: String? { listing.priceDisplay }
}

// MARK: - MKMapView UIViewRepresentable

/// UIViewRepresentable wrapper to support MKTileOverlay + MKPolygon for hazard maps
struct HazardMapView: UIViewRepresentable {
    let listings: [Listing]
    let activeHazardLayers: Set<HazardLayer>
    let activeRiskLayers: Set<TokyoRiskLayer>
    var usePaleBaseMap: Bool = false
    var showsUserLocation: Bool = false
    @Binding var selectedListing: Listing?
    /// いいねトグル時に SwiftData を保存するためのコールバック
    var onLikeTapped: ((Listing) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        mapView.mapType = usePaleBaseMap ? .mutedStandard : .standard

        // 東京駅中心
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
        mapView.setRegion(region, animated: false)

        // ピンのクラスタリング
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // ベースマップ切替
        let desiredType: MKMapType = usePaleBaseMap ? .mutedStandard : .standard
        if mapView.mapType != desiredType {
            mapView.mapType = desiredType
        }

        // 現在地表示の切替
        if mapView.showsUserLocation != showsUserLocation {
            mapView.showsUserLocation = showsUserLocation
        }

        // --- タイル + ポリゴンオーバーレイの差分更新 ---
        updateOverlays(mapView, coordinator: context.coordinator)

        // --- アノテーション（物件ピン）の更新 ---
        updateAnnotations(mapView)
    }

    private func updateOverlays(_ mapView: MKMapView, coordinator: Coordinator) {
        // レイヤーが変更されていなければスキップ（P4: 差分更新）
        let currentHazard = activeHazardLayers
        let currentRisk = activeRiskLayers
        if coordinator.previousHazardLayers == currentHazard && coordinator.previousRiskLayers == currentRisk {
            return
        }
        coordinator.previousHazardLayers = currentHazard
        coordinator.previousRiskLayers = currentRisk

        // 既存のタイルオーバーレイを削除
        let existingTiles = mapView.overlays.compactMap { $0 as? MKTileOverlay }
        mapView.removeOverlays(existingTiles)

        // 既存のポリゴンオーバーレイ (RankedPolygon) を削除
        let existingPolygons = mapView.overlays.compactMap { $0 as? RankedPolygon }
        mapView.removeOverlays(existingPolygons)

        // アクティブな GSI タイルオーバーレイを追加
        for layer in activeHazardLayers {
            guard let urlTemplate = layer.tileURLTemplate else { continue }
            let tileOverlay = MKTileOverlay(urlTemplate: urlTemplate)
            tileOverlay.canReplaceMapContent = false
            tileOverlay.minimumZ = 2
            tileOverlay.maximumZ = 17
            mapView.addOverlay(tileOverlay, level: .aboveRoads)
        }

        // アクティブな東京都地域危険度ポリゴンオーバーレイを追加
        let riskService = TokyoRiskService.shared
        for layer in activeRiskLayers {
            let polygons = riskService.polygons(for: layer)
            if !polygons.isEmpty {
                mapView.addOverlays(polygons, level: .aboveRoads)
            }
        }
    }

    private func updateAnnotations(_ mapView: MKMapView) {
        let existing = mapView.annotations.compactMap { $0 as? ListingAnnotation }
        let existingURLs = Set(existing.map { $0.listing.url })
        let newURLs = Set(listings.map(\.url))

        // 削除
        let toRemove = existing.filter { !newURLs.contains($0.listing.url) }
        mapView.removeAnnotations(toRemove)

        // 追加（座標なしの物件はスキップ — (0,0) 表示を防止）
        let toAdd = listings
            .filter { !existingURLs.contains($0.url) && $0.hasCoordinate }
            .map { ListingAnnotation(listing: $0) }
        mapView.addAnnotations(toAdd)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: HazardMapView
        /// 前回のオーバーレイ状態（差分更新用）
        var previousHazardLayers: Set<HazardLayer>?
        var previousRiskLayers: Set<TokyoRiskLayer>?

        init(parent: HazardMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(overlay: tileOverlay)
            }
            if let rankedPolygon = overlay as? RankedPolygon {
                let renderer = MKPolygonRenderer(polygon: rankedPolygon)
                renderer.fillColor = riskColor(for: rankedPolygon.rank)
                renderer.strokeColor = riskColor(for: rankedPolygon.rank).withAlphaComponent(0.6)
                renderer.lineWidth = 0.5
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let listingAnnotation = annotation as? ListingAnnotation else { return nil }
            let listing = listingAnnotation.listing

            let identifier = "ListingPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)

            view.annotation = annotation
            // HTML準拠: いいね=赤、新築=緑、中古=青
            if listing.isLiked {
                view.markerTintColor = UIColor.systemRed
                view.glyphImage = UIImage(systemName: "heart.fill")
            } else if listing.isShinchiku {
                view.markerTintColor = UIColor.systemGreen
                view.glyphImage = UIImage(systemName: "building.2.fill")
            } else {
                view.markerTintColor = UIColor.systemBlue
                view.glyphImage = UIImage(systemName: "building.2.fill")
            }
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.canShowCallout = true

            // カスタム callout
            let detailButton = UIButton(type: .detailDisclosure)
            detailButton.accessibilityLabel = "詳細を表示"
            view.rightCalloutAccessoryView = detailButton

            // callout 内のいいねボタン
            let likeButton = UIButton(type: .system)
            let heartImage = listing.isLiked
                ? UIImage(systemName: "heart.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
                : UIImage(systemName: "heart")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            likeButton.setImage(heartImage, for: .normal)
            likeButton.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            likeButton.accessibilityLabel = listing.isLiked ? "いいねを解除" : "いいねする"
            view.leftCalloutAccessoryView = likeButton

            // カスタム詳細 callout ビュー（物件情報 + ハザード）
            view.detailCalloutAccessoryView = makeCalloutDetailView(for: listing)

            return view
        }

        /// callout に表示する物件詳細 + ハザード情報のカスタムビュー
        private func makeCalloutDetailView(for listing: Listing) -> UIView {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 3
            stack.alignment = .leading

            // 物件詳細行（間取り・面積・徒歩・築年）
            let detailParts = [listing.layout, listing.areaDisplay, listing.walkDisplay, listing.builtAgeDisplay]
                .compactMap { $0 }
                .filter { $0 != "—" }
            if !detailParts.isEmpty {
                let detailLabel = UILabel()
                detailLabel.text = detailParts.joined(separator: " ・ ")
                detailLabel.font = .systemFont(ofSize: 11)
                detailLabel.textColor = .secondaryLabel
                detailLabel.numberOfLines = 2
                stack.addArrangedSubview(detailLabel)
            }

            // 階数・権利形態
            let subParts = [
                listing.floorDisplay != "—" ? listing.floorDisplay : nil,
                listing.ownershipShort != "—" ? listing.ownershipShort : nil,
                listing.totalUnitsDisplay != "—" ? listing.totalUnitsDisplay : nil
            ].compactMap { $0 }
            if !subParts.isEmpty {
                let subLabel = UILabel()
                subLabel.text = subParts.joined(separator: " ・ ")
                subLabel.font = .systemFont(ofSize: 10)
                subLabel.textColor = .tertiaryLabel
                subLabel.numberOfLines = 1
                stack.addArrangedSubview(subLabel)
            }

            // ハザード情報
            let hazard = listing.parsedHazardData
            if hazard.hasAnyHazard {
                // スペーサー
                let spacer = UIView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: 2).isActive = true
                stack.addArrangedSubview(spacer)

                let hazardStack = UIStackView()
                hazardStack.axis = .horizontal
                hazardStack.spacing = 4
                hazardStack.alignment = .center

                let warningIcon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
                warningIcon.tintColor = .systemOrange
                warningIcon.translatesAutoresizingMaskIntoConstraints = false
                warningIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
                warningIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
                warningIcon.contentMode = .scaleAspectFit
                hazardStack.addArrangedSubview(warningIcon)

                let labels = hazard.activeLabels.map { $0.label }
                let hazardLabel = UILabel()
                let displayLabels = labels.prefix(3).joined(separator: "・")
                hazardLabel.text = labels.count > 3
                    ? "\(displayLabels) 他\(labels.count - 3)件"
                    : displayLabels
                hazardLabel.font = .systemFont(ofSize: 10, weight: .medium)
                hazardLabel.textColor = .systemOrange
                hazardLabel.numberOfLines = 2
                hazardStack.addArrangedSubview(hazardLabel)

                stack.addArrangedSubview(hazardStack)
            }

            return stack
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let listingAnnotation = view.annotation as? ListingAnnotation else { return }

            if control == view.rightCalloutAccessoryView {
                // 詳細ボタン → 詳細画面へ遷移
                parent.selectedListing = listingAnnotation.listing
            } else if control == view.leftCalloutAccessoryView {
                // いいねボタン — コールバック経由で modelContext.save() を呼ぶ
                let listing = listingAnnotation.listing
                listing.isLiked.toggle()
                parent.onLikeTapped?(listing)

                // ピンの表示を更新（いいね=赤、新築=緑、中古=青）
                if let markerView = view as? MKMarkerAnnotationView {
                    let heartImage = listing.isLiked
                        ? UIImage(systemName: "heart.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
                        : UIImage(systemName: "heart")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                    (markerView.leftCalloutAccessoryView as? UIButton)?.setImage(heartImage, for: .normal)
                    if listing.isLiked {
                        markerView.markerTintColor = .systemRed
                        markerView.glyphImage = UIImage(systemName: "heart.fill")
                    } else {
                        markerView.markerTintColor = listing.isShinchiku ? .systemGreen : .systemBlue
                        markerView.glyphImage = UIImage(systemName: "building.2.fill")
                    }
                }
            }
        }
    }
}

// MARK: - Map Tab View

struct MapTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ListingStore.self) private var store
    @Query private var listings: [Listing]

    @State private var selectedListing: Listing?
    /// OOUI: 地図タブ独自のフィルタ状態（一覧タブと干渉しない）
    @State private var filterStore = FilterStore()
    @State private var showHazardSheet = false
    @State private var activeHazardLayers: Set<HazardLayer> = []
    @State private var activeRiskLayers: Set<TokyoRiskLayer> = []
    @State private var usePaleBaseMap = false
    @State private var hasStartedGeocoding = false
    @State private var showsUserLocation = false
    /// HIG: 凡例の折りたたみ状態（画面圧迫を防ぐ）
    @State private var isLegendExpanded = true
    /// ジオコーディング失敗件数
    @State private var geocodingFailureCount = 0
    /// データ取得エラー表示
    @State private var showErrorAlert = false

    /// 座標未取得の物件数（ジオコーディング待ち or 失敗）
    private var ungeocodedCount: Int {
        listings.filter { !$0.hasCoordinate }.count
    }

    private var filteredListings: [Listing] {
        // 掲載終了物件は地図に表示しない
        var list = listings.filter { $0.hasCoordinate && !$0.isDelisted }

        // 新築は価格帯（priceMan〜priceMaxMan）を持つため、範囲交差で判定する
        if let min = filterStore.filter.priceMin {
            list = list.filter {
                let upper = $0.priceMaxMan ?? $0.priceMan ?? 0
                return upper >= min
            }
        }
        if let max = filterStore.filter.priceMax {
            list = list.filter {
                let lower = $0.priceMan ?? 0
                return lower <= max
            }
        }
        if !filterStore.filter.layouts.isEmpty {
            list = list.filter { filterStore.filter.layouts.contains($0.layout ?? "") }
        }
        if !filterStore.filter.wards.isEmpty {
            list = list.filter { listing in
                guard let ward = ListingFilter.extractWard(from: listing.address) else { return false }
                return filterStore.filter.wards.contains(ward)
            }
        }
        if let max = filterStore.filter.walkMax {
            list = list.filter { ($0.walkMin ?? 99) <= max }
        }
        if let min = filterStore.filter.areaMin {
            list = list.filter { ($0.areaM2 ?? 0) >= min }
        }
        if !filterStore.filter.ownershipTypes.isEmpty {
            list = list.filter { listing in
                let o = listing.ownership ?? ""
                return filterStore.filter.ownershipTypes.contains { type in
                    switch type {
                    case .ownership: return o.contains("所有権")
                    case .leasehold: return o.contains("借地")
                    }
                }
            }
        }
        if !filterStore.filter.stations.isEmpty {
            list = list.filter { listing in
                let listingStations = listing.parsedStations.map(\.stationName)
                return filterStore.filter.stations.contains(where: { listingStations.contains($0) })
            }
        }
        return list
    }

    private var availableLayouts: [String] {
        Set(listings.compactMap(\.layout).filter { !$0.isEmpty }).sorted()
    }

    private var availableWards: Set<String> {
        Set(listings.compactMap { ListingFilter.extractWard(from: $0.address) })
    }

    private var availableStations: [String] {
        Set(listings.flatMap { $0.parsedStations.map(\.stationName) }).sorted()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapContent

                // 右上: フィルタ情報・座標なし物件案内
                VStack {
                    HStack {
                        Spacer()
                        overlayButtons
                    }
                    Spacer()
                }

                // 左下: 凡例 + 現在地ボタン
                VStack(alignment: .leading, spacing: 8) {
                    Spacer()
                    mapLegendView
                    Button {
                        showsUserLocation.toggle()
                    } label: {
                        Image(systemName: showsUserLocation ? "location.fill" : "location")
                            .font(.body)
                            .foregroundStyle(showsUserLocation ? .white : .accentColor)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle().fill(showsUserLocation ? Color.accentColor : Color(.systemBackground).opacity(0.9))
                            )
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    }
                    .accessibilityLabel(showsUserLocation ? "現在地を非表示" : "現在地を表示")
                }
                .padding(.leading, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                if store.isRefreshing {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("更新中…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                    }
                }
            }
            .navigationTitle("地図")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await store.refresh(modelContext: modelContext) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                        .accessibilityLabel("更新")

                        Button {
                            showHazardSheet = true
                        } label: {
                            Image(systemName: activeHazardLayers.isEmpty && activeRiskLayers.isEmpty
                                  ? "water.waves"
                                  : "water.waves.and.arrow.trianglehead.up")
                        }
                        .accessibilityLabel("ハザードマップ")

                        Button {
                            filterStore.showFilterSheet = true
                        } label: {
                            Image(systemName: filterStore.filter.isActive
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("フィルタ")
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(get: { filterStore.showFilterSheet }, set: { filterStore.showFilterSheet = $0 })) {
                ListingFilterSheet(filter: Binding(get: { filterStore.filter }, set: { filterStore.filter = $0 }), availableLayouts: availableLayouts, availableWards: availableWards, availableStations: availableStations, filteredCount: filteredListings.count)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    // データ取得エラー
                    if let error = store.lastError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(error)
                                .font(.caption)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 16)
                        .onTapGesture { showErrorAlert = true }
                    }
                    // ジオコーディング失敗
                    if geocodingFailureCount > 0 {
                        Text("\(geocodingFailureCount)件の住所を地図に表示できませんでした")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.top, 4)
            }
            .alert("データ取得エラー", isPresented: $showErrorAlert) {
                Button("再取得") {
                    Task { await store.refresh(modelContext: modelContext) }
                }
                Button("閉じる", role: .cancel) { }
            } message: {
                Text(store.lastError ?? "")
            }
            .sheet(isPresented: $showHazardSheet) {
                hazardLayerSheet
            }
            .sheet(item: $selectedListing) { listing in
                ListingDetailView(listing: listing)
            }
            .task {
                await startGeocoding()
            }
        }
    }

    // MARK: - Map Content

    @ViewBuilder
    private var mapContent: some View {
        HazardMapView(
            listings: filteredListings,
            activeHazardLayers: activeHazardLayers,
            activeRiskLayers: activeRiskLayers,
            usePaleBaseMap: usePaleBaseMap,
            showsUserLocation: showsUserLocation,
            selectedListing: $selectedListing,
            onLikeTapped: { listing in
                SaveErrorHandler.shared.save(modelContext, source: "MapTab")
                FirebaseSyncService.shared.pushLikeState(for: listing)
            }
        )
        .ignoresSafeArea(edges: .bottom)
        // HIG: VoiceOver で地図の概要情報を提供
        .accessibilityElement(children: .contain)
        .accessibilityLabel("物件マップ")
        .accessibilityValue(
            "\(filteredListings.count)件の物件を表示中" +
            (activeHazardLayers.isEmpty && activeRiskLayers.isEmpty
                ? ""
                : "、\(activeHazardLayers.count + activeRiskLayers.count)件のハザードレイヤー表示中")
        )
    }

    // MARK: - Overlay Buttons

    @ViewBuilder
    private var overlayButtons: some View {
        VStack(spacing: 8) {
            // フィルタ情報 & 座標なし物件案内
            VStack(alignment: .trailing, spacing: 4) {
                if filterStore.filter.isActive {
                    Text("\(filteredListings.count)件")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(.ultraThinMaterial)
                        )
                }
                if ungeocodedCount > 0 {
                    Label("\(ungeocodedCount)件 座標取得中", systemImage: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(.ultraThinMaterial)
                        )
                }
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 12)
    }

    // MARK: - Hazard Layer Sheet

    @ViewBuilder
    private var hazardLayerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 全ON/OFF ボタン
                    hazardToggleAllButtons

                    // 基本レイヤー
                    hazardSectionHeader("基本レイヤー")
                    ForEach(HazardLayer.basicLayers) { layer in
                        hazardToggleRow(layer)
                        if layer != HazardLayer.basicLayers.last { sheetDivider }
                    }

                    // 洪水詳細
                    hazardSectionHeader("洪水詳細")
                    ForEach(HazardLayer.floodDetailLayers) { layer in
                        hazardToggleRow(layer)
                        if layer != HazardLayer.floodDetailLayers.last { sheetDivider }
                    }

                    // 地盤の揺れやすさ
                    hazardSectionHeader("地震")
                    hazardToggleRow(.seismicRisk)

                    // 東京都地域危険度
                    hazardSectionHeader("地域危険度（東京都）")
                    ForEach(TokyoRiskLayer.allCases) { layer in
                        riskToggleRow(layer)
                        if layer != TokyoRiskLayer.allCases.last { sheetDivider }
                    }
                    // ランク凡例
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { rank in
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color(uiColor: riskColor(for: rank)))
                                    .frame(width: 10, height: 10)
                                Text("\(rank)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("低←→高")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // ベースマップ切替
                    hazardSectionHeader("表示設定")
                    HStack {
                        Image("tab-map")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        Text("淡色地図")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $usePaleBaseMap)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Text("ハザード表示時は淡色地図にするとオーバーレイが見やすくなります")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    // 出典
                    hazardSectionHeader("出典")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("国土地理院ハザードマップポータルサイトのタイルデータを利用しています。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("© 国土地理院 / 東京都都市整備局")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ハザードマップ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showHazardSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func hazardSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sheetDivider: some View {
        Divider().padding(.leading, 52)
    }

    // MARK: - 地図凡例（ピン + ハザードレイヤー動的）

    /// 地図上に表示する凡例ビュー
    /// - ピン色（中古/新築）は常時表示
    /// - 選択中のハザードレイヤーの色凡例を動的に表示
    /// HIG: 折りたたみ可能な凡例ビュー（画面圧迫を防止）
    @ViewBuilder
    private var mapLegendView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 凡例ヘッダー（タップで折りたたみ切替）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isLegendExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "map")
                        .font(.caption2)
                    Text("凡例")
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: isLegendExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("凡例")
            .accessibilityHint(isLegendExpanded ? "タップで折りたたみ" : "タップで展開")

            if isLegendExpanded {
                // ピン凡例（常時表示）— HTML準拠: 中古/新築/♥いいね
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle().fill(.blue).frame(width: 8, height: 8)
                        Text("中古").font(.caption2)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("新築").font(.caption2)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("♥いいね").font(.caption2)
                    }
                }

                // ハザードレイヤー凡例（選択中のみ表示）
                let sortedHazard = Array(activeHazardLayers).sorted { $0.rawValue < $1.rawValue }
                let sortedRisk = Array(activeRiskLayers).sorted { $0.rawValue < $1.rawValue }

                if !sortedHazard.isEmpty || !sortedRisk.isEmpty {
                    Divider()

                    ForEach(Array(sortedHazard.enumerated()), id: \.element.id) { idx, layer in
                        if idx > 0 {
                            Divider().padding(.leading, 4)
                        }
                        hazardLegendSection(title: layer.rawValue,
                                            icon: layer.systemImage,
                                            items: layer.legendItems)
                    }

                    ForEach(Array(sortedRisk.enumerated()), id: \.element.id) { idx, layer in
                        if !sortedHazard.isEmpty || idx > 0 {
                            Divider().padding(.leading, 4)
                        }
                        riskLegendSection(title: layer.rawValue,
                                          icon: layer.systemImage)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .animation(.easeInOut(duration: 0.25), value: activeHazardLayers)
        .animation(.easeInOut(duration: 0.25), value: activeRiskLayers)
        .animation(.easeInOut(duration: 0.25), value: isLegendExpanded)
    }

    /// ハザードレイヤー凡例セクション（色バー + ラベル）
    @ViewBuilder
    private func hazardLegendSection(title: String, icon: String, items: [(color: Color, label: String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // カラーバー（グラデーション風に横並び）
            HStack(spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.color)
                        .frame(height: 8)
                }
            }

            // 最小・最大ラベル
            if let first = items.first, let last = items.last, items.count >= 2 {
                HStack {
                    Text(first.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(last.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 東京都地域危険度レイヤー凡例（ランク1-5共通）
    @ViewBuilder
    private func riskLegendSection(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { rank in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(uiColor: riskColor(for: rank)))
                        .frame(height: 8)
                }
            }

            HStack {
                Text("ランク1 低")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("ランク5 高")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 全ON/OFF トグルボタン（シート上部に目立つように配置）
    @ViewBuilder
    private var hazardToggleAllButtons: some View {
        let allOn = activeHazardLayers.count == HazardLayer.allCases.count
            && activeRiskLayers.count == TokyoRiskLayer.allCases.count
        let allOff = activeHazardLayers.isEmpty && activeRiskLayers.isEmpty
        let activeCount = activeHazardLayers.count + activeRiskLayers.count
        let totalCount = HazardLayer.allCases.count + TokyoRiskLayer.allCases.count

        VStack(spacing: 8) {
            // 選択数表示
            Text("\(activeCount)/\(totalCount) レイヤー選択中")
                .font(.caption)
                .foregroundStyle(.secondary)

            // ボタン
            HStack(spacing: 10) {
                Button {
                    withAnimation {
                        activeHazardLayers = Set(HazardLayer.allCases)
                        activeRiskLayers = Set(TokyoRiskLayer.allCases)
                        for layer in TokyoRiskLayer.allCases {
                            Task { await TokyoRiskService.shared.fetchIfNeeded(layer) }
                        }
                    }
                } label: {
                    Label("すべてON", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(allOn)

                Button {
                    withAnimation {
                        activeHazardLayers.removeAll()
                        activeRiskLayers.removeAll()
                    }
                } label: {
                    Label("すべてOFF", systemImage: "xmark.circle")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(allOff)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    @State private var infoTargetHazard: HazardLayer?
    @State private var infoTargetRisk: TokyoRiskLayer?

    @ViewBuilder
    private func hazardToggleRow(_ layer: HazardLayer) -> some View {
        let isActive = activeHazardLayers.contains(layer)
        HStack(spacing: 8) {
            Image(systemName: layer.systemImage)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            Text(layer.rawValue)
                .font(.subheadline)
            Spacer()
            Button {
                infoTargetHazard = layer
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(
                get: { activeHazardLayers.contains(layer) },
                set: { on in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if on { activeHazardLayers.insert(layer) }
                        else { activeHazardLayers.remove(layer) }
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .sheet(item: $infoTargetHazard) { target in
            hazardInfoSheet(target)
        }
    }

    @ViewBuilder
    private func riskToggleRow(_ layer: TokyoRiskLayer) -> some View {
        let isActive = activeRiskLayers.contains(layer)
        HStack(spacing: 8) {
            Image(systemName: layer.systemImage)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            Text(layer.rawValue)
                .font(.subheadline)
            Spacer()
            Button {
                infoTargetRisk = layer
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(
                get: { activeRiskLayers.contains(layer) },
                set: { on in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if on {
                            activeRiskLayers.insert(layer)
                            Task { await TokyoRiskService.shared.fetchIfNeeded(layer) }
                        } else {
                            activeRiskLayers.remove(layer)
                        }
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .sheet(item: $infoTargetRisk) { target in
            riskInfoSheet(target)
        }
    }

    // MARK: - Info Sheets

    @ViewBuilder
    private func hazardInfoSheet(_ layer: HazardLayer) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // アイコン + タイトル
                    HStack(spacing: 10) {
                        Image(systemName: layer.systemImage)
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        Text(layer.rawValue)
                            .font(.headline)
                    }

                    // 説明
                    Text(layer.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // 凡例
                    VStack(alignment: .leading, spacing: 8) {
                        Text("凡例（色とリスクの対応）")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(Array(layer.legendItems.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(item.color)
                                    .frame(width: 24, height: 14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                                    )
                                Text(item.label)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text("出典: 国土地理院ハザードマップポータルサイト")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
            }
            .navigationTitle("レイヤー情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { infoTargetHazard = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func riskInfoSheet(_ layer: TokyoRiskLayer) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: layer.systemImage)
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                        Text(layer.rawValue)
                            .font(.headline)
                    }

                    Text(layer.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("凡例（色とリスクの対応）")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ForEach(1...5, id: \.self) { rank in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(uiColor: riskColor(for: rank)))
                                    .frame(width: 24, height: 14)
                                Text("ランク\(rank)")
                                    .font(.caption)
                                    .fontWeight(rank >= 4 ? .semibold : .regular)
                                    .foregroundStyle(rank >= 4 ? .red : .primary)
                                Text(riskRankDescription(rank))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text("出典: 東京都都市整備局 地域危険度測定調査")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
            }
            .navigationTitle("レイヤー情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { infoTargetRisk = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func riskRankDescription(_ rank: Int) -> String {
        switch rank {
        case 1: return "— 危険性が低い"
        case 2: return "— やや危険"
        case 3: return "— 危険"
        case 4: return "— かなり危険"
        case 5: return "— 非常に危険"
        default: return ""
        }
    }

    // MARK: - Geocoding

    private func startGeocoding() async {
        guard !hasStartedGeocoding else { return }
        hasStartedGeocoding = true
        let toGeocode = listings.filter { !$0.hasCoordinate && $0.address != nil && !($0.address ?? "").isEmpty }
        guard !toGeocode.isEmpty else { return }

        let failures = await GeocodingService.shared.geocodeBatch(toGeocode, modelContext: modelContext)
        geocodingFailureCount = failures
    }
}

// MARK: - Preview

#Preview {
    MapTabView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
