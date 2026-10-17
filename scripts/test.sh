#!/bin/bash
# 테스트 실행 래퍼
# Usage: scripts/test.sh [swift test 추가 인자...]
#
# Command Line Tools(Xcode 미설치) 환경에서는 swiftbuild가 Swift Testing 매크로 플러그인
# (TestingMacros)을 컴파일러에 전달하지 못해 "plugin for module 'TestingMacros' not found"
# 로 빌드가 실패하는 경우가 있어, 플러그인을 직접 지정한다. Xcode 환경에서는 그대로 실행.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

EXTRA_FLAGS=()
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
TESTING_PLUGIN="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* ]] && [ -f "$TESTING_PLUGIN" ]; then
    EXTRA_FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi

swift test "${EXTRA_FLAGS[@]}" "$@"
