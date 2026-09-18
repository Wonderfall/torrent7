import SwiftUI
import TorrentEngineModel

struct TorrentPriorityMenu: View {
    let selection: TorrentQueuePriority?
    let setPriority: (TorrentQueuePriority) -> Void

    var body: some View {
        Picker("Priority", selection: Binding(
            get: { selection },
            set: { if let priority = $0 { setPriority(priority) } }
        )) {
            if selection == nil {
                Text("Mixed Priorities")
                    .tag(Optional<TorrentQueuePriority>.none)
                    .disabled(true)
            }
            ForEach(TorrentQueuePriority.allCases) { priority in
                Text(priority.title).tag(Optional(priority))
            }
        }
        .pickerStyle(.menu)
    }
}
