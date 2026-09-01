import Foundation
import UnsafeBoundaryLintCore

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    writeStandardError("Usage: unsafe-boundary-lint SWIFT_FILE...")
    exit(2)
}

let linter = UnsafeBoundaryLinter()
var diagnostics = [UnsafeBoundaryDiagnostic]()
var hadReadFailure = false

for path in paths {
    do {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        diagnostics.append(contentsOf: linter.lint(source: source, path: path))
    } catch {
        writeStandardError("\(path): error: unable to read Swift source: \(error)")
        hadReadFailure = true
    }
}

for diagnostic in diagnostics.sorted(by: {
    ($0.path, $0.line, $0.column, $0.kind.rawValue)
        < ($1.path, $1.line, $1.column, $1.kind.rawValue)
}) {
    writeStandardError(diagnostic.rendered)
}

if hadReadFailure || !diagnostics.isEmpty {
    exit(1)
}
