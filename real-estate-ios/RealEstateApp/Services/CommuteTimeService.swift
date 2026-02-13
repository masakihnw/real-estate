//
//  CommuteTimeService.swift
//  RealEstateApp
//
//  物件から各オフィスへの door-to-door 通勤時間を MKDirections（公共交通機関）で計算。
//  計算結果は Listing.commuteInfoJSON にキャッシュし、住所ベースのジオコーディング→経路検索を行う。
//

import Foundation
import MapKit
import SwiftData
import UIKit

/// 経路計算用の定数（MainActor に依存せずバックグラウンドで参照可能）
private enum _RouteCoordinates {
    static let playground = CLLocationCoordinate2D(latitude: 35.688449, longitude: 139.743415)
    static let playgroundName = "Playground株式会社"
    static let m3career = CLLocationCoordinate2D(latitude: 35.666018, longitude: 139.743807)
    static let m3careerName = "エムスリーキャリア"
}

@MainActor
final class CommuteTimeService {
    static let shared = CommuteTimeService()

    // MARK: - 目的地定義（_RouteCoordinates を参照、MainActor 非依存の実体はファイル先頭）

    /// 経路計算中かどうか
    private(set) var isCalculating = false

    /// キャッシュ無効化バージョン。変更時は全物件の通勤時間を Apple Maps で再計算する。
    /// v2→v3: JSON 概算を廃止し、Apple Maps (MKDirections) のみで計算する方式に変更
    private static let coordinateVersion = 3
    private static let coordinateVersionKey = "commuteTime.coordinateVersion"

    private init() {
        // 座標バージョンが古い場合、全物件の通勤時間キャッシュを再計算対象にする
        let saved = UserDefaults.standard.integer(forKey: Self.coordinateVersionKey)
        if saved < Self.coordinateVersion {
            UserDefaults.standard.set(Self.coordinateVersion, forKey: Self.coordinateVersionKey)
            needsRecalculation = true
        }
    }

    /// 座標更新で全件再計算が必要かどうか
    private(set) var needsRecalculation = false

    // MARK: - Google Maps ディープリンク

    enum Destination {
        case playground
        case m3career

        var coordinate: CLLocationCoordinate2D {
            switch self {
            case .playground: return _RouteCoordinates.playground
            case .m3career: return _RouteCoordinates.m3career
            }
        }

        var name: String {
            switch self {
            case .playground: return _RouteCoordinates.playgroundName
            case .m3career: return _RouteCoordinates.m3careerName
            }
        }
    }

    /// Google Maps アプリ（またはブラウザ）で物件から目的地への公共交通機関ルートを開く
    static func openGoogleMaps(from listing: Listing, to destination: Destination) {
        guard let lat = listing.latitude, let lon = listing.longitude else { return }

        let dest = destination.coordinate

        // Google Maps アプリがインストールされている場合はアプリで開く
        let appURLString = "comgooglemaps://?saddr=\(lat),\(lon)&daddr=\(dest.latitude),\(dest.longitude)&directionsmode=transit"
        if let appURL = URL(string: appURLString),
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
            return
        }

