//
//  AuthService.swift
//  RealEstateApp
//
//  Google アカウントによる認証を管理する。
//  Firebase Auth + Google Sign-In SDK を使用。
//

import Foundation
import FirebaseAuth
import FirebaseCore
import GoogleSignIn

@Observable
final class AuthService {
    static let shared = AuthService()

    private(set) var currentUser: User?
    private(set) var isSignedIn = false
    private(set) var isLoading = true

    var userDisplayName: String? { currentUser?.displayName }
    var userEmail: String? { currentUser?.email }
    var userPhotoURL: URL? { currentUser?.photoURL }

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    /// サインアウトなどで発生した直近のエラー（UI で表示可能）
    private(set) var lastError: String?

    private init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.currentUser = user
            self?.isSignedIn = user != nil
            self?.isLoading = false
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    // MARK: - Google Sign-In

    /// Google アカウントでサインインする。
    @MainActor
    func signInWithGoogle() async throws {
        lastError = nil
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthError.missingClientID
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            throw AuthError.noRootViewController
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingIDToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )

        try await Auth.auth().signIn(with: credential)
    }

    // MARK: - Sign Out

    /// サインアウトする。
    func signOut() {
        lastError = nil
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            lastError = error.localizedDescription
            print("[Auth] サインアウト失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - URL Handling

    /// Google Sign-In のコールバック URL を処理する。
    func handle(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case missingClientID
        case noRootViewController
        case missingIDToken

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Firebase Client ID が見つかりません。Firebase Console で Google Sign-In を有効化し、GoogleService-Info.plist を再ダウンロードしてください。"
            case .noRootViewController:
                return "画面の取得に失敗しました"
            case .missingIDToken:
                return "Google ID Token の取得に失敗しました"
            }
        }
    }
}
