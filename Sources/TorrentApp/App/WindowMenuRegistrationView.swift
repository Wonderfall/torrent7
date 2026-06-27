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
        guard let window = unsafe self.window else {
            return
        }
        window.isExcludedFromWindowsMenu = false
    }
}
