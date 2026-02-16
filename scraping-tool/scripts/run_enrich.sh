#!/bin/bash
# WF2 enrich ジョブ用スクリプト
# --property-type chuko|shinchiku で中古/新築を切替
# Phase 1: embed_geocode (< 1min)
# Phase 2: 全 enricher を完全並列実行 (各 enricher が独自ファイルコピーで動作)
# Phase 3: merge_enrichments.py でフィールドレベルマージ + upload_floor_plans
#
# set -e は使わない: 各 enricher の失敗は個別に許容する

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# ──────────────────────────── 引数パース ────────────────────────────

PROPERTY_TYPE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --property-type) PROPERTY_TYPE="$2"; shift 2 ;;
        *) echo "不明な引数: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PROPERTY_TYPE" ]; then
    echo "使い方: run_enrich.sh --property-type chuko|shinchiku" >&2
    exit 1
fi

echo "=== Enrich: ${PROPERTY_TYPE} ===" >&2
echo "日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >&2

# ──────────────────────────── ファイルパス設定 ────────────────────────────

if [ "$PROPERTY_TYPE" = "chuko" ]; then
    INPUT="results/latest.json"
else
    INPUT="results/latest_shinchiku.json"
fi

if [ ! -f "$INPUT" ]; then
    echo "エラー: 入力ファイルが存在しません: $INPUT" >&2
    exit 1
fi

COUNT=$(python3 -c "import json; print(len(json.load(open('$INPUT'))))" 2>/dev/null || echo "0")
echo "入力件数: ${COUNT}件" >&2

WORK_DIR="results/.enrich_work_${PROPERTY_TYPE}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# ──────────────────────────── ブラウザフラグ検出 ────────────────────────────

BROWSER_FLAG=""
if python3 -c "
import sys
try:
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        path = p.chromium.executable_path
        import os
        if os.path.isfile(path):
            sys.exit(0)
        else:
            sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    BROWSER_FLAG="--browser"
    echo "Playwright 検出: ブラウザモード有効" >&2
else
    echo "Playwright 未検出: HTTP モードのみ" >&2
fi

# ──────────────────────────── Phase 1: embed_geocode ────────────────────────────

echo "--- Phase 1: embed_geocode ---" >&2
_t=$(date +%s)
python3 scripts/embed_geocode.py "$INPUT" || echo "embed_geocode 失敗（続行）" >&2
echo "[TIMING] embed_geocode: $(( ($(date +%s) - _t) ))s" >&2

# ──────────────────────────── Phase 2: 全 enricher 完全並列 ────────────────────────────

echo "--- Phase 2: 全 enricher 完全並列実行 ---" >&2
_t_phase2=$(date +%s)

# 各 enricher 用にファイルをコピー
cp "$INPUT" "$WORK_DIR/track_uc.json"  # Track PREP: units_cache
cp "$INPUT" "$WORK_DIR/track_ss.json"  # sumai_surfin
cp "$INPUT" "$WORK_DIR/track_hz.json"  # geocode_cross + hazard
cp "$INPUT" "$WORK_DIR/track_cm.json"  # commute
cp "$INPUT" "$WORK_DIR/track_ri.json"  # reinfolib
cp "$INPUT" "$WORK_DIR/track_es.json"  # estat

# Track PREP: build_units_cache → merge_detail_cache
(
    _t=$(date +%s)
    if [ "$PROPERTY_TYPE" = "chuko" ]; then
        python3 scripts/build_units_cache.py "$WORK_DIR/track_uc.json" || true
        python3 scripts/merge_detail_cache.py "$WORK_DIR/track_uc.json" || true
    else
        python3 shinchiku_detail_enricher.py \
            --input "$WORK_DIR/track_uc.json" \
            --output "$WORK_DIR/track_uc.json" || true
    fi
    echo "[TIMING] track_prep: $(( ($(date +%s) - _t) ))s" >&2
) &
PREP_PID=$!

