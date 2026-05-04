import CoreState
import Testing

struct TerminalDropPayloadBuilderTests {
    @Test
    func shellEscapedPathPayloadWrapsEachPathAndAppendsSpace() throws {
        let payload = try #require(
            TerminalDropPayloadBuilder.shellEscapedPathPayload(
                forFilePaths: ["/tmp/image one.png", "/tmp/second.jpg"]
            )
        )

        #expect(payload == "'/tmp/image one.png' '/tmp/second.jpg' ")
    }

    @Test
    func shellEscapedPathEscapesSingleQuotes() {
        let escaped = TerminalDropPayloadBuilder.shellEscapedPath("/tmp/olivia's-image.png")
        #expect(escaped == "'/tmp/olivia'\"'\"'s-image.png'")
    }

    @Test
    func shellEscapedPathPayloadReturnsNilForNoPaths() {
        #expect(
            TerminalDropPayloadBuilder.shellEscapedPathPayload(forFilePaths: []) == nil
        )
    }

    @Test
    func shellEscapedPathPayloadRejectsPathsContainingLineBreaks() {
        #expect(
            TerminalDropPayloadBuilder.shellEscapedPathPayload(
                forFilePaths: ["/tmp/image\none.png"]
            ) == nil
        )
    }

    @Test
    func shellEscapedPathPayloadCanSkipTrailingSpace() throws {
        let payload = try #require(
            TerminalDropPayloadBuilder.shellEscapedPathPayload(
                forFilePaths: ["/tmp/image.png"],
                appendTrailingSpace: false
            )
        )
        #expect(payload == "'/tmp/image.png'")
    }

    @Test
    func shellEscapedPathPayloadHandlesNonImagePathsWithShellCharacters() throws {
        let payload = try #require(
            TerminalDropPayloadBuilder.shellEscapedPathPayload(
                forFilePaths: ["/Users/test/Downloads/app (1) $final.dmg"]
            )
        )

        #expect(payload == "'/Users/test/Downloads/app (1) $final.dmg' ")
    }
}