        // フォールバック: ブラウザで Google Maps を開く
        let webURLString = "https://www.google.com/maps/dir/?api=1&origin=\(lat),\(lon)&destination=\(dest.latitude),\(dest.longitude)&destination_place_id=&travelmode=transit"
        if let webURL = URL(string: webURLString) {
            UIApplication.shared.open(webURL)
        }
    }

    // MARK: - バッチ計算

    /// 座標を持つ物件の通勤時間を計算
    /// - 未計算の物件: 新規計算
    /// - フォールバック概算（経路情報取得不可）の物件: 毎回リトライ
    /// - 正常取得済みの物件: 7日以上経過した場合のみ再計算
    func calculateForAllListings(modelContext: ModelContext, onError: ((String) -> Void)? = nil) async {
        guard !isCalculating else { return }
        isCalculating = true
        defer { isCalculating = false }

        let descriptor = FetchDescriptor<Listing>()
        let listings: [Listing]
        do {
            listings = try modelContext.fetch(descriptor)
        } catch {
            print("[CommuteTimeService] 物件一覧の取得に失敗: \(error.localizedDescription)")
            onError?("通勤時間の取得に失敗: \(error.localizedDescription)")
            return
        }

        let forceAll = needsRecalculation
        let targets = listings.filter { listing in
            guard listing.hasCoordinate else { return false }
            // 座標更新時（オフィス移転など）は全件再計算
            if forceAll { return true }

            let info = listing.parsedCommuteInfo

            // 未計算の物件は対象
            guard let pg = info.playground, let m3 = info.m3career else { return true }

            // フォールバック概算の物件は毎回リトライ（経路取得の再試行）
            if info.hasFallbackEstimate { return true }

            // 正常取得済みの物件は 7日以上経過した場合のみ再計算
            let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
            return pg.calculatedAt < sevenDaysAgo || m3.calculatedAt < sevenDaysAgo
        }
        if forceAll { needsRecalculation = false }

        print("[CommuteTimeService] 計算対象: \(targets.count)件 / 全\(listings.count)件")

        // ループ処理をバックグラウンドへ（MKDirections はスレッドセーフ）
        let targetsData: [(listing: Listing, lat: Double, lon: Double, existingJSON: String?)] = targets.compactMap { listing in
            guard let lat = listing.latitude, let lon = listing.longitude else { return nil }
            return (listing, lat, lon, listing.commuteInfoJSON)
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                for (listing, lat, lon, existingJSON) in targetsData {
                    try Task.checkCancellation()
                    let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    let encoded = await Self.computeCommuteJSON(origin: origin, existingJSON: existingJSON)
                    await MainActor.run {
                        if let encoded { listing.commuteInfoJSON = encoded }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒（レート制限回避）
                }
            }.value
        } catch {
            print("[CommuteTimeService] 通勤時間計算に失敗: \(error.localizedDescription)")
            onError?("通勤時間の計算に失敗: \(error.localizedDescription)")
        }

        SaveErrorHandler.shared.save(modelContext, source: "CommuteTime")
    }

    /// 単一物件の通勤時間を計算（MainActor / バックグラウンドのどちらからも呼び出し可能）
    nonisolated func calculateForListing(_ listing: Listing, modelContext: ModelContext) async {
        guard let lat = listing.latitude, let lon = listing.longitude else { return }
        let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let encoded = await Self.computeCommuteJSON(origin: origin, existingJSON: listing.commuteInfoJSON)
        await MainActor.run {
            if let encoded { listing.commuteInfoJSON = encoded }
        }
    }

    /// 経路計算のコアロジック（非 MainActor で実行可能、MKDirections はスレッドセーフ）
    nonisolated private static func computeCommuteJSON(origin: CLLocationCoordinate2D, existingJSON: String?) async -> String? {
        var commuteData: CommuteData
        if let existingJSON, let data = existingJSON.data(using: .utf8) {
            commuteData = (try? CommuteData.decoder.decode(CommuteData.self, from: data)) ?? CommuteData()
        } else {
            commuteData = CommuteData()
        }

        // Playground への経路
        if let pgResult = await Self.calculateRoute(from: origin, to: _RouteCoordinates.playground, destinationName: _RouteCoordinates.playgroundName) {
            commuteData.playground = pgResult
        }

        // エムスリーキャリアへの経路
        if let m3Result = await Self.calculateRoute(from: origin, to: _RouteCoordinates.m3career, destinationName: _RouteCoordinates.m3careerName) {
            commuteData.m3career = m3Result
        }

        return commuteData.encode()
    }

    // MARK: - 経路計算

    /// MKDirections で公共交通機関の経路を計算（リトライ付き）
    nonisolated private static func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        destinationName: String
    ) async -> CommuteDestination? {
        // 1st attempt: departureDate 指定（次の平日朝 8:00 出発）
        if let result = await Self.attemptTransitRoute(
            from: origin, to: destination, destinationName: destinationName,
            departureDate: Self.nextWeekdayMorning()
        ) {
            return result
        }

        // 短い待機後にリトライ（一時的なエラー対策）
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒

        // 2nd attempt: 日時指定なし（現在時刻ベース）
        if let result = await Self.attemptTransitRoute(
            from: origin, to: destination, destinationName: destinationName,
            departureDate: nil
        ) {
            return result
        }

        // 全て失敗した場合のみフォールバック
        print("[CommuteTimeService] 全リトライ失敗、フォールバック概算 → \(destinationName)")
        return await Self.calculateFallbackRoute(from: origin, to: destination, destinationName: destinationName)
    }

    /// MKDirections で Transit 経路を1回試行
    nonisolated private static func attemptTransitRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        destinationName: String,
        departureDate: Date?
    ) async -> CommuteDestination? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .transit

        if let departureDate {
            request.departureDate = departureDate
        }

        let directions = MKDirections(request: request)

        do {
            let response = try await directions.calculate()
            guard let route = response.routes.first else {
                print("[CommuteTimeService] 経路なし（routes empty） → \(destinationName)")
                return nil
            }

            let minutes = Int(ceil(route.expectedTravelTime / 60.0))
            let summary = Self.buildRouteSummary(route: route, destinationName: destinationName)
            let transfers = Self.countTransfers(route: route)

            return CommuteDestination(
                minutes: minutes,
                summary: summary,
                transfers: transfers,
                calculatedAt: Date()
            )
        } catch {
            let dateDesc = departureDate.map { "departure=\($0)" } ?? "no date"
            print("[CommuteTimeService] 経路計算失敗 (\(dateDesc)) → \(destinationName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Transit 経路が取得できない場合のフォールバック（直線距離ベースの概算）
    nonisolated private static func calculateFallbackRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        destinationName: String
    ) async -> CommuteDestination? {
        // 直線距離から概算（東京の公共交通機関: 直線距離の1.4倍 ÷ 平均速度25km/h + 徒歩15分）
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let destLocation = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        let distanceKm = originLocation.distance(from: destLocation) / 1000.0

        let transitMinutes = Int(ceil(distanceKm * 1.4 / 25.0 * 60.0)) + 15 // 乗車時間 + 徒歩
        return CommuteDestination(
            minutes: transitMinutes,
            summary: "直線\(String(format: "%.1f", distanceKm))kmから概算（経路情報取得不可）",
            transfers: nil,
            calculatedAt: Date()
        )
    }

    /// 経路情報からサマリーテキストを生成
    /// 物件→（徒歩）→路線1「駅名」→路線2「駅名」→（徒歩）→目的地 形式
    nonisolated private static func buildRouteSummary(route: MKRoute, destinationName: String) -> String {
        let steps = route.steps.filter { !$0.instructions.isEmpty }
        if steps.isEmpty {
            let minutes = Int(ceil(route.expectedTravelTime / 60.0))
            return "\(destinationName)まで\(minutes)分"
        }

        // 公共交通機関のステップのみ抽出（徒歩区間を除外）
        let transitSteps = steps.filter { $0.transportType == .transit }

        if transitSteps.isEmpty {
            // 全て徒歩の場合
            let walkMin = Int(ceil(route.expectedTravelTime / 60.0))
            return "徒歩\(walkMin)分"
        }

        // 各交通機関ステップから路線名を抽出して連結
        var routeParts: [String] = []
        for step in transitSteps {
            let instruction = step.instructions
            routeParts.append(instruction)
        }

        // 最大4ステップまで表示（見やすさのため）
        let displayParts = routeParts.prefix(4)
        var summary = displayParts.joined(separator: " → ")

        if routeParts.count > 4 {
            summary += " 他"
        }

        return summary
    }

    /// 乗り換え回数をカウント
    nonisolated private static func countTransfers(route: MKRoute) -> Int {
        let transitSteps = route.steps.filter {
            $0.transportType == .transit
        }
        return max(0, transitSteps.count - 1)
    }

    /// 次の平日（月〜金）の朝8:00 を返す（出発時刻として使用）
    nonisolated private static func nextWeekdayMorning() -> Date {
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.year, .month, .day, .weekday], from: Date())
        components.hour = 8
        components.minute = 0
        components.second = 0

        guard var date = calendar.date(from: components) else { return Date() }

        // 今日が週末なら次の月曜日にする
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 { // 日曜
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        } else if weekday == 7 { // 土曜
            date = calendar.date(byAdding: .day, value: 2, to: date) ?? date
        }

        // すでに過ぎている場合は翌日
        if date < Date() {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            let newWeekday = calendar.component(.weekday, from: date)
            if newWeekday == 1 {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            } else if newWeekday == 7 {
                date = calendar.date(byAdding: .day, value: 2, to: date) ?? date
            }
        }

        return date
    }
}
