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
    int retain_count = 0;
    int release_count = 0;
    int wake_count = 0;
};

void pointer_authentication_retain(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->retain_count;
}

void pointer_authentication_release(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->release_count;
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

[[nodiscard]] AuthorizedRootLifetimeRelease make_pointer_authentication_lifetime(
    PointerAuthenticationProbe *context
)
{
    return AuthorizedRootLifetimeRelease{
        .callbacks = {
            .retain = pointer_authentication_retain,
            .release = pointer_authentication_release,
        },
        .context = context,
    };
}

} // namespace

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeWake(
    WakeCallbackInvocation const *invocation
) noexcept
{
    invocation->callback(invocation->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeAuthorizedRootRetain(
    AuthorizedRootLifetimeRelease const *lifetime
) noexcept
{
    lifetime->callbacks.retain(lifetime->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeAuthorizedRootRelease(
    AuthorizedRootLifetimeRelease const *lifetime
) noexcept
{
    lifetime->callbacks.release(lifetime->context);
}

extern "C" bool TorrentBridgeTestPACSlotsInvokeNormally() noexcept
{
    PointerAuthenticationProbe probe;
    WakeCallbackInvocation const wake{
        .callback = pointer_authentication_wake,
        .context = &probe,
    };
    AuthorizedRootLifetimeRelease const lifetime = make_pointer_authentication_lifetime(&probe);

    TorrentBridgeTestInvokeWake(&wake);
    TorrentBridgeTestInvokeAuthorizedRootRetain(&lifetime);
    TorrentBridgeTestInvokeAuthorizedRootRelease(&lifetime);
    return probe.wake_count == 1 && probe.retain_count == 1 && probe.release_count == 1;
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
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    AuthorizedRootLifetimeRelease source = make_pointer_authentication_lifetime(&source_context);
    AuthorizedRootLifetimeRelease destination = make_pointer_authentication_lifetime(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.callbacks.release = pointer_authentication_release;
    destination.context = &destination_context;
    TorrentBridgeTestInvokeAuthorizedRootRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayAuthorizedRootRelease() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    AuthorizedRootLifetimeRelease source = make_pointer_authentication_lifetime(&source_context);
    AuthorizedRootLifetimeRelease destination = make_pointer_authentication_lifetime(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.callbacks.retain = pointer_authentication_retain;
    destination.context = &destination_context;
    TorrentBridgeTestInvokeAuthorizedRootRelease(&destination);
}

extern "C" void TorrentBridgeTestReplayAuthorizedRootContext() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    AuthorizedRootLifetimeRelease source = make_pointer_authentication_lifetime(&source_context);
    AuthorizedRootLifetimeRelease destination = make_pointer_authentication_lifetime(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.callbacks.retain = pointer_authentication_retain;
    destination.callbacks.release = pointer_authentication_release;
    TorrentBridgeTestInvokeAuthorizedRootRelease(&destination);
}

} // namespace torrent_bridge::internal
