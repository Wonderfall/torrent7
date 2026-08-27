#include "../../Sources/TorrentBridge/TorrentBridge.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientAlerts.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientCache.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientIdentity.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientLifecycle.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientPersistence.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeClientResume.cpp"
#include "../../Sources/TorrentBridge/TorrentBridgeMetainfo.cpp"
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
    int swarm_retain_count = 0;
    int swarm_release_count = 0;
    int swarm_parse_count = 0;
    int swarm_capsule_release_count = 0;
    int peer_retain_count = 0;
    int peer_release_count = 0;
    int peer_handshake_count = 0;
    int peer_metadata_count = 0;
    int peer_pex_count = 0;
    int tracker_retain_count = 0;
    int tracker_release_count = 0;
    int tracker_http_count = 0;
    int dht_retain_count = 0;
    int dht_release_count = 0;
    int dht_message_count = 0;
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

std::uint8_t pointer_authentication_swarm_retain(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->swarm_retain_count;
    return 1U;
}

void pointer_authentication_swarm_release(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->swarm_release_count;
}

int32_t pointer_authentication_swarm_parse(
    void *context,
    char const *,
    int32_t,
    TTorrentOwnedMetainfoCapsule *result
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->swarm_parse_count;
    *result = TTorrentOwnedMetainfoCapsule{};
    return EINVAL;
}

void pointer_authentication_swarm_capsule_release(
    void *context,
    TTorrentOwnedMetainfoCapsule
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->swarm_capsule_release_count;
}

std::uint8_t pointer_authentication_peer_retain(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->peer_retain_count;
    return 1U;
}

void pointer_authentication_peer_release(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->peer_release_count;
}

int32_t pointer_authentication_peer_handshake(
    void *context,
    char const *,
    int32_t,
    std::uint8_t *,
    int32_t,
    TTorrentExtensionHandshakeResult *result
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->peer_handshake_count;
    *result = TTorrentExtensionHandshakeResult{};
    return EINVAL;
}

int32_t pointer_authentication_peer_metadata(
    void *context,
    char const *,
    int32_t,
    TTorrentMetadataMessageResult *result
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->peer_metadata_count;
    *result = TTorrentMetadataMessageResult{};
    return EINVAL;
}

int32_t pointer_authentication_peer_pex(
    void *context,
    char const *,
    int32_t,
    TTorrentPeerExchangeRecord *,
    int32_t,
    TTorrentPeerExchangeResult *result
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->peer_pex_count;
    *result = TTorrentPeerExchangeResult{};
    return EINVAL;
}

std::uint8_t pointer_authentication_tracker_retain(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->tracker_retain_count;
    return 1U;
}

void pointer_authentication_tracker_release(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->tracker_release_count;
}

int32_t pointer_authentication_tracker_http(
    void *context,
    char const *,
    int32_t,
    std::uint8_t,
    std::uint8_t const *,
    int32_t,
    TTorrentTrackerPeerRecord *,
    int32_t,
    TTorrentHTTPTrackerResponseResult *result
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->tracker_http_count;
    *result = TTorrentHTTPTrackerResponseResult{};
    return EINVAL;
}

std::uint8_t pointer_authentication_dht_retain(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->dht_retain_count;
    return 1U;
}

void pointer_authentication_dht_release(void *context)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->dht_release_count;
}

