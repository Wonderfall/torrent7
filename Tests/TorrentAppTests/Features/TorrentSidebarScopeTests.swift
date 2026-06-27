import Testing
@testable import TorrentApp

@Suite("Torrent sidebar scope")
struct TorrentSidebarScopeTests {
    @Test("Scopes include matching torrent states")
    func scopesIncludeMatchingTorrentStates() {
        let error = makeTorrent(error: "disk full")
        let activeDownload = makeTorrent(state: .downloading)
        let activeUpload = makeTorrent(uploadRate: 1, seeding: true)
        let seeding = makeTorrent(seeding: true)
        let queued = makeTorrent(paused: true, autoManaged: true)
        let paused = makeTorrent(paused: true, autoManaged: false)
        let completed = makeTorrent(finished: true)
        let metadata = makeTorrent(state: .downloadingMetadata, hasMetadata: false)
        let completedSeeding = makeTorrent(seeding: true, finished: true)
        let highPriority = makeTorrent(queuePriority: .high)
        let normalPriority = makeTorrent(queuePriority: .normal)
        let lowPriority = makeTorrent(queuePriority: .low)

        #expect(TorrentSidebarScope.all.contains(error))
        #expect(TorrentSidebarScope.errors.contains(error))
        #expect(TorrentSidebarScope.active.contains(activeDownload))
        #expect(TorrentSidebarScope.active.contains(activeUpload))
        #expect(TorrentSidebarScope.seeding.contains(seeding))
        #expect(TorrentSidebarScope.queued.contains(queued))
        #expect(TorrentSidebarScope.paused.contains(paused))
        #expect(TorrentSidebarScope.completed.contains(completed))
        #expect(TorrentSidebarScope.completed.contains(completedSeeding))
        #expect(TorrentSidebarScope.downloading.contains(metadata))
        #expect(TorrentSidebarScope.priorityHigh.contains(highPriority))
        #expect(TorrentSidebarScope.priorityNormal.contains(normalPriority))
        #expect(TorrentSidebarScope.priorityLow.contains(lowPriority))
    }

    @Test("Scopes exclude errors and incompatible states")
    func scopesExcludeErrorsAndIncompatibleStates() {
        let erroredDownload = makeTorrent(error: "disk full", state: .downloading)
        let pausedDownload = makeTorrent(state: .downloading, paused: true, autoManaged: false)
        let seeding = makeTorrent(seeding: true, finished: true)
        let pausedSeeding = makeTorrent(paused: true, autoManaged: false, seeding: true, finished: true)

        #expect(!TorrentSidebarScope.active.contains(erroredDownload))
        #expect(!TorrentSidebarScope.downloading.contains(pausedDownload))
        #expect(!TorrentSidebarScope.seeding.contains(pausedSeeding))
        #expect(TorrentSidebarScope.completed.contains(seeding))
        #expect(TorrentSidebarScope.completed.contains(pausedSeeding))
        #expect(!TorrentSidebarScope.errors.contains(makeTorrent()))
        #expect(!TorrentSidebarScope.priorityHigh.contains(makeTorrent(queuePriority: .normal)))
        #expect(!TorrentSidebarScope.priorityLow.contains(makeTorrent(queuePriority: .high)))
    }

    @Test("Sidebar scopes have stable labels and symbols")
    func sidebarScopesHaveStableLabelsAndSymbols() {
        #expect(TorrentSidebarScope.all.title == "All")
        #expect(TorrentSidebarScope.completed.emptyTitle == "No Completed Torrents")
        #expect(TorrentSidebarScope.errors.systemImage == "exclamationmark.triangle")
        #expect(TorrentSidebarScope.statusScopes == [.all, .active, .downloading, .seeding, .queued, .paused, .completed, .errors])
        #expect(TorrentSidebarScope.statusFilterScopes == [.active, .downloading, .seeding, .queued, .paused, .completed, .errors])
        #expect(TorrentSidebarScope.priorityScopes == [.priorityHigh, .priorityNormal, .priorityLow])
        #expect(TorrentSidebarScope.active.isStatusFilterScope)
        #expect(!TorrentSidebarScope.all.isStatusFilterScope)
        #expect(TorrentSidebarScope.priorityHigh.title == "High")
        #expect(TorrentSidebarScope.priorityNormal.emptyTitle == "No Normal Priority Torrents")
        #expect(TorrentSidebarScope.priorityLow.systemImage == "arrow.down.circle")
    }

    @Test("Sidebar selection can filter labels")
    func sidebarSelectionCanFilterLabels() {
        let torrent = makeTorrent(id: "alpha")
        let label = TorrentLabel(id: "linux", name: "Linux")
        let selection = TorrentSidebarSelection.label(label.id)

        #expect(selection.contains(torrent, labelIDs: ["linux"], trackerHosts: []))
        #expect(!selection.contains(torrent, labelIDs: ["iso"], trackerHosts: []))
        #expect(selection.emptyTitle(labels: [label]) == "No Linux Torrents")
        #expect(selection.emptySystemImage(labels: [label]) == "tag")
    }

    @Test("Sidebar selection can filter unlabeled torrents")
    func sidebarSelectionCanFilterUnlabeledTorrents() {
        let torrent = makeTorrent(id: "alpha")
        let selection = TorrentSidebarSelection.unlabeled

        #expect(selection.contains(torrent, labelIDs: [], trackerHosts: []))
        #expect(!selection.contains(torrent, labelIDs: ["linux"], trackerHosts: []))
        #expect(selection.emptyTitle(labels: []) == "No Unlabeled Torrents")
        #expect(selection.emptySystemImage(labels: []) == "tag.slash")
        #expect(selection.isLabelScope)
    }

    @Test("Sidebar selection can filter tracker hosts")
    func sidebarSelectionCanFilterTrackerHosts() {
        let torrent = makeTorrent(id: "alpha")
        let selection = TorrentSidebarSelection.trackerHost("tracker.example.org")

        #expect(selection.contains(torrent, labelIDs: [], trackerHosts: ["tracker.example.org"]))
        #expect(!selection.contains(torrent, labelIDs: [], trackerHosts: ["tracker.example.com"]))
        #expect(selection.emptyTitle(labels: []) == "No Torrents from tracker.example.org")
        #expect(selection.emptySystemImage(labels: []) == "antenna.radiowaves.left.and.right")
        #expect(selection.isTrackerScope)
    }

    @Test("Sidebar selection can filter torrents without trackers")
    func sidebarSelectionCanFilterTorrentsWithoutTrackers() {
        let torrent = makeTorrent(id: "alpha")
        let selection = TorrentSidebarSelection.noTrackers

        #expect(selection.contains(torrent, labelIDs: [], trackerHosts: []))
        #expect(!selection.contains(torrent, labelIDs: [], trackerHosts: ["tracker.example.org"]))
        #expect(selection.emptyTitle(labels: []) == "No Torrents Without Trackers")
        #expect(selection.emptySystemImage(labels: []) == "antenna.radiowaves.left.and.right.slash")
        #expect(selection.isTrackerScope)
    }

    @Test("Built-in unlabeled selection ID cannot collide with label IDs")
    func builtInUnlabeledSelectionIDCannotCollideWithLabelIDs() {
        #expect(TorrentSidebarSelection.unlabeled.id != TorrentSidebarSelection.label("unlabeled").id)
    }
}
