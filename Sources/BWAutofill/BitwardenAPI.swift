import Foundation

/// Bitwarden Vault 상태
enum VaultStatus {
    case unauthenticated
    case locked
    case unlocked

    var displayText: String {
        switch self {
        case .unauthenticated: return "로그인 필요"
        case .locked: return "잠금됨"
        case .unlocked: return "잠금 해제됨"
        }
    }
}

/// Vault 항목 모델
struct VaultItem: Codable, Identifiable {
    let id: String
    let type: Int?
    let name: String
    let login: LoginInfo?

    var isLogin: Bool { type == 1 }
    var username: String? { login?.username }
    var password: String? { login?.password }
    var uri: String? { login?.uris?.first?.uri }

    struct LoginInfo: Codable {
        let username: String?
        let password: String?
        let uris: [URIInfo]?
    }

    struct URIInfo: Codable {
        let uri: String?
    }
}

/// bw serve 응답 래퍼
private struct BWResponse<T: Codable>: Codable {
    let success: Bool
    let message: String?
    let data: BWData<T>?
}

private struct BWData<T: Codable>: Codable {
    let data: T?
    let template: T?
    let object: String?
}

/// bw serve status 응답용
private struct BWStatusTemplate: Codable {
    let status: String?
    let userEmail: String?
}

