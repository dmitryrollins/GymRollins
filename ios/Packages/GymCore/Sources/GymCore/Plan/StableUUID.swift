import CryptoKit
import Foundation

/// Name-based UUIDs (UUIDv5 layout, SHA-256 instead of SHA-1): the same namespace + name always gives the same id,
/// so two devices applying the same proposal create routines with identical ids.
public enum StableUUID {
    public static func make(namespace: UUID, name: String) -> UUID {
        var input = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        input.append(Data(name.utf8))
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// An `add-routine` id generator for `PlanChangeApplier.apply`: the id derives from the proposal and change ids.
    public static func generator(namespace: UUID) -> (String) -> UUID {
        { changeId in make(namespace: namespace, name: changeId) }
    }
}
