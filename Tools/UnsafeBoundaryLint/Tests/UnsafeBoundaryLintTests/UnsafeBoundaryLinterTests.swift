import Testing
@testable import UnsafeBoundaryLintCore

@Suite("Unsafe boundary lint")
struct UnsafeBoundaryLinterTests {
    private let linter = UnsafeBoundaryLinter()

    @Test("Declaration proof documents unchecked Sendable")
    func declarationProofDocumentsUncheckedSendable() {
        let diagnostics = lint(
            """
            // SAFETY: synchronization is provided by an internal lock.
            final class LockedBox: @unchecked Sendable {}
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Additional conformance attributes do not hide unchecked Sendable")
    func additionalConformanceAttributesDoNotHideUncheckedSendable() {
        let diagnostics = lint(
            """
            extension Imported: @retroactive @unchecked Sendable {}
            """
        )

        #expect(diagnostics.map(\.kind) == [.uncheckedSendable])
    }

    @Test("Unchecked Sendable requires its own declaration proof")
    func uncheckedSendableRequiresItsOwnDeclarationProof() {
        let diagnostics = lint(
            """
            // SAFETY: this comment documents only DocumentedBox.
            final class DocumentedBox: @unchecked Sendable {}

            final class UndocumentedBox: @unchecked Sendable {}
            """
        )

        #expect(diagnostics.map(\.kind) == [.uncheckedSendable])
        #expect(diagnostics.first?.line == 4)
    }

    @Test("Outer declaration proof does not document nested unchecked Sendable")
    func outerDeclarationProofDoesNotDocumentNestedUncheckedSendable() {
        let diagnostics = lint(
            """
            // SAFETY: this comment documents only the outer type.
            struct Outer {
                final class Inner: @unchecked Sendable {}
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.uncheckedSendable])
    }

    @Test("Statement proof documents Unmanaged")
    func statementProofDocumentsUnmanaged() {
        let diagnostics = lint(
            """
            func retain(_ object: AnyObject) {
                // SAFETY: the receiver balances this retain after synchronous use.
                _ = Unmanaged.passRetained(object)
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("A bare safety marker is not documentation")
    func bareSafetyMarkerIsNotDocumentation() {
        let diagnostics = lint(
            """
            func retain(_ object: AnyObject) {
                // SAFETY:
                _ = Unmanaged.passRetained(object)
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unmanaged])
    }

