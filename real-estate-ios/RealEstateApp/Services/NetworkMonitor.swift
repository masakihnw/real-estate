//
//  NetworkMonitor.swift
//  RealEstateApp
//
//  NWPathMonitor を使ったネットワーク接続状態の監視。
//  ContentView でオフライン時にバナーを表示するために使用する。
//

import Foundation
import Network

@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// 現在ネットワークに接続しているか
    private(set) var isConnected = true
    /// 接続タイプ（Wi-Fi / セルラー / その他）
    private(set) var connectionType: NWInterface.InterfaceType?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = path.availableInterfaces.first?.type
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
