import AppKit

/// 현재 활성 앱 정보
struct AppContext {
    let bundleIdentifier: String
    let appName: String
}

/// 현재 포커스된 앱을 감지
enum AppContextDetector {
    /// 현재 최상위 앱 정보 반환
    static func frontmostApp() -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleId = app.bundleIdentifier ?? "unknown"
        let name = app.localizedName ?? "unknown"
        return AppContext(bundleIdentifier: bundleId, appName: name)
    }

    /// 번들 ID에서 서비스명 매핑
    static func guessServiceName(from bundleId: String) -> String? {
        let mapping: [String: String] = [
            "com.tinyspeck.slackmacgap": "slack",
            "com.spotify.client": "spotify",
            "com.figma.Desktop": "figma",
            "com.linear": "linear",
            "com.notion.id": "notion",
            "com.github.GitHubClient": "github",
            "com.microsoft.teams2": "teams",
            "com.microsoft.Outlook": "outlook",
            "com.apple.mail": "mail",
            "com.discord.Discord": "discord",
            "com.openai.chat": "chatgpt",
            "us.zoom.xos": "zoom",
            "com.docker.docker": "docker",
            "com.jetbrains.intellij.ce": "jetbrains",
            "com.microsoft.VSCode": "vscode",
        ]
        return mapping[bundleId]
    }
}