    @Test("First-item proof does not cover later statements in its code block")
    func firstItemProofDoesNotCoverLaterStatements() {
        let diagnostics = lint(
            """
            func retain(_ object: AnyObject) {
                // SAFETY: this assertion itself has no unsafe behavior.
                precondition(true)
                _ = Unmanaged.passRetained(object)
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unmanaged])
    }

    @Test("Callable declaration proof covers its body")
    func callableDeclarationProofCoversItsBody() {
        let diagnostics = lint(
            """
            // SAFETY: the function balances the opaque retain before returning.
            func retain(_ object: AnyObject) {
                _ = Unmanaged.passRetained(object)
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Container proof does not document a method operation")
    func containerProofDoesNotDocumentAMethodOperation() {
        let diagnostics = lint(
            """
            // SAFETY: this comment documents only Container's synchronization.
            final class Container {
                func retain(_ object: AnyObject) {
                    _ = Unmanaged.passRetained(object)
                }
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unmanaged])
    }

    @Test("Outer proof covers a nested closure")
    func outerProofCoversNestedClosure() {
        let diagnostics = lint(
            """
            func retain(_ object: AnyObject) {
                // SAFETY: this synchronous function owns and balances its one opaque retain.
                do {
                    precondition(true)
                    withoutActuallyEscaping({
                        _ = Unmanaged.passRetained(object)
                    }) { body in
                        body()
                    }
                }
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Proof on an unrelated statement does not leak")
    func proofOnUnrelatedStatementDoesNotLeak() {
        let diagnostics = lint(
            """
            func retain(_ object: AnyObject) {
                precondition(true)
                // SAFETY: this comment covers only the following assertion.
                assert(true)
                _ = Unmanaged.passRetained(object)
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unmanaged])
    }

    @Test("Safety text in a string is not documentation")
    func safetyTextInStringIsNotDocumentation() {
        let diagnostics = lint(
            """
            let explanation = "SAFETY: not a comment"
            _ = Unmanaged.passRetained(explanation as AnyObject)
            """
        )

        #expect(diagnostics.map(\.kind) == [.unmanaged])
    }

    @Test("Boundary spellings in strings are ignored")
    func boundarySpellingsInStringsAreIgnored() {
        let diagnostics = lint(
            #"""
            let text = "unsafe for unsafe @unsafe @preconcurrency nonisolated(unsafe)"
                + " unowned(unsafe) Unmanaged @unchecked Sendable malloc(1) value.deallocate()"
            """#
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Unsafe expression requires documentation")
    func unsafeExpressionRequiresDocumentation() {
        let diagnostics = lint(
            """
            func read(_ pointer: UnsafePointer<Int>) -> Int {
                unsafe pointer.pointee
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeOperation])
    }

    @Test("Statement proofs cover guard, initializer, and return expressions")
    func statementProofsCoverCommonExpressions() {
        let diagnostics = lint(
            """
            func read(_ pointer: UnsafePointer<Int>?) -> Int {
                // SAFETY: the caller keeps the optional pointer valid for this synchronous read.
                guard let pointer = unsafe pointer else { return 0 }
                // SAFETY: the bound pointer contains one initialized Int.
                let value = unsafe pointer.pointee
                // SAFETY: returning this copied value does not extend pointer access.
                return unsafe value
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Multiple unsafe operations in one statement produce one diagnostic")
    func multipleUnsafeOperationsInOneStatementProduceOneDiagnostic() {
        let diagnostics = lint(
            """
            func sum(_ first: UnsafePointer<Int>, _ second: UnsafePointer<Int>) -> Int {
                unsafe first.pointee + unsafe second.pointee
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeOperation])
    }

    @Test("Specialized ownership diagnostic wins over generic unsafe diagnostic")
    func specializedOwnershipDiagnosticWins() {
        let diagnostics = lint(
            """
            func allocate() {
                _ = unsafe Darwin.malloc(16)
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.rawAllocation])
    }

    @Test("For unsafe requires documentation")
    func forUnsafeRequiresDocumentation() {
        let diagnostics = lint(
            """
            func visit(_ values: [Int]) {
                for unsafe value in values {
                    _ = value
                }
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeOperation])
    }

    @Test("Statement proof documents for unsafe")
    func statementProofDocumentsForUnsafe() {
        let diagnostics = lint(
            """
            func visit(_ values: [Int]) {
                // SAFETY: the collection remains unchanged for the complete iteration.
                for unsafe value in values {
                    _ = value
                }
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Unsafe import acknowledgements require exact declaration proofs")
    func unsafeImportAcknowledgementsRequireExactDeclarationProofs() {
        let diagnostics = lint(
            """
            // SAFETY: LegacyKit's imported declarations are externally synchronized.
            @preconcurrency import LegacyKit
            @unsafe import UnsafeKit
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeDeclaration])
        #expect(diagnostics.first?.line == 3)
    }

    @Test("One declaration proof covers combined import acknowledgements")
    func oneDeclarationProofCoversCombinedImportAcknowledgements() {
        let diagnostics = lint(
            """
            // SAFETY: this import is confined behind a checked adapter.
            @preconcurrency @unsafe import LegacyKit
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Unsafe declaration modifiers require documentation")
    func unsafeDeclarationModifiersRequireDocumentation() {
        let diagnostics = lint(
            """
            final class Owner {}
            final class Container {
                nonisolated(unsafe) static var shared = 0
                unowned(unsafe) var owner: Owner
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeDeclaration, .unsafeDeclaration])
    }

    @Test("Declaration proof documents an unsafe modifier")
    func declarationProofDocumentsUnsafeModifier() {
        let diagnostics = lint(
            """
            // SAFETY: all access occurs while the process-wide startup lock is held.
            nonisolated(unsafe) var shared = 0
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Unsafe conformance requires documentation")
    func unsafeConformanceRequiresDocumentation() {
        let diagnostics = lint(
            """
            struct ImportedBox: @unsafe LegacyProtocol {}
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeDeclaration])
    }

    @Test("Unowned unsafe capture requires documentation")
    func unownedUnsafeCaptureRequiresDocumentation() {
        let diagnostics = lint(
            """
            let callback = { [unowned(unsafe) owner] in
                owner.run()
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeOperation])
    }

    @Test("Statement proof documents an unowned unsafe capture")
    func statementProofDocumentsUnownedUnsafeCapture() {
        let diagnostics = lint(
            """
            // SAFETY: the callback cannot outlive owner because both belong to one request.
            let callback = { [unowned(unsafe) owner] in
                owner.run()
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Outer callable proof does not document a nested callable")
    func outerCallableProofDoesNotDocumentNestedCallable() {
        let diagnostics = lint(
            """
            // SAFETY: this proof belongs to outer only.
            func outer(_ pointer: UnsafePointer<Int>) {
                func nested() {
                    _ = unsafe pointer.pointee
                }
                nested()
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.unsafeOperation])
    }

    @Test("Function proof covers paired C allocation ownership")
    func functionProofCoversPairedCAllocationOwnership() {
        let diagnostics = lint(
            """
            // SAFETY: this function uniquely owns and releases the allocation.
            func copyBytes(_ count: Int) {
                guard let bytes = malloc(count) else { return }
                free(bytes)
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Qualified unsafe C allocation is detected")
    func qualifiedUnsafeCAllocationIsDetected() {
        let diagnostics = lint(
            """
            func allocate() {
                _ = unsafe Darwin.malloc(16)
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.rawAllocation])
    }

    @Test("Raw pointer allocation requires documentation")
    func rawPointerAllocationRequiresDocumentation() {
        let diagnostics = lint(
            """
            func allocate() {
                let bytes = UnsafeMutableRawPointer.allocate(
                    byteCount: 16,
                    alignment: 8
                )
                bytes.deallocate()
            }
            """
        )

        #expect(diagnostics.map(\.kind) == [.rawAllocation, .rawAllocation])
    }

    @Test("Allocator name in a declaration is not a call")
    func allocatorNameInDeclarationIsNotACall() {
        let diagnostics = lint(
            """
            func malloc(_ count: Int) -> Int { count }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Unrelated methods with allocator-like names are ignored")
    func unrelatedMethodsWithAllocatorLikeNamesAreIgnored() {
        let diagnostics = lint(
            """
            func release(_ pool: Pool) {
                pool.free()
                pool.deallocate(reason: "finished")
            }
            """
        )

        #expect(diagnostics.isEmpty)
    }

    @Test("Diagnostics use compiler-compatible locations")
    func diagnosticsUseCompilerCompatibleLocations() {
        let diagnostics = lint(
            """
            struct Container {
                func retain(_ object: AnyObject) {
                    _ = Unmanaged.passRetained(object)
                }
            }
            """
        )

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.line == 3)
        #expect(diagnostics.first?.column == 13)
        #expect(
            diagnostics.first?.rendered.contains("fixture.swift:3:13: error:") == true
        )
    }

    private func lint(_ source: String) -> [UnsafeBoundaryDiagnostic] {
        linter.lint(source: source, path: "fixture.swift")
    }
}
