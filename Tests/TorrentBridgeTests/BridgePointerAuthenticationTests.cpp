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
}
