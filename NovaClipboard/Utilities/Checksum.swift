import Foundation
import CryptoKit

enum Checksum {
    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
