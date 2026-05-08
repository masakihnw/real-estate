//
//  AnnotationRouter.swift
//  RealEstateApp
//
//  Supabase アノテーションサービスへのルーター。
//  View から直接サービスを呼ばず、このルーター経由で統一アクセスする。
//

import Foundation
import SwiftData

enum AnnotationRouter {
    static var isAuthenticated: Bool {
        SupabaseAnnotationService.shared.isAuthenticated
    }

    static var currentUserId: String? {
        SupabaseAnnotationService.shared.currentUserId
    }

    static func pushLikeState(for listing: Listing) {
        SupabaseAnnotationService.shared.pushLikeState(for: listing)
    }

    @MainActor
    static func addComment(for listing: Listing, text: String, modelContext: ModelContext) {
        SupabaseAnnotationService.shared.addComment(for: listing, text: text, modelContext: modelContext)
    }

    @MainActor
    static func editComment(for listing: Listing, commentId: String, newText: String, modelContext: ModelContext) {
        SupabaseAnnotationService.shared.editComment(for: listing, commentId: commentId, newText: newText, modelContext: modelContext)
    }

    @MainActor
    static func deleteComment(for listing: Listing, commentId: String, modelContext: ModelContext) {
        SupabaseAnnotationService.shared.deleteComment(for: listing, commentId: commentId, modelContext: modelContext)
    }
}
