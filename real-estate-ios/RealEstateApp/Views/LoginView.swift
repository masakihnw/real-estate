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
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("物件情報")
                    .font(.largeTitle.bold())

                Text("家族で物件情報を共有しましょう")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Google Sign-In button (Google Branding Guidelines 準拠: Light テーマ)
            // https://developers.google.com/identity/branding-guidelines
            VStack(spacing: 16) {
                Button {
                    signIn()
                } label: {
                    HStack(spacing: 12) {
                        // Google "G" マルチカラーロゴ（白背景の丸内に配置）
                        googleGLogo
                            .frame(width: 20, height: 20)
                        Text("Google でログイン")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(Color(red: 0x1F/255, green: 0x1F/255, blue: 0x1F/255)) // #1F1F1F
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                            .stroke(Color(red: 0x74/255, green: 0x77/255, blue: 0x75/255), lineWidth: 1) // #747775
                    )
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

    /// Google "G" マルチカラーロゴ（ブランドガイドライン準拠）
    private var googleGLogo: some View {
        // Google 公式の4色 "G" ロゴを Canvas で描画
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w / 2
            let cy = h / 2
            let r = min(w, h) / 2

            // 背景の白丸
            context.fill(Circle().path(in: CGRect(origin: .zero, size: size)), with: .color(.white))

            // 4色アーク + 中央バー
            let lineWidth = r * 0.38
            let arcR = r * 0.6

            // 赤（上→右上）
            var redPath = Path()
            redPath.addArc(center: CGPoint(x: cx, y: cy), radius: arcR, startAngle: .degrees(-45), endAngle: .degrees(10), clockwise: false)
            context.stroke(redPath, with: .color(Color(red: 0xEA/255, green: 0x43/255, blue: 0x35/255)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))

            // 黄（右上→下）
            var yellowPath = Path()
            yellowPath.addArc(center: CGPoint(x: cx, y: cy), radius: arcR, startAngle: .degrees(10), endAngle: .degrees(100), clockwise: false)
            context.stroke(yellowPath, with: .color(Color(red: 0xFB/255, green: 0xBC/255, blue: 0x05/255)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))

            // 緑（下→左）
            var greenPath = Path()
            greenPath.addArc(center: CGPoint(x: cx, y: cy), radius: arcR, startAngle: .degrees(100), endAngle: .degrees(190), clockwise: false)
            context.stroke(greenPath, with: .color(Color(red: 0x34/255, green: 0xA8/255, blue: 0x53/255)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))

            // 青（左→上）
            var bluePath = Path()
            bluePath.addArc(center: CGPoint(x: cx, y: cy), radius: arcR, startAngle: .degrees(190), endAngle: .degrees(315), clockwise: false)
            context.stroke(bluePath, with: .color(Color(red: 0x42/255, green: 0x85/255, blue: 0xF4/255)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))

            // 中央の横バー（青→右へ）
            let barRect = CGRect(x: cx - lineWidth * 0.15, y: cy - lineWidth / 2, width: r * 0.55, height: lineWidth)
            context.fill(Path(barRect), with: .color(Color(red: 0x42/255, green: 0x85/255, blue: 0xF4/255)))
        }
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
