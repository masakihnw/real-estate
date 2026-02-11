//
//  LoginView.swift
//  RealEstateApp
//
//  Google アカウントでログインする画面。
//  青いウェーブ背景 + アプリアイコン + Google サインインボタン。
//  HIG: 明確なアクション、ブランドガイドラインに沿った Google ボタン。
//

import SwiftUI
import GoogleSignIn

struct LoginView: View {
    @Environment(AuthService.self) private var authService
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            // 全画面グラデーション背景（上: 薄い青 → 下: ごく薄い青）
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.80, green: 0.88, blue: 0.98), location: 0.0),
                    .init(color: Color(red: 0.87, green: 0.92, blue: 0.99), location: 0.30),
                    .init(color: Color(red: 0.91, green: 0.94, blue: 0.99), location: 0.55),
                    .init(color: Color(red: 0.94, green: 0.96, blue: 0.99), location: 0.80),
                    .init(color: Color(red: 0.95, green: 0.96, blue: 1.0), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // ウェーブ装飾（全画面に重ねる）
            WaveBackground()
                .ignoresSafeArea()

            // コンテンツ
            VStack(spacing: 0) {
                Spacer()

                // アプリアイコン + タイトル（上部 1/3 付近に配置）
                VStack(spacing: 16) {
                    Image("AppIcon-Login")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
                        .accessibilityHidden(true)

                    Text("物件情報")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }

                // 上 1 : 下 2 の比率で黄金比付近に配置
                Spacer()
                Spacer()

                // ステータス表示 + Google Sign-In ボタン
                VStack(spacing: 0) {
                    // ローディング / エラー（固定高さでボタン位置を安定化）
                    ZStack {
                        if isSigningIn {
                            ProgressView()
                        } else if let errorMessage {
                            Text(errorMessage)
                                .font(ListingObjectStyle.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                    .frame(height: 36)
                    .padding(.bottom, 24)

                    // Google Sign-In button (Google Branding Guidelines 準拠: Light テーマ)
                    Button {
                        signIn()
                    } label: {
                        HStack(spacing: 12) {
                            googleGLogo
                                .frame(width: 20, height: 20)
                            Text("Google でログイン")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(Color(red: 0x1F/255, green: 0x1F/255, blue: 0x1F/255))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color(red: 0xDA/255, green: 0xDC/255, blue: 0xE0/255), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
                    }
                    .disabled(isSigningIn)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 92)
            }
        }
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

// MARK: - ウェーブ背景

/// ログイン画面の青いウェーブ装飾。
/// 全画面グラデーションの上に重ねる透過ウェーブレイヤー。
private struct WaveBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ウェーブレイヤー 1（上部の大きな流れ）
                WaveShape(waveTop: 0.10, waveMid: 0.30, waveBottom: 0.50)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.30, green: 0.65, blue: 0.95).opacity(0.30),
                                Color(red: 0.55, green: 0.80, blue: 1.0).opacity(0.10)
                            ],
                            startPoint: .topTrailing,
                            endPoint: .bottomLeading
                        )
                    )

                // ウェーブレイヤー 2（中央の流れ）
                WaveShape(waveTop: 0.20, waveMid: 0.42, waveBottom: 0.60)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.20, green: 0.55, blue: 0.90).opacity(0.25),
                                Color(red: 0.45, green: 0.75, blue: 1.0).opacity(0.08)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                // ウェーブレイヤー 3（下部のアクセント）
                WaveShape(waveTop: 0.35, waveMid: 0.55, waveBottom: 0.72)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.45, blue: 0.85).opacity(0.20),
                                Color(red: 0.40, green: 0.70, blue: 1.0).opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// カスタムウェーブ形状（全画面対応）
/// waveTop/waveMid/waveBottom は画面高さに対する比率（0.0〜1.0）で
/// ウェーブの開始・中間・終了位置を指定。
private struct WaveShape: Shape {
    let waveTop: CGFloat
    let waveMid: CGFloat
    let waveBottom: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // 左上から開始 → 右上
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))

        // 右辺を下る → ウェーブ開始
        path.addLine(to: CGPoint(x: w, y: h * waveTop))

        // S字カーブ: 右 → 左
        path.addCurve(
            to: CGPoint(x: w * 0.5, y: h * waveMid),
            control1: CGPoint(x: w * 0.85, y: h * (waveTop + (waveMid - waveTop) * 0.8)),
            control2: CGPoint(x: w * 0.65, y: h * (waveMid - (waveMid - waveTop) * 0.15))
        )
        path.addCurve(
            to: CGPoint(x: 0, y: h * waveBottom),
            control1: CGPoint(x: w * 0.35, y: h * (waveMid + (waveBottom - waveMid) * 0.6)),
            control2: CGPoint(x: w * 0.15, y: h * (waveBottom - (waveBottom - waveMid) * 0.1))
        )

        path.closeSubpath()
        return path
    }
}

#Preview {
    LoginView()
        .environment(AuthService.shared)
}
