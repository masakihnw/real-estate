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
    case flood = "洪水浸水想定"
    case sediment = "土砂災害警戒"
    case stormSurge = "高潮浸水想定"
    case tsunami = "津波浸水想定"
    case liquefaction = "液状化リスク"
    case seismicRisk = "地域危険度"

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
            // 東京都地域危険度（重ねるハザードマップ）— 国土地理院配信
            return "https://disaportaldata.gsi.go.jp/raster/13_jibanshindou/{z}/{x}/{y}.png"
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
        }
    }
}

// MARK: - Geocoding Service

@Observable
final class GeocodingService {
    static let shared = GeocodingService()
    private let geocoder = CLGeocoder()
    private var isGeocoding = false
    private var queue: [Listing] = []

    /// バッチジオコーディング（未ジオコーディングの物件をまとめて処理）
    func geocodeBatch(_ listings: [Listing], modelContext: ModelContext) async {
        let toGeocode = listings.filter { !$0.hasCoordinate && $0.address != nil && !($0.address ?? "").isEmpty }
        for listing in toGeocode {
            guard let address = listing.address else { continue }
            do {
                let placemarks = try await geocoder.geocodeAddressString(address)
                if let loc = placemarks.first?.location {
                    await MainActor.run {
                        listing.latitude = loc.coordinate.latitude
                        listing.longitude = loc.coordinate.longitude
                    }
                }
                // Apple Geocoder rate limit: ~1 req/sec
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                continue
            }
        }
        try? modelContext.save()
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

/// UIViewRepresentable wrapper to support MKTileOverlay for hazard maps
struct HazardMapView: UIViewRepresentable {
    let listings: [Listing]
    let activeHazardLayers: Set<HazardLayer>
    @Binding var selectedListing: Listing?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.mapType = .standard

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

        // --- タイルオーバーレイの更新 ---
        updateOverlays(mapView)

        // --- アノテーション（物件ピン）の更新 ---
        updateAnnotations(mapView)
    }

    private func updateOverlays(_ mapView: MKMapView) {
        // 既存のタイルオーバーレイを削除
        let existingOverlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
        mapView.removeOverlays(existingOverlays)

        // アクティブなレイヤーのタイルオーバーレイを追加
        for layer in activeHazardLayers {
            guard let urlTemplate = layer.tileURLTemplate else { continue }
            let tileOverlay = MKTileOverlay(urlTemplate: urlTemplate)
            tileOverlay.canReplaceMapContent = false
            tileOverlay.minimumZ = 2
            tileOverlay.maximumZ = 17
            mapView.addOverlay(tileOverlay, level: .aboveRoads)
        }
    }

    private func updateAnnotations(_ mapView: MKMapView) {
        let existing = mapView.annotations.compactMap { $0 as? ListingAnnotation }
        let existingURLs = Set(existing.map { $0.listing.url })
        let newURLs = Set(listings.map(\.url))

        // 削除
        let toRemove = existing.filter { !newURLs.contains($0.listing.url) }
        mapView.removeAnnotations(toRemove)

        // 追加
        let toAdd = listings.filter { !existingURLs.contains($0.url) }
            .map { ListingAnnotation(listing: $0) }
        mapView.addAnnotations(toAdd)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: HazardMapView

        init(parent: HazardMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(overlay: tileOverlay)
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
            view.markerTintColor = listing.isShinchiku
                ? UIColor.systemGreen
                : UIColor.systemBlue
            view.glyphImage = listing.isLiked
                ? UIImage(systemName: "heart.fill")
                : UIImage(systemName: "building.2.fill")
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.canShowCallout = true

            // カスタム callout
            let detailButton = UIButton(type: .detailDisclosure)
            view.rightCalloutAccessoryView = detailButton

            // callout 内のいいねボタン
            let likeButton = UIButton(type: .system)
            let heartImage = listing.isLiked
                ? UIImage(systemName: "heart.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
                : UIImage(systemName: "heart")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            likeButton.setImage(heartImage, for: .normal)
            likeButton.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            view.leftCalloutAccessoryView = likeButton

            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let listingAnnotation = view.annotation as? ListingAnnotation else { return }

            if control == view.rightCalloutAccessoryView {
                // 詳細ボタン → 詳細画面へ遷移
                parent.selectedListing = listingAnnotation.listing
            } else if control == view.leftCalloutAccessoryView {
                // いいねボタン
                let listing = listingAnnotation.listing
                listing.isLiked.toggle()
                FirebaseSyncService.shared.pushAnnotation(for: listing)

                // ピンの表示を更新
                if let markerView = view as? MKMarkerAnnotationView {
                    let heartImage = listing.isLiked
                        ? UIImage(systemName: "heart.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
                        : UIImage(systemName: "heart")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                    (markerView.leftCalloutAccessoryView as? UIButton)?.setImage(heartImage, for: .normal)
                    markerView.glyphImage = listing.isLiked
                        ? UIImage(systemName: "heart.fill")
                        : UIImage(systemName: "building.2.fill")
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
    @State private var showFilterSheet = false
    @State private var showHazardSheet = false
    @State private var filter = ListingFilter()
    @State private var activeHazardLayers: Set<HazardLayer> = []
    @State private var hasStartedGeocoding = false

    private var filteredListings: [Listing] {
        var list = listings.filter { $0.hasCoordinate }

        if let min = filter.priceMin {
            list = list.filter { ($0.priceMan ?? 0) >= min }
        }
        if let max = filter.priceMax {
            list = list.filter { ($0.priceMan ?? Int.max) <= max }
        }
        if !filter.layouts.isEmpty {
            list = list.filter { filter.layouts.contains($0.layout ?? "") }
        }
        if !filter.stations.isEmpty {
            list = list.filter { filter.stations.contains($0.stationName ?? "") }
        }
        if let max = filter.walkMax {
            list = list.filter { ($0.walkMin ?? 99) <= max }
        }
        if let min = filter.areaMin {
            list = list.filter { ($0.areaM2 ?? 0) >= min }
        }
        if !filter.ownershipTypes.isEmpty {
            list = list.filter { listing in
                let o = listing.ownership ?? ""
                return filter.ownershipTypes.contains { type in
                    switch type {
                    case .ownership: return o.contains("所有権")
                    case .leasehold: return o.contains("借地")
                    }
                }
            }
        }
        return list
    }

    private var availableLayouts: [String] {
        Set(listings.compactMap(\.layout).filter { !$0.isEmpty }).sorted()
    }

    private var stationsByLine: [(line: String, stations: [String])] {
        var dict: [String: Set<String>] = [:]
        for listing in listings {
            guard let lineName = listing.lineName,
                  let stationName = listing.stationName else { continue }
            dict[lineName, default: []].insert(stationName)
        }
        return dict.keys.sorted().map { (line: $0, stations: dict[$0]!.sorted()) }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                mapContent
                overlayButtons
            }
            .navigationTitle("地図")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            showHazardSheet = true
                        } label: {
                            Image(systemName: activeHazardLayers.isEmpty
                                  ? "square.3.layers.3d.down.left"
                                  : "square.3.layers.3d.down.left.slash")
                        }
                        .accessibilityLabel("ハザードマップ")

                        Button {
                            showFilterSheet = true
                        } label: {
                            Image(systemName: filter.isActive
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("フィルタ")
                    }
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                ListingFilterSheet(filter: $filter, availableLayouts: availableLayouts, stationsByLine: stationsByLine)
                    .presentationDetents([.medium, .large])
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
            selectedListing: $selectedListing
        )
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Overlay Buttons

    @ViewBuilder
    private var overlayButtons: some View {
        VStack(spacing: 8) {
            // 凡例
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Circle().fill(.blue).frame(width: 10, height: 10)
                    Text("中古").font(.caption2)
                }
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    Text("新築").font(.caption2)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
            )

            // アクティブレイヤー表示
            if !activeHazardLayers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(activeHazardLayers).sorted(by: { $0.rawValue < $1.rawValue })) { layer in
                        HStack(spacing: 4) {
                            Image(systemName: layer.systemImage)
                                .font(.system(size: 9))
                            Text(layer.rawValue)
                                .font(.system(size: 9))
                        }
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
            }

            // フィルタ情報
            if filter.isActive {
                Text("\(filteredListings.count)件")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(.ultraThinMaterial)
                    )
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 12)
    }

    // MARK: - Hazard Layer Sheet

    @ViewBuilder
    private var hazardLayerSheet: some View {
        NavigationStack {
            List {
                Section("ハザードマップ（国土地理院）") {
                    ForEach(HazardLayer.allCases.filter { $0 != .seismicRisk }) { layer in
                        hazardToggleRow(layer)
                    }
                }
                Section("地域危険度") {
                    hazardToggleRow(.seismicRisk)
                    Text("地震に関する地域の揺れやすさを表すデータです。国土地理院配信タイルを利用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("出典")
                            .font(.caption.bold())
                        Text("国土地理院ハザードマップポータルサイトのタイルデータを利用しています。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("© 国土地理院")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("レイヤー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showHazardSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func hazardToggleRow(_ layer: HazardLayer) -> some View {
        let isActive = activeHazardLayers.contains(layer)
        Button {
            if isActive {
                activeHazardLayers.remove(layer)
            } else {
                activeHazardLayers.insert(layer)
            }
        } label: {
            HStack {
                Image(systemName: layer.systemImage)
                    .foregroundColor(isActive ? .accentColor : .secondary)
                    .frame(width: 28)
                Text(layer.rawValue)
                    .foregroundStyle(.primary)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Geocoding

    private func startGeocoding() async {
        guard !hasStartedGeocoding else { return }
        hasStartedGeocoding = true
        let toGeocode = listings.filter { !$0.hasCoordinate && $0.address != nil && !($0.address ?? "").isEmpty }
        guard !toGeocode.isEmpty else { return }

        await GeocodingService.shared.geocodeBatch(toGeocode, modelContext: modelContext)
    }
}

// MARK: - Preview

#Preview {
    MapTabView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
