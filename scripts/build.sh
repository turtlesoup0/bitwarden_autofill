#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/dist"
APP_NAME="BW Autofill"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# 매 빌드마다 바뀌는 ad-hoc 서명 CDHash 때문에 손쉬운 사용 권한이 매번 재요청되는
# 문제를 피하기 위해, 로컬 Keychain에 한 번 생성한 자체 서명 인증서로 서명.
CODESIGN_IDENTITY="BW Autofill Self-Signed"

echo "=== BW Autofill 빌드 시작 ==="

# 기존 빌드 정리
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Spotlight/LaunchServices에서 빌드 산출물을 제외 (검색 결과 중복 방지)
touch "$BUILD_DIR/.metadata_never_index"

# Release 빌드
echo "[1/4] Swift 빌드 (Release)..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

BINARY="$PROJECT_DIR/.build/release/BWAutofill"
if [ ! -f "$BINARY" ]; then
    echo "빌드 실패: 바이너리를 찾을 수 없습니다"
    exit 1
fi

# .app 번들 생성
echo "[2/4] .app 번들 생성..."
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

# 자체 서명 인증서 준비
# (Gatekeeper 신뢰가 아닌 "designated requirement 고정"이 목표 — codesign 서명만 되면 충분)
echo "[3/4] 코드서명 인증서 확인..."
# grep 대상은 -v(valid) 없이 — 자체 서명은 CSSMERR_TP_NOT_TRUSTED 표시되지만 codesign은 사용 가능
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$CODESIGN_IDENTITY\""; then
    echo "  → 인증서 없음. 자동 생성 중 (최초 1회)..."

    TMPDIR_CERT="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_CERT"' EXIT

    cat > "$TMPDIR_CERT/cert.conf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_ext

[ req_distinguished_name ]
CN = $CODESIGN_IDENTITY

[ v3_ext ]
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
EOF

    # 10년짜리 RSA 2048 자체 서명 인증서
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMPDIR_CERT/key.pem" \
        -out "$TMPDIR_CERT/cert.pem" \
        -days 3650 \
        -config "$TMPDIR_CERT/cert.conf" \
        -extensions v3_ext 2>/dev/null

    # PKCS#12로 묶기. OpenSSL 3.x는 빈 비밀번호를 macOS Security가 읽을 수 없는 형태로 저장하므로
    # 임시 비밀번호 + legacy 알고리즘 사용.
    P12_PASS="bwautofill-$(date +%s)-$$"
    openssl pkcs12 -export \
        -inkey "$TMPDIR_CERT/key.pem" \
        -in "$TMPDIR_CERT/cert.pem" \
        -out "$TMPDIR_CERT/cert.p12" \
        -name "$CODESIGN_IDENTITY" \
        -passout "pass:$P12_PASS" \
        -legacy \
        -keypbe PBE-SHA1-3DES \
        -certpbe PBE-SHA1-3DES \
        -macalg SHA1 2>/dev/null

    # login.keychain에 import — codesign이 암호 입력 없이 사용 가능하도록 -A + -T 허용
    LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    if [ ! -f "$LOGIN_KEYCHAIN" ]; then
        LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain"
    fi

    if security import "$TMPDIR_CERT/cert.p12" \
        -k "$LOGIN_KEYCHAIN" \
        -P "$P12_PASS" \
        -A \
        -T /usr/bin/codesign \
        -T /usr/bin/security >/dev/null 2>&1; then
        echo "  ✅ 자체 서명 인증서 생성 및 Keychain 등록 완료"
    else
        echo "  ⚠️  인증서 등록 실패 — ad-hoc 서명으로 폴백 (권한이 빌드마다 재요청될 수 있음)"
        CODESIGN_IDENTITY="-"
    fi
else
    echo "  ✅ 기존 인증서 사용: $CODESIGN_IDENTITY"
fi

# 번들 서명
echo "[4/4] 코드서명..."
codesign --force --sign "$CODESIGN_IDENTITY" \
    --timestamp=none \
    "$APP_BUNDLE/Contents/MacOS/BWAutofill" 2>&1 | grep -v "replacing existing signature" || true

codesign --force --sign "$CODESIGN_IDENTITY" \
    --timestamp=none \
    "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true

# 서명 검증 (designated requirement가 인증서 지문에 고정됐는지)
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    REQ=$(codesign -d --requirements - "$APP_BUNDLE" 2>&1 | grep "designated =>" || true)
    if echo "$REQ" | grep -q "certificate leaf"; then
        echo "  ✅ 서명 검증 통과 (designated requirement 고정됨)"
    else
        echo "  ⚠️  서명은 됐지만 인증서 지문이 requirement에 반영되지 않았습니다"
    fi
fi

echo ""
echo "=== 빌드 완료 ==="
echo ""
echo "  앱 경로: $APP_BUNDLE"
echo ""
echo "  설치 (권장, admin 불필요):"
echo "    mkdir -p ~/Applications && cp -R \"$APP_BUNDLE\" ~/Applications/"
echo ""
echo "  실행 후 시스템 설정 > 개인정보 보호 > 손쉬운 사용에서 앱을 허용하세요."
echo "  (자체 서명 인증서로 서명되므로 한 번 허용하면 이후 재빌드/업데이트에서 유지됩니다)"
