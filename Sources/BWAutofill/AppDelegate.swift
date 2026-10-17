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
        searchPanelController = SearchPanelController(
            bitwardenAPI: api,
            onRequestUnlock: { [weak self] in
                self?.unlockVaultMenu()
            }
        )
        hotkeyManager = HotkeyManager { [weak self] in
            self?.handleHotkey()
        }
        let registered = hotkeyManager?.register() ?? false
        applyHotkeyRegistrationResult(registered)

        // Keychain에서 세션 복원 → bw serve 자동 시작 (stale 토큰은 resumeSession이 폐기)
        Task {
            _ = await api.resumeSession()
            await updateStatus()
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

        let updateItem = NSMenuItem(title: "업데이트 실행…", action: #selector(runUpdateMenu), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

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

        bringToFront()
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            // 터미널 열기
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }

    // MARK: - 잠금 해제

    @objc private func unlockVaultMenu() {
        runVaultFlow { [weak self] in
            await self?.unlockVaultAndShowPanel()
        }
    }

    /// 마스터 비밀번호 입력 → 잠금 해제 + serve 기동 → 성공 시에만 검색 패널
    private func unlockVaultAndShowPanel() async {
        guard let api = bwAPI else { return }

        guard let password = promptText(
            message: "Bitwarden 마스터 비밀번호를 입력하세요",
            info: nil,
            placeholder: "",
            secure: true
        ), !password.isEmpty else { return }

        let error = await api.unlockAndServe(password: password)
        await updateStatus()
        if let error {
            showAlert(title: "잠금 해제 실패", message: error.errorDescription ?? "알 수 없는 오류")
            return
        }
        showSearchPanel()
    }

    /// 잠금 해제 · 세션 복원 흐름 중복 실행 방지 (단축키 연타, 메뉴 동시 클릭)
    private var isVaultFlowRunning = false

    private func runVaultFlow(_ flow: @escaping @MainActor () async -> Void) {
        guard !isVaultFlowRunning else { return }
        isVaultFlowRunning = true
        Task {
            await flow()
            isVaultFlowRunning = false
        }
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

        runVaultFlow { [weak self] in
            guard let self else { return }

            switch await api.resumeSession() {
            case .unlocked:
                self.showSearchPanel()
                return
            case .serveFailed:
                // 토큰은 유효할 수 있으므로 비밀번호를 다시 묻지 않고 원인만 안내
                self.showAlert(
                    title: "Vault 연결 실패",
                    message: UnlockError.serveFailed.errorDescription ?? ""
                )
                await self.updateStatus()
                return
            case .noToken, .tokenExpired:
                break
            }

            // 토큰이 없거나 만료된 경우
            switch await api.getStatus() {
            case .unauthenticated:
                self.showLoginGuide()
            case .locked, .unlocked:
                await self.unlockVaultAndShowPanel()
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

        // 메뉴바 전용(accessory) 앱은 비활성 상태라 입력창이 키 윈도우가 되지 못하면
        // 입력(마스터 비밀번호)이 이전 앱으로 들어갈 수 있음 → 모달 전에 활성화
        bringToFront()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        bringToFront()
        alert.runModal()
    }

    /// 모달 다이얼로그가 키 입력을 받도록 앱 활성화
    private func bringToFront() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 업데이트

    @objc private func runUpdateMenu() {
        UpdateRunner(showAlert: { [weak self] title, message in
            self?.showAlert(title: title, message: message)
        }).run()
    }
}
