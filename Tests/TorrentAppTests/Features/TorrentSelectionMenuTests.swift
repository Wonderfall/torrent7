import AppKit
import SwiftUI
import Testing
import TorrentEngineModel
@testable import TorrentApp

@MainActor
@Suite("Native menu selection", .serialized)
struct TorrentSelectionMenuTests {
    @Test("Aggregate selection renders native states and sends one bulk command",
          arguments: [(0, 3, 0), (1, 3, -1), (3, 3, 1), (0, 1, 0), (1, 1, 1)])
    func aggregateSelection(selected: Int, total: Int, state: Int) throws {
        _ = NSApplication.shared
        var activations = 0
        let menu = NSHostingMenu(rootView: TorrentSelectionMenuToggle(
            title: "Linux", selectedCount: selected, totalCount: total
        ) { activations += 1 })
        menu.update()
        let item = try #require(menu.items.first)
        #expect(menu.items.count == 1)
        #expect(item.title == "Linux")
        #expect(item.state.rawValue == state)
        #expect(item.isEnabled)
        menu.performActionForItem(at: 0)
        #expect(activations == 1)
    }

    @Test("Empty aggregate selection is disabled and unchecked")
    func emptySelection() throws {
        _ = NSApplication.shared
        let menu = NSHostingMenu(rootView: TorrentSelectionMenuToggle(
            title: "Linux", selectedCount: 0, totalCount: 0
        ) { Issue.record("Empty selection invoked a bulk action") })
        menu.update()
        let item = try #require(menu.items.first)
        #expect(item.state == .off)
        #expect(!item.isEnabled)
    }

    @Test("Priority picker has a native selected value, including mixed priorities",
          arguments: [Optional<TorrentQueuePriority>.none] + TorrentQueuePriority.allCases.map(Optional.some))
    func prioritySelection(_ priority: TorrentQueuePriority?) throws {
        _ = NSApplication.shared
        var writes: [TorrentQueuePriority] = []
        let menu = NSHostingMenu(rootView: TorrentPriorityMenu(selection: priority) { writes.append($0) })
        menu.update()
        let submenu = try #require(menu.items.first?.submenu)
        submenu.update()
        let selected = submenu.items.filter { $0.state == .on }
        #expect(selected.count == 1)
        #expect(selected.first?.title == (priority?.title ?? "Mixed Priorities"))
        let chosenPriority: TorrentQueuePriority = priority == .high ? .low : .high
        let chosen = try #require(submenu.items.firstIndex { $0.title == chosenPriority.title })
        submenu.performActionForItem(at: chosen)
        #expect(writes == [chosenPriority])
    }
}
