#!/usr/bin/env swift

import Foundation
import System

private extension URL {
    var fileSystemPath: String {
        FilePath(path(percentEncoded: false)).string
    }
}

enum CheckFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message):
            message
        }
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let publishedAt: String
    let prerelease: Bool
    let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case prerelease
        case draft
    }
}

struct Release {
    let version: String
    let publishedAt: Date
}

struct ProcessResult {
    let stdout: String
    let stderr: String
    let status: Int32
}

struct GitHubCommit: Decodable {
    struct Metadata: Decodable {
        struct Identity: Decodable {
            let date: String
        }

        let committer: Identity
    }

    let sha: String
    let commit: Metadata
}

struct GitilesCommit: Decodable {
    let commit: String
    let tree: String
}

@MainActor
final class DependencyChecker {
    private let buildDepsPath: URL
    private let libtorrentPatchSeriesPath: URL
    private let summaryPath: URL?
    private let now: Date
    private let cooldownDays: Int
    private let userAgent = "torrent7-dependency-check"
    private let githubToken: String?
    private let secondsPerDay: TimeInterval = 86_400
    private var successes: [String] = []
    private var notes: [String] = []
    private var failures: [String] = []

    init() throws {
        let scriptPath = URL(filePath: CommandLine.arguments[0])
        let scriptDirectory = scriptPath.deletingLastPathComponent()
        let root = try Self.findRoot(startingAt: scriptDirectory)

        self.buildDepsPath = root.appending(path: "Scripts/build-deps.zsh")
        self.libtorrentPatchSeriesPath = root.appending(path: "Scripts/libtorrent-patch-series.sh")
        self.summaryPath = try Self.summaryPath(from: Array(CommandLine.arguments.dropFirst()))

        if let override = ProcessInfo.processInfo.environment["DEPENDENCY_CHECK_NOW"] {
            guard let parsed = DependencyChecker.isoDateFormatter.date(from: override) else {
                throw CheckFailure.message("Could not parse DEPENDENCY_CHECK_NOW as ISO-8601: \(override)")
            }
            self.now = parsed
        } else {
            self.now = Date()
        }

        let configuredCooldown = ProcessInfo.processInfo.environment["DEPENDENCY_COOLDOWN_DAYS"] ?? "4"
        guard let parsedCooldown = Int(configuredCooldown), parsedCooldown >= 0 else {
            throw CheckFailure.message("DEPENDENCY_COOLDOWN_DAYS must be a non-negative integer")
        }
        self.cooldownDays = parsedCooldown

        let configuredGitHubToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.githubToken = configuredGitHubToken?.isEmpty == false ? configuredGitHubToken : nil
    }

