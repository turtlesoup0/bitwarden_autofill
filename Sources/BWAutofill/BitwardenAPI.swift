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
    func startServe(sessionToken: String) async -> Bool {
        await stopServe()
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

            let ready = await waitForServer(timeout: 5.0)
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
    private func waitForServer(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await httpGet(path: "/status") != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
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
    func unlock(password: String) async -> String? {
        let (stdout, _, exitCode) = await runCLI(["unlock", "--passwordenv", "BW_PASSWORD", "--raw"], passwordEnv: password)
        guard exitCode == 0,
              let output = stdout else { return nil }

        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        sessionToken = token
        _ = SecurityManager.saveSessionToken(token)
        return token
    }

    func lock() async {
        await stopServe()
        _ = await runCLI(["lock"])
        sessionToken = nil
        SecurityManager.deleteSessionToken()
    }

    func restoreSession(token: String) {
        sessionToken = token
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
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func httpPost(path: String) async -> Data? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - CLI 직접 호출 (login/unlock 전용)

    /// CLI 실행 (비밀번호는 BW_PASSWORD 환경변수로 전달 — ps 명령어에 노출되지 않음)
    private func runCLI(_ args: [String], passwordEnv: String? = nil) async -> (stdout: String?, stderr: String?, exitCode: Int32) {
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
        // bw CLI가 BW_PASSWORD 환경변수를 인식하여 대화형 프롬프트를 건너뜀
        if let password = passwordEnv {
            env["BW_PASSWORD"] = password
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (
                    String(data: stdoutData, encoding: .utf8),
                    String(data: stderrData, encoding: .utf8),
                    proc.terminationStatus
                ))
            }
            do {
                try process.run()
            } catch {
                #if DEBUG
                print("[BitwardenAPI] CLI 실행 오류: \(error)")
                #endif
                process.terminationHandler = nil
                continuation.resume(returning: (nil, nil, -1))
            }
        }
    }
}
