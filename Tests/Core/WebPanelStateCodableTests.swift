import CoreState
import Foundation
import Testing

struct WebPanelStateCodableTests {
    @Test
    func localDocumentStateRoundTripsWithTypedPayload() throws {
        let state = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            localDocument: LocalDocumentState(
                filePath: "/tmp/project/README.md",
                format: .markdown
            )
        )

        let data = try JSONEncoder().encode(state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let localDocument = try #require(json["localDocument"] as? [String: Any])

        #expect(json["definition"] as? String == "localDocument")
        #expect(json["filePath"] == nil)
        #expect(localDocument["filePath"] as? String == "/tmp/project/README.md")
        #expect(localDocument["format"] as? String == "markdown")

        let decoded = try JSONDecoder().decode(WebPanelState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.filePath == "/tmp/project/README.md")
    }

    @Test
    func localDocumentStateRoundTripsWithoutFilePath() throws {
        let state = WebPanelState(
            definition: .localDocument,
            title: "Untitled",
            localDocument: LocalDocumentState(filePath: nil, format: .markdown)
        )

        let data = try JSONEncoder().encode(state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let localDocument = try #require(json["localDocument"] as? [String: Any])

        #expect(json["filePath"] == nil)
        #expect(localDocument["filePath"] == nil)
        #expect(localDocument["format"] as? String == "markdown")

        let decoded = try JSONDecoder().decode(WebPanelState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.filePath == nil)
        #expect(decoded.localDocument == LocalDocumentState(filePath: nil, format: .markdown))
    }

    @Test
    func decodingLegacyMarkdownPayloadHydratesLocalDocumentState() throws {
        let legacy = LegacyMarkdownWebPanelStatePayload(
            title: "README.md",
            filePath: "/tmp/project/README.md"
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(WebPanelState.self, from: data)

        #expect(decoded.definition == .localDocument)
        #expect(decoded.title == "README.md")
        #expect(decoded.filePath == "/tmp/project/README.md")
        #expect(
            decoded.localDocument == LocalDocumentState(
                filePath: "/tmp/project/README.md",
                format: .markdown
            )
        )
        #expect(decoded.initialURL == nil)
        #expect(decoded.currentURL == nil)
    }

    @Test
    func decodingLegacyBrowserPayloadKeepsBrowserURLs() throws {
        let legacy = LegacyBrowserWebPanelStatePayload(
            title: "Docs",
            initialURL: "https://example.com/docs",
            currentURL: "https://example.com/docs/latest"
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(WebPanelState.self, from: data)

        #expect(decoded.definition == .browser)
        #expect(decoded.title == "Docs")
        #expect(decoded.initialURL == "https://example.com/docs")
        #expect(decoded.currentURL == "https://example.com/docs/latest")
        #expect(decoded.restorableURL == "https://example.com/docs/latest")
        #expect(decoded.browserPageZoom == nil)
        #expect(decoded.effectiveBrowserPageZoom == WebPanelState.defaultBrowserPageZoom)
        #expect(decoded.localDocument == nil)
    }

    @Test
    func browserPageZoomRoundTripsWhenPresent() throws {
        let state = WebPanelState(
            definition: .browser,
            title: "Docs",
            initialURL: "https://example.com/docs",
            currentURL: "https://example.com/docs/latest",
            browserPageZoom: 1.25
        )

        let data = try JSONEncoder().encode(state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["browserPageZoom"] as? Double == 1.25)

        let decoded = try JSONDecoder().decode(WebPanelState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.browserPageZoom == 1.25)
        #expect(decoded.effectiveBrowserPageZoom == 1.25)
    }

    @Test
    func defaultBrowserPageZoomNormalizesOutOfPersistence() throws {
        let state = WebPanelState(
            definition: .browser,
            title: "Docs",
            initialURL: "https://example.com/docs",
            browserPageZoom: WebPanelState.defaultBrowserPageZoom
        )

        let data = try JSONEncoder().encode(state)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["browserPageZoom"] == nil)

        let decoded = try JSONDecoder().decode(WebPanelState.self, from: data)
        #expect(decoded.browserPageZoom == nil)
        #expect(decoded.effectiveBrowserPageZoom == WebPanelState.defaultBrowserPageZoom)
    }

    @Test
    func decodingUnknownWebPanelDefinitionThrows() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "definition": "futurePanel",
                "title": "Future",
            ]
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WebPanelState.self, from: data)
        }
    }
}

private struct LegacyMarkdownWebPanelStatePayload: Encodable {
    let definition = "markdown"
    let title: String
    let filePath: String
}

private struct LegacyBrowserWebPanelStatePayload: Encodable {
    let definition = "browser"
    let title: String
    let initialURL: String
    let currentURL: String
}
