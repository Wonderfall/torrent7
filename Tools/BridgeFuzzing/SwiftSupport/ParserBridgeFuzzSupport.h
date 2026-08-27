#ifndef TORRENT_APP_PARSER_BRIDGE_FUZZ_SUPPORT_H
#define TORRENT_APP_PARSER_BRIDGE_FUZZ_SUPPORT_H

#include "TorrentBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

int32_t TorrentParserFuzzMakeSwarmMetainfoCallbacks(
    TTorrentSwarmMetainfoParserCallbacks *output
);
int32_t TorrentParserFuzzMakePeerProtocolCallbacks(
    TTorrentPeerProtocolParserCallbacks *output
);
int32_t TorrentParserFuzzMakeTrackerResponseCallbacks(
    TTorrentTrackerResponseParserCallbacks *output
);
int32_t TorrentParserFuzzMakeDHTMessageCallbacks(
    TTorrentDHTMessageParserCallbacks *output
);

#ifdef __cplusplus
}
#endif

#endif