int32_t pointer_authentication_dht_message(
    void *context,
    char const *,
    int32_t,
    std::uint8_t,
    TTorrentDHTNodeRecord *,
    int32_t,
    TTorrentDHTPeerRecord *,
    int32_t,
    TTorrentDHTMessageResult *result
)
{
    ++static_cast<PointerAuthenticationProbe *>(context)->dht_message_count;
    *result = TTorrentDHTMessageResult{};
    return EINVAL;
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

[[nodiscard]] SwarmMetainfoParserCallbacks make_swarm_pointer_authentication_callbacks(
    PointerAuthenticationProbe *context
)
{
    return SwarmMetainfoParserCallbacks{
        .context = context,
        .retain_context = pointer_authentication_swarm_retain,
        .release_context = pointer_authentication_swarm_release,
        .parse_info = pointer_authentication_swarm_parse,
        .release_capsule = pointer_authentication_swarm_capsule_release,
    };
}

[[nodiscard]] PeerProtocolParserCallbacks make_peer_pointer_authentication_callbacks(
    PointerAuthenticationProbe *context
)
{
    return PeerProtocolParserCallbacks{
        .context = context,
        .retain_context = pointer_authentication_peer_retain,
        .release_context = pointer_authentication_peer_release,
        .parse_extension_handshake = pointer_authentication_peer_handshake,
        .parse_metadata_message = pointer_authentication_peer_metadata,
        .parse_peer_exchange = pointer_authentication_peer_pex,
    };
}

[[nodiscard]] TrackerResponseParserCallbacks make_tracker_pointer_authentication_callbacks(
    PointerAuthenticationProbe *context
)
{
    return TrackerResponseParserCallbacks{
        .context = context,
        .retain_context = pointer_authentication_tracker_retain,
        .release_context = pointer_authentication_tracker_release,
        .parse_http_response = pointer_authentication_tracker_http,
    };
}

[[nodiscard]] DHTMessageParserCallbacks make_dht_pointer_authentication_callbacks(
    PointerAuthenticationProbe *context
)
{
    return DHTMessageParserCallbacks{
        .context = context,
        .retain_context = pointer_authentication_dht_retain,
        .release_context = pointer_authentication_dht_release,
        .parse_message = pointer_authentication_dht_message,
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

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeSwarmMetainfoRetain(
    SwarmMetainfoParserCallbacks const *callbacks
) noexcept
{
    static_cast<void>(callbacks->retain_context(callbacks->context));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeSwarmMetainfoRelease(
    SwarmMetainfoParserCallbacks const *callbacks
) noexcept
{
    callbacks->release_context(callbacks->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeSwarmMetainfoParse(
    SwarmMetainfoParserCallbacks const *callbacks
) noexcept
{
    std::array<char, 1U> info{{'d'}};
    TTorrentOwnedMetainfoCapsule result{};
    static_cast<void>(callbacks->parse_info(
        callbacks->context,
        info.data(),
        static_cast<int32_t>(info.size()),
        &result
    ));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeSwarmMetainfoCapsuleRelease(
    SwarmMetainfoParserCallbacks const *callbacks
) noexcept
{
    callbacks->release_capsule(callbacks->context, TTorrentOwnedMetainfoCapsule{});
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePeerProtocolRetain(
    PeerProtocolParserCallbacks const *callbacks
) noexcept
{
    static_cast<void>(callbacks->retain_context(callbacks->context));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePeerProtocolRelease(
    PeerProtocolParserCallbacks const *callbacks
) noexcept
{
    callbacks->release_context(callbacks->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePeerProtocolHandshake(
    PeerProtocolParserCallbacks const *callbacks
) noexcept
{
    std::array<char, 1U> message{{'d'}};
    std::array<std::uint8_t, TTORRENT_MAX_PEER_CLIENT_VERSION_BYTES> version{};
    TTorrentExtensionHandshakeResult result{};
    static_cast<void>(callbacks->parse_extension_handshake(
        callbacks->context,
        message.data(),
        static_cast<int32_t>(message.size()),
        version.data(),
        static_cast<int32_t>(version.size()),
        &result
    ));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePeerProtocolMetadata(
    PeerProtocolParserCallbacks const *callbacks
) noexcept
{
    std::array<char, 1U> message{{'d'}};
    TTorrentMetadataMessageResult result{};
    static_cast<void>(callbacks->parse_metadata_message(
        callbacks->context,
        message.data(),
        static_cast<int32_t>(message.size()),
        &result
    ));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokePeerProtocolPEX(
    PeerProtocolParserCallbacks const *callbacks
) noexcept
{
    std::array<char, 1U> message{{'d'}};
    std::array<TTorrentPeerExchangeRecord, TTORRENT_MAX_PEX_MESSAGE_CONTACTS> records{};
    TTorrentPeerExchangeResult result{};
    static_cast<void>(callbacks->parse_peer_exchange(
        callbacks->context,
        message.data(),
        static_cast<int32_t>(message.size()),
        records.data(),
        static_cast<int32_t>(records.size()),
        &result
    ));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeTrackerParserRetain(
    TrackerResponseParserCallbacks const *callbacks
) noexcept
{
    static_cast<void>(callbacks->retain_context(callbacks->context));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeTrackerParserRelease(
    TrackerResponseParserCallbacks const *callbacks
) noexcept
{
    callbacks->release_context(callbacks->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeTrackerParserHTTP(
    TrackerResponseParserCallbacks const *callbacks
) noexcept
{
    std::array<char, 2U> body{{'d', 'e'}};
    std::array<TTorrentTrackerPeerRecord, 1U> peers{};
    TTorrentHTTPTrackerResponseResult result{};
    static_cast<void>(callbacks->parse_http_response(
        callbacks->context,
        body.data(),
        static_cast<int32_t>(body.size()),
        0U,
        nullptr,
        0,
        peers.data(),
        static_cast<int32_t>(peers.size()),
        &result
    ));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeDHTParserRetain(
    DHTMessageParserCallbacks const *callbacks
) noexcept
{
    static_cast<void>(callbacks->retain_context(callbacks->context));
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeDHTParserRelease(
    DHTMessageParserCallbacks const *callbacks
) noexcept
{
    callbacks->release_context(callbacks->context);
}

extern "C" __attribute__((noinline, used)) void TorrentBridgeTestInvokeDHTParserMessage(
    DHTMessageParserCallbacks const *callbacks
) noexcept
{
    std::array<char, 2U> body{{'d', 'e'}};
    std::array<TTorrentDHTNodeRecord, 1U> nodes{};
    std::array<TTorrentDHTPeerRecord, 1U> peers{};
    TTorrentDHTMessageResult result{};
    static_cast<void>(callbacks->parse_message(
        callbacks->context,
        body.data(),
        static_cast<int32_t>(body.size()),
        TTORRENT_PEER_ADDRESS_IPV4,
        nodes.data(),
        static_cast<int32_t>(nodes.size()),
        peers.data(),
        static_cast<int32_t>(peers.size()),
        &result
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
    SwarmMetainfoParserCallbacks const swarm_callbacks =
        make_swarm_pointer_authentication_callbacks(&probe);
    PeerProtocolParserCallbacks const peer_callbacks =
        make_peer_pointer_authentication_callbacks(&probe);
    TrackerResponseParserCallbacks const tracker_callbacks =
        make_tracker_pointer_authentication_callbacks(&probe);
    DHTMessageParserCallbacks const dht_callbacks =
        make_dht_pointer_authentication_callbacks(&probe);

    TorrentBridgeTestInvokeWake(&wake);
    TorrentBridgeTestInvokePayloadRetain(&callbacks);
    TorrentBridgeTestInvokePayloadRelease(&callbacks);
    TorrentBridgeTestInvokePayloadOpen(&callbacks);
    TorrentBridgeTestInvokePayloadSize(&callbacks);
    TorrentBridgeTestInvokeSwarmMetainfoRetain(&swarm_callbacks);
    TorrentBridgeTestInvokeSwarmMetainfoRelease(&swarm_callbacks);
    TorrentBridgeTestInvokeSwarmMetainfoParse(&swarm_callbacks);
    TorrentBridgeTestInvokeSwarmMetainfoCapsuleRelease(&swarm_callbacks);
    TorrentBridgeTestInvokePeerProtocolRetain(&peer_callbacks);
    TorrentBridgeTestInvokePeerProtocolRelease(&peer_callbacks);
    TorrentBridgeTestInvokePeerProtocolHandshake(&peer_callbacks);
    TorrentBridgeTestInvokePeerProtocolMetadata(&peer_callbacks);
    TorrentBridgeTestInvokePeerProtocolPEX(&peer_callbacks);
    TorrentBridgeTestInvokeTrackerParserRetain(&tracker_callbacks);
    TorrentBridgeTestInvokeTrackerParserRelease(&tracker_callbacks);
    TorrentBridgeTestInvokeTrackerParserHTTP(&tracker_callbacks);
    TorrentBridgeTestInvokeDHTParserRetain(&dht_callbacks);
    TorrentBridgeTestInvokeDHTParserRelease(&dht_callbacks);
    TorrentBridgeTestInvokeDHTParserMessage(&dht_callbacks);
    return probe.wake_count == 1
        && probe.retain_count == 1
        && probe.release_count == 1
        && probe.open_count == 1
        && probe.size_count == 1
        && probe.swarm_retain_count == 1
        && probe.swarm_release_count == 1
        && probe.swarm_parse_count == 1
        && probe.swarm_capsule_release_count == 1
        && probe.peer_retain_count == 1
        && probe.peer_release_count == 1
        && probe.peer_handshake_count == 1
        && probe.peer_metadata_count == 1
        && probe.peer_pex_count == 1
        && probe.tracker_retain_count == 1
        && probe.tracker_release_count == 1
        && probe.tracker_http_count == 1
        && probe.dht_retain_count == 1
        && probe.dht_release_count == 1
        && probe.dht_message_count == 1;
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

extern "C" void TorrentBridgeTestReplaySwarmMetainfoRetain() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    SwarmMetainfoParserCallbacks source =
        make_swarm_pointer_authentication_callbacks(&source_context);
    SwarmMetainfoParserCallbacks destination =
        make_swarm_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.release_context = pointer_authentication_swarm_release;
    destination.parse_info = pointer_authentication_swarm_parse;
    destination.release_capsule = pointer_authentication_swarm_capsule_release;
    TorrentBridgeTestInvokeSwarmMetainfoRetain(&destination);
}

extern "C" void TorrentBridgeTestReplaySwarmMetainfoRelease() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    SwarmMetainfoParserCallbacks source =
        make_swarm_pointer_authentication_callbacks(&source_context);
    SwarmMetainfoParserCallbacks destination =
        make_swarm_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_swarm_retain;
    destination.parse_info = pointer_authentication_swarm_parse;
    destination.release_capsule = pointer_authentication_swarm_capsule_release;
    TorrentBridgeTestInvokeSwarmMetainfoRelease(&destination);
}

extern "C" void TorrentBridgeTestReplaySwarmMetainfoParse() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    SwarmMetainfoParserCallbacks source =
        make_swarm_pointer_authentication_callbacks(&source_context);
    SwarmMetainfoParserCallbacks destination =
        make_swarm_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_swarm_retain;
    destination.release_context = pointer_authentication_swarm_release;
    destination.release_capsule = pointer_authentication_swarm_capsule_release;
    TorrentBridgeTestInvokeSwarmMetainfoParse(&destination);
}

extern "C" void TorrentBridgeTestReplaySwarmMetainfoCapsuleRelease() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    SwarmMetainfoParserCallbacks source =
        make_swarm_pointer_authentication_callbacks(&source_context);
    SwarmMetainfoParserCallbacks destination =
        make_swarm_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_swarm_retain;
    destination.release_context = pointer_authentication_swarm_release;
    destination.parse_info = pointer_authentication_swarm_parse;
    TorrentBridgeTestInvokeSwarmMetainfoCapsuleRelease(&destination);
}

extern "C" void TorrentBridgeTestReplaySwarmMetainfoContext() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    SwarmMetainfoParserCallbacks source =
        make_swarm_pointer_authentication_callbacks(&source_context);
    SwarmMetainfoParserCallbacks destination =
        make_swarm_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.retain_context = pointer_authentication_swarm_retain;
    destination.release_context = pointer_authentication_swarm_release;
    destination.parse_info = pointer_authentication_swarm_parse;
    destination.release_capsule = pointer_authentication_swarm_capsule_release;
    TorrentBridgeTestInvokeSwarmMetainfoRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayPeerProtocolRetain() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PeerProtocolParserCallbacks source =
        make_peer_pointer_authentication_callbacks(&source_context);
    PeerProtocolParserCallbacks destination =
        make_peer_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.release_context = pointer_authentication_peer_release;
    destination.parse_extension_handshake = pointer_authentication_peer_handshake;
    destination.parse_metadata_message = pointer_authentication_peer_metadata;
    destination.parse_peer_exchange = pointer_authentication_peer_pex;
    TorrentBridgeTestInvokePeerProtocolRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayPeerProtocolRelease() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PeerProtocolParserCallbacks source =
        make_peer_pointer_authentication_callbacks(&source_context);
    PeerProtocolParserCallbacks destination =
        make_peer_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_peer_retain;
    destination.parse_extension_handshake = pointer_authentication_peer_handshake;
    destination.parse_metadata_message = pointer_authentication_peer_metadata;
    destination.parse_peer_exchange = pointer_authentication_peer_pex;
    TorrentBridgeTestInvokePeerProtocolRelease(&destination);
}

extern "C" void TorrentBridgeTestReplayPeerProtocolHandshake() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PeerProtocolParserCallbacks source =
        make_peer_pointer_authentication_callbacks(&source_context);
    PeerProtocolParserCallbacks destination =
        make_peer_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_peer_retain;
    destination.release_context = pointer_authentication_peer_release;
    destination.parse_metadata_message = pointer_authentication_peer_metadata;
    destination.parse_peer_exchange = pointer_authentication_peer_pex;
    TorrentBridgeTestInvokePeerProtocolHandshake(&destination);
}

extern "C" void TorrentBridgeTestReplayPeerProtocolMetadata() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PeerProtocolParserCallbacks source =
        make_peer_pointer_authentication_callbacks(&source_context);
    PeerProtocolParserCallbacks destination =
        make_peer_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_peer_retain;
    destination.release_context = pointer_authentication_peer_release;
    destination.parse_extension_handshake = pointer_authentication_peer_handshake;
    destination.parse_peer_exchange = pointer_authentication_peer_pex;
    TorrentBridgeTestInvokePeerProtocolMetadata(&destination);
}

extern "C" void TorrentBridgeTestReplayPeerProtocolPEX() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PeerProtocolParserCallbacks source =
        make_peer_pointer_authentication_callbacks(&source_context);
    PeerProtocolParserCallbacks destination =
        make_peer_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_peer_retain;
    destination.release_context = pointer_authentication_peer_release;
    destination.parse_extension_handshake = pointer_authentication_peer_handshake;
    destination.parse_metadata_message = pointer_authentication_peer_metadata;
    TorrentBridgeTestInvokePeerProtocolPEX(&destination);
}

extern "C" void TorrentBridgeTestReplayPeerProtocolContext() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    PeerProtocolParserCallbacks source =
        make_peer_pointer_authentication_callbacks(&source_context);
    PeerProtocolParserCallbacks destination =
        make_peer_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.retain_context = pointer_authentication_peer_retain;
    destination.release_context = pointer_authentication_peer_release;
    destination.parse_extension_handshake = pointer_authentication_peer_handshake;
    destination.parse_metadata_message = pointer_authentication_peer_metadata;
    destination.parse_peer_exchange = pointer_authentication_peer_pex;
    TorrentBridgeTestInvokePeerProtocolRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayTrackerParserRetain() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    TrackerResponseParserCallbacks source =
        make_tracker_pointer_authentication_callbacks(&source_context);
    TrackerResponseParserCallbacks destination =
        make_tracker_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.release_context = pointer_authentication_tracker_release;
    destination.parse_http_response = pointer_authentication_tracker_http;
    TorrentBridgeTestInvokeTrackerParserRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayTrackerParserRelease() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    TrackerResponseParserCallbacks source =
        make_tracker_pointer_authentication_callbacks(&source_context);
    TrackerResponseParserCallbacks destination =
        make_tracker_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_tracker_retain;
    destination.parse_http_response = pointer_authentication_tracker_http;
    TorrentBridgeTestInvokeTrackerParserRelease(&destination);
}

extern "C" void TorrentBridgeTestReplayTrackerParserHTTP() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    TrackerResponseParserCallbacks source =
        make_tracker_pointer_authentication_callbacks(&source_context);
    TrackerResponseParserCallbacks destination =
        make_tracker_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_tracker_retain;
    destination.release_context = pointer_authentication_tracker_release;
    TorrentBridgeTestInvokeTrackerParserHTTP(&destination);
}

extern "C" void TorrentBridgeTestReplayTrackerParserContext() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    TrackerResponseParserCallbacks source =
        make_tracker_pointer_authentication_callbacks(&source_context);
    TrackerResponseParserCallbacks destination =
        make_tracker_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.retain_context = pointer_authentication_tracker_retain;
    destination.release_context = pointer_authentication_tracker_release;
    destination.parse_http_response = pointer_authentication_tracker_http;
    TorrentBridgeTestInvokeTrackerParserRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayDHTParserRetain() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    DHTMessageParserCallbacks source =
        make_dht_pointer_authentication_callbacks(&source_context);
    DHTMessageParserCallbacks destination =
        make_dht_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.release_context = pointer_authentication_dht_release;
    destination.parse_message = pointer_authentication_dht_message;
    TorrentBridgeTestInvokeDHTParserRetain(&destination);
}

extern "C" void TorrentBridgeTestReplayDHTParserRelease() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    DHTMessageParserCallbacks source =
        make_dht_pointer_authentication_callbacks(&source_context);
    DHTMessageParserCallbacks destination =
        make_dht_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_dht_retain;
    destination.parse_message = pointer_authentication_dht_message;
    TorrentBridgeTestInvokeDHTParserRelease(&destination);
}

extern "C" void TorrentBridgeTestReplayDHTParserMessage() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    DHTMessageParserCallbacks source =
        make_dht_pointer_authentication_callbacks(&source_context);
    DHTMessageParserCallbacks destination =
        make_dht_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.context = &destination_context;
    destination.retain_context = pointer_authentication_dht_retain;
    destination.release_context = pointer_authentication_dht_release;
    TorrentBridgeTestInvokeDHTParserMessage(&destination);
}

extern "C" void TorrentBridgeTestReplayDHTParserContext() noexcept
{
    PointerAuthenticationProbe source_context;
    PointerAuthenticationProbe destination_context;
    DHTMessageParserCallbacks source =
        make_dht_pointer_authentication_callbacks(&source_context);
    DHTMessageParserCallbacks destination =
        make_dht_pointer_authentication_callbacks(&destination_context);
    replay_object_bytes(&destination, &source, sizeof(destination));
    destination.retain_context = pointer_authentication_dht_retain;
    destination.release_context = pointer_authentication_dht_release;
    destination.parse_message = pointer_authentication_dht_message;
    TorrentBridgeTestInvokeDHTParserRetain(&destination);
}

} // namespace torrent_bridge::internal
