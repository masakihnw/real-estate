//
//  LoginView.swift
//  RealEstateApp
//
//  Google アカウントでログインする画面。
//  HIG: 明確なアクション、ブランドガイドラインに沿った Google ボタン。
//

import SwiftUI
import GoogleSignIn

struct LoginView: View {
    @Environment(AuthService.self) private var authService
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon & title
            VStack(spacing: 16) {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("物件情報")
                    .font(.largeTitle.bold())

                Text("家族で物件情報を共有しましょう")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Google Sign-In button
            VStack(spacing: 16) {
                Button {
                    signIn()
                } label: {
                    HStack(spacing: 12) {
                        // Google "G" ロゴ風アイコン
                        Image(systemName: "g.circle.fill")
                            .font(.title2)
                        Text("Google でログイン")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
                }
                .disabled(isSigningIn)

                if isSigningIn {
                    ProgressView()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(ListingObjectStyle.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.horizontal, 32)

            Spacer()
                .frame(height: 60)
        }
        .padding()
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await authService.signInWithGoogle()
            } catch let error as GIDSignInError where error.code == .canceled {
                // ユーザーがキャンセルした場合は何もしない
            } catch {
                errorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}

#Preview {
    LoginView()
        .environment(AuthService.shared)
}
