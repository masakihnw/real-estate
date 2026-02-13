#!/usr/bin/env bash
# ============================================================================
# deploy.sh — RealEstateApp をアーカイブし App Store Connect にアップロード
# ============================================================================
#
# 使い方:
#   ./scripts/deploy.sh              # アーカイブ + アップロード
#   ./scripts/deploy.sh --archive    # アーカイブのみ（アップロードしない）
#   ./scripts/deploy.sh --upload     # 既存アーカイブのアップロードのみ
#
# 初回セットアップ:
#   1. App Store Connect → ユーザとアクセス → 統合 → App Store Connect API
#      で「キーを生成」し、.p8 ファイルをダウンロード
#   2. setup サブコマンドを実行:
#      ./scripts/deploy.sh --setup
#   3. 案内に従って Key ID, Issuer ID, .p8 ファイルのパスを入力
#
# ============================================================================
set -euo pipefail

# ── 定数 ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_DIR/RealEstateApp.xcodeproj"
SCHEME="RealEstateApp"
TEAM_ID="YRP5KV2X62"

CONFIG_DIR="$HOME/.config/real-estate-deploy"
CONFIG_FILE="$CONFIG_DIR/config"

ARCHIVE_PATH="/tmp/RealEstateApp.xcarchive"
EXPORT_PATH="/tmp/RealEstateExport"
EXPORT_OPTIONS="/tmp/RealEstateExportOptions.plist"

# ── ヘルパー ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}ℹ${NC}  $*"; }
ok()    { echo -e "${GREEN}✔${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
fail()  { echo -e "${RED}✖${NC}  $*" >&2; exit 1; }

# ── セットアップ ──────────────────────────────────────
do_setup() {
    echo ""
    info "App Store Connect API Key のセットアップ"
    echo "  → https://appstoreconnect.apple.com/access/integrations/api"
    echo ""

    read -rp "  Key ID (例: ABC1234DEF): " key_id
    read -rp "  Issuer ID (例: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx): " issuer_id
    read -rp "  .p8 ファイルのパス: " p8_path

    # パスを展開
    p8_path="${p8_path/#\~/$HOME}"

    [[ -z "$key_id" ]] && fail "Key ID が空です"
    [[ -z "$issuer_id" ]] && fail "Issuer ID が空です"
    [[ -f "$p8_path" ]] || fail ".p8 ファイルが見つかりません: $p8_path"

    # キーファイルを安全な場所にコピー
    mkdir -p "$CONFIG_DIR/private_keys"
    cp "$p8_path" "$CONFIG_DIR/private_keys/AuthKey_${key_id}.p8"
    chmod 600 "$CONFIG_DIR/private_keys/AuthKey_${key_id}.p8"

    # 設定ファイルを書き出し
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<CFG
# App Store Connect API Key 設定
# 生成日: $(date '+%Y-%m-%d %H:%M:%S')
ASC_KEY_ID="${key_id}"
ASC_ISSUER_ID="${issuer_id}"
ASC_KEY_PATH="${CONFIG_DIR}/private_keys/AuthKey_${key_id}.p8"
CFG
    chmod 600 "$CONFIG_FILE"

    echo ""
    ok "セットアップ完了"
    info "設定ファイル: $CONFIG_FILE"
    info "キーファイル: $CONFIG_DIR/private_keys/AuthKey_${key_id}.p8"
    echo ""
}

# ── 設定読み込み ──────────────────────────────────────
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        fail "設定が見つかりません。先に ./scripts/deploy.sh --setup を実行してください"
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    [[ -f "$ASC_KEY_PATH" ]] || fail "APIキーファイルが見つかりません: $ASC_KEY_PATH"
    ok "API Key 読み込み完了 (Key ID: $ASC_KEY_ID)"
}

# ── アーカイブ ────────────────────────────────────────
do_archive() {
    info "アーカイブ中… (scheme: $SCHEME, configuration: Release)"

    # 前回のアーカイブを削除
    rm -rf "$ARCHIVE_PATH"

    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination 'generic/platform=iOS' \
        archive \
        2>&1 | tail -5

    [[ -d "$ARCHIVE_PATH" ]] || fail "アーカイブに失敗しました"

    # ビルド番号を表示
    local build_num
    build_num=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo "?")
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo "?")

    ok "アーカイブ成功 (v${version} build ${build_num})"
}

# ── エクスポート＋アップロード ─────────────────────────
do_upload() {
    load_config

    info "エクスポート＋アップロード中…"

    [[ -d "$ARCHIVE_PATH" ]] || fail "アーカイブが見つかりません: $ARCHIVE_PATH\n   先に --archive を実行してください"

    # ExportOptions.plist を生成
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

    # 前回のエクスポートを削除
    rm -rf "$EXPORT_PATH"

    xcodebuild \
        -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        2>&1 | tail -10

    if [[ $? -eq 0 ]] || grep -q "EXPORT SUCCEEDED\|Upload Succeeded" /tmp/RealEstateExport/*.plist 2>/dev/null; then
        ok "App Store Connect へのアップロード完了"
    else
        # エクスポートだけ成功してアップロードが失敗した場合のフォールバック
        if ls "$EXPORT_PATH"/*.ipa 1>/dev/null 2>&1; then
            warn "エクスポート成功・アップロード未確認。IPA: $(ls "$EXPORT_PATH"/*.ipa)"
        else
            fail "エクスポート / アップロードに失敗しました"
        fi
    fi
}

# ── メイン ────────────────────────────────────────────
main() {
    local mode="${1:-all}"

    echo ""
    echo -e "${CYAN}━━━ RealEstateApp Deploy ━━━${NC}"
    echo ""

    case "$mode" in
        --setup)
            do_setup
            ;;
        --archive)
            do_archive
            ;;
        --upload)
            do_upload
            ;;
        --help|-h)
            echo "Usage: $0 [--setup|--archive|--upload|--help]"
            echo ""
            echo "  (引数なし)   アーカイブ + アップロード"
            echo "  --setup      API Key の初回セットアップ"
            echo "  --archive    アーカイブのみ"
            echo "  --upload     既存アーカイブのアップロードのみ"
            echo ""
            ;;
        all|"")
            do_archive
            echo ""
            do_upload
            ;;
        *)
            fail "不明なオプション: $mode\n  $0 --help で使い方を確認してください"
            ;;
    esac

    echo ""
}

main "$@"
