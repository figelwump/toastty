import Foundation
import RemoteProtocol
import ToasttyMobileDomain

extension ToasttyPreviewService {
    static var fixture: Self {
        Self(
            content: { target in
                try Task.checkCancellation()
                return try ToasttyPreviewFixture.content(for: target)
            },
            resource: { request in
                try Task.checkCancellation()
                guard case .html(let entry) = try ToasttyPreviewFixture.content(for: request.target),
                      entry.sourcePath == request.expectedSourcePath else {
                    return RemoteHTMLResourceResponse(error: .stale)
                }
                guard let resource = ToasttyPreviewFixture.resources[request.relativePath] else {
                    return RemoteHTMLResourceResponse(error: .missing)
                }
                return RemoteHTMLResourceResponse(mimeType: resource.mimeType, data: Data(resource.text.utf8))
            }
        )
    }
}

/// Exercises actual web renderers without reading the developer's files or pairing a host.
enum ToasttyPreviewFixture {
    fileprivate struct Resource: Sendable {
        let mimeType: String
        let text: String
    }

    static func content(for target: RemotePreviewTarget) throws -> RemotePreviewContent {
        switch target {
        case .panel(let workspaceID, let panelID):
            guard let workspace = ToasttyMobileFixture.home.workspaces.first(where: { $0.id == workspaceID }),
                  workspace.panels.contains(where: { $0.panelID == panelID }) else {
                throw RemotePreviewError.missing
            }
            switch panelID {
            case ToasttyMobileFixture.scratchpadPanelID:
                return scratchpad(title: "Workspace map", documentNumber: 1)
            case ToasttyMobileFixture.navigationScratchpadPanelID:
                return scratchpad(title: "Navigation sketch", documentNumber: 2)
            case ToasttyMobileFixture.documentPanelID, ToasttyMobileFixture.olderDocumentPanelID, ToasttyMobileFixture.undatedDocumentPanelID:
                return document(line: nil)
            case ToasttyMobileFixture.htmlPanelID:
                return html
            case ToasttyMobileFixture.websitePanelID:
                return .webURL(URL(string: "https://example.com")!)
            default:
                throw RemotePreviewError.unsupported
            }
        case .conversationFile(let conversationID, let fileReference):
            guard ToasttyMobileFixture.home.activitySessions.contains(where: { $0.id == conversationID.rawValue }) else {
                throw RemotePreviewError.missing
            }
            let parts = fileReference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            var path = String(parts[0])
            var line: Int?
            if parts.count == 2 {
                line = Int(parts[1].drop(while: { $0 == "L" }))
            } else if let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]) {
                line = number
                path = String(path[..<colon])
            }
            switch path {
            case "docs/mobile-preview.md", "/fixtures/toastty/docs/mobile-preview.md":
                return document(line: line)
            case "site/preview.html", "/fixtures/toastty/site/preview.html":
                return html
            default:
                throw RemotePreviewError.missing
            }
        }
    }

    private static func document(line: Int?) -> RemotePreviewContent {
        .document(RemotePreviewDocument(
            title: "mobile-preview.md",
            sourcePath: "/fixtures/toastty/docs/mobile-preview.md",
            content: source,
            format: "markdown",
            line: line,
            revision: "fixture-document-1",
            formatLabel: "Markdown"
        ))
    }

    private static func scratchpad(title: String, documentNumber: Int) -> RemotePreviewContent {
        .scratchpad(RemotePreviewScratchpad(
            documentID: UUID(uuidString: String(format: "F1000000-0000-0000-0000-%012d", documentNumber))!,
            title: title,
            html: scratchpadHTML,
            revision: 1
        ))
    }

    private static let html = RemotePreviewContent.html(RemotePreviewHTML(
        title: "preview.html",
        sourcePath: "/fixtures/toastty/site/preview.html",
        html: """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Fieldnotes preview</title><link rel="stylesheet" href="styles/preview.css">
        <script defer src="scripts/preview.js"></script></head><body><main>
        <header><span class="leaf" aria-hidden="true"></span>Fieldnotes</header>
        <p class="eyebrow">A little room to think</p><h1>Good ideas<br>start here.</h1>
        <p>A quiet place for half-formed thoughts, small discoveries, and what comes next.</p>
        <button id="sample-button">Read a sample</button>
        <article><small>Friday / September 04</small><h2 id="sample-title">Leave some room.</h2>
        <p id="sample-copy">The best part of a blank page is that it doesn’t ask you to have it figured out yet.</p></article>
        </main></body></html>
        """,
        revision: "fixture-html-1"
    ))

    fileprivate static let resources: [String: Resource] = [
        "styles/preview.css": Resource(mimeType: "text/css", text: """
            *{box-sizing:border-box}body{margin:0;background:#f8f5ed;color:#282d27;font-family:system-ui}
            main{max-width:600px;margin:auto;padding:28px 24px}header{display:flex;align-items:center;gap:8px;
            font-weight:650;border-bottom:1px solid #dfdfd3;padding-bottom:24px}.leaf{display:inline-block;
            width:26px;height:26px;background:url('../images/leaf.svg') center/contain no-repeat}
            .eyebrow{font-size:10px;letter-spacing:1.8px;text-transform:uppercase;color:#6d7b61;margin-top:34px}
            h1{font:44px/1.05 Georgia,serif;letter-spacing:-1.5px;margin:18px 0}p{font-size:14px;line-height:1.6;
            color:#777c70}button{background:#536743;color:white;border:0;border-radius:8px;padding:14px 18px;
            font:14px system-ui;margin:14px 0 26px}article{padding:24px;background:#fffdf7;border:1px solid #e3e1d4;
            border-radius:4px}small{font:10px ui-monospace,monospace;color:#8c937d}h2{font:25px Georgia,serif;color:#46513d}
            """),
        "scripts/preview.js": Resource(mimeType: "text/javascript", text: """
            document.getElementById('sample-button').addEventListener('click', () => {
              document.getElementById('sample-title').textContent = 'Notice the small things.';
              document.getElementById('sample-copy').textContent = 'A good conversation. A new route home. An idea in the margin.';
              document.getElementById('sample-button').textContent = 'Sample loaded';
            });
            """),
        "images/leaf.svg": Resource(mimeType: "image/svg+xml", text: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28"><rect width="28" height="28" rx="8" fill="#536743"/>
            <path d="M9 19L19 9M10 9h9v9" fill="none" stroke="#fff" stroke-width="2"/></svg>
            """),
    ]

    private static let source = """
    # Mobile document previews

    Open workspace files on your phone.

    ## Supported files

    - Markdown and plain text
    - Code and configuration files
    - HTML in a browser preview

    ## Opening a file
    Tap a filename in the conversation.
    The preview opens in a sheet.

    Line references reveal that line.
    Close to return to your conversation.

    ## Workspace panels

    Open panels are listed above sessions.
    Each row includes its desktop tab.

    ## Scratchpads

    Pinch to zoom into a diagram.
    Drag to explore the canvas.

    Use Fit to match the screen width and return to the top.
    """

    private static let scratchpadHTML = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><style>
    *{box-sizing:border-box}body{margin:0;background:#f8f5ec;color:#51493b;font-family:system-ui}
    main{width:960px;padding:38px}h1{font-size:30px;font-weight:600;margin:12px 0}
    .eyebrow{font-size:12px;letter-spacing:2px;color:#918673}p{color:#8c8271;font-size:16px}
    .controls{display:flex;gap:22px;align-items:center;padding:22px 0;border-top:1px solid #d5cbb9}
    button,input{font:16px system-ui}button{border:1px solid #d8ba85;background:#f2dfbd;color:#755627;
    border-radius:8px;padding:10px 14px}label{display:flex;gap:8px;align-items:center}
    input[type=text]{width:150px;padding:8px;border:1px solid #d5cbb9;border-radius:5px}
    .notes{height:105px;overflow:auto;border:1px solid #d5cbb9;padding:14px;margin-top:12px;font-size:14px}
    </style></head><body><main><div class="eyebrow">TOASTTY / WORKSPACE MAP</div>
    <h1>Everything belongs to a workspace.</h1><p>Sessions do the work. Panels keep the results close.</p>
    <svg xmlns="http://www.w3.org/2000/svg" width="880" height="350" viewBox="0 0 880 350" role="img" aria-label="Workspace connections">
    <g fill="none" stroke="#b9ae9d" stroke-width="2"><path d="M440 80v32H240v37M440 80v32h200v37M640 209v40H170v29M640 209v40H440v29M640 209v40h70v29"/></g>
    <g font-family="system-ui" font-size="18" text-anchor="middle"><rect x="330" y="10" width="220" height="70" rx="12" fill="#423e34"/>
    <text x="440" y="53" fill="#f9f5ed">Toastty workspace</text><rect x="130" y="149" width="220" height="60" rx="12" fill="#ece5d7" stroke="#d5cbb9"/>
    <text x="240" y="186" fill="#51493b">Sessions</text><rect x="530" y="149" width="220" height="60" rx="12" fill="#f2dfbd" stroke="#d8ba85"/>
    <text x="640" y="186" fill="#755627">Open panels</text><rect x="60" y="278" width="220" height="60" rx="12" fill="#fffdf7" stroke="#d5cbb9"/>
    <text x="170" y="315" fill="#51493b">Documents</text><rect x="330" y="278" width="220" height="60" rx="12" fill="#fffdf7" stroke="#d5cbb9"/>
    <text x="440" y="315" fill="#51493b">Scratchpads</text><rect x="600" y="278" width="220" height="60" rx="12" fill="#fffdf7" stroke="#d5cbb9"/>
    <text x="710" y="315" fill="#51493b">Browser</text></g></svg>
    <div class="controls"><button id="count-button">Tap to count</button><output id="count-output" aria-live="polite">Count: 0</output>
    <label>Diagram detail<input aria-label="Diagram detail" type="range" min="0" max="100" value="50"></label>
    <label>Note<input aria-label="Scratchpad note" type="text" placeholder="Add a note"></label></div>
    <div class="notes" tabindex="0" aria-label="Scrollable notes"><strong>Scrollable notes</strong>
    <p>Open a panel to review its content on your phone.</p><p>Zoom and pan stay local to this viewer.</p>
    <p>Buttons, sliders, and text inputs should remain interactive.</p><p>Fit returns to the top at screen width.</p></div>
    <section style="padding-top:1800px"><h2>Further down the workspace</h2>
    <p>This tall document keeps its readable width while you scroll vertically.</p>
    <button id="bottom-button">Mark reviewed</button><output id="bottom-output">Not reviewed</output></section>
    </main><script>document.getElementById('bottom-button').addEventListener('click',()=>{
    document.getElementById('bottom-output').textContent='Reviewed';});let count=0;document.getElementById('count-button').addEventListener('click',()=>{
    document.getElementById('count-output').textContent='Count: '+(++count);});</script></body></html>
    """
}
