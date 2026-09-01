import SwiftParser
import SwiftSyntax

public enum UnsafeBoundaryKind: String, Sendable {
    case uncheckedSendable = "unchecked-sendable"
    case unsafeDeclaration = "unsafe-declaration"
    case unsafeOperation = "unsafe-operation"
    case unmanaged = "unmanaged"
    case rawAllocation = "raw-allocation"
}

public struct UnsafeBoundaryDiagnostic: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let column: Int
    public let kind: UnsafeBoundaryKind
    public let message: String

    public var rendered: String {
        "\(path):\(line):\(column): error: \(message) [unsafe-boundary-\(kind.rawValue)]"
    }

    init(
        path: String,
        line: Int,
        column: Int,
        kind: UnsafeBoundaryKind,
        message: String
    ) {
        self.path = path
        self.line = line
        self.column = column
        self.kind = kind
        self.message = message
    }
}

public struct UnsafeBoundaryLinter {
    public init() {}

    public func lint(source: String, path: String) -> [UnsafeBoundaryDiagnostic] {
        let sourceFile = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: sourceFile)
        let tokens = Array(sourceFile.tokens(viewMode: .sourceAccurate))
        var boundaries = unmanagedBoundaries(in: tokens)
        boundaries.append(contentsOf: unsafeKeywordBoundaries(in: tokens))

        let unsafeSyntaxVisitor = UnsafeSyntaxVisitor(viewMode: .sourceAccurate)
        unsafeSyntaxVisitor.walk(sourceFile)
        boundaries.append(contentsOf: unsafeSyntaxVisitor.boundaries)

        let preconcurrencyVisitor = PreconcurrencyVisitor(
            viewMode: .sourceAccurate
        )
        preconcurrencyVisitor.walk(sourceFile)
        boundaries.append(contentsOf: preconcurrencyVisitor.boundaries)

        let uncheckedSendableVisitor = UncheckedSendableVisitor(
            viewMode: .sourceAccurate
        )
        uncheckedSendableVisitor.walk(sourceFile)
        boundaries.append(contentsOf: uncheckedSendableVisitor.boundaries)

        let allocationVisitor = RawAllocationVisitor(viewMode: .sourceAccurate)
        allocationVisitor.walk(sourceFile)
        boundaries.append(contentsOf: allocationVisitor.boundaries)

        let uncovered = boundaries
            .filter { !hasSafetyProof(for: $0.syntax, kind: $0.kind) }

        var grouped = [ProofScope: Boundary]()
        for boundary in uncovered {
            let scope = proofScope(for: boundary)
            if let existing = grouped[scope] {
                grouped[scope] = preferredDiagnosticBoundary(
                    existing,
                    boundary
                )
            } else {
                grouped[scope] = boundary
            }
        }

        return grouped.values
            .map { boundary in
                let location = converter.location(
                    for: boundary.position
                )
                return UnsafeBoundaryDiagnostic(
                    path: path,
                    line: location.line,
                    column: location.column,
                    kind: boundary.kind,
                    message: boundary.message
                )
            }
            .sorted {
                ($0.path, $0.line, $0.column, $0.kind.rawValue)
                    < ($1.path, $1.line, $1.column, $1.kind.rawValue)
            }
    }

    private func unmanagedBoundaries(in tokens: [TokenSyntax]) -> [Boundary] {
        var boundaries = [Boundary]()

        for token in tokens {
            if token.text == "Unmanaged",
               case .identifier = token.tokenKind {
                boundaries.append(
                    Boundary(
                        kind: .unmanaged,
                        syntax: Syntax(token),
                        position: token.positionAfterSkippingLeadingTrivia,
                        message: "Unmanaged requires a syntax-scoped SAFETY: explanation"
                    )
                )
            }
        }

        return boundaries
    }

    private func unsafeKeywordBoundaries(in tokens: [TokenSyntax]) -> [Boundary] {
        tokens.compactMap { token in
            guard token.tokenKind == .keyword(.unsafe) else {
                return nil
            }

            let syntax = Syntax(token)
            if unsafeKeywordRequiresDeclarationProof(syntax) {
                return Boundary(
                    kind: .unsafeDeclaration,
                    syntax: syntax,
                    position: token.positionAfterSkippingLeadingTrivia,
                    message: "unsafe declaration acknowledgement requires an exact "
                        + "declaration-scoped SAFETY: explanation"
                )
            }

            return Boundary(
                kind: .unsafeOperation,
                syntax: syntax,
                position: token.positionAfterSkippingLeadingTrivia,
                message: "unsafe operation requires a syntax-scoped SAFETY: explanation"
            )
        }
    }
}

