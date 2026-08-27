#ifndef TORRENT_BRIDGE_POINTER_AUTHENTICATION_TEST_SUPPORT_HPP
#define TORRENT_BRIDGE_POINTER_AUTHENTICATION_TEST_SUPPORT_HPP

extern "C" {

[[nodiscard]] bool TorrentBridgeTestPACSlotsInvokeNormally() noexcept;

void TorrentBridgeTestReplayWakeCallback() noexcept;
void TorrentBridgeTestReplayWakeContext() noexcept;
void TorrentBridgeTestReplayPayloadRetain() noexcept;
void TorrentBridgeTestReplayPayloadRelease() noexcept;
void TorrentBridgeTestReplayPayloadOpen() noexcept;
void TorrentBridgeTestReplayPayloadSize() noexcept;
void TorrentBridgeTestReplayPayloadContext() noexcept;
void TorrentBridgeTestReplaySwarmMetainfoRetain() noexcept;
void TorrentBridgeTestReplaySwarmMetainfoRelease() noexcept;
void TorrentBridgeTestReplaySwarmMetainfoParse() noexcept;
void TorrentBridgeTestReplaySwarmMetainfoCapsuleRelease() noexcept;
void TorrentBridgeTestReplaySwarmMetainfoContext() noexcept;
void TorrentBridgeTestReplayPeerProtocolRetain() noexcept;
void TorrentBridgeTestReplayPeerProtocolRelease() noexcept;
void TorrentBridgeTestReplayPeerProtocolHandshake() noexcept;
void TorrentBridgeTestReplayPeerProtocolMetadata() noexcept;
void TorrentBridgeTestReplayPeerProtocolPEX() noexcept;
void TorrentBridgeTestReplayPeerProtocolContext() noexcept;

}

#endif
