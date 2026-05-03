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
TRACKS="all"
while [[ $# -gt 0 ]]; do
    case $1 in
        --property-type) PROPERTY_TYPE="$2"; shift 2 ;;
        --tracks) TRACKS="$2"; shift 2 ;;
        *) echo "不明な引数: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PROPERTY_TYPE" ]; then
    echo "使い方: run_enrich.sh --property-type chuko|shinchiku [--tracks core|sumai|mansion|all]" >&2
    exit 1
fi

echo "=== Enrich: ${PROPERTY_TYPE} (tracks: ${TRACKS}) ===" >&2
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

# ──────────────────────────── Phase 2: enricher 実行 ────────────────────────────

echo "--- Phase 2: enricher 実行 (tracks: ${TRACKS}) ---" >&2
_t_phase2=$(date +%s)

PIDS=""
ENRICHED_FILES=""

# ── core トラック ──
if [ "$TRACKS" = "all" ] || [ "$TRACKS" = "core" ]; then

    # Track PREP: build_units_cache → merge_detail_cache
    cp "$INPUT" "$WORK_DIR/track_uc.json"
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
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_uc.json"

    # Track B: geocode_cross_validator → hazard_enricher
    cp "$INPUT" "$WORK_DIR/track_hz.json"
    (
        _t=$(date +%s)
        python3 scripts/geocode_cross_validator.py "$WORK_DIR/track_hz.json" --fix || true
        python3 hazard_enricher.py \
            --input "$WORK_DIR/track_hz.json" \
            --output "$WORK_DIR/track_hz.json" || true
        echo "[TIMING] geocode_hazard: $(( ($(date +%s) - _t) ))s" >&2
    ) &
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_hz.json"

    # Track C: commute_enricher + commute_station_master_enricher
    cp "$INPUT" "$WORK_DIR/track_cm.json"
    (
        _t=$(date +%s)
        python3 commute_enricher.py \
            --input "$WORK_DIR/track_cm.json" \
            --output "$WORK_DIR/track_cm.json" || true
        python3 commute_station_master_enricher.py \
            --input "$WORK_DIR/track_cm.json" \
            --output "$WORK_DIR/track_cm.json" \
            --stations-csv ../configs/commute/stations.csv \
            --station-master-csv ../data/commute/station_master_template.csv \
            --offices-yaml ../configs/commute/offices.yaml || true
        echo "[TIMING] commute: $(( ($(date +%s) - _t) ))s" >&2
    ) &
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_cm.json"

    # Track D: reinfolib_enricher
    cp "$INPUT" "$WORK_DIR/track_ri.json"
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
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_ri.json"

    # Track E: estat_enricher
    cp "$INPUT" "$WORK_DIR/track_es.json"
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
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_es.json"

    # Track F: commute_gmaps_enricher
    cp "$INPUT" "$WORK_DIR/track_gm.json"
    (
        _t=$(date +%s)
        if [ -n "$BROWSER_FLAG" ]; then
            python3 commute_gmaps_enricher.py \
                --input "$WORK_DIR/track_gm.json" \
                --output "$WORK_DIR/track_gm.json" \
                --workers 2 || true
        else
            echo "commute_gmaps: Playwright 未検出（スキップ）" >&2
        fi
        echo "[TIMING] commute_gmaps: $(( ($(date +%s) - _t) ))s" >&2
    ) &
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_gm.json"

fi

# ── sumai トラック ──
if [ "$TRACKS" = "all" ] || [ "$TRACKS" = "sumai" ]; then

    cp "$INPUT" "$WORK_DIR/track_ss.json"
    (
        _t=$(date +%s)
        python3 sumai_surfin_enricher.py \
            --input "$WORK_DIR/track_ss.json" \
            --output "$WORK_DIR/track_ss.json" \
            --property-type "$PROPERTY_TYPE" \
            --max-time 40 \
            $BROWSER_FLAG || true
        echo "[TIMING] sumai_surfin: $(( ($(date +%s) - _t) ))s" >&2
    ) &
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_ss.json"

fi

# ── mansion トラック ──
if [ "$TRACKS" = "all" ] || [ "$TRACKS" = "mansion" ]; then

    cp "$INPUT" "$WORK_DIR/track_mr.json"
    (
        _t=$(date +%s)
        if [ "$PROPERTY_TYPE" = "chuko" ]; then
            python3 mansion_review_scraper.py \
                --input "$WORK_DIR/track_mr.json" \
                --output "$WORK_DIR/track_mr.json" \
                --max-time 40 || true
        else
            echo "mansion_review: 新築はスキップ" >&2
        fi
        echo "[TIMING] mansion_review: $(( ($(date +%s) - _t) ))s" >&2
    ) &
    PIDS="$PIDS $!"
    ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_mr.json"

fi

# ── claude トラック ──
if [ "$TRACKS" = "all" ] || [ "$TRACKS" = "claude" ]; then

    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        # Track CL1: claude_dedup + claude_text_enricher
        cp "$INPUT" "$WORK_DIR/track_cl.json"
        (
            _t=$(date +%s)
            python3 claude_dedup.py \
                --input "$WORK_DIR/track_cl.json" \
                --output "$WORK_DIR/track_cl.json" || true
            python3 claude_text_enricher.py \
                --input "$WORK_DIR/track_cl.json" \
                --output "$WORK_DIR/track_cl.json" || true
            echo "[TIMING] claude_dedup+text: $(( ($(date +%s) - _t) ))s" >&2
        ) &
        PIDS="$PIDS $!"
        ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_cl.json"

        # Track CL2: claude_image_analyzer (独立、画像処理は重いため分離)
        cp "$INPUT" "$WORK_DIR/track_ci.json"
        (
            _t=$(date +%s)
            python3 claude_image_analyzer.py \
                --input "$WORK_DIR/track_ci.json" \
                --output "$WORK_DIR/track_ci.json" || true
            echo "[TIMING] claude_image: $(( ($(date +%s) - _t) ))s" >&2
        ) &
        PIDS="$PIDS $!"
        ENRICHED_FILES="$ENRICHED_FILES $WORK_DIR/track_ci.json"
    else
        echo "claude: ANTHROPIC_API_KEY 未設定（スキップ）" >&2
    fi

fi

echo "enricher 起動完了 (PIDs:$PIDS)" >&2

# 全プロセス完了待ち (各プロセスの exit code は無視)
for pid in $PIDS; do
    wait "$pid" 2>/dev/null || true
done

echo "[TIMING] phase2_parallel: $(( ($(date +%s) - _t_phase2) ))s" >&2

# ──────────────────────────── Phase 3: マージ ────────────────────────────

echo "--- Phase 3: マージ ---" >&2
_t=$(date +%s)

if [ -n "$ENRICHED_FILES" ]; then
    python3 scripts/merge_enrichments.py \
        --base "$INPUT" \
        --enriched $ENRICHED_FILES \
        --output "$INPUT"
else
    echo "実行されたトラックがありません" >&2
fi

echo "[TIMING] merge: $(( ($(date +%s) - _t) ))s" >&2

# upload_floor_plans は finalize ジョブに移動済み（enrich の所要時間を短縮し、
# アーティファクト保存の確実性を向上させるため）

# JSON バリデーション
if ! python3 -c "import json; json.load(open('$INPUT'))" 2>/dev/null; then
    echo "警告: 出力 JSON が破損しています。Phase 1 の結果にフォールバック。" >&2
fi

# クリーンアップ
rm -rf "$WORK_DIR"

echo "=== Enrich ${PROPERTY_TYPE} 完了 ===" >&2
