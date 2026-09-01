import AppKit
import SwiftUI

struct WindowMenuRegistrationView: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowMenuRegistrationNSView {
        WindowMenuRegistrationNSView()
    }

    func updateNSView(_ view: WindowMenuRegistrationNSView, context: Context) {
        view.registerWindow()
    }
}

final class WindowMenuRegistrationNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindow()
    }

    func registerWindow() {
        // SAFETY: Ownership/lifetime: AppKit owns the view and its window for this
        // main-actor callback; bounds/alignment: no raw memory is accessed;
        // synchronization: AppKit invokes view lifecycle work on the main actor;
        // safe alternative: NSView.window is imported with unsafe unowned ownership.
        guard let window = unsafe self.window else {
            return
        }
        window.isExcludedFromWindowsMenu = false
    }
}
