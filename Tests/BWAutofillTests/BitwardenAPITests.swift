import Foundation
import Testing
@testable import BWAutofill

// MARK: - 테스트 더블

final class FakeServe: ServeHandle {
    var isRunning = true
    private(set) var terminateCount = 0

    func terminate() {
        terminateCount += 1
        isRunning = false
    }
}

final class FakeBackend: BitwardenBackend {
    /// 첫 번째 CLI 인자(서브커맨드) → 결과
    var cliResults: [String: CLIResult] = [:]
    /// URL path → GET 응답. 포트에서 서버(우리 serve 또는 고아 serve)가 떠 있을 때만 응답
    var getResponses: [String: Data] = [:]
    var launchError: Error?

    /// 이전 실행이 남긴 고아 bw serve 가 포트를 점유 중인지
    var orphanServeRunning = false
    /// terminateOrphanServe 가 고아 프로세스를 종료할 수 있는지
    var canTerminateOrphan = true
    /// 기동 직후 바로 죽는 serve (포트 충돌 시 bw serve 동작)
    var launchedServeDiesImmediately = false
    /// launchServe 직후 실행할 훅 (경쟁 상황 재현용)
    var onLaunch: (() -> Void)?

    private(set) var cliCalls: [(arguments: [String], environment: [String: String])] = []
    private(set) var launches: [(arguments: [String], environment: [String: String], serve: FakeServe)] = []
    private(set) var postPaths: [String] = []
    private(set) var orphanTerminationPorts: [Int] = []

    func runCLI(executable: String, arguments: [String], environment: [String: String]) async -> CLIResult {
        cliCalls.append((arguments, environment))
        return cliResults[arguments.first ?? ""] ?? CLIResult(stdout: nil, stderr: nil, exitCode: 1)
    }

    func launchServe(executable: String, arguments: [String], environment: [String: String]) throws -> ServeHandle {
        if let launchError { throw launchError }
        let serve = FakeServe()
        if launchedServeDiesImmediately { serve.isRunning = false }
        launches.append((arguments, environment, serve))
        onLaunch?()
        return serve
    }

    func terminateOrphanServe(port: Int) async -> Bool {
        orphanTerminationPorts.append(port)
        guard orphanServeRunning, canTerminateOrphan else { return false }
        orphanServeRunning = false
        return true
    }

    func httpGet(_ url: URL) async -> Data? {
        let anyServerListening = orphanServeRunning || launches.contains { $0.serve.isRunning }
        return anyServerListening ? getResponses[url.path] : nil
    }

    func httpPost(_ url: URL) async -> Data? {
        postPaths.append(url.path)
        return Data()
    }
}

final class FakeTokenStore: SessionTokenStore {
    var token: String?

    func save(_ token: String) -> Bool {
        self.token = token
        return true
    }

    func load() -> String? { token }

    func delete() -> Bool {
        token = nil
        return true
    }
}

// MARK: - 응답 픽스처