private struct Boundary {
    let kind: UnsafeBoundaryKind
    let syntax: Syntax
    let position: AbsolutePosition
    let message: String
}

private struct ProofScope: Hashable {
    enum Kind: Hashable {
        case declaration
        case operation
    }

    let kind: Kind
    let position: Int
}

private final class UnsafeSyntaxVisitor: SyntaxVisitor {
    fileprivate var boundaries = [Boundary]()

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        guard attributeName(node) == "unsafe" else {
            return .visitChildren
        }

        boundaries.append(
            Boundary(
                kind: .unsafeDeclaration,
                syntax: Syntax(node),
                position: node.atSign.positionAfterSkippingLeadingTrivia,
                message: "@unsafe requires an exact declaration-scoped SAFETY: explanation"
            )
        )
        return .skipChildren
    }

    override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == "nonisolated" || node.name.text == "unowned",
              let detail = node.detail?.detail,
              detail.text == "unsafe" else {
            return .visitChildren
        }

        boundaries.append(
            Boundary(
                kind: .unsafeDeclaration,
                syntax: Syntax(node),
                position: detail.positionAfterSkippingLeadingTrivia,
                message: "\(node.name.text)(unsafe) requires an exact declaration-scoped "
                    + "SAFETY: explanation"
            )
        )
        return .skipChildren
    }

    override func visit(
        _ node: ClosureCaptureSpecifierSyntax
    ) -> SyntaxVisitorContinueKind {
        guard node.specifier.text == "unowned",
              let detail = node.detail,
              detail.text == "unsafe" else {
            return .visitChildren
        }

        boundaries.append(
            Boundary(
                kind: .unsafeOperation,
                syntax: Syntax(node),
                position: detail.positionAfterSkippingLeadingTrivia,
                message: "unowned(unsafe) capture requires a syntax-scoped "
                    + "SAFETY: explanation"
            )
        )
        return .skipChildren
    }
}

private final class PreconcurrencyVisitor: SyntaxVisitor {
    fileprivate var boundaries = [Boundary]()

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        guard attributeName(node) == "preconcurrency" else {
            return .visitChildren
        }

        boundaries.append(
            Boundary(
                kind: .unsafeDeclaration,
                syntax: Syntax(node),
                position: node.atSign.positionAfterSkippingLeadingTrivia,
                message: "@preconcurrency requires an exact declaration-scoped "
                    + "SAFETY: explanation"
            )
        )
        return .skipChildren
    }
}

private func attributeName(_ node: AttributeSyntax) -> String {
    node.attributeName.tokens(viewMode: .sourceAccurate)
        .map(\.text)
        .joined()
}

private final class UncheckedSendableVisitor: SyntaxVisitor {
    fileprivate var boundaries = [Boundary]()

    override func visit(_ node: InheritedTypeSyntax) -> SyntaxVisitorContinueKind {
        let tokens = Array(node.type.tokens(viewMode: .sourceAccurate))
        guard tokens.last(where: { token in
            if case .identifier = token.tokenKind {
                return true
            }
            return false
        })?.text == "Sendable",
        let uncheckedIndex = tokens.firstIndex(where: { $0.text == "unchecked" }),
        uncheckedIndex > tokens.startIndex,
        tokens[tokens.index(before: uncheckedIndex)].text == "@" else {
            return .visitChildren
        }

        let atSign = tokens[tokens.index(before: uncheckedIndex)]
        boundaries.append(
            Boundary(
                kind: .uncheckedSendable,
                syntax: Syntax(node),
                position: atSign.positionAfterSkippingLeadingTrivia,
                message: "@unchecked Sendable requires a declaration-scoped SAFETY: explanation"
            )
        )
        return .skipChildren
    }
}

private final class RawAllocationVisitor: SyntaxVisitor {
    private static let cOwnershipModules: Set<String> = [
        "CoreFoundation",
        "Darwin",
        "Glibc",
        "Musl",
        "SwiftGlibc"
    ]

