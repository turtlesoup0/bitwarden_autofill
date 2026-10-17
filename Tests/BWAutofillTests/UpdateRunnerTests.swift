import Foundation
import Testing
@testable import BWAutofill

@Suite("업데이트 스크립트 생성")
struct UpdateRunnerTests {
    @Test("작은따옴표는 '\\'' 로 이스케이프")
    func shellQuoteEscapesSingleQuote() {
        #expect(UpdateRunner.shellQuote("it's") == #"'it'\''s'"#)
        #expect(UpdateRunner.shellQuote("") == "''")
    }

    @Test("공백·특수문자가 든 경로도 bash 에서 원래 값으로 전달됨")
    func commandScriptRoundTripsPathsThroughBash() throws {
        let script = "/tmp/a b/scripts/update.sh"
        let repo = "/Users/me/O'Brien $HOME `x`"
        let app = "/Users/me/Applications/BW Autofill.app"

        let contents = UpdateRunner.makeCommandScript(scriptPath: script, repoPath: repo, appPath: app)
        let bashLine = try #require(contents.split(separator: "\n").first { $0.hasPrefix("bash ") })

        // "bash <script> <repo> <app>" 의 bash 를 printf 로 바꿔 실제 쉘이 해석한 인자를 확인
        let probe = "printf '%s\\n'" + bashLine.dropFirst("bash".count)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", probe]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)

        #expect(output == "\(script)\n\(repo)\n\(app)\n")
    }

    @Test("실패 시 창이 닫히지 않도록 키 입력 대기")
    func commandScriptWaitsOnFailure() {
        let contents = UpdateRunner.makeCommandScript(scriptPath: "/s", repoPath: "/r", appPath: "/a")
        #expect(contents.hasPrefix("#!/bin/bash\n"))
        #expect(contents.contains("if [ $exit_code -ne 0 ]; then"))
        #expect(contents.contains("read -n 1"))
    }
}
