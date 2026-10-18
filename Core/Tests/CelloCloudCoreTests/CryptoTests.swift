import CryptoKit
import XCTest
@testable import CelloCloudCore

/// The iPhone app must open what the website encrypted, and the website what the iPhone encrypts.
/// In CI, Interop/vectors.mjs runs the website's own crypto code (web-crypto.js) to make
/// $CELLOCLOUD_INTEROP/web.json; these tests open it and write swift.json for Node to check back.
final class CryptoTests: XCTestCase {
    private var dir: URL? { ProcessInfo.processInfo.environment["CELLOCLOUD_INTEROP"].map { URL(fileURLWithPath: $0) } }

    private func webVectors() throws -> [String: String] {
        guard let dir else { throw XCTSkip("CELLOCLOUD_INTEROP not set (CI runs it)") }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("web.json")))
    }

    func testPasswordGivesTheSameKeysAsTheBrowser() throws {
        let v = try webVectors()
        let keys = try Crypto.passwordKeys(v["password"]!, saltHex: v["salt"]!)
        XCTAssertEqual(keys.authKey, v["authKey"])
        XCTAssertEqual(try Crypto.openB64(keys.encKey, v["wrappedVault"]!), Crypto.unhex(v["vault"]!))
    }

    func testRecoveryKeyMatchesTheBrowser() throws {
        let v = try webVectors()
        let parsed = try XCTUnwrap(Crypto.parseRecoveryText(v["recoveryText"]!))
        XCTAssertEqual(parsed, Crypto.unhex(v["recovery"]!))
        XCTAssertEqual(Crypto.recoveryText(parsed), v["recoveryText"])
        // Typed sloppily: lowercase, spaces, O for 0, l for 1.
        let sloppy = v["recoveryText"]!.lowercased().replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        XCTAssertEqual(Crypto.parseRecoveryText(sloppy), parsed)
        let rk = Crypto.recoveryKeys(parsed)
        XCTAssertEqual(rk.recAuth, v["recAuth"])
        XCTAssertEqual(try Crypto.openB64(rk.encKey, v["recWrapped"]!), Crypto.unhex(v["vault"]!))
    }

    func testOpensFileDetailsAndPiecesFromTheBrowser() throws {
        let v = try webVectors()
        let vault = Crypto.key(Crypto.unhex(v["vault"]!)!)
        let meta = String(decoding: try Crypto.openB64(vault, v["meta"]!), as: UTF8.self)
        XCTAssertTrue(meta.contains(v["metaName"]!))
        let chunk = try Crypto.open(Crypto.key(Crypto.unhex(v["fileKey"]!)!), Data(base64Encoded: v["chunk"]!)!)
        XCTAssertEqual(String(decoding: chunk, as: UTF8.self), v["chunkText"])
    }

    /// Made here, checked by Node with the website's code (vectors.mjs verify).
    func testWritesVectorsForTheBrowser() throws {
        guard let dir else { throw XCTSkip("CELLOCLOUD_INTEROP not set (CI runs it)") }
        let password = "Ïphone pässwörd ﬀ 12+"
        let salt = Crypto.hex(Crypto.random(16))
        let keys = try Crypto.passwordKeys(password, saltHex: salt)
        let vault = Crypto.random(32)
        let recovery = Crypto.random(32)
        let rk = Crypto.recoveryKeys(recovery)
        let fileKey = Crypto.random(32)
        let meta = try JSONSerialization.data(withJSONObject: ["name": "Ünïcode 📷.heic", "type": "image/heic", "size": 7,
                                                               "mtime": 1_760_000_000_000, "key": fileKey.base64EncodedString()])
        let out: [String: String] = [
            "password": password, "salt": salt, "authKey": keys.authKey,
            "vault": Crypto.hex(vault), "wrappedVault": try Crypto.sealB64(keys.encKey, vault),
            "recovery": Crypto.hex(recovery), "recoveryText": Crypto.recoveryText(recovery), "recAuth": rk.recAuth,
            "recWrapped": try Crypto.sealB64(rk.encKey, vault),
            "meta": try Crypto.sealB64(Crypto.key(vault), meta), "metaName": "Ünïcode 📷.heic", "fileKey": Crypto.hex(fileKey),
            "chunk": try Crypto.sealB64(Crypto.key(fileKey), Data("hello from the iPhone".utf8)), "chunkText": "hello from the iPhone",
        ]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("swift.json"))
    }

    func testSealsWhatItOpens() throws {
        let key = Crypto.key(Crypto.random(32))
        let data = Crypto.random(5000)
        XCTAssertEqual(try Crypto.open(key, Crypto.seal(key, data)), data)
        XCTAssertEqual(try Crypto.seal(key, Data()).count, 28) // empty file: nonce + tag
        var tampered = try Crypto.seal(key, data)
        tampered[20] ^= 1
        XCTAssertThrowsError(try Crypto.open(key, tampered))
    }

    func testRecoveryTextRoundTrips() {
        for _ in 0..<50 {
            let bytes = Crypto.random(32)
            let text = Crypto.recoveryText(bytes)
            XCTAssertEqual(text.count, 52 + 12) // 52 characters in groups of 4
            XCTAssertEqual(Crypto.parseRecoveryText(text), bytes)
        }
        XCTAssertNil(Crypto.parseRecoveryText("UUUU"))
        XCTAssertNil(Crypto.parseRecoveryText("0000-0000"))
    }
}
