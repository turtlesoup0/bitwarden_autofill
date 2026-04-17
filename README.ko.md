# BW Autofill

macOS 네이티브 Bitwarden 자동 입력 도구.
1Password의 `Cmd+\` Quick Access 경험을 Bitwarden에서 구현합니다.

*English: [README.md](README.md)*

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

### 최초 설정

1. **터미널에서 로그인** (2FA·대화형 프롬프트 이슈를 피하기 위해 로그인은 앱이 아닌 CLI로 수행)
   ```bash
   bw login
   ```
2. 앱 실행 → 메뉴바에 열쇠 아이콘 표시
3. 메뉴 → **Vault 잠금해제** (`⌘U`) → 마스터 비밀번호 입력
   - 이후 세션 토큰은 Keychain에 암호화 저장되어 **`Cmd+\` 누를 때 자동 복원**

### 평상시 사용

1. 로그인이 필요한 앱/브라우저에서 `Cmd+\` 입력
2. 검색 패널에서 항목 선택 (Enter로 펼치기)
3. ID 또는 Password 클릭 → 클립보드 복사 → 붙여넣기

### 검색 패널 단축키

| 키 | 동작 |
|----|------|
| ↑ ↓ | 항목 이동 |
| Enter | 항목 펼치기/접기 |
| Cmd+R | 새로고침 (Bitwarden 동기화) |
| ESC | 닫기 |

### 앱 컨텍스트 자동 감지

Slack에서 `Cmd+\`를 누르면 자동으로 "slack" 검색어로 필터링됩니다.
지원 앱: Slack, Spotify, Figma, Linear, Notion, GitHub, Teams, Discord, Zoom 등.

### 검색 결과 랭킹

매칭 품질 점수에 따라 정렬됩니다:

| 매칭 유형 | 점수 |
|---|---|
| 이름 정확 일치 | 1000 |
| 이름 접두사 일치 | 500 |
| 이름 부분 일치 | 300 |
| username 또는 URL만 포함 | 100 |

동점 시 원본 순서 유지 (Swift stable sort).

### 오류 표시

검색 패널에 연결/파싱 문제를 구분해 표시합니다:

- **Vault 연결 안 됨 — 잠금 해제 필요**: `bw serve` 미기동
- **bw serve 응답 없음**: 서버는 떠 있으나 통신 실패
- **응답 해석 실패**: JSON 파싱 오류

모든 오류는 `⌘R`로 재시도 가능합니다.

### 핫키 등록 실패

다른 앱이 `⌘\`를 이미 점유한 경우, 메뉴바 아이콘이 `🔑̶`(key.slash)로 바뀌고 메뉴에 경고가 표시됩니다.

## 권한 설정

앱 최초 실행 시 **손쉬운 사용** 권한이 필요합니다:

**시스템 설정 → 개인 정보 보호 및 보안 → 손쉬운 사용** → 앱 허용

권한 허용 후 앱 재시작이 필요합니다.

## 보안

- 비밀번호를 프로세스 인자로 노출하지 않음 (`BW_PASSWORD` 환경변수로 전달 — `ps` 명령어에 보이지 않음)
- `bw serve`는 `127.0.0.1`에만 바인딩 (외부 접근 차단)
- 세션 토큰은 macOS Keychain에 암호화 저장 (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- 비밀번호 클립보드 복사 시 `org.nspasteboard.ConcealedType` 적용 (클립보드 히스토리 제외)
- 클립보드 10초 후 자동 클리어
- **앱 종료 시에도 클립보드에 우리가 복사한 내용이 남아 있으면 즉시 클리어** (`changeCount` 매칭)
- 환경변수 최소화 (`PATH` / `HOME` / `BW_SESSION` / 필요 시 `BW_PASSWORD`만 전달)

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
    (Concealed + 10s 자동삭제
     + 앱 종료 시 즉시 클리어)
```

### 동시성 모델

- `BitwardenAPI`는 `actor` — 내부 상태(`serveProcess`, `cachedItems`, `sessionToken`) 직렬화
- 모든 HTTP 호출은 `URLSession.data(for:)` async API 사용 (actor 스레드 블로킹 없음)
- CLI 프로세스는 `Process.terminationHandler` + `withCheckedContinuation`으로 대기
- 앱 종료는 `applicationShouldTerminate` + `.terminateLater` 패턴 (UI 프리즈 방지)

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

## 개발 메모

### 왜 로그인은 터미널에서 하나요?

`bw login`은 2FA 입력을 `inquirer.js` 대화형 프롬프트로 요구하는데, macOS 앱에서 이 프롬프트를 안정적으로 주입하기 어렵고 `ERR_USE_AFTER_CLOSE` 문제가 발생합니다. `bw unlock`은 `--passwordenv` 플래그로 비대화형 처리가 가능하므로 앱에서 처리합니다.

### 왜 `--passwordenv` 대신 stdin을 쓰지 않나요?

stdin 주입은 일부 `bw` 버전에서 파이프가 끊어지는 문제가 있어, 공식 지원되는 `BW_PASSWORD` 환경변수 방식이 더 안정적입니다.
