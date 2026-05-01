//
//  AnnotationRouter.swift
//  RealEstateApp
//
//  useSupabase フラグに応じて Firebase / Supabase のアノテーションサービスに振り分ける。
//  View から直接 FirebaseSyncService を呼んでいた箇所をこのルーターに置き換える。
//

import Foundation
import SwiftData

enum AnnotationRouter {
    private static var useSupabase: Bool { ListingStore.shared.useSupabase }

    static var isAuthenticated: Bool {
        useSupabase
            ? SupabaseAnnotationService.shared.isAuthenticated
            : FirebaseSyncService.shared.isAuthenticated
    }

    static var currentUserId: String? {
        useSupabase
            ? SupabaseAnnotationService.shared.currentUserId
            : FirebaseSyncService.shared.currentUserId
    }

    static func pushLikeState(for listing: Listing) {
        if useSupabase {
            SupabaseAnnotationService.shared.pushLikeState(for: listing)
        } else {
            FirebaseSyncService.shared.pushLikeState(for: listing)
        }
    }

    @MainActor
    static func addComment(for listing: Listing, text: String, modelContext: ModelContext) {
        if useSupabase {
            SupabaseAnnotationService.shared.addComment(for: listing, text: text, modelContext: modelContext)
        } else {
            FirebaseSyncService.shared.addComment(for: listing, text: text, modelContext: modelContext)
        }
    }

    @MainActor
    static func editComment(for listing: Listing, commentId: String, newText: String, modelContext: ModelContext) {
        if useSupabase {
            SupabaseAnnotationService.shared.editComment(for: listing, commentId: commentId, newText: newText, modelContext: modelContext)
        } else {
            FirebaseSyncService.shared.editComment(for: listing, commentId: commentId, newText: newText, modelContext: modelContext)
        }
    }

    @MainActor
    static func deleteComment(for listing: Listing, commentId: String, modelContext: ModelContext) {
        if useSupabase {
            SupabaseAnnotationService.shared.deleteComment(for: listing, commentId: commentId, modelContext: modelContext)
        } else {
            FirebaseSyncService.shared.deleteComment(for: listing, commentId: commentId, modelContext: modelContext)
        }
    }
}
