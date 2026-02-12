//
//  AuthService.swift
//  RealEstateApp
//
//  Google アカウントによる認証を管理する。
//  Firebase Auth + Google Sign-In SDK を使用。
//
//  アクセス制御:
//  許可されたメールアドレスのみサインイン可能
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

    // MARK: - Access Control（アクセス制御）

    /// 許可されたメールアドレス一覧（小文字で記載）
    /// ここに許可する Google アカウントのメールアドレスを追加する。
    private static let allowedEmails: Set<String> = [
        "masaki.hanawa.417@gmail.com",
        "nogura.yuka.kf@gmail.com",
    ]

    /// 現在のユーザーのメールアドレスが許可リストに含まれるか
    var isEmailAllowed: Bool {
        guard let email = currentUser?.email?.lowercased() else { return false }
        return Self.allowedEmails.contains(email)
    }

    /// アプリへのアクセスが許可されているか（サインイン済み + メール許可）
    var isAuthorized: Bool {
        isSignedIn && isEmailAllowed
    }

    private init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.currentUser = user

            // 許可されていないメールアドレスのセッションが復元された場合、
            // 自動でサインアウトする
            if let user, let email = user.email?.lowercased(),
               !Self.allowedEmails.contains(email) {
                self.isSignedIn = false
                self.isLoading = false
                self.lastError = "このアカウント（\(email)）はアクセスが許可されていません"
                try? Auth.auth().signOut()
                GIDSignIn.sharedInstance.signOut()
                return
            }

            self.isSignedIn = user != nil
            self.isLoading = false
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    // MARK: - Google Sign-In

    /// Google アカウントでサインインする。
    /// メールアドレスが許可リストに含まれない場合は自動でサインアウトしエラーを投げる。
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

        // メールアドレスの許可チェック
        if let email = Auth.auth().currentUser?.email?.lowercased(),
           !Self.allowedEmails.contains(email) {
            signOut()
            throw AuthError.unauthorizedEmail
        }
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
        case unauthorizedEmail

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Firebase Client ID が見つかりません。Firebase Console で Google Sign-In を有効化し、GoogleService-Info.plist を再ダウンロードしてください。"
            case .noRootViewController:
                return "画面の取得に失敗しました"
            case .missingIDToken:
                return "Google ID Token の取得に失敗しました"
            case .unauthorizedEmail:
                return "このアカウントはアクセスが許可されていません"
            }
        }
    }
}