    private static let cOwnershipFunctions: Set<String> = [
        "CFAllocatorAllocate",
        "CFAllocatorDeallocate",
        "CFAllocatorReallocate",
        "aligned_alloc",
        "calloc",
        "free",
        "malloc",
        "malloc_zone_calloc",
        "malloc_zone_free",
        "malloc_zone_malloc",
        "malloc_zone_memalign",
        "malloc_zone_realloc",
        "malloc_zone_valloc",
        "posix_memalign",
        "realloc",
        "reallocf",
        "strdup",
        "strndup",
        "valloc"
    ]

    private static let pointerTypes: Set<String> = [
        "UnsafeMutableBufferPointer",
        "UnsafeMutablePointer",
        "UnsafeMutableRawBufferPointer",
        "UnsafeMutableRawPointer"
    ]

    fileprivate var boundaries = [Boundary]()

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calleeTokens = Array(
            node.calledExpression.tokens(viewMode: .sourceAccurate)
        )
        guard let nameToken = calleeTokens.last(where: { token in
            if case .identifier = token.tokenKind {
                return true
            }
            return false
        }) else {
            return .visitChildren
        }

        let name = nameToken.text
        let isRawOwnershipCall: Bool
        switch name {
        case "allocate":
            isRawOwnershipCall = calleeTokens.contains {
                Self.pointerTypes.contains($0.text)
            }
        case "deallocate":
            // The receiver's inferred type is unavailable without type checking. In Swift's
            // standard library, a parameterless deallocate() call is the raw-memory ownership
            // boundary, so intentionally prefer a conservative diagnostic for this spelling.
            isRawOwnershipCall = node.arguments.isEmpty
        default:
            isRawOwnershipCall = Self.isCOwnershipFunction(
                named: name,
                calleeTokens: calleeTokens
            )
        }

        if isRawOwnershipCall {
            boundaries.append(
                Boundary(
                    kind: .rawAllocation,
                    syntax: Syntax(node),
                    position: nameToken.positionAfterSkippingLeadingTrivia,
                    message: "raw allocation ownership call '\(name)' requires a "
                        + "syntax-scoped SAFETY: explanation"
                )
            )
        }

        return .visitChildren
    }

    private static func isCOwnershipFunction(
        named name: String,
        calleeTokens: [TokenSyntax]
    ) -> Bool {
        guard cOwnershipFunctions.contains(name) else {
            return false
        }

        let identifiers = calleeTokens.compactMap { token -> String? in
            if case .identifier(let identifier) = token.tokenKind {
                return identifier
            }
            return nil
        }
        return identifiers.count == 1
            || (identifiers.count == 2 && cOwnershipModules.contains(identifiers[0]))
    }
}

private func hasSafetyProof(
    for boundary: Syntax,
    kind: UnsafeBoundaryKind
) -> Bool {
    if requiresDeclarationProof(kind) {
        return hasDeclarationProof(for: boundary)
    }

    return hasOperationProof(for: boundary)
}

private func requiresDeclarationProof(_ kind: UnsafeBoundaryKind) -> Bool {
    kind == .uncheckedSendable || kind == .unsafeDeclaration
}

private func unsafeKeywordRequiresDeclarationProof(_ boundary: Syntax) -> Bool {
    var current: Syntax? = boundary

    while let syntax = current {
        if syntax.as(UnsafeExprSyntax.self) != nil
            || syntax.as(ForStmtSyntax.self) != nil
            || syntax.as(ClosureCaptureSpecifierSyntax.self) != nil {
            return false
        }

        if syntax.as(DeclModifierSyntax.self) != nil
            || syntax.as(AttributeSyntax.self) != nil
            || syntax.as(InheritedTypeSyntax.self) != nil {
            return true
        }

        if syntax.as(CodeBlockItemSyntax.self) != nil {
            return false
        }

        if syntax.isProtocol(DeclSyntaxProtocol.self) {
            return true
        }
        current = syntax.parent
    }

    return false
}

