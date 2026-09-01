import Testing
@testable import TorrentNetworkSecurity

@Suite("Network interface monitor")
struct NetworkInterfaceMonitorTests {
    // SAFETY: Ownership/lifetime: the initial strong optional keeps the passUnretained pointer
    // alive until retainCallback adds ownership, then releaseCallback balances it;
    // bounds/alignment: the pointer is the exact aligned class address with no byte access;
    // synchronization: the test invokes callbacks serially; safe alternative: verifying the C
    // context ownership protocol requires an opaque Unmanaged pointer.
    @Test("Dynamic store callbacks balance context ownership")
    func dynamicStoreCallbacksBalanceContextOwnership() {
        var context: NetworkInterfaceMonitorDynamicStoreContext? =
            NetworkInterfaceMonitorDynamicStoreContext(monitor: nil)
        weak let weakContext = context
        let info = unsafe Unmanaged.passUnretained(context!).toOpaque()
        let retainedInfo = unsafe NetworkInterfaceMonitorDynamicStoreContext
            .retainCallback(info)

        context = nil
        #expect(weakContext != nil)

        unsafe NetworkInterfaceMonitorDynamicStoreContext
            .releaseCallback(retainedInfo)
        #expect(weakContext == nil)
    }

    @Test("Dynamic store context does not retain its monitor")
    func dynamicStoreContextDoesNotRetainMonitor() {
        var monitor: NetworkInterfaceMonitor? = NetworkInterfaceMonitor()
        weak let weakMonitor = monitor
        let context = NetworkInterfaceMonitorDynamicStoreContext(
            monitor: monitor
        )

        monitor = nil

        #expect(weakMonitor == nil)
        withExtendedLifetime(context) {}
    }
}
