//
//  SaveErrorHandler.swift
//  RealEstateApp
//
//  modelContext.save() 失敗を集約して UI にトースト表示するためのハンドラ。
//  各所で do { try modelContext.save() } catch { ... } のエラーをここに報告する。
//

import Foundation
import SwiftData

@Observable
final class SaveErrorHandler {
    static let shared = SaveErrorHandler()

    /// 最新の保存エラーメッセージ（nil = エラーなし）
    var lastSaveError: String?
    /// アラート表示用フラグ
    var showSaveError = false

    private init() {}

    /// modelContext の保存を試み、失敗時にユーザーへフィードバックする
    @MainActor
    func save(_ context: ModelContext, source: String = "") {
        do {
            try context.save()
        } catch {
            let msg = source.isEmpty
                ? "データの保存に失敗しました: \(error.localizedDescription)"
                : "[\(source)] データの保存に失敗しました: \(error.localizedDescription)"
            print("[SaveErrorHandler] \(msg)")
            lastSaveError = msg
            showSaveError = true
        }
    }
}
