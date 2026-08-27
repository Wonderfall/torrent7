#include "BridgePointerAuthenticationTestSupport.hpp"
#include "../DependencyHardening/PointerAuthenticationFailureTestSupport.hpp"

#include <doctest.h>

namespace {

using torrent7::test_support::replay_triggers_pointer_authentication_failure;

} // namespace

TEST_CASE("Bridge indirect pointer PAC rejects cross-storage replay")
{
    REQUIRE(TorrentBridgeTestPACSlotsInvokeNormally());
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayWakeCallback));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayWakeContext));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPayloadRetain));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPayloadRelease));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPayloadOpen));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPayloadSize));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPayloadContext));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplaySwarmMetainfoRetain));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplaySwarmMetainfoRelease));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplaySwarmMetainfoParse));
    CHECK(replay_triggers_pointer_authentication_failure(
        TorrentBridgeTestReplaySwarmMetainfoCapsuleRelease
    ));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplaySwarmMetainfoContext));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPeerProtocolRetain));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPeerProtocolRelease));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPeerProtocolHandshake));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPeerProtocolMetadata));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPeerProtocolPEX));
    CHECK(replay_triggers_pointer_authentication_failure(TorrentBridgeTestReplayPeerProtocolContext));
}
