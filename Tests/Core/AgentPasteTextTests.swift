import RemoteProtocol
import Testing

/// Claude Code 2.1.326 drops the Return that Toastty types after a paste
/// when a line of the paste names an image file. Each "converted" case below
/// was checked against the real CLI: the raw text stayed in the prompt as
/// `[Image #N]`, and the result submitted. Each "kept" case submitted as is.
struct AgentPasteTextTests {
    @Test(arguments: [
        // A line that is one image path, under a message's first line.
        ("Header\n/Users/me/attachments/a.jpg", "Header\n`/Users/me/attachments/a.jpg`"),
        // Two image paths on one line.
        ("/Users/me/a.jpg /Users/me/b.png", "`/Users/me/a.jpg` `/Users/me/b.png`"),
        // An image path next to another path: only the image path changes.
        ("/Users/me/a.jpg /etc/hosts", "`/Users/me/a.jpg` /etc/hosts"),
        // A line of prose that ends in an image name: its last word.
        ("Fix the icon in logo.png", "Fix the icon in `logo.png`"),
        ("shot.png", "`shot.png`"),
        ("/a.jpg", "`/a.jpg`"),
        // Every image extension Claude Code reads, in any case.
        ("/Users/me/A.JPG\n/Users/me/b.jpeg\n/Users/me/c.webp\n/Users/me/d.gif",
         "`/Users/me/A.JPG`\n`/Users/me/b.jpeg`\n`/Users/me/c.webp`\n`/Users/me/d.gif`"),
        // A path with a space stays one code span.
        ("'/Users/me/my shot.png'", "`'/Users/me/my shot.png'`"),
        (#"/Users/me/my\ shot.png"#, #"`/Users/me/my\ shot.png`"#),
        // The spaces around the path, other lines and CRLF line ends stay.
        ("  /Users/me/a.jpg  ", "  `/Users/me/a.jpg`  "),
        ("line\r\n/Users/me/a.jpg\r\nmore", "line\r\n`/Users/me/a.jpg`\r\nmore"),
        // A backtick in the path gets a longer fence.
        ("/Users/me/a`b.png", "``/Users/me/a`b.png``"),
        // Claude Code trims as JavaScript does, also a byte order mark.
        ("/Users/me/a.png\u{FEFF}", "`/Users/me/a.png`\u{FEFF}"),
    ])
    func linesThatClaudeCodeReadsAsImagesBecomeCodeSpans(text: String, expected: String) {
        let result = AgentPasteText.keepingImagePathsAsText(text)
        #expect(result == expected)
        // A second pass finds nothing more: the result submits.
        #expect(AgentPasteText.keepingImagePathsAsText(result) == result)
    }

    @Test(arguments: [
        "Plain text\nsecond line",
        // Claude Code keeps a line whose pieces are not all paths.
        "See /Users/me/a.jpg for details",
        "- /Users/me/a.jpg",
        "Screenshots: /Users/me/a.jpg /Users/me/b.jpg",
        // Not an image extension, or not at the end.
        "/Users/me/a.svg\n/Users/me/b.pdf",
        "/Users/me/a.jpg.",
        // Already a code span, as a phone attachment's path is.
        "Read the following files attached to this message on this Mac:\n`/Users/me/a.jpg`",
        "",
    ])
    func linesThatClaudeCodeKeepsAsTextDoNotChange(text: String) {
        #expect(AgentPasteText.keepingImagePathsAsText(text) == text)
    }
}
