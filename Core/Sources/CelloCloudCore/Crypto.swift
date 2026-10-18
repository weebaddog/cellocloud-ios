// CelloCloud's end-to-end encryption (the same as web/crypto.js and the Android Crypto.kt).
//
//   password ──PBKDF2-SHA256, 600k rounds, per-user salt──▶ 64 bytes
//     ├─ first 32: password key (encrypts the vault key; never leaves this device)
//     └─ last 32:  auth key (sent to sign in; the server only keeps a scrypt hash of it)
//   vault key:     32 random bytes, made at sign-up; encrypts every file's details + key
//   recovery key:  32 random bytes shown once at sign-up; HKDF → its own encrypt + auth keys
//   each file:     its own random 32-byte key; every 4 MB piece is AES-256-GCM sealed
//
// Sealed format everywhere: 12-byte random nonce ‖ ciphertext ‖ 16-byte tag.

import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum CryptoError: Error {
    case badInput
    case cantOpen
}

public enum Crypto {
    public static let chunkSize = 4 * 1024 * 1024
    static let pbkdf2Rounds: UInt32 = 600_000

    public struct PasswordKeys {
        public let encKey: SymmetricKey
        public let authKey: String
    }

    public struct RecoveryKeys {
        public let encKey: SymmetricKey
        public let recAuth: String
    }

    public static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "no secure random numbers")
        return data
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    public static func unhex(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }

    /// The two keys made from a password (see the top of this file). Slow on purpose (~0.5 s).
    public static func passwordKeys(_ password: String, saltHex: String) throws -> PasswordKeys {
        guard let salt = unhex(saltHex) else { throw CryptoError.badInput }
        // NFKC, like the browser's password.normalize("NFKC"), then UTF-8.
        let pw = Array(password.precomposedStringWithCompatibilityMapping.utf8).map { CChar(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 64)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), pbkdf2Rounds, &out, out.count)
        }
        guard status == kCCSuccess else { throw CryptoError.badInput }
        defer { out.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        return PasswordKeys(encKey: SymmetricKey(data: out[0..<32]), authKey: hex(Data(out[32..<64])))
    }

    /// The two keys made from the recovery key.
    public static func recoveryKeys(_ recovery: Data) -> RecoveryKeys {
        let base = SymmetricKey(data: recovery)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: base, salt: Data(count: 32), info: Data(info.utf8), outputByteCount: 32)
        }
        let auth = derive("cellocloud recovery auth").withUnsafeBytes { Data($0) }
        return RecoveryKeys(encKey: derive("cellocloud recovery encrypt"), recAuth: hex(auth))
    }

    public static func key(_ raw: Data) -> SymmetricKey { SymmetricKey(data: raw) }

    public static func seal(_ key: SymmetricKey, _ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce()).combined else { throw CryptoError.badInput }
        return combined
    }

    public static func open(_ key: SymmetricKey, _ sealed: Data) throws -> Data {
        guard sealed.count >= 28 else { throw CryptoError.cantOpen }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key) } catch { throw CryptoError.cantOpen }
    }

    public static func sealB64(_ key: SymmetricKey, _ data: Data) throws -> String { try seal(key, data).base64EncodedString() }

    public static func openB64(_ key: SymmetricKey, _ text: String) throws -> Data {
        guard let data = Data(base64Encoded: text) else { throw CryptoError.cantOpen }
        return try open(key, data)
    }

    // ---- recovery key as text (Crockford base32, groups of 4; ambiguous letters accepted) ----
    static let b32 = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func recoveryText(_ bytes: Data) -> String {
        var bits = 0
        var value: UInt32 = 0
        var out = ""
        for b in bytes {
            value = (value &<< 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                out.append(b32[Int((value >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(b32[Int((value &<< UInt32(5 - bits)) & 31)]) }
        var groups: [String] = []
        var rest = Substring(out)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: "-")
    }

    public static func parseRecoveryText(_ text: String) -> Data? {
        var bits = 0
        var value: UInt32 = 0
        var out = Data()
        for ch in text.uppercased() {
            guard ch.isASCII, ch.isLetter || ch.isNumber else { continue }
            let c: Character = ch == "O" ? "0" : (ch == "I" || ch == "L") ? "1" : ch
            guard let v = b32.firstIndex(of: c) else { return nil }
            value = (value &<< 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> UInt32(bits - 8)) & 255))
                bits -= 8
            }
        }
        return out.count == 32 ? out : nil
    }
}
