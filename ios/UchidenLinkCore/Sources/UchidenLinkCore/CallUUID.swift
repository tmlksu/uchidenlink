import Foundation

/// Deterministic callId -> CallKit UUID derivation (design v0.3 §2.4).
/// UUIDv5 (SHA-1, RFC 4122) over the relay callId, so the three entry points
/// (WSS incoming / hello.call reconciliation / future push) all derive the
/// same UUID for the same call and duplicate reports collapse.
public enum CallUUID {
    /// Fixed namespace UUID; its bytes spell "UCHIDENLINK" in ASCII.
    public static let namespace = UUID(uuidString: "53504942-5249-4447-4500-000000000001")!

    public static func derive(callId: String) -> UUID {
        var nsBytes = [UInt8](repeating: 0, count: 16)
        (namespace as NSUUID).getBytes(&nsBytes)
        let digest = SHA1.hash(nsBytes + [UInt8](callId.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return NSUUID(uuidBytes: bytes) as UUID
    }
}
