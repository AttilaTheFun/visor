import Crypto
import CryptoExtras
import Foundation

/// The Runner's user's password as its secrets keep it (docs/runner-accounts.md):
/// never the password, only scrypt's key of it with a salt of its own,
/// written `scrypt$<N>$<r>$<p>$<salt>$<key>` (base64), so a stolen secrets
/// file gives no password and the cost can rise later without a new form.
public enum RunnerPassword {
    /// scrypt's cost: 2^15 rounds of 8 blocks, one lane (32 MiB, a few
    /// tens of milliseconds a try).
    static let rounds = 1 << 15
    static let blockSize = 8
    static let parallelism = 1
    static let keyBytes = 32

    /// A password's hash, with a new random salt.
    public static func hash(_ password: String) throws -> String {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try derive(password, salt: salt, rounds: rounds, blockSize: blockSize, parallelism: parallelism)
        return ["scrypt", String(rounds), String(blockSize), String(parallelism), salt.base64EncodedString(), key.base64EncodedString()]
            .joined(separator: "$")
    }

    /// Whether `password` is the one `stored` was made from, compared in
    /// constant time. A hash of a form this build doesn't know is no match.
    public static func verifies(_ password: String, against stored: String) -> Bool {
        let parts = stored.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "scrypt", let rounds = Int(parts[1]), let blockSize = Int(parts[2]),
              let parallelism = Int(parts[3]), let salt = Data(base64Encoded: parts[4]), let expected = Data(base64Encoded: parts[5]),
              rounds > 1, rounds <= 1 << 20, blockSize > 0, blockSize <= 16, parallelism > 0, parallelism <= 4,
              let key = try? derive(password, salt: salt, rounds: rounds, blockSize: blockSize, parallelism: parallelism, bytes: expected.count)
        else { return false }
        return key.count == expected.count && zip(key, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ password: String, salt: Data, rounds: Int, blockSize: Int, parallelism: Int,
                               bytes: Int = keyBytes) throws -> Data {
        try KDF.Scrypt.deriveKey(from: Data(password.utf8), salt: salt, outputByteCount: bytes, rounds: rounds,
                                 blockSize: blockSize, parallelism: parallelism).withUnsafeBytes { Data($0) }
    }
}
