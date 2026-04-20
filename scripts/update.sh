#!/bin/bash
# BW Autofill 업데이트 스크립트
# Usage: update.sh <repo-path> [current-app-bundle-path]
#
# - git pull --ff-only
# - swift build (scripts/build.sh)
# - 실행 중인 앱 종료
# - 기존 위치(.app)에 덮어쓰기. 기존 위치 없으면 ~/Applications로 설치
# - 새 앱 실행
set -e

REPO_DIR="$1"
CURRENT_APP="$2"
APP_NAME="BW Autofill.app"

if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR/.git" ]; then
    echo "❌ 유효한 git 저장소 경로가 필요합니다"
    echo "Usage: $0 <repo-path> [current-app-bundle-path]"
    exit 1
fi

# 설치 대상: 현재 실행 중인 앱 위치 우선, 아니면 ~/Applications
if [ -n "$CURRENT_APP" ] && [ -d "$CURRENT_APP" ]; then
    TARGET_APP="$CURRENT_APP"
else
    TARGET_APP="$HOME/Applications/$APP_NAME"
fi

cd "$REPO_DIR"

echo ""
echo "📥 git pull (ff-only)..."
git pull --ff-only

echo ""
echo "🔨 빌드 중..."
./scripts/build.sh

if [ ! -d "$REPO_DIR/dist/$APP_NAME" ]; then
    echo "❌ 빌드 결과물을 찾을 수 없습니다: $REPO_DIR/dist/$APP_NAME"
    exit 1
fi

echo ""
echo "⏹  기존 앱 종료 대기..."
osascript -e 'quit app "BW Autofill"' 2>/dev/null || true

# 프로세스 완전히 종료될 때까지 대기 (최대 5초)
TIMEOUT=50
while pgrep -x "BWAutofill" > /dev/null; do
    sleep 0.1
    TIMEOUT=$((TIMEOUT - 1))
    if [ "$TIMEOUT" -le 0 ]; then
        echo "⚠️  강제 종료..."
        pkill -x "BWAutofill" || true
        sleep 0.5
        break
    fi
done

echo ""
echo "📦 앱 교체: $TARGET_APP"
TARGET_DIR="$(dirname "$TARGET_APP")"
mkdir -p "$TARGET_DIR"

# /Applications 등 admin 권한 필요할 수 있는 경로는 쓰기 가능 여부 미리 확인
if [ -d "$TARGET_APP" ] && [ ! -w "$TARGET_DIR" ]; then
    echo "❌ 쓰기 권한이 없습니다: $TARGET_DIR"
    echo "   ~/Applications 로 이동 설치하는 것을 권장합니다."
    exit 1
fi

rm -rf "$TARGET_APP"
cp -R "$REPO_DIR/dist/$APP_NAME" "$TARGET_APP"

# LaunchServices에 번들 재등록 (방금 복사된 위치의 -600 에러 방지)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi

echo ""
echo "🚀 새 앱 실행..."
# 첫 open은 LaunchServices 인덱싱 지연으로 -600을 반환할 수 있음 → 재시도
if ! open "$TARGET_APP" 2>/dev/null; then
    sleep 1
    open "$TARGET_APP"
fi

echo ""
echo "✅ 업데이트 완료"
echo ""
echo "이 Terminal 창은 닫으셔도 됩니다."
