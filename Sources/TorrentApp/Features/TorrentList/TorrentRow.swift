import SwiftUI
import TorrentEngineModel

struct TorrentRow: View {
    let row: TorrentRowSnapshot
    let metricsState: TorrentTransferMetricsState
    let labels: [TorrentLabel]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    TorrentFileIcon(row: row)

                    Text(row.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !labels.isEmpty {
                        TorrentLabelPillStrip(labels: labels)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 12)

                Text(metrics.progress, format: .percent.precision(.fractionLength(1)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TorrentMetadataStrip(chips: metadataChips)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                TransferRatesView(
                    downloadRate: Int64(metrics.downloadPayloadRate),
                    uploadRate: Int64(metrics.uploadPayloadRate),
                    showsDownloadRate: shouldShowDownloadRate,
                    showsUploadRate: shouldShowUploadRate
                )
            }

            TorrentProgressBar(value: metrics.progress, fillStyle: progressFillStyle, snapKey: progressSnapKey)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metrics: TorrentTransferMetrics {
        metricsState.metrics
    }

    private var metadataChips: [TorrentMetadataChipModel] {
        if !row.error.isEmpty {
            return [
                .init(kind: .status, title: row.error, systemImage: "exclamationmark.triangle.fill", tint: .red, width: 250)
            ]
        }
        if row.manuallyPaused {
            return chips(status: "Paused", statusIcon: "pause.fill", progressSummary)
        }
        if row.queued {
            return chips(status: "Queued", statusIcon: "clock.fill", progressSummary)
        }
        if row.seeding {
            return chips(
                status: "Seeding",
                statusIcon: "arrow.up",
                ratioText,
                peerText,
                "Uploaded \(ByteFormat.size(metrics.displayedAllTimeUpload))"
            )
        }
        if row.finished {
            return chips(
                status: "Complete",
                statusIcon: "checkmark",
                "Uploaded \(ByteFormat.size(metrics.displayedAllTimeUpload))"
            )
        }
        if !row.hasMetadata || row.state == .downloadingMetadata {
            return chips(status: "Finding metadata", statusIcon: "magnifyingglass", peerText)
        }

        switch row.state {
        case .checkingFiles:
            return chips(status: "Checking files", statusIcon: "checkmark", progressSummary)
        case .checkingResumeData:
            return chips(status: "Resuming", statusIcon: "arrow.triangle.2.circlepath", progressSummary)
        case .downloading:
            return chips(status: "Downloading", statusIcon: "arrow.down", progressSummary, peerText, etaText)
        case .finished:
            return chips(
                status: "Complete",
                statusIcon: "checkmark",
                "Uploaded \(ByteFormat.size(metrics.displayedAllTimeUpload))"
            )
        case .seeding:
            return chips(
                status: "Seeding",
                statusIcon: "arrow.up",
                ratioText,
                peerText,
                "Uploaded \(ByteFormat.size(metrics.displayedAllTimeUpload))"
            )
        case .downloadingMetadata:
            return chips(status: "Finding metadata", statusIcon: "magnifyingglass", peerText)
        case .unknown:
            return chips(status: row.statusText, statusIcon: "questionmark.circle", progressSummary)
        }
    }

    private func chips(status: String, statusIcon: String, _ values: String?...) -> [TorrentMetadataChipModel] {
        var chips: [TorrentMetadataChipModel] = [
            .init(kind: .status, title: status, systemImage: statusIcon, tint: nil, width: statusChipWidth(for: status))
        ]

        for value in values.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            chips.append(chip(for: value))
        }

        return chips
    }

    private func chip(for value: String) -> TorrentMetadataChipModel {
        if value.hasPrefix("Ratio ") {
            return .init(kind: .ratio, title: value, systemImage: "chart.bar", tint: nil, width: 92)
        }
        if value.hasPrefix("Uploaded ") {
            return .init(kind: .uploaded, title: value, systemImage: "arrow.up", tint: nil, width: 148)
        }
        if value.hasSuffix(" left") {
            return .init(kind: .eta, title: value, systemImage: "clock", tint: nil, width: 110)
        }
        if value.contains("peer") {
            return .init(kind: .peers, title: value, systemImage: "person.2", tint: nil, width: 132)
        }
        return .init(kind: .progress, title: value, systemImage: "arrow.down", tint: nil, width: 160)
    }

    private func statusChipWidth(for status: String) -> CGFloat {
        switch status {
        case "Finding metadata", "Checking files":
            return 138
        default:
            return 112
        }
    }

    private var progressSummary: String? {
        guard metrics.totalWanted > 0 else {
            return nil
        }
        return "\(ByteFormat.size(metrics.totalDone)) of \(ByteFormat.size(metrics.totalWanted))"
    }

    private var peerText: String? {
        metrics.peerSummaryText
    }

    private var etaText: String? {
        guard metrics.downloadPayloadRate > 0, metrics.totalWanted > metrics.totalDone else {
            return nil
        }

        let remainingBytes = metrics.totalWanted - metrics.totalDone
        let seconds = Int(ceil(Double(remainingBytes) / Double(metrics.downloadPayloadRate)))
        return "\(Self.formatDuration(seconds)) left"
    }

    private var ratioText: String {
        let downloaded = max(metrics.displayedAllTimeDownload, metrics.totalWanted)
        guard downloaded > 0 else {
            return "Ratio 0.0"
        }
        let ratio = Double(metrics.displayedAllTimeUpload) / Double(downloaded)
        return "Ratio \(ratio.formatted(.number.precision(.fractionLength(1))))"
    }

    private var shouldShowDownloadRate: Bool {
        !row.seeding && !row.finished
    }

    private var shouldShowUploadRate: Bool {
        metrics.uploadPayloadRate > 0 || row.seeding || row.finished
    }

    private var progressFillStyle: Color {
        if !row.error.isEmpty {
            return .red
        }
        if row.manuallyPaused || row.queued {
            return .secondary
        }
        if row.seeding || row.finished {
            return .green
        }
        return .blue
    }

    private var progressSnapKey: ProgressSnapKey {
        ProgressSnapKey(
            id: row.id,
            state: row.state,
            hasError: !row.error.isEmpty,
            manuallyPaused: row.manuallyPaused,
            queued: row.queued,
            seeding: row.seeding,
            finished: row.finished,
            hasMetadata: row.hasMetadata
        )
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "<1 min"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
        }

        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days) day" : "\(days) day \(remainingHours) hr"
    }
}

