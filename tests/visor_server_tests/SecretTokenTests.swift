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

    /// The bytes as the strings are: the password's words (UTF-8, not
    /// characters), a hash beside another.
    @Test func testBytesAreTheSameOnlyWhole() {
        #expect(SecretToken.same(Array("pearl-grove".utf8), Array("pearl-grove".utf8)))
        #expect(!SecretToken.same(Array("pearl-grovf".utf8), Array("pearl-grove".utf8)), "the last byte")
        #expect(!SecretToken.same(Array("qearl-grove".utf8), Array("pearl-grove".utf8)), "the first byte")
        #expect(!SecretToken.same(Array("pearl".utf8), Array("pearl-grove".utf8)), "a prefix")
        #expect(!SecretToken.same(Array("pearl-grove-".utf8), Array("pearl-grove".utf8)), "longer")
        #expect(!SecretToken.same([], []))
        #expect(!SecretToken.same([0], []))
        #expect(!SecretToken.same([], [0]))
        #expect(SecretToken.same("café", "café"))
        #expect(!SecretToken.same("cafe\u{301}", "café"), "the bytes, not the characters")
    }

    /// One among many: `hello`'s tokens, every one looked at.
    @Test func testATokenIsFoundAmongThemOnlyWhole() {
        let kept = (0..<8).map { _ in SecretToken.mint() }
        #expect(SecretToken.any(kept, is: kept[0]))
        #expect(SecretToken.any(kept, is: kept[7]))
        #expect(SecretToken.any(Set(kept), is: kept[3]))
        #expect(!SecretToken.any(kept, is: String(kept[3].dropLast())))
        #expect(!SecretToken.any(kept, is: SecretToken.mint()))
        #expect(!SecretToken.any(kept, is: ""))
        #expect(!SecretToken.any(kept, is: nil))
        #expect(!SecretToken.any([String](), is: kept[0]))
        #expect(!SecretToken.any([""], is: ""))
    }
}
}