# Track A: sumai_surfin
(
    _t=$(date +%s)
    python3 sumai_surfin_enricher.py \
        --input "$WORK_DIR/track_ss.json" \
        --output "$WORK_DIR/track_ss.json" \
        --property-type "$PROPERTY_TYPE" $BROWSER_FLAG || true
    echo "[TIMING] sumai_surfin: $(( ($(date +%s) - _t) ))s" >&2
) &
SS_PID=$!

# Track B: geocode_cross_validator → hazard_enricher
(
    _t=$(date +%s)
    python3 scripts/geocode_cross_validator.py "$WORK_DIR/track_hz.json" --fix || true
    python3 hazard_enricher.py \
        --input "$WORK_DIR/track_hz.json" \
        --output "$WORK_DIR/track_hz.json" || true
    echo "[TIMING] geocode_hazard: $(( ($(date +%s) - _t) ))s" >&2
) &
HZ_PID=$!

# Track C: commute_enricher
(
    _t=$(date +%s)
    python3 commute_enricher.py \
        --input "$WORK_DIR/track_cm.json" \
        --output "$WORK_DIR/track_cm.json" || true
    echo "[TIMING] commute: $(( ($(date +%s) - _t) ))s" >&2
) &
CM_PID=$!

# Track D: reinfolib_enricher
(
    _t=$(date +%s)
    if [ -f "data/reinfolib_prices.json" ]; then
        python3 reinfolib_enricher.py \
            --input "$WORK_DIR/track_ri.json" \
            --output "$WORK_DIR/track_ri.json" || true
    else
        echo "reinfolib: キャッシュなし（スキップ）" >&2
    fi
    echo "[TIMING] reinfolib: $(( ($(date +%s) - _t) ))s" >&2
) &
RI_PID=$!

# Track E: estat_enricher
(
    _t=$(date +%s)
    if [ -f "data/estat_population.json" ]; then
        python3 estat_enricher.py \
            --input "$WORK_DIR/track_es.json" \
            --output "$WORK_DIR/track_es.json" || true
    else
        echo "estat: キャッシュなし（スキップ）" >&2
    fi
    echo "[TIMING] estat: $(( ($(date +%s) - _t) ))s" >&2
) &
ES_PID=$!

echo "全 enricher 起動完了 (PID: PREP=$PREP_PID SS=$SS_PID HZ=$HZ_PID CM=$CM_PID RI=$RI_PID ES=$ES_PID)" >&2

# 全プロセス完了待ち (各プロセスの exit code は無視)
for pid in $PREP_PID $SS_PID $HZ_PID $CM_PID $RI_PID $ES_PID; do
    wait "$pid" 2>/dev/null || true
done

echo "[TIMING] phase2_parallel: $(( ($(date +%s) - _t_phase2) ))s" >&2

# ──────────────────────────── Phase 3: マージ + アップロード ────────────────────────────

echo "--- Phase 3: マージ + アップロード ---" >&2
_t=$(date +%s)

python3 scripts/merge_enrichments.py \
    --base "$INPUT" \
    --enriched \
        "$WORK_DIR/track_uc.json" \
        "$WORK_DIR/track_ss.json" \
        "$WORK_DIR/track_hz.json" \
        "$WORK_DIR/track_cm.json" \
        "$WORK_DIR/track_ri.json" \
        "$WORK_DIR/track_es.json" \
    --output "$INPUT"

echo "[TIMING] merge: $(( ($(date +%s) - _t) ))s" >&2

# upload_floor_plans
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
    _t=$(date +%s)
    python3 upload_floor_plans.py \
        --input "$INPUT" \
        --output "$INPUT" || echo "upload_floor_plans 失敗（続行）" >&2
    echo "[TIMING] upload_floor_plans: $(( ($(date +%s) - _t) ))s" >&2
else
    echo "upload_floor_plans: FIREBASE_SERVICE_ACCOUNT 未設定のためスキップ" >&2
fi

# JSON バリデーション
if ! python3 -c "import json; json.load(open('$INPUT'))" 2>/dev/null; then
    echo "警告: 出力 JSON が破損しています。Phase 1 の結果にフォールバック。" >&2
fi

# クリーンアップ
rm -rf "$WORK_DIR"

echo "=== Enrich ${PROPERTY_TYPE} 完了 ===" >&2
