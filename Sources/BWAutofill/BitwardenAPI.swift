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

/// Vault 항목 로드 실패 원인
enum LoadError: Error, LocalizedError {
    case notServing
    case httpFailure
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .notServing: return "Vault 연결 안 됨 — 잠금 해제 필요"
        case .httpFailure: return "bw serve 응답 없음"
        case .parseFailure: return "응답 해석 실패"
        }
    }
}

/// 잠금 해제 실패 원인
enum UnlockError: Error, Equatable, LocalizedError {
    /// bw unlock 비정상 종료 (message: bw stderr)
    case cliFailed(exitCode: Int32, message: String)
    /// bw 실행 파일을 실행할 수 없음
    case launchFailed
    /// exit 0 이지만 세션 토큰이 비어 있음
    case emptyToken
    /// 잠금 해제는 됐지만 bw serve 기동 실패
    case serveFailed

    var errorDescription: String? {
        switch self {
        case .cliFailed(let exitCode, let message):
            return message.isEmpty ? "bw unlock 실패 (종료 코드 \(exitCode))" : message
        case .launchFailed:
            return "bw CLI를 실행할 수 없습니다. bitwarden-cli 설치(brew install bitwarden-cli)를 확인하세요."
        case .emptyToken:
            return "bw unlock이 세션 토큰을 반환하지 않았습니다."
        case .serveFailed:
            return "잠금 해제는 됐지만 bw serve를 시작하지 못했습니다. 포트 8087을 다른 프로세스가 사용 중인지 확인하세요."
        }
    }
}

/// 저장된 토큰으로 세션 복원 결과
enum ResumeResult: Equatable {
    /// serve 실행 중 + unlocked
    case unlocked
    /// 저장된 토큰 없음
    case noToken
    /// serve 는 떴지만 unlocked 가 아님 → 토큰 폐기됨
    case tokenExpired
    /// serve 기동 실패 (환경 문제) → 토큰 유지
    case serveFailed
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

// MARK: - 외부 의존 경계 (테스트에서 가짜로 대체)

/// CLI 실행 결과
struct CLIResult {
    let stdout: String?
    let stderr: String?
    let exitCode: Int32
}

/// 실행 중인 bw serve 프로세스 핸들
protocol ServeHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: ServeHandle {}

/// bw CLI 실행 · bw serve 기동 · HTTP 호출
protocol BitwardenBackend {
    func runCLI(executable: String, arguments: [String], environment: [String: String]) async -> CLIResult
    func launchServe(executable: String, arguments: [String], environment: [String: String]) throws -> ServeHandle
    /// 포트를 점유한 고아 bw serve(이전 실행이 강제 종료되며 남긴 것) 종료. 하나라도 종료했으면 true
    func terminateOrphanServe(port: Int) async -> Bool
    func httpGet(_ url: URL) async -> Data?
    func httpPost(_ url: URL) async -> Data?
}

/// 세션 토큰 영속 저장소
protocol SessionTokenStore {
    @discardableResult func save(_ token: String) -> Bool
    func load() -> String?
    @discardableResult func delete() -> Bool
}

/// Keychain 기반 토큰 저장소 (SecurityManager 위임)
struct KeychainSessionTokenStore: SessionTokenStore {
    func save(_ token: String) -> Bool { SecurityManager.saveSessionToken(token) }
    func load() -> String? { SecurityManager.loadSessionToken() }
    func delete() -> Bool { SecurityManager.deleteSessionToken() }
}

/// 실제 Process / URLSession 기반 백엔드
struct SystemBitwardenBackend: BitwardenBackend {
    /// HTTP 세션 (캐시/쿠키 없는 ephemeral 사용)
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    func launchServe(executable: String, arguments: [String], environment: [String: String]) throws -> ServeHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    func terminateOrphanServe(port: Int) async -> Bool {
        let env = ["PATH": "/usr/sbin:/usr/bin:/bin"]
        let lsof = await runCLI(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"],
            environment: env
        )
        let pids = (lsof.stdout ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

        var terminated = false
        for pid in pids {
            let ps = await runCLI(executable: "/bin/ps", arguments: ["-o", "command=", "-p", String(pid)], environment: env)
            let command = ps.stdout ?? ""
            // 우리가 띄우는 형태의 bw serve 만 종료 — 다른 프로세스는 건드리지 않음
            guard command.contains("bw serve"), command.contains("--port \(port)") else { continue }
            if kill(pid, SIGTERM) == 0 {
                #if DEBUG
                print("[BitwardenAPI] 고아 bw serve 종료 (pid: \(pid))")
                #endif
                terminated = true
            }
        }
        return terminated
    }

    func runCLI(executable: String, arguments: [String], environment: [String: String]) async -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CLIResult(
                    stdout: String(data: stdoutData, encoding: .utf8),
                    stderr: String(data: stderrData, encoding: .utf8),
                    exitCode: proc.terminationStatus
                ))
            }
            do {
                try process.run()
            } catch {
                #if DEBUG
                print("[BitwardenAPI] CLI 실행 오류: \(error)")
                #endif
                process.terminationHandler = nil
                continuation.resume(returning: CLIResult(stdout: nil, stderr: nil, exitCode: -1))
            }
        }
    }

    func httpGet(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await urlSession.data(from: url)
            return Self.okBody(data, response)
        } catch {
            return nil
        }
    }

    func httpPost(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await urlSession.data(for: request)
            return Self.okBody(data, response)
        } catch {
            return nil
        }
    }

    private static func okBody(_ data: Data, _ response: URLResponse) -> Data? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return data
    }
}

