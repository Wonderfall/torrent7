#include "BridgePointerAuthenticationTestSupport.hpp"
#include "../DependencyHardening/PointerAuthenticationFailureTestSupport.hpp"

#include <doctest.h>

namespace {

using torrent7::test_support::PointerAuthenticationFailure;
using torrent7::test_support::replay_triggers_pointer_authentication_failure;

} // namespace

TEST_CASE("Bridge indirect pointer PAC rejects cross-storage replay")
{
    REQUIRE(TorrentBridgeTestPACSlotsInvokeNormally());
    CHECK(replay_triggers_pointer_authentication_failure(
        TorrentBridgeTestReplayWakeCallback,
        PointerAuthenticationFailure::code_pointer
    ));
    CHECK(replay_triggers_pointer_authentication_failure(
        TorrentBridgeTestReplayWakeContext,
        PointerAuthenticationFailure::data_pointer
    ));
    CHECK(replay_triggers_pointer_authentication_failure(
        TorrentBridgeTestReplayAuthorizedRootRetain,
        PointerAuthenticationFailure::code_pointer
    ));
    CHECK(replay_triggers_pointer_authentication_failure(
        TorrentBridgeTestReplayAuthorizedRootRelease,
        PointerAuthenticationFailure::code_pointer
    ));
    CHECK(replay_triggers_pointer_authentication_failure(
        TorrentBridgeTestReplayAuthorizedRootContext,
        PointerAuthenticationFailure::data_pointer
    ));
}
