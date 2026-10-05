import AppKit
import SwiftUI
import TorrentAppInfrastructure
import TorrentEngineModel

struct TorrentPeersView: View {
    @Environment(TorrentStore.self) private var store
    let torrentID: String
    let isPresented: Bool
    @State private var snapshot: TorrentPeerSnapshot?
    @State private var rows = [TorrentPeerRow]()
    @State private var countries: TorrentCountryDatabase?
    @State private var error: String?
    @State private var countryDataUnavailable = false
    @State private var sortOrder = [TorrentPeerRow.Sort(.address)]

    private struct PresentationRequest: Equatable {
        let snapshot: TorrentPeerSnapshot?
        let sortOrder: [TorrentPeerRow.Sort]
        let countryDate: UInt32?
        let isPresented: Bool
    }

    var body: some View {
        TorrentPeersContent(
            rows: rows, totalCount: snapshot?.totalCount, sortOrder: $sortOrder,
            error: error, countryDataUnavailable: countryDataUnavailable
        )
        .task(id: isPresented) {
            guard isPresented else { return }
            do { countries = try await TorrentCountryDatabase.loadBundled() }
            catch is CancellationError { return }
            catch { countryDataUnavailable = true }
            while !Task.isCancelled {
                do {
                    let value = try await store.peers(for: torrentID)
                    try Task.checkCancellation()
                    snapshot = value
                    error = nil
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    self.error = "Peer information could not be refreshed. Retrying…"
                }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .task(id: PresentationRequest(
            snapshot: snapshot, sortOrder: sortOrder, countryDate: countries?.date, isPresented: isPresented
        )) {
            guard isPresented, let snapshot else { return }
            do {
                let prepared = try await TorrentPeerRow.prepare(
                    snapshot: snapshot, countries: countries, sortOrder: sortOrder
                )
                try Task.checkCancellation()
                rows = prepared
            } catch { return }
        }
    }
}

/// Separate immutable content keeps previews deterministic and uses the same
/// grouped Form / native Table presentation as Files.
struct TorrentPeersContent: View {
    let rows: [TorrentPeerRow]
    let totalCount: Int32?
    @Binding var sortOrder: [TorrentPeerRow.Sort]
    var error: String?
    var countryDataUnavailable = false
    @State private var selection: TorrentPeer.ID?
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            if let error {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            Section {
                if totalCount == nil {
                    ProgressView("Loading peers…").controlSize(.small)
                } else if rows.isEmpty {
                    Text("No Connected Peers").foregroundStyle(.secondary)
                } else {
                    table
                }
            } header: {
                HStack {
                    Label("Peers", systemImage: "person.2")
                    Spacer()
                    if let totalCount {
                        Text(summary(totalCount: totalCount))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                if countryDataUnavailable {
                    Text("Country information is unavailable.")
                }
                if let totalCount, totalCount > rows.count {
                    Text("Showing \(rows.count.formatted()) of \(totalCount.formatted()) connected peers.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var table: some View {
        Table(of: TorrentPeerRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Peer", sortUsing: TorrentPeerRow.Sort(.address)) { row in
                HStack(spacing: 6) {
                    Text(row.flag).frame(width: 20).accessibilityHidden(true)
                    Text(row.address).monospacedDigit().lineLimit(1).truncationMode(.middle)
                }
                .help("\(row.endpoint)\n\(row.country) (IP location)\n\(row.connectionDetails)")
                .accessibilityLabel("\(row.address), \(row.country)")
            }
            .width(min: 110, max: .infinity)
            .disabledCustomizationBehavior(.resize)

            TableColumn("Client", sortUsing: TorrentPeerRow.Sort(.client)) { row in
                Text(row.peer.client.isEmpty ? "Unknown" : row.peer.client)
                    .lineLimit(1).help(row.peer.client.isEmpty ? "Unknown client" : row.peer.client)
            }
            // Start compact so all five columns fit the inspector's minimum width.
            .width(min: 70, ideal: 70, max: 160)
            .disabledCustomizationBehavior(.resize)

            TableColumn("Progress", sortUsing: TorrentPeerRow.Sort(.progress)) { row in
                Text(row.peer.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.peer.flags.contains(.seed) ? "Seed · Peer has the complete torrent" : "Portion of the torrent this peer has")
            }
            .width(62)

            TableColumn("Download", sortUsing: TorrentPeerRow.Sort(.download)) { row in
                rate(row.peer.downloadRate)
                    .help("\(row.downloadState)\nReceived \(ByteFormat.size(row.peer.downloaded)) this connection")
            }
            .width(76)

            TableColumn("Upload", sortUsing: TorrentPeerRow.Sort(.upload)) { row in
                rate(row.peer.uploadRate)
                    .help("\(row.uploadState)\nSent \(ByteFormat.size(row.peer.uploaded)) this connection")
            }
            .width(76)
        } rows: {
            ForEach(rows) { row in TableRow(row) }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .controlSize(.small)
        .focused($isFocused)
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        // The grouped Form owns scrolling, including when peers join or leave.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Connected peers")
        .contextMenu(forSelectionType: TorrentPeer.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Copy IP Address") { copy(row.address) }
                Button("Copy Endpoint") { copy(row.endpoint) }
            }
        }
        .copyable(rows.first(where: { $0.id == selection }).map { [$0.address] } ?? [])
    }

    private func rate(_ value: Int32) -> some View {
        Text(value == 0 ? "—" : ByteFormat.rate(value))
            .monospacedDigit()
            .foregroundStyle(value == 0 ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(value == 0 ? "0 bytes per second" : ByteFormat.rate(value))
    }

    private func summary(totalCount: Int32) -> String {
        let seeds = rows.count { $0.peer.flags.contains(.seed) }
        let count = "\(totalCount.formatted()) connected"
        guard seeds > 0, totalCount == rows.count else { return count }
        return "\(count) · \(seeds.formatted()) \(seeds == 1 ? "seed" : "seeds")"
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
