import AppKit
import SwiftUI

/// 포커스를 빼앗지 않는 Floating 패널
/// 1Password Quick Access 스타일의 검색 UI
class SearchPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // 패널 설정
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        // 항상 키 입력을 받을 수 있도록
        becomesKeyOnlyIfNeeded = false

        // 화면 중앙 상단에 표시
        positionCenter()
    }

    private func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        // 화면 상단에서 약간 아래 (1Password 스타일)
        let y = screenFrame.maxY - frame.height - 120
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // ESC로 닫기
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    // 패널이 key window가 될 수 있도록
    override var canBecomeKey: Bool { true }
}

/// 검색 패널을 관리하는 컨트롤러
class SearchPanelController {
    private var panel: SearchPanel?
    private var hostingView: NSHostingView<SearchView>?
    private let bitwardenAPI: BitwardenAPI
    private var escMonitor: Any?

    // 호출 시점의 앱 컨텍스트 저장
    private var callerAppContext: AppContext?

    init(bitwardenAPI: BitwardenAPI) {
        self.bitwardenAPI = bitwardenAPI
    }

    @MainActor
    func show() {
        // 이미 열려있으면 포커스만 다시 줌
        if let existingPanel = panel, existingPanel.isVisible {
            existingPanel.makeKeyAndOrderFront(nil)
            return
        }

        // 현재 앱 컨텍스트 캡처 (패널 표시 전)
        callerAppContext = AppContextDetector.frontmostApp()

        let initialSearch = callerAppContext.flatMap {
            AppContextDetector.guessServiceName(from: $0.bundleIdentifier)
        } ?? ""

        let viewModel = SearchViewModel(
            bitwardenAPI: bitwardenAPI,
            initialSearch: initialSearch,
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let searchView = SearchView(viewModel: viewModel)
        let panel = SearchPanel()
        let hostingView = NSHostingView(rootView: searchView)
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView

        // 키보드 이벤트 모니터 (ESC + Cmd+R)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak viewModel] event in
            if event.keyCode == 53 { // ESC
                self?.hide()
                return nil
            }
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "r" {
                viewModel?.refresh()
                return nil
            }
            return event
        }

        panel.makeKeyAndOrderFront(nil)

        // 캐시 무효화 후 초기 검색 (순서 보장)
        Task {
            await bitwardenAPI.invalidateCache()
            if !initialSearch.isEmpty {
                await viewModel.search()
            }
        }
    }

    func hide() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        panel?.close()
        panel = nil
        hostingView = nil
    }
}

// MARK: - SearchViewModel

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query: String {
        didSet { debounceSearch() }
    }
    @Published var items: [VaultItem] = []
    @Published var selectedIndex: Int = 0
    @Published var expandedItemId: String? = nil
    @Published var isLoading = false
    @Published var copiedField: String? = nil

    private let bitwardenAPI: BitwardenAPI
    private let onDismiss: () -> Void
    private var searchTask: Task<Void, Never>?

    init(
        bitwardenAPI: BitwardenAPI,
        initialSearch: String,
        onDismiss: @escaping () -> Void
    ) {
        self.query = initialSearch
        self.bitwardenAPI = bitwardenAPI
        self.onDismiss = onDismiss
    }

    private func debounceSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    func search() async {
        isLoading = true
        let searchQuery = query.isEmpty ? nil : query
        let results = await bitwardenAPI.listItems(search: searchQuery)
        items = results
        selectedIndex = 0
        expandedItemId = nil
        isLoading = false
    }

    func moveUp() {
        if selectedIndex > 0 { selectedIndex -= 1 }
    }

    func moveDown() {
        if selectedIndex < items.count - 1 { selectedIndex += 1 }
    }

    /// Enter로 항목 펼치기/접기
    func confirm() {
        guard !items.isEmpty, selectedIndex < items.count else { return }
        let item = items[selectedIndex]
        if expandedItemId == item.id {
            expandedItemId = nil
        } else {
            expandedItemId = item.id
        }
    }

    /// 클립보드에 복사 + 피드백 표시
    func copyToClipboard(_ text: String, fieldName: String, isSecret: Bool = false) {
        SecurityManager.secureClipboard(text: text, concealed: isSecret)
        copiedField = fieldName
        // 1.5초 후 피드백 제거
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedField == fieldName {
                copiedField = nil
            }
        }
    }

    /// 캐시 무효화 후 재검색
    func refresh() {
        Task {
            await bitwardenAPI.invalidateCache()
            await search()
        }
    }

    func dismiss() {
        onDismiss()
    }
}

// MARK: - SearchView (SwiftUI)

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 검색 입력
            SearchInputView(query: $viewModel.query, onConfirm: {
                viewModel.confirm()
            }, onMoveUp: {
                viewModel.moveUp()
            }, onMoveDown: {
                viewModel.moveDown()
            }, onEscape: {
                viewModel.dismiss()
            })
            .padding(12)

            Divider()

            // 복사 피드백
            if let field = viewModel.copiedField {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("\(field) 복사됨")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.1))
                .transition(.opacity)
            }

            // 결과 목록
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if viewModel.items.isEmpty {
                Text(viewModel.query.isEmpty ? "Cmd+\\ 로 빠른 검색" : "결과 없음")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(viewModel.items.prefix(20).enumerated()), id: \.element.id) { idx, item in
                                ItemRow(
                                    item: item,
                                    isSelected: idx == viewModel.selectedIndex,
                                    isExpanded: viewModel.expandedItemId == item.id,
                                    onTap: {
                                        viewModel.selectedIndex = idx
                                        viewModel.confirm()
                                    },
                                    onCopyUsername: {
                                        if let username = item.username {
                                            viewModel.copyToClipboard(username, fieldName: "ID")
                                        }
                                    },
                                    onCopyPassword: {
                                        if let password = item.password {
                                            viewModel.copyToClipboard(password, fieldName: "Password", isSecret: true)
                                        }
                                    }
                                )
                                .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: viewModel.selectedIndex) { newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 420, height: 360)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.15), value: viewModel.copiedField)
        .animation(.easeInOut(duration: 0.15), value: viewModel.expandedItemId)
    }
}

struct SearchInputView: NSViewRepresentable {
    @Binding var query: String
    let onConfirm: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "검색... (⌘R 새로고침)"
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 18, weight: .light)
        field.focusRingType = .none
        field.delegate = context.coordinator

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != query {
            nsView.stringValue = query
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: SearchInputView

        init(_ parent: SearchInputView) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.query = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onConfirm()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

struct ItemRow: View {
    let item: VaultItem
    let isSelected: Bool
    let isExpanded: Bool
    let onTap: () -> Void
    let onCopyUsername: () -> Void
    let onCopyPassword: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 항목 헤더
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)

                    if let username = item.username {
                        Text(username)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // 펼쳐진 상태: 복사 버튼들
            if isExpanded {
                VStack(spacing: 4) {
                    if item.username != nil {
                        CopyButton(label: "ID", value: item.username ?? "", onCopy: onCopyUsername)
                    }
                    if item.password != nil {
                        CopyButton(label: "Password", value: "••••••••", onCopy: onCopyPassword)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .padding(.leading, 34)
            }
        }
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct CopyButton: View {
    let label: String
    let value: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { onCopy() }
    }
}

/// macOS 블러 배경 효과
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
