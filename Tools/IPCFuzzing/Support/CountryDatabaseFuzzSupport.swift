import Foundation
import TorrentAppInfrastructure

// SAFETY: libFuzzer owns byteCount readable bytes for this synchronous call.
// The size is capped before copiedIPCFuzzInput makes a call-local owned copy;
// no pointer escapes and the immutable database uses only checked collection access.
@c(TorrentCountryDatabaseFuzzOneInput)
public func torrentCountryDatabaseFuzzOneInput(_ bytes: UnsafePointer<UInt8>?, _ byteCount: UInt) {
    guard byteCount <= 32 * 1_024 * 1_024 + 1,
          let data = unsafe copiedIPCFuzzInput(bytes, byteCount) else { return }
    autoreleasepool {
        guard let database = try? TorrentCountryDatabase(data: data) else { return }
        _ = database.countryCode(for: Data(data.prefix(4)))
        _ = database.countryCode(for: Data(data.suffix(16)))
        _ = database.countryCode(for: Data([1, 0, 0, 0]))
        _ = database.countryCode(for: Data([1, 0, 0, 1]))
        precondition(database.countryCode(for: Data([127, 0, 0, 1])) == nil)
    }
}
