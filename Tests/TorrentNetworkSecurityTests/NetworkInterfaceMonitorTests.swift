import Testing
@testable import TorrentNetworkSecurity

@Suite("Network interface monitor")
struct NetworkInterfaceMonitorTests {
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