enum Fixture {
    static func cliStatus(_ status: String) -> CLIResult {
        CLIResult(stdout: #"{"serverUrl":null,"status":"\#(status)"}"#, stderr: "", exitCode: 0)
    }

    static func serveStatus(_ status: String) -> Data {
        Data(#"{"success":true,"data":{"object":"template","template":{"status":"\#(status)"}}}"#.utf8)
    }

    static func items(_ items: [[String: Any]]) -> Data {
        let body: [String: Any] = ["success": true, "data": ["object": "list", "data": items]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    static func login(_ id: String, name: String, username: String? = nil, uri: String? = nil) -> [String: Any] {
        var login: [String: Any] = ["password": "pw-\(id)"]
        if let username { login["username"] = username }
        if let uri { login["uris"] = [["uri": uri]] }
        return ["id": id, "type": 1, "name": name, "login": login]
    }

    static func secureNote(_ id: String, name: String) -> [String: Any] {
        ["id": id, "type": 2, "name": name]
    }
}

private func makeAPI(
    backend: FakeBackend = FakeBackend(),
    store: FakeTokenStore = FakeTokenStore()
) -> BitwardenAPI {
    BitwardenAPI(port: 18087, backend: backend, tokenStore: store, serveStartTimeout: 0.5)
}

// MARK: - 상태 조회

@Suite("상태 조회")
struct StatusTests {
    @Test("serve 미실행 시 CLI status 결과를 파싱", arguments: [
        ("locked", VaultStatus.locked),
        ("unlocked", VaultStatus.unlocked),
        ("unauthenticated", VaultStatus.unauthenticated),
    ])
    func statusViaCLI(raw: String, expected: VaultStatus) async {
        let backend = FakeBackend()
        backend.cliResults["status"] = Fixture.cliStatus(raw)
        let api = makeAPI(backend: backend)

        #expect(await api.getStatus() == expected)
        #expect(backend.cliCalls.map(\.arguments) == [["status"]])
    }

    @Test("CLI 실행 실패 시 unauthenticated")
    func statusViaCLIFailure() async {
        let api = makeAPI()
        #expect(await api.getStatus() == .unauthenticated)
    }

    @Test("serve 실행 중이면 /status 응답을 파싱하고 CLI는 호출하지 않음")
    func statusViaServe() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let api = makeAPI(backend: backend)

        #expect(await api.startServe(sessionToken: "tok"))
        #expect(await api.getStatus() == .unlocked)
        #expect(backend.cliCalls.isEmpty)
    }
}

// MARK: - 잠금 해제 / 잠금

@Suite("잠금 해제와 잠금")
struct UnlockTests {
    @Test("성공 시 토큰을 trim 하여 반환하고 저장소에 저장")
    func unlockSuccess() async throws {
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: "session-token\n", stderr: "", exitCode: 0)
        let store = FakeTokenStore()
        let api = makeAPI(backend: backend, store: store)

        let result = await api.unlock(password: "master")

        #expect(try result.get() == "session-token")
        #expect(store.token == "session-token")
        let call = try #require(backend.cliCalls.first)
        #expect(call.arguments == ["unlock", "--passwordenv", "BW_PASSWORD", "--raw"])
        #expect(call.environment["BW_PASSWORD"] == "master")
    }

    @Test("비밀번호가 프로세스 인자에 노출되지 않음")
    func passwordNotInArguments() async {
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: "tok", stderr: "", exitCode: 0)
        let api = makeAPI(backend: backend)

        _ = await api.unlock(password: "s3cret")

        #expect(!backend.cliCalls.flatMap(\.arguments).contains { $0.contains("s3cret") })
    }

    // 버그 A: 실패 원인과 무관하게 "비밀번호가 올바르지 않습니다"만 표시됨
    @Test("CLI 실패 시 bw stderr 를 실패 원인으로 전달, 저장하지 않음")
    func unlockFailureCarriesStderr() async {
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: "", stderr: "Invalid master password.\n", exitCode: 1)
        let store = FakeTokenStore()
        let api = makeAPI(backend: backend, store: store)

        let result = await api.unlock(password: "wrong")

        #expect(result == .failure(.cliFailed(exitCode: 1, message: "Invalid master password.")))
        #expect(store.token == nil)
    }

    @Test("bw 실행 자체가 불가하면 launchFailed")
    func unlockLaunchFailure() async {
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: nil, stderr: nil, exitCode: -1)
        let api = makeAPI(backend: backend)

        #expect(await api.unlock(password: "master") == .failure(.launchFailed))
    }

    @Test("exit 0 이지만 출력이 비어 있으면 emptyToken")
    func unlockEmptyOutput() async {
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: "  \n", stderr: "", exitCode: 0)
        let api = makeAPI(backend: backend)

        #expect(await api.unlock(password: "master") == .failure(.emptyToken))
    }

    @Test("unlockAndServe 성공 시 serve 기동 + 토큰 저장")
    func unlockAndServeSuccess() async throws {
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: "tok\n", stderr: "", exitCode: 0)
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let store = FakeTokenStore()
        let api = makeAPI(backend: backend, store: store)

        #expect(await api.unlockAndServe(password: "master") == nil)
        #expect(await api.isServing)
        #expect(store.token == "tok")
        #expect(backend.launches.first?.environment["BW_SESSION"] == "tok")
    }

    // 버그 C: serve 기동 실패를 무시하고 검색 패널을 띄워 "잠금 해제 필요" 무한 루프
    @Test("unlockAndServe: 잠금 해제는 됐지만 serve 가 안 뜨면 serveFailed, 토큰은 유지")
    func unlockAndServeServeFails() async {
        struct LaunchFailed: Error {}
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: "tok\n", stderr: "", exitCode: 0)
        backend.launchError = LaunchFailed()
        let store = FakeTokenStore()
        let api = makeAPI(backend: backend, store: store)

        #expect(await api.unlockAndServe(password: "master") == .serveFailed)
        #expect(await !api.isServing)
        #expect(store.token == "tok")
    }

    @Test("unlockAndServe: 잠금 해제 실패 시 serve 를 띄우지 않음")
    func unlockAndServeUnlockFails() async {
        let backend = FakeBackend()
        backend.cliResults["unlock"] = CLIResult(stdout: "", stderr: "Invalid master password.", exitCode: 1)
        let api = makeAPI(backend: backend)

        #expect(await api.unlockAndServe(password: "wrong")
            == .cliFailed(exitCode: 1, message: "Invalid master password."))
        #expect(backend.launches.isEmpty)
    }

    @Test("lock 은 serve 종료 → bw lock → 토큰 삭제")
    func lockStopsServeAndClearsToken() async throws {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let store = FakeTokenStore()
        store.token = "tok"
        let api = makeAPI(backend: backend, store: store)
        #expect(await api.startServe(sessionToken: "tok"))

        await api.lock()

        let serve = try #require(backend.launches.first?.serve)
        #expect(serve.terminateCount == 1)
        #expect(await !api.isServing)
        #expect(backend.cliCalls.map(\.arguments) == [["lock"]])
        #expect(store.token == nil)
    }
}