// MARK: - BitwardenAPI

/// bw serve REST API 클라이언트
/// localhost:8087 에서 동작하는 bw serve 프로세스와 통신
actor BitwardenAPI {
    private let baseURL: String
    private let port: Int
    private let bwPath: String
    private let backend: BitwardenBackend
    private let tokenStore: SessionTokenStore
    private let serveStartTimeout: TimeInterval
    private var serveProcess: ServeHandle?
    private var sessionToken: String?

    /// 캐시
    private var cachedItems: [VaultItem]?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 300

    init(
        port: Int = 8087,
        backend: BitwardenBackend = SystemBitwardenBackend(),
        tokenStore: SessionTokenStore = KeychainSessionTokenStore(),
        serveStartTimeout: TimeInterval = 5.0
    ) {
        self.port = port
        self.baseURL = "http://127.0.0.1:\(port)"
        self.backend = backend
        self.tokenStore = tokenStore
        self.serveStartTimeout = serveStartTimeout

        let possiblePaths = [
            "/opt/homebrew/bin/bw",
            "/usr/local/bin/bw",
            "/usr/bin/bw"
        ]
        self.bwPath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) } ?? "bw"
    }

    // MARK: - bw serve 프로세스 관리

    /// bw serve 시작 (세션 토큰으로 unlocked 상태)
    func startServe(sessionToken: String) async -> Bool {
        await stopServe()
        self.sessionToken = sessionToken

        guard await ensurePortAvailable() else {
            #if DEBUG
            print("[BitwardenAPI] 포트 \(port) 점유 중 — bw serve 시작 불가")
            #endif
            return false
        }

        // loopback 바인딩으로 외부 접근 차단
        let arguments = ["serve", "--hostname", "127.0.0.1", "--port", String(port)]

        // 최소한의 환경변수만 전달
        let environment = [
            "BW_SESSION": sessionToken,
            "NO_COLOR": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        ]

        do {
            serveProcess = try backend.launchServe(executable: bwPath, arguments: arguments, environment: environment)

            let ready = await waitForServer(timeout: serveStartTimeout)
            #if DEBUG
            if ready {
                print("[BitwardenAPI] bw serve 시작됨 (port: \(port))")
            } else {
                print("[BitwardenAPI] bw serve 시작 타임아웃")
            }
            #endif
            if !ready { await stopServe() }
            return ready
        } catch {
            #if DEBUG
            print("[BitwardenAPI] bw serve 시작 실패: \(error)")
            #endif
            return false
        }
    }

    /// bw serve 중지
    func stopServe() async {
        let processToStop = serveProcess
        serveProcess = nil
        cachedItems = nil
        cacheTimestamp = nil

        guard let process = processToStop, process.isRunning else { return }
        process.terminate()

        // 최대 3초 대기 (actor 스레드 블로킹 없이 폴링)
        for _ in 0..<30 {
            if !process.isRunning { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 서버 준비 대기
    /// 우리 프로세스가 죽었으면(포트 충돌 등) 다른 서버의 응답을 "준비됨"으로 믿지 않음
    private func waitForServer(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isServing else { return false }
            if await httpGet(path: "/status") != nil {
                return isServing
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    /// 우리 serve 를 띄우기 전, 포트를 이미 점유한 서버(이전 실행의 고아 bw serve)를 정리
    /// stopServe 직후이므로 이 시점에 응답하는 서버는 우리 것이 아님
    private func ensurePortAvailable() async -> Bool {
        guard await httpGet(path: "/status") != nil else { return true }

        guard await backend.terminateOrphanServe(port: port) else { return false }

        // 종료 후 포트가 비워질 때까지 최대 3초 대기
        for _ in 0..<30 {
            if await httpGet(path: "/status") == nil { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    var isServing: Bool {
        serveProcess?.isRunning == true
    }

    // MARK: - 상태 관리

    func getStatus() async -> VaultStatus {
        guard isServing else {
            return await getStatusViaCLI()
        }

        guard let data = await httpGet(path: "/status") else {
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

    private func getStatusViaCLI() async -> VaultStatus {
        let (output, _, _) = await runCLI(["status"])
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

    // MARK: - 잠금해제 (로그인은 터미널에서 `bw login` 직접 수행)

    /// bw unlock (비밀번호는 BW_PASSWORD 환경변수로 전달) → 세션 토큰 반환
    func unlock(password: String) async -> Result<String, UnlockError> {
        let (stdout, stderr, exitCode) = await runCLI(["unlock", "--passwordenv", "BW_PASSWORD", "--raw"], passwordEnv: password)
        if exitCode == -1 && stdout == nil {
            return .failure(.launchFailed)
        }
        guard exitCode == 0 else {
            let message = (stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.cliFailed(exitCode: exitCode, message: message))
        }

        let token = (stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.emptyToken) }

        sessionToken = token
        tokenStore.save(token)
        return .success(token)
    }

    /// 잠금 해제 + bw serve 기동. 성공 시 nil
    /// serve 기동 실패 시에도 토큰은 저장된 상태로 유지 (다음 resumeSession 에서 재시도)
    func unlockAndServe(password: String) async -> UnlockError? {
        switch await unlock(password: password) {
        case .failure(let error):
            return error
        case .success(let token):
            return await startServe(sessionToken: token) ? nil : .serveFailed
        }
    }

    /// 저장된 토큰으로 bw serve 를 띄워 unlocked 세션 복원
    func resumeSession() async -> ResumeResult {
        if isServing, await getStatus() == .unlocked {
            return .unlocked
        }

        guard let token = tokenStore.load() else { return .noToken }

        guard await startServe(sessionToken: token) else {
            // 포트 점유 등 환경 문제일 수 있으므로 토큰은 유지
            return .serveFailed
        }

        if await getStatus() == .unlocked {
            return .unlocked
        }

        // serve 는 떴지만 locked → 토큰이 stale (다른 곳에서 bw lock 등)
        #if DEBUG
        print("[BitwardenAPI] 저장된 토큰이 stale — 폐기")
        #endif
        await stopServe()
        sessionToken = nil
        tokenStore.delete()
        return .tokenExpired
    }

    func lock() async {
        await stopServe()
        _ = await runCLI(["lock"])
        sessionToken = nil
        tokenStore.delete()
    }

    // MARK: - 데이터 조회 (REST API)

    /// 로그인 항목 검색 (클라이언트 사이드 필터링 + 점수 기반 정렬)
    func listItems(search: String?) async throws -> [VaultItem] {
        let allItems = try await loadAllItems()

        guard let search = search, !search.isEmpty else {
            return allItems
        }

        let query = search.lowercased()
        let scored = allItems.compactMap { item -> (item: VaultItem, score: Int)? in
            let score = Self.matchScore(for: item, query: query)
            return score > 0 ? (item, score) : nil
        }
        // Swift sorted(by:)는 stable 정렬 — 동점 시 원본 순서 유지
        return scored
            .sorted { $0.score > $1.score }
            .map { $0.item }
    }

    /// 검색어 매칭 점수 (0이면 제외)
    /// 이름 정확 일치 > 접두사 > 부분 > username/uri 부분
    private static func matchScore(for item: VaultItem, query: String) -> Int {
        let name = item.name.lowercased()
        if name == query { return 1000 }
        if name.hasPrefix(query) { return 500 }
        if name.contains(query) { return 300 }

        let username = (item.username ?? "").lowercased()
        let uri = (item.uri ?? "").lowercased()
        if username.contains(query) || uri.contains(query) { return 100 }
        return 0
    }

    private func loadAllItems() async throws -> [VaultItem] {
        if let cached = cachedItems,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheTTL {
            return cached
        }

        guard isServing else {
            throw LoadError.notServing
        }

        guard let data = await httpGet(path: "/list/object/items") else {
            #if DEBUG
            print("[BitwardenAPI] 항목 조회 실패 (HTTP)")
            #endif
            throw LoadError.httpFailure
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success,
                  let dataObj = json["data"] as? [String: Any],
                  let itemsArray = dataObj["data"] else {
                throw LoadError.parseFailure
            }
            let itemsData = try JSONSerialization.data(withJSONObject: itemsArray)
            let allItems = try JSONDecoder().decode([VaultItem].self, from: itemsData)
            let loginItems = allItems.filter { $0.isLogin }
            cachedItems = loginItems
            cacheTimestamp = Date()
            #if DEBUG
            print("[BitwardenAPI] 로그인 항목 \(loginItems.count)개 로드 완료")
            #endif
            return loginItems
        } catch let error as LoadError {
            throw error
        } catch {
            #if DEBUG
            print("[BitwardenAPI] JSON 파싱 오류: \(error)")
            #endif
            throw LoadError.parseFailure
        }
    }

    /// 캐시 무효화 + Bitwarden 클라우드 동기화
    func invalidateCache() async {
        cachedItems = nil
        cacheTimestamp = nil

        // bw serve에 클라우드 동기화 요청
        if isServing {
            _ = await httpPost(path: "/sync")
        }
    }

    // MARK: - HTTP 클라이언트 (비동기)

    private func httpGet(path: String) async -> Data? {
        guard let url = URL(string: baseURL + path) else { return nil }
        return await backend.httpGet(url)
    }

    private func httpPost(path: String) async -> Data? {
        guard let url = URL(string: baseURL + path) else { return nil }
        return await backend.httpPost(url)
    }

    // MARK: - CLI 직접 호출 (login/unlock 전용)

    /// CLI 실행 (비밀번호는 BW_PASSWORD 환경변수로 전달 — ps 명령어에 노출되지 않음)
    private func runCLI(_ args: [String], passwordEnv: String? = nil) async -> (stdout: String?, stderr: String?, exitCode: Int32) {
        // 최소한의 환경변수만 전달
        var env: [String: String] = [
            "NO_COLOR": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin",
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        ]
        if let token = sessionToken {
            env["BW_SESSION"] = token
        }
        // bw CLI가 BW_PASSWORD 환경변수를 인식하여 대화형 프롬프트를 건너뜀
        if let password = passwordEnv {
            env["BW_PASSWORD"] = password
        }

        let result = await backend.runCLI(executable: bwPath, arguments: args, environment: env)
        return (result.stdout, result.stderr, result.exitCode)
    }
}
