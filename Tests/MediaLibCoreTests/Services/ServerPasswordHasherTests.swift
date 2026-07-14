import XCTest
@testable import MediaLibCore

final class ServerPasswordHasherTests: XCTestCase {
    func testArgon2idRoundTripUsesVersion19AndConfiguredParameters() throws {
        let hasher = try ServerPasswordHasher(
            iterations: 2,
            memoryCostKib: 1_024,
            parallelism: 1,
            saltLength: 16,
            hashLength: 32,
            randomBytes: { count in Array(0..<UInt8(count)) }
        )

        let encoded = try hasher.hash(password: "correct horse battery staple")

        XCTAssertTrue(encoded.hasPrefix("$argon2id$v=19$m=1024,t=2,p=1$"))
        XCTAssertTrue(hasher.verify(password: "correct horse battery staple", encodedHash: encoded))
        XCTAssertFalse(hasher.verify(password: "incorrect horse battery staple", encodedHash: encoded))
    }

    func testPasswordLengthAndRandomSaltLengthAreEnforced() throws {
        let hasher = try ServerPasswordHasher(
            iterations: 1,
            memoryCostKib: 1_024,
            randomBytes: { _ in [1, 2, 3] }
        )

        XCTAssertThrowsError(try hasher.hash(password: "too-short")) { error in
            XCTAssertEqual(error as? ServerPasswordHasherError, .passwordLengthInvalid)
        }
        XCTAssertThrowsError(try hasher.hash(password: "long-enough-password")) { error in
            XCTAssertEqual(error as? ServerPasswordHasherError, .randomGenerationFailed)
        }
    }

    func testTokenDigestMatchesIndependentBLAKE2b256KnownAnswer() {
        XCTAssertEqual(
            ServerTokenSecurity.digest("abc"),
            "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
        )
    }

    func testGeneratedTokensAreURLSafeAndHaveAtLeast256BitsOfInput() {
        let first = ServerTokenSecurity.generateToken()
        let second = ServerTokenSecurity.generateToken()

        XCTAssertEqual(first.count, 43)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}