private struct TorrentMetadataChipModel: Identifiable {
    enum Kind: Hashable {
        case status
        case progress
        case peers
        case eta
        case ratio
        case uploaded
    }

    let kind: Kind
    let title: String
    let systemImage: String
    let tint: Color?
    let width: CGFloat

    var id: Kind {
        kind
    }
}

private struct TorrentMetadataStrip: View {
    let chips: [TorrentMetadataChipModel]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(chips) { chip in
                TorrentMetadataChip(chip: chip)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

private struct TorrentMetadataChip: View {
    let chip: TorrentMetadataChipModel

    private var foregroundStyle: Color {
        chip.tint ?? .secondary
    }

    private var iconStyle: Color {
        chip.tint ?? Color.secondary.opacity(0.72)
    }

    private var borderStyle: Color {
        chip.tint ?? .primary
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: chip.systemImage)
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(iconStyle)
                .frame(width: 12)

            Text(chip.title)
                .font(.footnote)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(foregroundStyle)
        .padding(.horizontal, 7)
        .frame(width: chip.width, height: 21, alignment: .center)
        .background(Color.primary.opacity(0.035), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(borderStyle.opacity(chip.tint == nil ? 0.045 : 0.22), lineWidth: 0.5)
        }
        .help(chip.title)
    }
}

private struct ProgressSnapKey: Equatable {
    let id: TorrentItem.ID
    let state: TorrentState
    let hasError: Bool
    let manuallyPaused: Bool
    let queued: Bool
    let seeding: Bool
    let finished: Bool
    let hasMetadata: Bool
}

private struct TorrentProgressBar: View {
    let value: Double
    let fillStyle: Color
    let snapKey: ProgressSnapKey

    @State private var displayedValue: Double?
    @State private var displayedSnapKey: ProgressSnapKey?

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    private var renderedValue: Double {
        displayedValue ?? clampedValue
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary.opacity(0.28))
                Capsule()
                    .fill(fillStyle)
                    .frame(width: max(0, proxy.size.width * renderedValue))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(clampedValue.formatted(.percent.precision(.fractionLength(1))))
        .onAppear {
            snap(to: clampedValue)
            displayedSnapKey = snapKey
        }
        .onChange(of: snapKey) { _, key in
            displayedSnapKey = key
            snap(to: clampedValue)
        }
        .onChange(of: clampedValue) { _, progress in
            updateDisplayedValue(progress)
        }
    }

    private func updateDisplayedValue(_ progress: Double) {
        guard displayedSnapKey == snapKey else {
            displayedSnapKey = snapKey
            snap(to: progress)
            return
        }

        let current = displayedValue ?? progress
        let delta = progress - current
        guard shouldAnimate(delta: delta, progress: progress, current: current) else {
            snap(to: progress)
            return
        }

        withAnimation(.linear(duration: 0.45)) {
            displayedValue = progress
        }
    }

    private func shouldAnimate(delta: Double, progress: Double, current: Double) -> Bool {
        let minimumVisibleChange = 0.0005
        let maximumSmoothStep = 0.08
        guard delta > minimumVisibleChange, delta <= maximumSmoothStep else {
            return false
        }
        guard current < 0.999, progress < 0.999 else {
            return false
        }
        return true
    }

    private func snap(to progress: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedValue = progress
        }
    }
}
