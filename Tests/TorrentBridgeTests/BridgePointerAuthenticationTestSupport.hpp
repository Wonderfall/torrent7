#ifndef TORRENT_BRIDGE_POINTER_AUTHENTICATION_TEST_SUPPORT_HPP
#define TORRENT_BRIDGE_POINTER_AUTHENTICATION_TEST_SUPPORT_HPP

extern "C" {

[[nodiscard]] bool TorrentBridgeTestPACSlotsInvokeNormally() noexcept;

void TorrentBridgeTestReplayWakeCallback() noexcept;
void TorrentBridgeTestReplayWakeContext() noexcept;
void TorrentBridgeTestReplayAuthorizedRootRetain() noexcept;
void TorrentBridgeTestReplayAuthorizedRootRelease() noexcept;

}

#endif
