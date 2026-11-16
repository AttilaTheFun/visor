// The server's bearer tokens: 32 random bytes as hex, and compared whole
// (in constant time), with nothing matching an empty or missing token.

@testable import VisorServer
import Testing

extension ServerTests {
@Suite struct SecretTokenTests {
    @Test func testAMintedTokenIsThirtyTwoBytesOfHex() {
        let tokens = (0..<64).map { _ in SecretToken.mint() }
        for token in tokens {
            #expect(token.count == 64)
            #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        #expect(Set(tokens).count == tokens.count)
    }

    @Test func testOnlyTheSameTokenIsTheSame() {
        let kept = SecretToken.mint()
        #expect(SecretToken.same(kept, kept))
        #expect(SecretToken.same(String(kept), kept))
        #expect(!SecretToken.same(String(kept.dropLast()), kept), "a prefix")
        #expect(!SecretToken.same(kept + "a", kept), "longer")
        #expect(!SecretToken.same("", kept))
        #expect(!SecretToken.same(nil, kept))
        #expect(!SecretToken.same(kept, nil))
        #expect(!SecretToken.same(kept, ""))
        #expect(!SecretToken.same("", ""), "no token matches an empty one")
        #expect(!SecretToken.same("b" + kept.dropFirst(), "a" + kept.dropFirst()))
    }
}
}
