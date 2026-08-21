#include "../../Sources/TorrentBridge/TorrentBridge.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientAlerts.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientCache.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientIdentity.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientLifecycle.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientPersistence.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientResume.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeSupport.cpp"

#include "BridgePointerAuthenticationTestSupport.hpp"

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace torrent_bridge::internal {

namespace {

struct PointerAuthenticationProbe {
    int wake_count = 0;
    int retain_count = 0;
    int release_count = 0;
    int open_count = 0;
    int size_count = 0;
};

std::uint8_t pointer_authentication_retain(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->retain_count;
    return 1U;
}

void pointer_authentication_release(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->release_count;
}

int32_t pointer_authentication_open(
    void *context,
    std::uint8_t const *,
    std::uint64_t,
    int32_t,
    std::uint8_t,
    int32_t *
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->open_count;
    return ENOENT;
}

int32_t pointer_authentication_size(
    void *context,
    std::uint8_t const *,
    std::uint64_t,
    int32_t,
    std::int64_t *
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->size_count;
    return ENOENT;
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

[[nodiscard]] PayloadBrokerCallbacks make_pointer_authentication_callbacks(
    PointerAuthenticationProbe *context
)
{
    return PayloadBrokerCallbacks{
        .context = context,
        .retain_context = pointer_authentication_retain,
        .release_context = pointer_authentication_release,
        .open_payload = pointer_authentication_open,
        .payload_size = pointer_authentication_size,
    };
}

} // namespace

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeWake(
    WakeCallbackInvocation const *invocation
) noexcept
{
    invocation->callback(invocation->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePayloadRetain(
    PayloadBrokerCallbacks const *callbacks
) noexcept
{
    static_cast<void>(callbacks->retain_context(callbacks->context));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePayloadRelease(
    PayloadBrokerCallbacks const *callbacks
) noexcept
{
    callbacks->release_context(callbacks->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePayloadOpen(
    PayloadBrokerCallbacks const *callbacks
) noexcept
{
    std::array<std::uint8_t, 16U> claim_id{};
    int32_t descriptor = -1;
    static_cast<void>(callbacks->open_payload(
        callbacks->context,
        claim_id.data(),
        1U,
        0,
        0U,
        &descriptor
    ));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePayloadSize(
    PayloadBrokerCallbacks const *callbacks
) noexcept
{
    std::array<std::uint8_t, 16U> claim_id{};
    std::int64_t size = -1;
    static_cast<void>(callbacks->payload_size(
        callbacks->context,
        claim_id.data(),
        1U,
        0,
        &size
    ));
}

extern "C" bool TorrentBridgeTestPACSlotsInvokeNormally() noexcept
{
    PointerAuthenticationProbe probe;
    WakeCallbackInvocation const wake{
        .callback = pointer_authentication_wake,
        .context = &probe,
    };
    PayloadBrokerCallbacks const callbacks = make_pointer_authentication_callbacks(&probe);

    TorrentBridgeTestInvokeWake(&wake);
    TorrentBridgeTestInvokePayloadRetain(&callbacks);
    TorrentBridgeTestInvokePayloadRelease(&callbacks);
    TorrentBridgeTestInvokePayloadOpen(&callbacks);
    TorrentBridgeTestInvokePayloadSize(&callbacks);
    return probe.wake_count == 1
        && probe.retain_count == 1
        && probe.release_count == 1
        && probe.open_count == 1
        && probe.size_count == 1;
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

extern "C" void TorrentBridgeTestReplayPayloadRetain() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PayloadBrokerCallbacks source = make_pointer_authentication_callbacks(&source_context);
    PayloadBrokerCallbacks destination = make_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.release_context = pointer_authentication_release;
    destination.open_payload = pointer_authentication_open;
    destination.payload_size = pointer_authentication_size;
    TorrentBridgeTestInvokePayloadRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayPayloadRelease() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PayloadBrokerCallbacks source = make_pointer_authentication_callbacks(&source_context);
    PayloadBrokerCallbacks destination = make_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_retain;
    destination.open_payload = pointer_authentication_open;
    destination.payload_size = pointer_authentication_size;
    TorrentBridgeTestInvokePayloadRelease(&destination);
}

extern "C" void TorrentBridgeTestReplayPayloadOpen() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PayloadBrokerCallbacks source = make_pointer_authentication_callbacks(&source_context);
    PayloadBrokerCallbacks destination = make_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_retain;
    destination.release_context = pointer_authentication_release;
    destination.payload_size = pointer_authentication_size;
    TorrentBridgeTestInvokePayloadOpen(&destination);
}

extern "C" void TorrentBridgeTestReplayPayloadSize() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PayloadBrokerCallbacks source = make_pointer_authentication_callbacks(&source_context);
    PayloadBrokerCallbacks destination = make_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_retain;
    destination.release_context = pointer_authentication_release;
    destination.open_payload = pointer_authentication_open;
    TorrentBridgeTestInvokePayloadSize(&destination);
}

extern "C" void TorrentBridgeTestReplayPayloadContext() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PayloadBrokerCallbacks source = make_pointer_authentication_callbacks(&source_context);
    PayloadBrokerCallbacks destination = make_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.retain_context = pointer_authentication_retain;
    destination.release_context = pointer_authentication_release;
    destination.open_payload = pointer_authentication_open;
    destination.payload_size = pointer_authentication_size;
    TorrentBridgeTestInvokePayloadRetain(&destination);
}

} // namespace torrent_bridge::internal
