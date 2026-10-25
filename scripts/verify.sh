#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLEAN=1
RUN_XCODE=1
for arg in "$@"; do
    case "$arg" in
        --no-clean) CLEAN=0 ;;
        --skip-xcode) RUN_XCODE=0 ;;
        -h|--help)
            echo "usage: $0 [--no-clean] [--skip-xcode]"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macdro-verify.XXXXXX")"
SCRATCH="$ROOT/.build/verify-spm"
trap 'status=$?; if [[ $status -ne 0 ]]; then echo "Verification failed. Logs: $LOG_DIR" >&2; fi' EXIT

echo "==> SwiftPM build"
if [[ "$CLEAN" == "1" ]]; then
    rm -rf "$SCRATCH"
fi
set -o pipefail
swift build --scratch-path "$SCRATCH" --build-tests 2>&1 | tee "$LOG_DIR/build.log"

if grep -E '(^|[[:space:]])warning:' "$LOG_DIR/build.log" >/dev/null; then
    echo "error: compiler warnings detected" >&2
    grep -E '(^|[[:space:]])warning:' "$LOG_DIR/build.log" >&2
    exit 1
fi

echo "==> Tests"
swift test --scratch-path "$SCRATCH" 2>&1 | tee "$LOG_DIR/test.log"

echo "==> Self-test"
swift run --scratch-path "$SCRATCH" MacdroSelfTest 2>&1 | tee "$LOG_DIR/self-test.log"

echo "==> Audit"
swift run --scratch-path "$SCRATCH" MacdroAudit test 2>&1 | tee "$LOG_DIR/audit.log"

if [[ "$RUN_XCODE" == "1" ]]; then
    echo "==> XcodeGen"
    command -v xcodegen >/dev/null
    xcodegen generate

    echo "==> Xcode build"
    xcodebuild \
        -project Macdro.xcodeproj \
        -scheme Macdro \
        -configuration Debug \
        -derivedDataPath .build/xcode \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | tee "$LOG_DIR/xcodebuild.log"

    APP="$ROOT/.build/xcode/Build/Products/Debug/Macdro.app"
    test -d "$APP/Contents/Resources/Macdro_MacdroKit.bundle"
fi

echo "Verification passed. Logs: $LOG_DIR"
