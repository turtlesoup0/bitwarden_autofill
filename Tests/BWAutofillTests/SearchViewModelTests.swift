import Foundation
import Testing
@testable import BWAutofill

@MainActor
@Suite("검색 패널 선택 이동")
struct SearchViewModelTests {
    /// count 개의 로그인 항목을 가진 serve 상태의 뷰모델
    private func makeViewModel(itemCount: Int) async -> SearchViewModel {
        let backend = FakeBackend()
        backend.getResponses["/status"] = Fixture.serveStatus("unlocked")
        backend.getResponses["/list/object/items"] = Fixture.items(
            (0..<itemCount).map { Fixture.login("\($0)", name: "item \($0)") }
        )
        let api = BitwardenAPI(port: 18087, backend: backend, tokenStore: FakeTokenStore(), serveStartTimeout: 0.5)
        _ = await api.startServe(sessionToken: "tok")

        let viewModel = SearchViewModel(bitwardenAPI: api, initialSearch: "", onDismiss: {}, onRequestUnlock: {})
        await viewModel.search()
        return viewModel
    }

    // 버그: 목록은 20개만 표시하는데 ↓ 이동은 전체 개수까지 가능 → 화면에 없는 항목이 선택·펼쳐짐
    @Test("결과가 표시 한도(20)보다 많아도 선택은 마지막 표시 항목에서 멈춤")
    func moveDownStopsAtLastVisibleItem() async {
        let viewModel = await makeViewModel(itemCount: 25)
        #expect(viewModel.items.count == 25)

        for _ in 0..<30 { viewModel.moveDown() }

        #expect(viewModel.selectedIndex == SearchViewModel.maxVisibleItems - 1)
    }

    @Test("Enter 는 표시된 항목만 펼침")
    func confirmExpandsVisibleItem() async {
        let viewModel = await makeViewModel(itemCount: 25)

        for _ in 0..<30 { viewModel.moveDown() }
        viewModel.confirm()

        #expect(viewModel.expandedItemId == viewModel.visibleItems.last?.id)
    }

    @Test("결과가 한도보다 적으면 실제 개수에서 멈춤")
    func moveDownStopsAtLastItemWhenFew() async {
        let viewModel = await makeViewModel(itemCount: 3)

        for _ in 0..<10 { viewModel.moveDown() }

        #expect(viewModel.selectedIndex == 2)
        #expect(viewModel.visibleItems.count == 3)
    }

    @Test("위로 이동은 0 에서 멈춤")
    func moveUpStopsAtZero() async {
        let viewModel = await makeViewModel(itemCount: 3)

        viewModel.moveUp()

        #expect(viewModel.selectedIndex == 0)
    }
}
