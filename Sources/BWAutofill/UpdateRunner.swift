import AppKit

/// 앱 내 업데이트 실행 (git pull → 빌드 → 앱 교체 → 재실행)
/// 실제 작업은 저장소의 scripts/update.sh 가 Terminal 에서 수행
@MainActor
struct UpdateRunner {
    private static let repoPathKey = "updateRepoPath"

    let showAlert: (_ title: String, _ message: String) -> Void

    func run() {
        guard let repoPath = findOrAskRepoPath() else { return }

        let scriptPath = (repoPath as NSString).appendingPathComponent("scripts/update.sh")
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            showAlert(
                "업데이트 불가",
                "scripts/update.sh를 찾을 수 없습니다:\n\(scriptPath)\n\n최신 버전을 한 번 git pull 해주세요."
            )
            return
        }

        // 확인 다이얼로그
        let confirm = NSAlert()
        confirm.messageText = "업데이트 실행"
        confirm.informativeText = "저장소:\n\(repoPath)\n\nTerminal에서 git pull → 빌드 → 앱 교체 → 재실행을 수행합니다. 잠시 후 현재 앱이 종료됩니다."
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "실행")
        confirm.addButton(withTitle: "취소")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        // Apple Events 권한(자동화) 우회 — .command 파일을 Terminal에서 직접 열기
        // 현재 실행 중인 앱 번들 경로를 전달 → 같은 위치에 덮어쓰기
        let commandContents = Self.makeCommandScript(
            scriptPath: scriptPath,
            repoPath: repoPath,
            appPath: Bundle.main.bundlePath
        )

        let tempDir = NSTemporaryDirectory()
        let commandFile = (tempDir as NSString).appendingPathComponent("bw-autofill-update.command")

        do {
            try commandContents.write(toFile: commandFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: commandFile
            )
        } catch {
            showAlert("업데이트 파일 생성 실패", "\(error)")
            return
        }

        // .command 확장자는 macOS에서 Terminal과 연결 — 권한 다이얼로그 없이 열림
        NSWorkspace.shared.open(URL(fileURLWithPath: commandFile))
    }

    /// Terminal 에서 실행할 .command 스크립트 내용
    nonisolated static func makeCommandScript(scriptPath: String, repoPath: String, appPath: String) -> String {
        """
        #!/bin/bash
        bash \(shellQuote(scriptPath)) \(shellQuote(repoPath)) \(shellQuote(appPath))
        exit_code=$?
        echo ""
        if [ $exit_code -ne 0 ]; then
            echo "❌ 업데이트 실패 (exit $exit_code). 위 로그를 확인해주세요."
            echo ""
            read -n 1 -s -r -p "아무 키나 눌러 창을 닫으세요..."
        fi
        """
    }

    /// 쉘 single-quote 이스케이프
    nonisolated static func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// UserDefaults에 저장된 경로를 확인, 없거나 무효하면 사용자에게 선택 요청
    private func findOrAskRepoPath() -> String? {
        if let saved = UserDefaults.standard.string(forKey: Self.repoPathKey),
           isValidRepo(saved) {
            return saved
        }

        let panel = NSOpenPanel()
        panel.title = "bitwarden_autofill 저장소 선택"
        panel.message = "업데이트를 수행할 bitwarden_autofill 저장소 폴더를 선택하세요 (.git 을 포함한 루트)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let path = url.path

        guard isValidRepo(path) else {
            showAlert(
                "올바른 저장소가 아님",
                "선택한 폴더에 .git 이 없습니다:\n\(path)"
            )
            return nil
        }

        UserDefaults.standard.set(path, forKey: Self.repoPathKey)
        return path
    }

    private func isValidRepo(_ path: String) -> Bool {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath)
    }
}
