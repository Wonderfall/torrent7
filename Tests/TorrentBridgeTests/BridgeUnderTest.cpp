#include "../../Sources/TorrentBridge/TorrentBridge.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientAlerts.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientCache.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientIdentity.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientLifecycle.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientPersistence.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientResume.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeSupport.cpp"

#include "BridgePointerAuthenticationTestSupport.hpp"

#include <cstddef>
#include <cstring>

namespace torrent_bridge::internal {

namespace {

struct PointerAuthenticationProbe {
    int wake_count = 0;
};

int pointer_authentication_retain_count = 0;
int pointer_authentication_release_count = 0;

std::uint8_t pointer_authentication_retain(std::uint64_t)
{
    ++pointer_authentication_retain_count;
    return 1U;
}

void pointer_authentication_release(std::uint64_t)
{
    ++pointer_authentication_release_count;
}

void pointer_authentication_wake(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->wake_count;
}

__attribute__((noinline)) void replay_object_bytes(
    void *destination,
    void const *source,
    std::size_t const size
)
{
    // Replaying the authenticated representation byte-for-byte is the attack
    // under test. Keep that deliberately unsafe operation isolated here.
    __unsafe_buffer_usage_begin
    std::memcpy(destination, source, size);
    __unsafe_buffer_usage_end
}

[[nodiscard]] AuthorizedRootLifetime make_pointer_authentication_lifetime(
    std::uint64_t const token
)
{
    return AuthorizedRootLifetime(
        AuthorizedRootLifetimeCallbacks{
            .retain = pointer_authentication_retain,
            .release = pointer_authentication_release,
        },
        token
    );
}

} // namespace

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeWake(
    WakeCallbackInvocation const *invocation
) noexcept
{
    invocation->callback(invocation->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeAuthorizedRootRetain(
    AuthorizedRootLifetime const *lifetime
) noexcept
{
    static_cast<void>(lifetime->callbacks.retain(lifetime->token));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeAuthorizedRootRelease(
    AuthorizedRootLifetime const *lifetime
) noexcept
{
    lifetime->callbacks.release(lifetime->token);
}

extern "C" bool TorrentBridgeTestPACSlotsInvokeNormally() noexcept
{
    PointerAuthenticationProbe probe;
    WakeCallbackInvocation const wake{
        .callback = pointer_authentication_wake,
        .context = &probe,
    };
    pointer_authentication_retain_count = 0;
    pointer_authentication_release_count = 0;
    AuthorizedRootLifetime const lifetime = make_pointer_authentication_lifetime(1U);

    TorrentBridgeTestInvokeWake(&wake);
    TorrentBridgeTestInvokeAuthorizedRootRetain(&lifetime);
    TorrentBridgeTestInvokeAuthorizedRootRelease(&lifetime);
    return probe.wake_count == 1
        && pointer_authentication_retain_count == 1
        && pointer_authentication_release_count == 1;
}

extern "C" void TorrentBridgeTestReplayWakeCallback() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    WakeCallbackInvocation source{
        .callback = pointer_authentication_wake,
        .context = &source_context,
    };
    WakeCallbackInvocation destination{
        .callback = pointer_authentication_wake,
        .context = &destination_context,
    };
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    TorrentBridgeTestInvokeWake(&destination);
}

extern "C" void TorrentBridgeTestReplayWakeContext() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    WakeCallbackInvocation source{
        .callback = pointer_authentication_wake,
        .context = &source_context,
    };
    WakeCallbackInvocation destination{
        .callback = pointer_authentication_wake,
        .context = &destination_context,
    };
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.callback = pointer_authentication_wake;
    TorrentBridgeTestInvokeWake(&destination);
}

extern "C" void TorrentBridgeTestReplayAuthorizedRootRetain() noexcept
{
    AuthorizedRootLifetime source = make_pointer_authentication_lifetime(1U);
    AuthorizedRootLifetime destination = make_pointer_authentication_lifetime(2U);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.callbacks.release = pointer_authentication_release;
    destination.token = 2U;
    TorrentBridgeTestInvokeAuthorizedRootRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayAuthorizedRootRelease() noexcept
{
    AuthorizedRootLifetime source = make_pointer_authentication_lifetime(1U);
    AuthorizedRootLifetime destination = make_pointer_authentication_lifetime(2U);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.callbacks.retain = pointer_authentication_retain;
    destination.token = 2U;
    TorrentBridgeTestInvokeAuthorizedRootRelease(&destination);
}

} // namespace torrent_bridge::internal
