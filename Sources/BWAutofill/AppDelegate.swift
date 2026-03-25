import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotkeyManager: HotkeyManager?
    private var bwAPI: BitwardenAPI?
    private var searchPanelController: SearchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()

        let api = BitwardenAPI()
        bwAPI = api
        searchPanelController = SearchPanelController(bitwardenAPI: api)
        hotkeyManager = HotkeyManager { [weak self] in
            self?.handleHotkey()
        }
        hotkeyManager?.register()

        if !SecurityManager.checkAccessibilityPermission() {
            SecurityManager.requestAccessibilityPermission()
        }

        // Keychain에서 세션 복원 → bw serve 자동 시작
        if let savedToken = SecurityManager.loadSessionToken() {
            Task {
                await api.restoreSession(token: savedToken)
                let _ = await api.startServe(sessionToken: savedToken)
                await updateStatus()
            }
        }

        #if DEBUG
        print("[BWAutofill] 앱 시작됨 - Cmd+\\ 로 활성화")
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 동기적으로 bw serve 프로세스 종료 보장
        if let api = bwAPI {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await api.stopServe()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "BW Autofill")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "BW Autofill", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let statusMenuItem = NSMenuItem(title: "상태: 초기화 중...", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Bitwarden 로그인", action: #selector(loginVaultMenu), keyEquivalent: "i")
        loginItem.target = self
        menu.addItem(loginItem)

        let unlockItem = NSMenuItem(title: "Vault 잠금해제", action: #selector(unlockVaultMenu), keyEquivalent: "u")
        unlockItem.target = self
        menu.addItem(unlockItem)

        menu.addItem(NSMenuItem.separator())

        let lockItem = NSMenuItem(title: "Vault 잠금", action: #selector(lockVault), keyEquivalent: "l")
        lockItem.target = self
        menu.addItem(lockItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        Task { await updateStatus() }
    }

    private func updateStatus() async {
        guard let api = bwAPI else { return }
        let status = await api.getStatus()
        if let item = statusItem?.menu?.item(withTag: 100) {
            item.title = "상태: \(status.displayText)"
        }
    }

    // MARK: - 로그인

    @objc private func loginVaultMenu() {
        Task { await loginVault() }
    }

    private func loginVault() async {
        guard let api = bwAPI else { return }

        // 이메일, 비밀번호, OTP를 한 번에 입력받음 (CLI가 2FA를 대화형으로 요청 시 crash 방지)
        guard let credentials = promptLogin() else { return }

        let result: BitwardenAPI.LoginResult
        if let code = credentials.otpCode, !code.isEmpty {
            result = await api.login(email: credentials.email, password: credentials.password, twoFactorCode: code)
        } else {
            result = await api.login(email: credentials.email, password: credentials.password)
        }

        switch result {
        case .success(let token):
            let _ = await api.startServe(sessionToken: token)
            showSearchPanel()

        case .requires2FA:
            // OTP 없이 시도했다가 2FA 필요 → OTP만 추가 입력
            guard let code = promptText(
                message: "2단계 인증",
                info: "인증 앱의 6자리 코드를 입력하세요",
                placeholder: "000000",
                secure: false
            ), !code.isEmpty else { return }

            let twoFAResult = await api.login(
                email: credentials.email, password: credentials.password, twoFactorCode: code
            )
            if case .success(let token) = twoFAResult {
                let _ = await api.startServe(sessionToken: token)
                showSearchPanel()
            } else {
                showAlert(title: "로그인 실패", message: "2FA 코드가 올바르지 않습니다.")
            }

        case .failed(let message):
            showAlert(title: "로그인 실패", message: message)
        }

        await updateStatus()
    }

    // MARK: - 잠금 해제

    @objc private func unlockVaultMenu() {
        Task {
            guard let api = bwAPI else { return }
            if let token = await unlockVault() {
                let _ = await api.startServe(sessionToken: token)
                showSearchPanel()
            }
        }
    }

    private func unlockVault() async -> String? {
        guard let api = bwAPI else { return nil }

        guard let password = promptText(
            message: "Bitwarden 마스터 비밀번호를 입력하세요",
            info: nil,
            placeholder: "",
            secure: true
        ), !password.isEmpty else { return nil }

        let token = await api.unlock(password: password)
        if token == nil {
            showAlert(title: "잠금 해제 실패", message: "마스터 비밀번호가 올바르지 않습니다.")
        }
        await updateStatus()
        return token
    }

    @objc private func lockVault() {
        Task {
            guard let api = bwAPI else { return }
            await api.lock()
            await updateStatus()
        }
    }

    @objc private func quitApp() {
        if let api = bwAPI {
            Task { await api.stopServe() }
        }
        NSApp.terminate(nil)
    }

    // MARK: - 핫키 핸들러

    private func handleHotkey() {
        guard let api = bwAPI else { return }

        Task {
            let isServing = await api.isServing

            if isServing {
                let status = await api.getStatus()
                if status == .unlocked {
                    showSearchPanel()
                    return
                }
            }

            // serve가 없으면 저장된 토큰으로 시작 시도
            if !isServing, let savedToken = SecurityManager.loadSessionToken() {
                let started = await api.startServe(sessionToken: savedToken)
                if started {
                    let status = await api.getStatus()
                    if status == .unlocked {
                        showSearchPanel()
                        return
                    }
                }
            }

            // 토큰이 없거나 만료된 경우
            let status = await api.getStatus()
            switch status {
            case .unauthenticated:
                await loginVault()

            case .locked:
                if let token = await unlockVault() {
                    let _ = await api.startServe(sessionToken: token)
                    showSearchPanel()
                }

            case .unlocked:
                if let token = SecurityManager.loadSessionToken() {
                    let _ = await api.startServe(sessionToken: token)
                }
                showSearchPanel()
            }
        }
    }

    // MARK: - 검색 패널

    private func showSearchPanel() {
        searchPanelController?.show()
    }

    // MARK: - UI 헬퍼

    /// 로그인 자격 증명 (이메일 + 비밀번호 + OTP를 한 화면에서)
    private struct LoginCredentials {
        let email: String
        let password: String
        let otpCode: String?
    }

    private func promptLogin() -> LoginCredentials? {
        let alert = NSAlert()
        alert.messageText = "Bitwarden 로그인"
        alert.informativeText = "2FA를 사용하는 경우 OTP도 입력하세요"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "로그인")
        alert.addButton(withTitle: "취소")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))

        let emailLabel = NSTextField(labelWithString: "이메일")
        emailLabel.frame = NSRect(x: 0, y: 76, width: 60, height: 20)
        emailLabel.font = .systemFont(ofSize: 12)
        let emailField = NSTextField(frame: NSRect(x: 65, y: 76, width: 215, height: 22))
        emailField.placeholderString = "email@example.com"

        let pwLabel = NSTextField(labelWithString: "비밀번호")
        pwLabel.frame = NSRect(x: 0, y: 44, width: 60, height: 20)
        pwLabel.font = .systemFont(ofSize: 12)
        let pwField = NSSecureTextField(frame: NSRect(x: 65, y: 44, width: 215, height: 22))

        let otpLabel = NSTextField(labelWithString: "OTP")
        otpLabel.frame = NSRect(x: 0, y: 12, width: 60, height: 20)
        otpLabel.font = .systemFont(ofSize: 12)
        let otpField = NSTextField(frame: NSRect(x: 65, y: 12, width: 215, height: 22))
        otpField.placeholderString = "6자리 (선택사항)"

        container.addSubview(emailLabel)
        container.addSubview(emailField)
        container.addSubview(pwLabel)
        container.addSubview(pwField)
        container.addSubview(otpLabel)
        container.addSubview(otpField)

        alert.accessoryView = container
        alert.window.initialFirstResponder = emailField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = pwField.stringValue
        let otp = otpField.stringValue.trimmingCharacters(in: .whitespaces)

        guard !email.isEmpty, !password.isEmpty else { return nil }
        return LoginCredentials(email: email, password: password, otpCode: otp.isEmpty ? nil : otp)
    }

    private func promptText(message: String, info: String?, placeholder: String, secure: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        if let info = info {
            alert.informativeText = info
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")

        let input: NSTextField
        if secure {
            input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        } else {
            input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        }
        input.placeholderString = placeholder
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
