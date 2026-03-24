#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/dist"
APP_NAME="BW Autofill"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "=== BW Autofill 빌드 시작 ==="

# 기존 빌드 정리
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Release 빌드
echo "[1/3] Swift 빌드 (Release)..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

BINARY="$PROJECT_DIR/.build/release/BWAutofill"
if [ ! -f "$BINARY" ]; then
    echo "빌드 실패: 바이너리를 찾을 수 없습니다"
    exit 1
fi

# .app 번들 생성
echo "[2/3] .app 번들 생성..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/BWAutofill"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# 간단한 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 아이콘이 있으면 복사
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

echo "[3/3] 빌드 완료!"
echo ""
echo "  앱 경로: $APP_BUNDLE"
echo "  설치: 위 .app 파일을 /Applications 폴더로 복사하세요"
echo ""
echo "  빠른 설치:"
echo "    cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "  실행 후 시스템 설정 > 개인정보 보호 > 손쉬운 사용에서 앱을 허용하세요."
