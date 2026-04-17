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
        let registered = hotkeyManager?.register() ?? false
        applyHotkeyRegistrationResult(registered)

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 클립보드에 우리가 복사한 내용이 남아 있으면 먼저 제거 (비밀번호 유출 방지)
        SecurityManager.clearClipboardIfOurs()

        guard let api = bwAPI else { return .terminateNow }
        Task { @MainActor in
            await api.stopServe()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

    /// 핫키 등록 결과를 UI에 반영
    private func applyHotkeyRegistrationResult(_ success: Bool) {
        guard !success else { return }

        statusItem?.button?.image = NSImage(
            systemSymbolName: "key.slash",
            accessibilityDescription: "BW Autofill (단축키 등록 실패)"
        )

        guard let menu = statusItem?.menu, menu.item(withTag: 101) == nil else { return }
        let warningItem = NSMenuItem(
            title: "⚠️ 단축키 등록 실패 — ⌘\\ 이 다른 앱에서 사용 중",
            action: nil,
            keyEquivalent: ""
        )
        warningItem.tag = 101
        // 상태 메뉴(tag 100) 바로 아래 삽입
        let statusIndex = menu.indexOfItem(withTag: 100)
        let insertIndex = statusIndex >= 0 ? statusIndex + 1 : 3
        menu.insertItem(warningItem, at: insertIndex)
    }

    private func updateStatus() async {
        guard let api = bwAPI else { return }
        let status = await api.getStatus()
        if let item = statusItem?.menu?.item(withTag: 100) {
            item.title = "상태: \(status.displayText)"
        }
    }

    // MARK: - 로그인 (터미널 안내)

    @objc private func loginVaultMenu() {
        showLoginGuide()
    }

    private func showLoginGuide() {
        let alert = NSAlert()
        alert.messageText = "Bitwarden 로그인 필요"
        alert.informativeText = "터미널에서 아래 명령어를 실행하세요:\n\nbw login\n\n로그인 완료 후 Cmd+\\ 를 누르면 자동으로 연결됩니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "터미널 열기")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            // 터미널 열기
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
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
        // applicationShouldTerminate가 stopServe를 담당
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
                showLoginGuide()

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
