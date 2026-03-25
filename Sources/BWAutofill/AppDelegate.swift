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

        // 1단계: 이메일
        guard let email = promptText(
            message: "Bitwarden 로그인",
            info: "이메일 주소를 입력하세요",
            placeholder: "email@example.com",
            secure: false
        ), !email.isEmpty else { return }

        // 2단계: 마스터 비밀번호
        guard let password = promptText(
            message: "Bitwarden 로그인",
            info: "마스터 비밀번호를 입력하세요",
            placeholder: "",
            secure: true
        ), !password.isEmpty else { return }

        // 3단계: OTP 입력 (제출 직전에 확인 — TOTP 시간 유효성)
        guard let code = promptText(
            message: "2단계 인증",
            info: "인증 앱의 6자리 코드를 입력하세요\n(2FA 미사용 시 빈 칸으로 확인)",
            placeholder: "000000",
            secure: false
        ) else { return }

        let result: BitwardenAPI.LoginResult
        if code.isEmpty {
            result = await api.login(email: email, password: password)
        } else {
            result = await api.login(email: email, password: password, twoFactorCode: code)
        }

        switch result {
        case .success(let token):
            let _ = await api.startServe(sessionToken: token)
            showSearchPanel()

        case .requires2FA:
            // OTP 없이 시도했으나 2FA 필요 → 재입력
            guard let retryCode = promptText(
                message: "2단계 인증 필요",
                info: "인증 앱의 6자리 코드를 입력하세요",
                placeholder: "000000",
                secure: false
            ), !retryCode.isEmpty else { return }

            let retryResult = await api.login(email: email, password: password, twoFactorCode: retryCode)
            if case .success(let token) = retryResult {
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
