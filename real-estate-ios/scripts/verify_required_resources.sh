#!/usr/bin/env bash
# ============================================================================
# verify_required_resources.sh
#   de-PII で外部 plist 化された「必須機密リソース」が、ソース・生成された
#   Xcode プロジェクト・ビルド成果物（.app）に確実に含まれているか検証する。
#
#   これらが欠けたままビルドすると:
#     - AllowedEmails.plist 欠落 → 許可リスト空 = 全アカウント拒否（fail-closed）
#       → 誰もログインできない（過去に de-PII で pbxproj の参照が抜けて発生）
#     - CommuteOffices.plist 欠落 → 通勤時間が座標0,0で壊れる
#
#   使い方:
#     ./scripts/verify_required_resources.sh                # ソース + pbxproj 参照を検証
#     ./scripts/verify_required_resources.sh --archive PATH # .xcarchive 内 .app のバンドルを検証
#
#   非ゼロ終了 = 検証失敗。deploy.sh から呼び出し、壊れたビルドのアップロードを止める。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$PROJECT_DIR/RealEstateApp"
PBXPROJ="$PROJECT_DIR/RealEstateApp.xcodeproj/project.pbxproj"

# 検証対象の必須リソース（ファイル名）
REQUIRED_PLISTS=("AllowedEmails.plist" "CommuteOffices.plist")

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
fail() { echo -e "${RED}✖ 必須リソース検証 失敗:${NC} $*" >&2; exit 1; }
ok()   { echo -e "${GREEN}✔${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }

# ── ソース plist の存在・妥当性（非空）を検証 ───────────────────────
verify_sources() {
    for name in "${REQUIRED_PLISTS[@]}"; do
        local f="$SRC_DIR/$name"
        [[ -f "$f" ]] || fail "$name がありません ($f)。${name%.plist}.sample.plist を複製して実値を記入してください。"
        plutil -lint "$f" >/dev/null 2>&1 || fail "$name が不正な plist です ($f)。"
        # 先頭要素を取り出せること = 非空配列であること
        plutil -extract 0 raw -o - "$f" >/dev/null 2>&1 \
            || fail "$name が空配列です ($f)。実値が記入されていません。"
        ok "ソース OK: $name"
    done
}

# ── 生成された pbxproj が各 plist を Copy Bundle Resources に含むか検証 ──
verify_pbxproj_refs() {
    [[ -f "$PBXPROJ" ]] || fail "project.pbxproj がありません。先に 'xcodegen generate' を実行してください。"
    for name in "${REQUIRED_PLISTS[@]}"; do
        grep -q "$name in Resources" "$PBXPROJ" \
            || fail "$name が Copy Bundle Resources に含まれていません（pbxproj 参照欠落）。'xcodegen generate' で再生成してください。"
        ok "pbxproj 参照 OK: $name"
    done
}

# ── ビルド成果物(.app)に各 plist が実際に同梱されているか検証（最終防衛線）──
verify_archive() {
    local archive="$1"
    [[ -d "$archive" ]] || fail "アーカイブが見つかりません: $archive"
    local app
    app="$(find "$archive/Products/Applications" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
    [[ -n "$app" && -d "$app" ]] || fail ".app がアーカイブ内に見つかりません: $archive"
    for name in "${REQUIRED_PLISTS[@]}"; do
        [[ -f "$app/$name" ]] \
            || fail "$name が .app バンドルに同梱されていません ($app)。このビルドはログイン不能/通勤破綻のためアップロード中止。"
        ok "バンドル同梱 OK: $name"
    done
}

main() {
    if [[ "${1:-}" == "--archive" ]]; then
        [[ -n "${2:-}" ]] || fail "--archive にはアーカイブパスが必要です。"
        info "ビルド成果物の必須リソースを検証: $2"
        verify_archive "$2"
    else
        info "ソース & Xcode プロジェクトの必須リソースを検証"
        verify_sources
        verify_pbxproj_refs
    fi
    echo -e "${GREEN}✔ 必須リソース検証 合格${NC}"
}

main "$@"
