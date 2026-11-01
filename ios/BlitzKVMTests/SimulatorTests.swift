import ApprovalKit
import XCTest
@testable import BlitzKVM

/// On the Simulator, ApprovalKit falls back to software keys and a software
/// vault (its Secure Enclave makes no keys).
final class SimulatorTests: XCTestCase {
    func testDevelopmentKeysPersist() throws {
        let store = MemoryBlobStore()
        let keys = try ApproverKeys.loadOrCreate(in: store)
        XCTAssertFalse(keys.hardwareBacked)
        let again = try ApproverKeys.loadOrCreate(in: store)
        XCTAssertEqual(again.id, keys.id)
        XCTAssertEqual(again.transport.publicKey, keys.transport.publicKey)
        XCTAssertEqual(again.seal.publicKey, keys.seal.publicKey)
        XCTAssertNotNil(store.load(AppConfig.sealKeyName), "the extension reads the seal key under this name")
    }

    func testVaultRoundTrip() throws {
        let vault = Vaults.make(store: MemoryBlobStore())
        XCTAssertFalse(vault.has(target: "t", kind: SecretKind.mac))
        try vault.store("pässwörd^`", target: "t", kind: SecretKind.mac)
        XCTAssertTrue(vault.has(target: "t", kind: SecretKind.mac))
        XCTAssertEqual(try vault.secret(target: "t", kind: SecretKind.mac, context: nil), "pässwörd^`")
        XCTAssertNil(try vault.secret(target: "t", kind: SecretKind.onePassword, context: nil))
        vault.remove(target: "t", kind: SecretKind.mac)
        XCTAssertFalse(vault.has(target: "t", kind: SecretKind.mac))
    }
}
