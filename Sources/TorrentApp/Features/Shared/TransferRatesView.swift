import SwiftUI

private struct RateText: View {
    let systemImage: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .lineLimit(1)
    }
}

struct TransferRatesView: View {
    let downloadRate: Int64
    let uploadRate: Int64
    let showsDownloadRate: Bool
    let showsUploadRate: Bool
    let helpText: String?

    init(
        downloadRate: Int64,
        uploadRate: Int64,
        showsDownloadRate: Bool,
        showsUploadRate: Bool,
        helpText: String? = nil
    ) {
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.showsDownloadRate = showsDownloadRate
        self.showsUploadRate = showsUploadRate
        self.helpText = helpText
    }

    var body: some View {
        HStack(spacing: 10) {
            if showsDownloadRate {
                RateText(systemImage: "arrow.down", value: ByteFormat.rate(downloadRate))
            }
            if showsUploadRate {
                RateText(systemImage: "arrow.up", value: ByteFormat.rate(uploadRate))
            }
        }
        .foregroundStyle(.secondary)
        .help(helpText ?? "")
    }
}
