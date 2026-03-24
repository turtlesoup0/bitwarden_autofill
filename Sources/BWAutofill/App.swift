import SwiftUI

@main
struct BWAutofillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 메뉴바 전용 앱 - 메인 윈도우 없음
        Settings {
            EmptyView()
        }
    }
}
