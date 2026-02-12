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

@MainActor
final class CommuteTimeService {
    static let shared = CommuteTimeService()

    // MARK: - 目的地定義

    /// Playground株式会社（〒102-0082 千代田区一番町4-6）
    static let playgroundCoordinate = CLLocationCoordinate2D(latitude: 35.688449, longitude: 139.743415)
    static let playgroundName = "Playground株式会社"

    /// エムスリーキャリア株式会社（〒105-0001 港区虎ノ門4丁目1-28）
    static let m3careerCoordinate = CLLocationCoordinate2D(latitude: 35.666018, longitude: 139.743807)
    static let m3careerName = "エムスリーキャリア"

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
            case .playground: return CommuteTimeService.playgroundCoordinate
            case .m3career: return CommuteTimeService.m3careerCoordinate
            }
        }

        var name: String {
            switch self {
            case .playground: return CommuteTimeService.playgroundName
            case .m3career: return CommuteTimeService.m3careerName
            }
        }
    }

    /// Google Maps アプリ（またはブラウザ）で物件から目的地への公共交通機関ルートを開く
    static func openGoogleMaps(from listing: Listing, to destination: Destination) {
        guard let lat = listing.latitude, let lon = listing.longitude else { return }

        let dest = destination.coordinate
        let destName = destination.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

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

    /// 座標を持つ全物件の通勤時間を計算（未計算 or 7日以上経過のみ）
    func calculateForAllListings(modelContext: ModelContext) async {
        guard !isCalculating else { return }
        isCalculating = true
        defer { isCalculating = false }

        let descriptor = FetchDescriptor<Listing>()
        let listings: [Listing]
        do {
            listings = try modelContext.fetch(descriptor)
        } catch {
            print("[CommuteTimeService] 物件一覧の取得に失敗: \(error.localizedDescription)")
            return
        }

        let forceAll = needsRecalculation
        let targets = listings.filter { listing in
            guard listing.hasCoordinate else { return false }
            // 座標更新時は全件再計算
            if forceAll { return true }
            // 未計算 or 7日以上経過で再計算
            let info = listing.parsedCommuteInfo
            if let pg = info.playground, let m3 = info.m3career {
                let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
                return pg.calculatedAt < sevenDaysAgo || m3.calculatedAt < sevenDaysAgo
            }
            return true
        }
        if forceAll { needsRecalculation = false }

        for listing in targets {
            await calculateForListing(listing, modelContext: modelContext)
            // レート制限回避: リクエスト間に少し間隔を空ける
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        }

        await MainActor.run { SaveErrorHandler.shared.save(modelContext, source: "CommuteTime") }
    }

    /// 単一物件の通勤時間を計算
    func calculateForListing(_ listing: Listing, modelContext: ModelContext) async {
        guard let lat = listing.latitude, let lon = listing.longitude else { return }
        let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)

        var commuteData = listing.parsedCommuteInfo

        // Playground への経路
        if let pgResult = await calculateRoute(from: origin, to: Self.playgroundCoordinate, destinationName: Self.playgroundName) {
            commuteData.playground = pgResult
        }

        // エムスリーキャリアへの経路
        if let m3Result = await calculateRoute(from: origin, to: Self.m3careerCoordinate, destinationName: Self.m3careerName) {
            commuteData.m3career = m3Result
        }

        // encode が nil を返した場合は既存データを消さない
        if let encoded = commuteData.encode() {
            listing.commuteInfoJSON = encoded
        }
    }

    // MARK: - 経路計算

    /// MKDirections で公共交通機関の経路を計算
    private func calculateRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        destinationName: String
    ) async -> CommuteDestination? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .transit

        // 平日朝8:30到着で計算（次の平日の8:30）
        request.arrivalDate = nextWeekdayMorning()

        let directions = MKDirections(request: request)

        do {
            let response = try await directions.calculate()
            guard let route = response.routes.first else { return nil }

            let minutes = Int(ceil(route.expectedTravelTime / 60.0))
            let summary = buildRouteSummary(route: route, destinationName: destinationName)
            let transfers = countTransfers(route: route)

            return CommuteDestination(
                minutes: minutes,
                summary: summary,
                transfers: transfers,
                calculatedAt: Date()
            )
        } catch {
            print("[CommuteTimeService] 経路計算失敗 → \(destinationName): \(error.localizedDescription)")
            // Transit が使えない場合は徒歩+車のフォールバック
            return await calculateFallbackRoute(from: origin, to: destination, destinationName: destinationName)
        }
    }

    /// Transit 経路が取得できない場合のフォールバック（直線距離ベースの概算）
    private func calculateFallbackRoute(
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
    private func buildRouteSummary(route: MKRoute, destinationName: String) -> String {
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
    private func countTransfers(route: MKRoute) -> Int {
        let transitSteps = route.steps.filter {
            $0.transportType == .transit
        }
        return max(0, transitSteps.count - 1)
    }

    /// 次の平日（月〜金）の朝8:30 を返す（到着時刻として使用）
    private func nextWeekdayMorning() -> Date {
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents([.year, .month, .day, .weekday], from: Date())
        components.hour = 8
        components.minute = 30
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
