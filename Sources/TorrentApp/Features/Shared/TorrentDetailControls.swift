import AppKit
import SwiftUI

struct SourceSectionHeader: View {
    let title: String
    let count: Int
    var detail: String? = nil
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let detail {
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct SourceLimitButton: View {
    let isShowingAll: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isShowingAll ? "Show Less" : "Show All", systemImage: isShowingAll ? "chevron.up" : "ellipsis")
        }
        .buttonStyle(.borderless)
        .help(isShowingAll ? "Show fewer items" : "Show all items")
    }
}


struct InfoDetailRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .fixedSize(horizontal: true, vertical: false)

            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct DownloadPathValueView: View {
    let path: String
    let revealInFinder: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .help(path)

            Button(action: revealInFinder) {
                Label("Reveal in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .fixedSize()
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
        }
    }
}

struct DownloadFolderPickerValueView: View {
    let text: String
    let isUnset: Bool
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isUnset ? Color.red : Color.primary)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .help(text)

            Button("Choose...", action: choose)
                .fixedSize()
        }
    }
}

struct InfoHashValueView: View {
    let infoHash: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(infoHash)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .help(infoHash)

            Button(action: copyInfoHash) {
                Label("Copy Info Hash", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .fixedSize()
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy full info hash")
            .accessibilityLabel("Copy full info hash")
        }
    }

    private func copyInfoHash() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(infoHash, forType: .string)
    }
}

struct SourceURLView: View {
    let url: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(styledURL)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: copyURL) {
                Label("Copy URL", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .fixedSize()
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy URL")
            .accessibilityLabel("Copy URL for \(sourceDescription)")
        }
    }

    private func copyURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    private var sourceDescription: String {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            return "source"
        }
        return host
    }

    private var styledURL: AttributedString {
        var text = AttributedString(url)
        guard let schemeSeparator = url.range(of: "://") else {
            return text
        }

        let scheme = url[..<schemeSeparator.lowerBound]
        guard scheme.caseInsensitiveCompare("https") != .orderedSame else {
            return text
        }

        let prefix = String(url[..<schemeSeparator.upperBound])
        if let prefixRange = text.range(of: prefix) {
            text[prefixRange].foregroundColor = .orange
        }
        return text
    }
}

struct IntegerFieldRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String?
    let validationMessage: String?
    let isLabelDisabled: Bool
    @State private var draftText: String
    @FocusState private var isEditingText

    init(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String? = nil,
        validationMessage: String? = nil,
        isLabelDisabled: Bool = false
    ) {
        self.title = title
        _value = value
        self.range = range
        self.suffix = suffix
        self.validationMessage = validationMessage
        self.isLabelDisabled = isLabelDisabled
        _draftText = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text(title)
                    .foregroundStyle(isLabelDisabled ? Color.secondary : Color.primary)

                Spacer()

                HStack(spacing: 8) {
                    if validationMessage == nil {
                        TextField("", value: clampedValue, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .frame(width: 96)
                            .accessibilityLabel(title)
                            .accessibilityHint(accessibilityHint)
                    } else {
                        TextField("", text: validatedText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .frame(width: 96)
                            .focused($isEditingText)
                            .accessibilityLabel(title)
                            .accessibilityHint(accessibilityHint)
                    }

                    Stepper(title, value: clampedValue, in: range)
                        .labelsHidden()

                    if let suffix {
                        Text(suffix)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 38, alignment: .leading)
                    }
                }
            }

            if let validationText {
                HStack {
                    Spacer()
                    Text(validationText)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: value) { _, newValue in
            guard validationMessage != nil, !isEditingText else {
                return
            }
            draftText = String(newValue)
        }
        .onChange(of: isEditingText) { _, isEditingText in
            guard validationMessage != nil, !isEditingText, validationText == nil else {
                return
            }
            draftText = String(value)
        }
    }

    private var clampedValue: Binding<Int> {
        Binding {
            value
        } set: { newValue in
            let nextValue = min(max(newValue, range.lowerBound), range.upperBound)
            value = nextValue
            draftText = String(nextValue)
        }
    }

    private var validatedText: Binding<String> {
        Binding {
            draftText
        } set: { newValue in
            draftText = newValue

            if let parsedValue = parsedDraftValue(newValue), range.contains(parsedValue) {
                value = parsedValue
            }
        }
    }

    private var validationText: String? {
        guard let validationMessage else {
            return nil
        }

        guard let parsedValue = parsedDraftValue(draftText), range.contains(parsedValue) else {
            return validationMessage
        }

        return nil
    }

    private var accessibilityHint: String {
        var parts = ["Enter a value from \(range.lowerBound) to \(range.upperBound)."]
        if let suffix {
            parts.append("Unit: \(suffix).")
        }
        if let validationMessage {
            parts.append(validationMessage)
        }
        return parts.joined(separator: " ")
    }

    private func parsedDraftValue(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