// MARK: - bw serve

@Suite("bw serve 관리")
struct ServeTests {
    @Test("loopback 바인딩 + BW_SESSION 환경변수로 기동")
    func launchArguments() async throws {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let api = makeAPI(backend: backend)

        #expect(await api.startServe(sessionToken: "tok"))
        #expect(await api.isServing)

        let launch = try #require(backend.launches.first)
        #expect(launch.arguments == ["serve", "--hostname", "127.0.0.1", "--port", "18087"])
        #expect(launch.environment["BW_SESSION"] == "tok")
    }

    @Test("/status 응답이 없으면 타임아웃 후 false + 프로세스 종료")
    func startTimeout() async throws {
        let backend = FakeBackend()
        let api = makeAPI(backend: backend)

        #expect(await !api.startServe(sessionToken: "tok"))
        #expect(await !api.isServing)
        let serve = try #require(backend.launches.first?.serve)
        #expect(serve.terminateCount == 1)
    }

    @Test("프로세스 실행 자체가 실패하면 false")
    func launchFailure() async {
        struct LaunchFailed: Error {}
        let backend = FakeBackend()
        backend.launchError = LaunchFailed()
        let api = makeAPI(backend: backend)

        #expect(await !api.startServe(sessionToken: "tok"))
        #expect(await !api.isServing)
    }

    @Test("재기동 시 이전 serve 를 먼저 종료")
    func restartTerminatesPrevious() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let api = makeAPI(backend: backend)

        #expect(await api.startServe(sessionToken: "a"))
        #expect(await api.startServe(sessionToken: "b"))

        #expect(backend.launches.count == 2)
        #expect(backend.launches[0].serve.terminateCount == 1)
        #expect(backend.launches[1].serve.isRunning)
    }

    @Test("포트가 비어 있으면 고아 정리를 시도하지 않음")
    func noOrphanNoTermination() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let api = makeAPI(backend: backend)

        #expect(await api.startServe(sessionToken: "tok"))
        #expect(backend.orphanTerminationPorts.isEmpty)
    }

    // 버그 D: 이전 실행이 남긴 고아 bw serve 가 포트를 점유 → 새 serve 는 bind 실패로 죽지만
    // 고아의 /status 응답 때문에 "준비됨"으로 오판 → isServing=false → "잠금 해제 필요" 무한 루프
    @Test("고아 serve 가 포트를 점유 중이면 먼저 종료한 뒤 기동")
    func orphanTerminatedBeforeLaunch() async throws {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("locked")
        backend.orphanServeRunning = true
        let api = makeAPI(backend: backend)

        #expect(await api.startServe(sessionToken: "tok"))
        #expect(backend.orphanTerminationPorts == [18087])
        #expect(backend.launches.count == 1)
        #expect(await api.isServing)
    }

    @Test("고아 serve 를 종료할 수 없으면 기동하지 않고 false")
    func orphanCannotBeTerminated() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("locked")
        backend.orphanServeRunning = true
        backend.canTerminateOrphan = false
        let api = makeAPI(backend: backend)

        #expect(await !api.startServe(sessionToken: "tok"))
        #expect(backend.launches.isEmpty)
    }

    @Test("우리 serve 가 죽었는데 다른 서버가 응답하면 준비됨으로 오판하지 않음")
    func deadServeWithForeignResponder() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        backend.launchedServeDiesImmediately = true
        backend.onLaunch = { [unowned backend] in backend.orphanServeRunning = true }
        let api = makeAPI(backend: backend)

        #expect(await !api.startServe(sessionToken: "tok"))
        #expect(await !api.isServing)
    }
}

// MARK: - 세션 복원

@Suite("저장된 토큰으로 세션 복원")
struct ResumeSessionTests {
    @Test("저장된 토큰이 없으면 noToken, serve 를 띄우지 않음")
    func noToken() async {
        let backend = FakeBackend()
        let api = makeAPI(backend: backend)

        #expect(await api.resumeSession() == .noToken)
        #expect(backend.launches.isEmpty)
    }

