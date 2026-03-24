import AppKit
import Security

/// 보안 관련 유틸리티
enum SecurityManager {
    // MARK: - Keychain (세션 토큰 저장)

    private static let serviceName = "com.bwautofill.session"
    private static let accountName = "bitwarden-session"

    /// 세션 토큰을 Keychain에 저장
    static func saveSessionToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        deleteSessionToken()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Keychain에서 세션 토큰 로드
    static func loadSessionToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Keychain에서 세션 토큰 삭제
    @discardableResult
    static func deleteSessionToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - 클립보드 보안

    /// 클립보드에 텍스트를 설정하고 지정 시간 후 자동 삭제
    /// Concealed 타입을 사용하여 클립보드 히스토리 도구에 비밀번호가 기록되지 않도록 함
    static func secureClipboard(text: String, clearAfter seconds: TimeInterval = 10, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if concealed {
            // "org.nspasteboard.ConcealedType" — 클립보드 매니저가 이 타입을 인식하면 히스토리에 저장하지 않음
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            pasteboard.setString("", forType: concealedType)
        }
        pasteboard.setString(text, forType: .string)

        // 자동 클리어를 위한 변경 카운터 저장
        let changeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            // changeCount가 동일한 경우에만 클리어 (사용자가 다른 것을 복사했으면 건드리지 않음)
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
            }
        }
    }

    // MARK: - Accessibility 권한 확인

    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// 손쉬운 사용 권한 요청 (시스템 다이얼로그 표시)
    static func requestAccessibilityPermission() {
        // takeUnretainedValue: 소유권을 가져가지 않음 (시스템 소유 상수)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