/// bw serve REST API 클라이언트
/// localhost:8087 에서 동작하는 bw serve 프로세스와 통신
actor BitwardenAPI {
    private let baseURL: String
    private let port: Int
    private let bwPath: String
    private var serveProcess: Process?
    private var sessionToken: String?

    /// 캐시
    private var cachedItems: [VaultItem]?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 300

    /// HTTP 세션 (캐시/쿠키 없는 ephemeral 사용)
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    init(port: Int = 8087) {
        self.port = port
        self.baseURL = "http://127.0.0.1:\(port)"

        let possiblePaths = [
            "/opt/homebrew/bin/bw",
            "/usr/local/bin/bw",
            "/usr/bin/bw"
        ]
        self.bwPath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) } ?? "bw"
    }

    // MARK: - bw serve 프로세스 관리

    /// bw serve 시작 (세션 토큰으로 unlocked 상태)
    func startServe(sessionToken: String) -> Bool {
        stopServe()
        self.sessionToken = sessionToken

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bwPath)
        // loopback 바인딩으로 외부 접근 차단
        process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", String(port)]

        // 최소한의 환경변수만 전달
        process.environment = [
            "BW_SESSION": sessionToken,
            "NO_COLOR": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        ]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serveProcess = process

            let ready = waitForServer(timeout: 5.0)
            #if DEBUG
            if ready {
                print("[BitwardenAPI] bw serve 시작됨 (port: \(port))")
            } else {
                print("[BitwardenAPI] bw serve 시작 타임아웃")
            }
            #endif
            if !ready { stopServe() }
            return ready
        } catch {
            #if DEBUG
            print("[BitwardenAPI] bw serve 시작 실패: \(error)")
            #endif
            return false
        }
    }

    /// bw serve 중지
    func stopServe() {
        if let process = serveProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serveProcess = nil
        cachedItems = nil
        cacheTimestamp = nil
    }

    /// 서버 준비 대기
    private func waitForServer(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if httpGetSync(path: "/status") != nil {
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    var isServing: Bool {
        serveProcess?.isRunning == true
    }

    // MARK: - 상태 관리

    func getStatus() -> VaultStatus {
        guard isServing else {
            return getStatusViaCLI()
        }

        guard let data = httpGetSync(path: "/status") else {
            return .unauthenticated
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, success,
           let dataObj = json["data"] as? [String: Any],
           let template = dataObj["template"] as? [String: Any],
           let status = template["status"] as? String {
            return parseStatus(status)
        }
        return .unauthenticated
    }

    private func getStatusViaCLI() -> VaultStatus {
        let (output, _, _) = runCLI(["status"])
        guard let output = output else { return .unauthenticated }
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? String {
            return parseStatus(status)
        }
        return .unauthenticated
    }

    private func parseStatus(_ status: String) -> VaultStatus {
        switch status {
        case "unlocked": return .unlocked
        case "locked": return .locked
        default: return .unauthenticated
        }
    }

    // MARK: - 로그인 / 잠금해제

    enum LoginResult {
        case success(sessionToken: String)
        case requires2FA
        case failed(String)
    }

    /// bw login (비밀번호는 stdin으로 전달)
    func login(email: String, password: String, twoFactorCode: String? = nil) -> LoginResult {
        _ = runCLI(["logout"])

        var args: [String]
        if let code = twoFactorCode {
            args = ["login", email, "--method", "0", "--code", code, "--raw"]
        } else {
            args = ["login", email, "--raw"]
        }

        let (stdout, stderr, exitCode) = runCLI(args, stdinInput: password)
        let output = stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if errorOutput.contains("Two-step") || errorOutput.contains("two-step")
            || errorOutput.contains("Additional authentication") {
            return .requires2FA
        }

        // exit code 기반 성공 판정
        if exitCode == 0 && !output.isEmpty {
            sessionToken = output
            _ = SecurityManager.saveSessionToken(output)
            return .success(sessionToken: output)
        }

        let errorMsg = errorOutput.isEmpty ? (output.isEmpty ? "알 수 없는 오류" : output) : errorOutput
        return .failed(errorMsg)
    }

    /// bw unlock (비밀번호는 stdin으로 전달) → 세션 토큰 반환
    func unlock(password: String) -> String? {
        let (stdout, _, exitCode) = runCLI(["unlock", "--raw"], stdinInput: password)
        guard exitCode == 0,
              let output = stdout else { return nil }

        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        sessionToken = token
        _ = SecurityManager.saveSessionToken(token)
        return token
    }

    func lock() {
        stopServe()
        _ = runCLI(["lock"])
        sessionToken = nil
        SecurityManager.deleteSessionToken()
    }

    func restoreSession(token: String) {
        sessionToken = token
    }

    // MARK: - 데이터 조회 (REST API)

    /// 로그인 항목 검색 (클라이언트 사이드 필터링)
    func listItems(search: String?) -> [VaultItem] {
        let allItems = loadAllItems()

        guard let search = search, !search.isEmpty else {
            return allItems
        }

        let query = search.lowercased()
        return allItems.filter { item in
            let targets = [
                item.name,
                item.username ?? "",
                item.uri ?? ""
            ]
            return targets.contains { $0.lowercased().contains(query) }
        }
    }

    private func loadAllItems() -> [VaultItem] {
        if let cached = cachedItems,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheTTL {
            return cached
        }

        guard let data = httpGetSync(path: "/list/object/items") else {
            #if DEBUG
            print("[BitwardenAPI] 항목 조회 실패")
            #endif
            return []
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success,
               let dataObj = json["data"] as? [String: Any],
               let itemsArray = dataObj["data"] {
                let itemsData = try JSONSerialization.data(withJSONObject: itemsArray)
                let allItems = try JSONDecoder().decode([VaultItem].self, from: itemsData)
                let loginItems = allItems.filter { $0.isLogin }
                cachedItems = loginItems
                cacheTimestamp = Date()
                #if DEBUG
                print("[BitwardenAPI] 로그인 항목 \(loginItems.count)개 로드 완료")
                #endif
                return loginItems
            }
        } catch {
            #if DEBUG
            print("[BitwardenAPI] JSON 파싱 오류: \(error)")
            #endif
        }
        return []
    }

    /// 캐시 무효화 + Bitwarden 클라우드 동기화
    func invalidateCache() {
        cachedItems = nil
        cacheTimestamp = nil

        // bw serve에 클라우드 동기화 요청
        if isServing {
            httpPostSync(path: "/sync")
        }
    }

    // MARK: - HTTP 클라이언트 (동기)

    private func httpGetSync(path: String) -> Data? {
        guard let url = URL(string: baseURL + path) else { return nil }
        let request = URLRequest(url: url)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        urlSession.dataTask(with: request) { data, response, _ in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                result = data
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        return result
    }

    @discardableResult
    private func httpPostSync(path: String) -> Data? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        urlSession.dataTask(with: request) { data, response, _ in
            if let data = data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                result = data
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        return result
    }

    // MARK: - CLI 직접 호출 (login/unlock 전용)

    /// CLI 실행 (비밀번호는 stdinInput으로 전달하여 프로세스 인자 노출 방지)
    private func runCLI(_ args: [String], stdinInput: String? = nil) -> (stdout: String?, stderr: String?, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bwPath)
        process.arguments = args

        // 최소한의 환경변수만 전달
        var env: [String: String] = [
            "NO_COLOR": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        ]
        if let token = sessionToken {
            env["BW_SESSION"] = token
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 비밀번호를 stdin으로 전달 (프로세스 인자에 노출되지 않음)
        if let input = stdinInput {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            if let data = input.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
                stdinPipe.fileHandleForWriting.closeFile()
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return (
                String(data: stdoutData, encoding: .utf8),
                String(data: stderrData, encoding: .utf8),
                process.terminationStatus
            )
        } catch {
            #if DEBUG
            print("[BitwardenAPI] CLI 실행 오류: \(error)")
            #endif
            return (nil, nil, -1)
        }
    }
}
