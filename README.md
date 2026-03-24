# BW Autofill

macOS 네이티브 Bitwarden 자동 입력 도구.
1Password의 `Cmd+\` Quick Access 경험을 Bitwarden에서 구현합니다.

## 사전 요구사항

- macOS 13 (Ventura) 이상
- Bitwarden CLI (`bw`)

```bash
brew install bitwarden-cli
```

## 설치

### 빌드 스크립트 (권장)

```bash
git clone https://github.com/turtlesoup0/bitwarden_autofill.git
cd bitwarden_autofill
./scripts/build.sh
```

빌드 완료 후 `dist/BW Autofill.app`이 생성됩니다.

```bash
# /Applications에 설치
cp -r "dist/BW Autofill.app" /Applications/
```

### 직접 빌드

```bash
swift build -c release
# 바이너리: .build/release/BWAutofill
```

## 사용 방법

1. 앱 실행 → 메뉴바에 열쇠 아이콘 표시
2. 최초 실행 시 메뉴에서 "Bitwarden 로그인" → 이메일 + 마스터 비밀번호 입력
3. 로그인이 필요한 앱/브라우저에서 `Cmd+\` 입력
4. 검색 패널에서 항목 선택 (Enter로 펼치기)
5. ID 또는 Password 클릭 → 클립보드 복사 → 붙여넣기

### 검색 패널 단축키

| 키 | 동작 |
|----|------|
| ↑ ↓ | 항목 이동 |
| Enter | 항목 펼치기/접기 |
| Cmd+R | 새로고침 (Bitwarden 동기화) |
| ESC | 닫기 |

### 앱 컨텍스트 자동 감지

Slack에서 `Cmd+\`를 누르면 자동으로 "slack" 검색어로 필터링됩니다.
지원 앱: Slack, Spotify, Figma, Linear, Notion, GitHub, Teams, Discord, Zoom 등

## 권한 설정

앱 최초 실행 시 **손쉬운 사용** 권한이 필요합니다:

**시스템 설정 → 개인 정보 보호 및 보안 → 손쉬운 사용** → 앱 허용

권한 허용 후 앱 재시작이 필요합니다.

## 보안

- 비밀번호를 프로세스 인자로 노출하지 않음 (stdin 파이프 전달)
- `bw serve`는 `127.0.0.1`에만 바인딩 (외부 접근 차단)
- 세션 토큰은 macOS Keychain에 암호화 저장 (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- 비밀번호 클립보드 복사 시 `org.nspasteboard.ConcealedType` 적용 (클립보드 히스토리 제외)
- 클립보드 10초 후 자동 클리어
- 환경변수 최소화 (PATH/HOME/BW_SESSION만 전달)

## 동작 원리

```
            Cmd+\
              │
      HotkeyManager (Carbon)
              │
         AppDelegate
              │
   ┌──────────┼──────────┐
   ▼          ▼          ▼
BitwardenAPI SearchPanel AppContext
(bw serve    (NSPanel    Detector
 REST API)   + SwiftUI)
              │
              ▼ (항목 선택)
         클립보드 복사
     (Concealed + 10s 자동삭제)
```

## 프로젝트 구조

```
bitwarden_autofill/
├── Package.swift
├── Info.plist
├── scripts/build.sh          # .app 번들 빌드 스크립트
└── Sources/BWAutofill/
    ├── App.swift              # SwiftUI 앱 진입점
    ├── AppDelegate.swift      # 메뉴바 + 이벤트 오케스트레이션
    ├── HotkeyManager.swift    # Cmd+\ 글로벌 단축키 (Carbon)
    ├── BitwardenAPI.swift     # bw serve REST API 클라이언트 (actor)
    ├── AppContextDetector.swift # 현재 활성 앱 감지
    ├── SearchPanel.swift      # Floating 검색 UI (NSPanel + SwiftUI)
    └── SecurityManager.swift  # Keychain + 클립보드 보안
```
