import SwiftUI
import TorrentAppInfrastructure

struct AcknowledgmentsView: View {
    private enum LoadState {
        case loading
        case loaded(String)
        case unavailable
    }

    @State private var state = LoadState.loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading acknowledgments…")
            case .loaded(let text):
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            case .unavailable:
                ContentUnavailableView(
                    "Acknowledgments Unavailable",
                    systemImage: "doc.text",
                    description: Text("The bundled third-party notices could not be read.")
                )
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .task {
            do {
                let text = try await ThirdPartyNotices.loadBundled()
                try Task.checkCancellation()
                state = .loaded(text)
            } catch is CancellationError { return }
            catch { state = .unavailable }
        }
    }
}