    private static func summaryPath(from arguments: [String]) throws -> URL? {
        var index = 0
        var path: String?

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--summary":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw CheckFailure.message("Missing value after --summary")
                }
                path = arguments[valueIndex]
                index += 2
            case "--help", "-h":
                print("Usage: check-dependencies.swift [--summary PATH]")
                Foundation.exit(0)
            default:
                throw CheckFailure.message("Unknown argument: \(argument)")
            }
        }

        guard let path else {
            return nil
        }

        if path.hasPrefix("/") {
            return URL(filePath: path)
        }

        return URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: path)
    }

    private static func findRoot(startingAt directory: URL) throws -> URL {
        var current = directory

        while true {
            let buildDeps = current.appending(path: "Scripts/build-deps.zsh")
            if FileManager.default.fileExists(atPath: buildDeps.fileSystemPath) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.fileSystemPath == current.fileSystemPath {
                throw CheckFailure.message("Could not find repository root from \(directory.fileSystemPath)")
            }

            current = parent
        }
    }

    func run() async throws {
        do {
            try await checkLibtorrent()
        } catch {
            recordFailure("libtorrent check error: \(error)")
        }

        do {
            try await checkBoringSSL()
        } catch {
            recordFailure("BoringSSL check error: \(error)")
        }

        do {
            try await checkBoost()
        } catch {
            recordFailure("Boost check error: \(error)")
        }

        if failures.isEmpty {
            ok("All pinned dependencies are current under the \(cooldownDays)-day cooldown")
        } else {
            print("")
            print("\(failures.count) dependency check(s) failed:")
            for failure in failures {
                print("- \(failure)")
            }
        }

        try writeSummary()

        if !failures.isEmpty {
            Foundation.exit(1)
        }
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackISODateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let boostDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private func recordFailure(_ message: String) {
        failures.append(message)
        print("[fail] \(message)")
    }

    private func ok(_ message: String) {
        successes.append(message)
        print("[ok] \(message)")
    }

    private func info(_ message: String) {
        notes.append(message)
        print("[info] \(message)")
    }

    private func writeSummary() throws {
        guard let summaryPath else {
            return
        }

        var lines: [String] = [
            "# Dependency Check",
            "",
            "- Cooldown: \(cooldownDays) day\(cooldownDays == 1 ? "" : "s")",
            "- Pins source: `Scripts/build-deps.zsh`, `Scripts/boost-patch-series.sh`, and `Scripts/libtorrent-patch-series.sh`",
            ""
        ]

        if failures.isEmpty {
            lines.append("## Status")
            lines.append("")
            lines.append("All pinned dependencies are current under the configured cooldown.")
            lines.append("")
        } else {
            lines.append("## Updates Or Verification Issues")
            lines.append("")
            for failure in failures {
                lines.append("- \(failure)")
            }
            lines.append("")
            lines.append("## Maintainer Action")
            lines.append("")
            lines.append("Update the pins from a trusted checkout, rebuild and verify dependencies, then rerun:")
            lines.append("")
            lines.append("```sh")
            lines.append("Tools/DependencyCheck/check-dependencies.swift")
            lines.append("Scripts/build-deps.zsh")
            lines.append("```")
            lines.append("")
        }

        if !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            for note in notes {
                lines.append("- \(note)")
            }
            lines.append("")
        }

        if !successes.isEmpty {
            lines.append("## Verified")
            lines.append("")
            for success in successes {
                lines.append("- \(success)")
            }
            lines.append("")
        }

        try FileManager.default.createDirectory(
            at: summaryPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: summaryPath, atomically: true, encoding: .utf8)
    }

    private func fetchData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw CheckFailure.message("Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if url.host(percentEncoded: false) == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if let githubToken {
                request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CheckFailure.message("No HTTP response for \(urlString)")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CheckFailure.message("Failed to fetch \(urlString): HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func fetchText(from urlString: String) async throws -> String {
        let data = try await fetchData(from: urlString)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CheckFailure.message("Response is not UTF-8: \(urlString)")
        }
        return text
    }

    private func fetchJSON<T: Decodable>(_ type: T.Type, from urlString: String) async throws -> T {
        let data = try await fetchData(from: urlString)
        return try JSONDecoder().decode(type, from: data)
    }

    private func buildDepDefault(_ name: String) throws -> String {
        let contents = try String(contentsOf: buildDepsPath, encoding: .utf8)
        let pattern = #"^typeset -r \#(NSRegularExpression.escapedPattern(for: name))=\$\{\#(NSRegularExpression.escapedPattern(for: name)):-([^}]+)\}"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)

        guard let match = regex.firstMatch(in: contents, range: range),
              let valueRange = Range(match.range(at: 1), in: contents)
        else {
            throw CheckFailure.message("Could not find \(name) default in \(buildDepsPath.fileSystemPath)")
        }

        return String(contents[valueRange])
    }

    private func versionParts(_ version: String) -> [Int] {
        version.split { !$0.isNumber }.compactMap { Int($0) }
    }

    private func compareVersions(_ left: String, _ right: String) -> Int {
        let leftParts = versionParts(left)
        let rightParts = versionParts(right)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let leftValue = index < leftParts.count ? leftParts[index] : 0
            let rightValue = index < rightParts.count ? rightParts[index] : 0

            if leftValue < rightValue {
                return -1
            }
            if leftValue > rightValue {
                return 1
            }
        }

        return 0
    }

    private func maxByVersion(_ releases: [Release]) -> Release? {
        releases.max { left, right in
            compareVersions(left.version, right.version) < 0
        }
    }

    private func releaseIsEligible(_ publishedAt: Date) -> Bool {
        now.timeIntervalSince(publishedAt) >= TimeInterval(cooldownDays) * secondsPerDay
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func coolingUntil(_ publishedAt: Date) -> String {
        dateString(publishedAt.addingTimeInterval(TimeInterval(cooldownDays) * secondsPerDay))
    }

    private func checkLatestVersion(name: String, pinnedVersion: String, observed: Release?, eligible: Release?) {
        if let observed, !releaseIsEligible(observed.publishedAt) {
            info("\(name) \(observed.version) was published \(dateString(observed.publishedAt)); ignoring until \(coolingUntil(observed.publishedAt))")
        } else if let observed, let eligible, compareVersions(observed.version, eligible.version) > 0 {
            info("\(name) \(observed.version) is newer than the eligible \(eligible.version) but still cooling down")
        }

        guard let eligible else {
            ok("\(name) has no release older than the \(cooldownDays)-day cooldown")
            return
        }

        if compareVersions(pinnedVersion, eligible.version) < 0 {
            recordFailure("\(name) is behind: pinned \(pinnedVersion), latest eligible \(eligible.version) published \(dateString(eligible.publishedAt))")
        } else {
            ok("\(name) pin \(pinnedVersion) is current under the \(cooldownDays)-day cooldown")
        }
    }

    private func parseHTMLText(_ value: String) throws -> String {
        let withoutTags = try replacing(pattern: #"<[^>]+>"#, in: value, with: " ")
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func replacing(pattern: String, in value: String, with replacement: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private func firstMatch(pattern: String, in value: String, options: NSRegularExpression.Options = []) throws -> [String]? {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)

        guard let match = regex.firstMatch(in: value, range: range) else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            guard let matchRange = Range(match.range(at: index), in: value) else {
                return ""
            }
            return String(value[matchRange])
        }
    }

    private func matches(pattern: String, in value: String, options: NSRegularExpression.Options = []) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)

        return regex.matches(in: value, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let matchRange = Range(match.range(at: index), in: value) else {
                    return ""
                }
                return String(value[matchRange])
            }
        }
    }

    private func parseISODate(_ value: String) throws -> Date {
        if let date = Self.isoDateFormatter.date(from: value) ?? Self.fallbackISODateFormatter.date(from: value) {
            return date
        }
        throw CheckFailure.message("Could not parse ISO-8601 date: \(value)")
    }

    private func executablePath(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }

        for directory in ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        guard let path = executablePath(executable) else {
            throw CheckFailure.message("Missing executable: \(executable)")
        }

        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return ProcessResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    private func checkLibtorrent() async throws {
        let pinnedTag = try buildDepDefault("LIBTORRENT_TAG")
        let commitResult = try runProcess(libtorrentPatchSeriesPath.fileSystemPath, ["commit"])
        let pinnedCommit = commitResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commitResult.status == 0,
              pinnedCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
        else {
            throw CheckFailure.message(
                "Could not read the pinned libtorrent commit from \(libtorrentPatchSeriesPath.fileSystemPath): "
                    + commitResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let releases = try await fetchJSON([GitHubRelease].self, from: "https://api.github.com/repos/arvidn/libtorrent/releases?per_page=100")

        let stable2x = try releases.compactMap { release -> Release? in
            guard !release.draft,
                  !release.prerelease,
                  release.tagName.range(of: #"^v2\.\d+\.\d+$"#, options: .regularExpression) != nil
            else {
                return nil
            }

            return Release(
                version: String(release.tagName.dropFirst()),
                publishedAt: try parseISODate(release.publishedAt)
            )
        }

        guard !stable2x.isEmpty else {
            throw CheckFailure.message("No stable libtorrent 2.x releases found")
        }

        let observed = maxByVersion(stable2x)
        let eligible = maxByVersion(stable2x.filter { releaseIsEligible($0.publishedAt) })
        checkLatestVersion(name: "libtorrent", pinnedVersion: String(pinnedTag.dropFirst()), observed: observed, eligible: eligible)

        let result = try runProcess("git", [
            "ls-remote",
            "--tags",
            "https://github.com/arvidn/libtorrent.git",
            "refs/tags/\(pinnedTag)",
            "refs/tags/\(pinnedTag)^{}"
        ])
        guard result.status == 0 else {
            throw CheckFailure.message("Could not resolve libtorrent \(pinnedTag): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let refs = result.stdout
            .split(separator: "\n")
            .compactMap { line -> (sha: String, ref: String)? in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count == 2 else {
                    return nil
                }
                return (sha: parts[0], ref: parts[1])
            }
        let peeledRef = "refs/tags/\(pinnedTag)^{}"
        let directRef = "refs/tags/\(pinnedTag)"
        let actualCommit = refs.first { $0.ref == peeledRef }?.sha
            ?? refs.first { $0.ref == directRef }?.sha

        if actualCommit == pinnedCommit {
            ok("libtorrent \(pinnedTag) resolves to pinned commit \(pinnedCommit)")
        } else {
            recordFailure("libtorrent \(pinnedTag) commit mismatch: expected \(pinnedCommit), got \(actualCommit ?? "none")")
        }
    }

    private func checkBoringSSL() async throws {
        let pinnedRepository = try buildDepDefault("BORINGSSL_REPO")
        let pinnedCommit = try buildDepDefault("BORINGSSL_COMMIT")
        let pinnedTree = try buildDepDefault("BORINGSSL_TREE")
        guard pinnedCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              pinnedTree.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
        else {
            throw CheckFailure.message("BoringSSL commit and tree pins must be full lowercase SHA-1 values")
        }

        let remoteResult = try runProcess("git", ["ls-remote", pinnedRepository, "HEAD"])
        let remoteHead = remoteResult.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard remoteResult.status == 0, let remoteHead else {
            throw CheckFailure.message(
                "Could not resolve BoringSSL HEAD: "
                    + remoteResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let gitilesData = try await fetchData(
            from: "https://boringssl.googlesource.com/boringssl/+/\(pinnedCommit)?format=JSON"
        )
        let xssiPrefix = Data(")]}'\n".utf8)
        guard gitilesData.starts(with: xssiPrefix) else {
            throw CheckFailure.message("BoringSSL Gitiles response lacks its XSSI prefix")
        }
        let pinnedMetadata = try JSONDecoder().decode(
            GitilesCommit.self,
            from: gitilesData.dropFirst(xssiPrefix.count)
        )
        if pinnedMetadata.commit == pinnedCommit, pinnedMetadata.tree == pinnedTree {
            ok("BoringSSL pinned commit and tree match upstream metadata")
        } else {
            recordFailure(
                "BoringSSL source identity mismatch: expected \(pinnedCommit) tree \(pinnedTree), "
                    + "got \(pinnedMetadata.commit) tree \(pinnedMetadata.tree)"
            )
        }

        var history: [(sha: String, date: Date)] = []
        for page in 1...20 {
            let commits = try await fetchJSON(
                [GitHubCommit].self,
                from: "https://api.github.com/repos/google/boringssl/commits?per_page=100&page=\(page)"
            )
            for commit in commits {
                history.append((
                    sha: commit.sha,
                    date: try parseISODate(commit.commit.committer.date)
                ))
            }

            let hasPinnedCommit = history.contains { $0.sha == pinnedCommit }
            let hasEligibleCommit = history.contains { releaseIsEligible($0.date) }
            if commits.count < 100 || (hasPinnedCommit && hasEligibleCommit) {
                break
            }
        }

        guard let observed = history.first else {
            throw CheckFailure.message("BoringSSL upstream history is empty")
        }
        if observed.sha == remoteHead {
            ok("BoringSSL official repository and GitHub mirror agree on HEAD \(remoteHead)")
        } else {
            recordFailure(
                "BoringSSL mirror mismatch: official HEAD \(remoteHead), GitHub mirror \(observed.sha)"
            )
        }

        guard let pinnedIndex = history.firstIndex(where: { $0.sha == pinnedCommit }) else {
            recordFailure("BoringSSL pinned commit is not in the recent upstream history")
            return
        }
        guard let eligibleIndex = history.firstIndex(where: { releaseIsEligible($0.date) }) else {
            ok("BoringSSL has no commit older than the \(cooldownDays)-day cooldown")
            return
        }

        let eligible = history[eligibleIndex]
        if pinnedIndex <= eligibleIndex {
            ok(
                "BoringSSL pin is at least as recent as eligible commit \(eligible.sha) "
                    + "from \(dateString(eligible.date))"
            )
        } else {
            recordFailure(
                "BoringSSL is behind: pinned \(pinnedCommit), latest eligible \(eligible.sha) "
                    + "from \(dateString(eligible.date))"
            )
        }

        if remoteHead != pinnedCommit, !releaseIsEligible(observed.date) {
            info(
                "BoringSSL HEAD \(remoteHead) is cooling down until \(coolingUntil(observed.date))"
            )
        }
    }

    private func boostArchiveBasename(version: String) -> String {
        "boost_\(version.replacingOccurrences(of: ".", with: "_"))"
    }

    private func boostArchiveMetadata(version: String) async throws -> [String: String] {
        let basename = boostArchiveBasename(version: version)
        return try await fetchJSON([String: String].self, from: "https://archives.boost.io/release/\(version)/source/\(basename).tar.gz.json")
    }

    private func checkBoost() async throws {
        let pinnedVersion = try buildDepDefault("BOOST_VERSION")
        let pinnedSHA256 = try buildDepDefault("BOOST_SHA256")
        let downloadPage = try await fetchText(from: "https://www.boost.org/users/download/")

        let latestVersion = try firstMatch(pattern: #"Newest Release.*?\((\d+\.\d+\.\d+)\)"#, in: downloadPage, options: [.dotMatchesLineSeparators])?[1]
            ?? firstMatch(pattern: #"Latest \((\d+\.\d+\.\d+)\)"#, in: downloadPage)?[1]
        guard let latestVersion else {
            throw CheckFailure.message("Could not parse latest Boost release from download page")
        }

        let pinnedMetadata = try await boostArchiveMetadata(version: pinnedVersion)

        guard let dateText = try firstMatch(
            pattern: #"<span[^>]*font-bold[^>]*>\s*([A-Za-z]+ \d{1,2}, \d{4})\s*</span>"#,
            in: downloadPage,
            options: [.dotMatchesLineSeparators]
        )?[1],
            let publishedAt = Self.boostDateFormatter.date(from: dateText)
        else {
            throw CheckFailure.message("Could not parse Boost \(latestVersion) public release date")
        }

        let observed = Release(version: latestVersion, publishedAt: publishedAt)
        let eligible = releaseIsEligible(publishedAt) ? observed : nil
        checkLatestVersion(name: "Boost", pinnedVersion: pinnedVersion, observed: observed, eligible: eligible)

        guard let upstreamSHA256 = pinnedMetadata["sha256"]?.lowercased() else {
            throw CheckFailure.message("Could not parse Boost \(pinnedVersion) SHA-256 metadata")
        }

        if upstreamSHA256 == pinnedSHA256 {
            ok("Boost \(pinnedVersion) SHA-256 matches upstream metadata")
        } else {
            recordFailure("Boost \(pinnedVersion) SHA-256 mismatch: expected \(upstreamSHA256), pinned \(pinnedSHA256)")
        }
    }
}

do {
    let checker = try DependencyChecker()
    try await checker.run()
} catch {
    fputs("[error] \(error)\n", stderr)
    Foundation.exit(1)
}
