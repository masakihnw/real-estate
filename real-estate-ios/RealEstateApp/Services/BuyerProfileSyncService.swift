//
//  BuyerProfileSyncService.swift
//  RealEstateApp
//
//  Supabase の buyer_profiles テーブルと UserDefaults のローカルキャッシュを同期する。
//  SupabaseAnnotationService と同じパターン：Firebase Auth UID + SECURITY DEFINER RPC。
//

import Foundation
import FirebaseAuth
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "BuyerProfileSync")

@Observable
final class BuyerProfileSyncService {
    static let shared = BuyerProfileSyncService()

    private(set) var isSyncing = false

    private let client = SupabaseClient.shared
    private let defaults = UserDefaults.standard

    private let didPushLocalKey = "supabase.buyerProfile.didPushLocal"
    private let pushLocalVersion = 1

    private init() {}

    // MARK: - Auth

    var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    // MARK: - Sync on launch

    func syncOnLaunch() async {
        guard let userId = currentUserId else {
            logger.info("Not authenticated — skipping buyer profile sync")
            return
        }

        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let didPush = defaults.integer(forKey: didPushLocalKey)
        if didPush < pushLocalVersion {
            await pushLocalToRemote(userId: userId)
            defaults.set(pushLocalVersion, forKey: didPushLocalKey)
        }

        await pullFromRemote(userId: userId)
    }

    // MARK: - Pull

    private func pullFromRemote(userId: String) async {
        do {
            let data = try await client.rpc("get_buyer_profile", params: ["p_user_id": userId])
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = rows.first else {
                logger.info("No remote buyer profile found")
                return
            }

            let remote = BuyerProfile.from(supabaseJSON: row)
            let local = BuyerProfile.load()

            if remote.updatedAt > local.updatedAt {
                logger.info("Remote profile is newer — overwriting local")
                remote.save()
            } else {
                logger.info("Local profile is newer or same — keeping local")
            }
        } catch {
            logger.error("Failed to pull buyer profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Push

    func push(_ profile: BuyerProfile) async {
        guard let userId = currentUserId else { return }

        var params = profile.toSupabaseJSON()
        params["p_user_id"] = userId

        do {
            _ = try await client.rpc("upsert_buyer_profile", params: ["p_user_id": userId, "p_profile": params])
            logger.info("Buyer profile pushed to Supabase")
        } catch {
            logger.error("Failed to push buyer profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Initial migration

    private func pushLocalToRemote(userId: String) async {
        let local = BuyerProfile.load()
        guard !local.isEmpty else { return }

        logger.info("Pushing local buyer profile to Supabase (initial migration)")
        await push(local)
    }
}