private func proofScope(for boundary: Boundary) -> ProofScope {
    if requiresDeclarationProof(boundary.kind) {
        return ProofScope(
            kind: .declaration,
            position: enclosingDeclarationPosition(for: boundary.syntax)
                ?? boundary.position.utf8Offset
        )
    }

    return ProofScope(
        kind: .operation,
        position: enclosingOperationPosition(for: boundary.syntax)
            ?? boundary.position.utf8Offset
    )
}

private func enclosingDeclarationPosition(for boundary: Syntax) -> Int? {
    var current: Syntax? = boundary

    while let syntax = current {
        if syntax.isProtocol(DeclSyntaxProtocol.self) {
            return syntax.positionAfterSkippingLeadingTrivia.utf8Offset
        }
        current = syntax.parent
    }

    return nil
}

private func enclosingOperationPosition(for boundary: Syntax) -> Int? {
    var current: Syntax? = boundary

    while let syntax = current {
        if let item = syntax.as(CodeBlockItemSyntax.self) {
            return item.positionAfterSkippingLeadingTrivia.utf8Offset
        }

        if syntax.as(VariableDeclSyntax.self) != nil || isCallableDeclaration(syntax) {
            return syntax.positionAfterSkippingLeadingTrivia.utf8Offset
        }
        current = syntax.parent
    }

    return nil
}

private func preferredDiagnosticBoundary(
    _ first: Boundary,
    _ second: Boundary
) -> Boundary {
    let firstPriority = diagnosticPriority(first.kind)
    let secondPriority = diagnosticPriority(second.kind)
    if firstPriority != secondPriority {
        return firstPriority > secondPriority ? first : second
    }
    return first.position < second.position ? first : second
}

private func diagnosticPriority(_ kind: UnsafeBoundaryKind) -> Int {
    switch kind {
    case .rawAllocation:
        4
    case .unmanaged:
        3
    case .uncheckedSendable:
        2
    case .unsafeDeclaration, .unsafeOperation:
        1
    }
}

private func hasDeclarationProof(for boundary: Syntax) -> Bool {
    var current: Syntax? = boundary

    while let syntax = current {
        if syntax.isProtocol(DeclSyntaxProtocol.self) {
            return hasSafetyMarker(
                inLeadingTriviaOf: syntax.firstToken(viewMode: .sourceAccurate)
            )
        }
        current = syntax.parent
    }

    return false
}

private func hasOperationProof(for boundary: Syntax) -> Bool {
    var current: Syntax? = boundary

    while let syntax = current {
        if let item = syntax.as(CodeBlockItemSyntax.self),
           hasSafetyMarker(inLeadingTriviaOf: item.firstToken(viewMode: .sourceAccurate)) {
            return true
        }

        if let block = syntax.as(CodeBlockSyntax.self),
           let firstItem = block.statements.first,
           hasSafetyMarker(inLeadingTriviaOf: firstItem.firstToken(viewMode: .sourceAccurate)) {
            return true
        }

        if syntax.as(VariableDeclSyntax.self) != nil,
           hasSafetyMarker(inLeadingTriviaOf: syntax.firstToken(viewMode: .sourceAccurate)) {
            return true
        }

        if isCallableDeclaration(syntax) {
            return hasSafetyMarker(
                inLeadingTriviaOf: syntax.firstToken(viewMode: .sourceAccurate)
            )
        }

        current = syntax.parent
    }

    return false
}

private func isCallableDeclaration(_ syntax: Syntax) -> Bool {
    syntax.as(FunctionDeclSyntax.self) != nil
        || syntax.as(InitializerDeclSyntax.self) != nil
        || syntax.as(DeinitializerDeclSyntax.self) != nil
        || syntax.as(SubscriptDeclSyntax.self) != nil
        || syntax.as(AccessorDeclSyntax.self) != nil
}

private func hasSafetyMarker(inLeadingTriviaOf token: TokenSyntax?) -> Bool {
    guard let token else {
        return false
    }

    let commentText = token.leadingTrivia.reduce(into: "") { result, piece in
        switch piece {
        case let .lineComment(text),
             let .blockComment(text),
             let .docLineComment(text),
             let .docBlockComment(text):
            result.append(text)
            result.append("\n")
        default:
            break
        }
    }

    guard let marker = commentText.firstRange(of: "SAFETY:") else {
        return false
    }

    return commentText[marker.upperBound...].contains { character in
        !character.isWhitespace && character != "/" && character != "*"
    }
}