    @Test("유효한 토큰이면 serve 기동 후 unlocked")
    func validToken() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let store = FakeTokenStore()
        store.token = "tok"
        let api = makeAPI(backend: backend, store: store)

        #expect(await api.resumeSession() == .unlocked)
        #expect(await api.isServing)
        #expect(backend.launches.first?.environment["BW_SESSION"] == "tok")
        #expect(store.token == "tok")
    }

    @Test("이미 serve 가 unlocked 상태면 재기동하지 않음")
    func alreadyServing() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let store = FakeTokenStore()
        store.token = "tok"
        let api = makeAPI(backend: backend, store: store)
        #expect(await api.resumeSession() == .unlocked)

        #expect(await api.resumeSession() == .unlocked)
        #expect(backend.launches.count == 1)
    }

    // 버그 E-1: Keychain 에서는 지우지만 actor 메모리의 stale 토큰이 남아 이후 CLI 호출에 BW_SESSION 으로 전달됨
    @Test("stale 토큰이면 tokenExpired: 저장소·메모리 모두 비우고 serve 종료")
    func staleToken() async throws {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("locked")
        backend.cliResults["status"] = Fixture.cliStatus("locked")
        let store = FakeTokenStore()
        store.token = "stale"
        let api = makeAPI(backend: backend, store: store)

        #expect(await api.resumeSession() == .tokenExpired)
        #expect(store.token == nil)
        #expect(await !api.isServing)

        _ = await api.getStatus()
        let lastCall = try #require(backend.cliCalls.last)
        #expect(lastCall.environment["BW_SESSION"] == nil)
    }

    // 버그 E-2: serve 가 일시적으로 실패해도 토큰을 폐기해 매번 마스터 비밀번호를 다시 요구
    @Test("serve 기동 실패는 serveFailed: 토큰은 유지")
    func serveLaunchFails() async {
        struct LaunchFailed: Error {}
        let backend = FakeBackend()
        backend.launchError = LaunchFailed()
        let store = FakeTokenStore()
        store.token = "tok"
        let api = makeAPI(backend: backend, store: store)

        #expect(await api.resumeSession() == .serveFailed)
        #expect(store.token == "tok")
    }
}

// MARK: - 항목 검색

@Suite("항목 검색")
struct ListItemsTests {
    private func servingAPI(items: [[String: Any]]) async -> (BitwardenAPI, FakeBackend) {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        backend.getResponses["/list/object/items"] = Fixture.items(items)
        let api = makeAPI(backend: backend)
        _ = await api.startServe(sessionToken: "tok")
        return (api, backend)
    }

    @Test("serve 미실행이면 notServing 에러")
    func notServing() async {
        let api = makeAPI()
        await #expect(throws: LoadError.notServing) {
            try await api.listItems(search: nil)
        }
    }

    @Test("로그인 타입(type == 1)만 반환")
    func onlyLoginItems() async throws {
        let (api, _) = await servingAPI(items: [
            Fixture.login("1", name: "GitHub"),
            Fixture.secureNote("2", name: "Memo"),
        ])

        let items = try await api.listItems(search: nil)
        #expect(items.map(\.id) == ["1"])
    }

    @Test("정확 일치 > 접두사 > 부분 일치 > username/uri 순 정렬, 불일치 제외")
    func scoring() async throws {
        let (api, _) = await servingAPI(items: [
            Fixture.login("uri", name: "Work", uri: "https://git.example.com"),
            Fixture.login("contains", name: "My Git Server"),
            Fixture.login("prefix", name: "GitHub"),
            Fixture.login("exact", name: "git"),
            Fixture.login("none", name: "Slack"),
        ])

        let items = try await api.listItems(search: "GIT")
        #expect(items.map(\.id) == ["exact", "prefix", "contains", "uri"])
    }

    @Test("HTTP 실패 시 httpFailure")
    func httpFailure() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        let api = makeAPI(backend: backend)
        _ = await api.startServe(sessionToken: "tok")

        await #expect(throws: LoadError.httpFailure) {
            try await api.listItems(search: nil)
        }
    }

    @Test("응답 형식이 다르면 parseFailure")
    func parseFailure() async {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        backend.getResponses["/list/object/items"] = Data(#"{"success":false}"#.utf8)
        let api = makeAPI(backend: backend)
        _ = await api.startServe(sessionToken: "tok")

        await #expect(throws: LoadError.parseFailure) {
            try await api.listItems(search: nil)
        }
    }

    @Test("invalidateCache 는 serve 에 /sync 요청")
    func invalidateCacheSyncs() async {
        let (api, backend) = await servingAPI(items: [])

        await api.invalidateCache()

        #expect(backend.postPaths == ["/sync"])
    }
}
