import XCTest
import AppKit
@testable import Zera

final class FilePayloadAndMarkdownTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zera-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try bytes.write(to: u)
        return u
    }

    func testTextFilesAreInlined() throws {
        let u = try write("notes.md", Data("# Hello\n\nsome notes".utf8))
        let p = try FilePayload.build(for: u)
        XCTAssertEqual(p.kind, .markdown)
        XCTAssertFalse(p.needsReadTool)
        guard case .inlineText(let t, let truncated) = p.mode else { return XCTFail() }
        XCTAssertEqual(t, "# Hello\n\nsome notes")
        XCTAssertFalse(truncated)
    }

    func testCodeIsDetectedByExtension() throws {
        let u = try write("main.swift", Data("print(1)".utf8))
        XCTAssertEqual(try FilePayload.build(for: u).kind, .code)
    }

    func testUnknownExtensionThatIsTextStillWorks() throws {
        let u = try write("weird.zqx", Data("just text\nmore text".utf8))
        let p = try FilePayload.build(for: u)
        guard case .inlineText = p.mode else { return XCTFail() }
    }

    func testBinaryGarbageIsRefused() throws {
        var bytes = Data(count: 4096)
        for i in 0..<bytes.count { bytes[i] = UInt8(i % 7) }   // lots of control bytes
        let u = try write("blob.zqx", bytes)
        XCTAssertThrowsError(try FilePayload.build(for: u)) { e in
            guard let be = e as? FilePayload.BuildError, case .unsupported = be else { return XCTFail("\(e)") }
        }
    }

    func testHugeTextIsTruncated() throws {
        let u = try write("big.log", Data(String(repeating: "x", count: FilePayload.inlineLimit + 1000).utf8))
        let p = try FilePayload.build(for: u)
        guard case .inlineText(let t, let truncated) = p.mode else { return XCTFail() }
        XCTAssertTrue(truncated)
        XCTAssertEqual(t.count, FilePayload.inlineLimit)
    }

    func testFoldersLinksAndMissingFiles() throws {
        XCTAssertThrowsError(try FilePayload.build(for: dir)) { e in
            guard let be = e as? FilePayload.BuildError, case .folder = be else { return XCTFail("\(e)") }
        }
        let link = try write("site.webloc", Data("<plist/>".utf8))
        XCTAssertThrowsError(try FilePayload.build(for: link)) { e in
            guard let be = e as? FilePayload.BuildError, case .link = be else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try FilePayload.build(for: dir.appendingPathComponent("nope.txt"))) { e in
            guard let be = e as? FilePayload.BuildError, case .missing = be else { return XCTFail("\(e)") }
        }
    }

    func testImagesGoToClaudeByPath() throws {
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let u = try write("dot.png", png)
        let p = try FilePayload.build(for: u)
        XCTAssertEqual(p.kind, .image)
        XCTAssertTrue(p.needsReadTool)
        let blocks = try p.apiBlocks(action: .explain)
        guard case .imageBase64(let media, _) = blocks.first?.kind else { return XCTFail() }
        XCTAssertEqual(media, "image/png")
    }

    /// A minimal PDF with a short text layer: too little text to trust → Claude reads the pages.
    func testScannedLikePDFUsesTheReadTool() throws {
        let u = try write("scan.pdf", Self.tinyPDF(text: "Hi"))
        let p = try FilePayload.build(for: u)
        XCTAssertEqual(p.kind, .pdf)
        XCTAssertEqual(p.pageCount, 1)
        XCTAssertTrue(p.needsReadTool)
    }

    func testTextPDFIsInlined() throws {
        let text = String(repeating: "The launch is on Friday and the budget is twelve thousand. ", count: 6)
        let u = try write("spec.pdf", Self.tinyPDF(text: text))
        let p = try FilePayload.build(for: u)
        guard case .inlineText(let t, _) = p.mode else { return XCTFail("expected inline text, got \(p.mode)") }
        XCTAssertTrue(t.contains("launch is on Friday"))
    }

    static func tinyPDF(text: String) -> Data {
        let content = "BT /F1 12 Tf 40 740 Td (\(text)) Tj ET"
        var objs: [String] = []
        objs.append("<< /Type /Catalog /Pages 2 0 R >>")
        objs.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objs.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        objs.append("<< /Length \(content.utf8.count) >>stream\n\(content)\nendstream")
        objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objs.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objs.count + 1)\n0000000000 65535 f \n"
        for off in offsets { out += String(format: "%010d 00000 n \n", off) }
        out += "trailer\n<< /Size \(objs.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    // MARK: Markdown

    private var theme: MarkdownLite.Theme {
        MarkdownLite.Theme(text: .black, secondary: .gray, code: .black, codeBackground: .lightGray, accent: .purple)
    }

    func testMarkdownMarkersAreConsumed() {
        let md = "## Summary\n\n- First **bold** point\n- Second `code` point\n1. Numbered\n\n```\nlet x = 1\n```\nPlain [link](https://example.com) text"
        let a = MarkdownLite.render(md, theme: theme, width: 300)
        let s = a.string
        XCTAssertFalse(s.contains("##"))
        XCTAssertFalse(s.contains("**"))
        XCTAssertFalse(s.contains("`"))
        XCTAssertFalse(s.contains("]("))
        XCTAssertTrue(s.contains("•\tFirst bold point"))
        XCTAssertTrue(s.contains("1.\tNumbered"))
        XCTAssertTrue(s.contains("let x = 1"))
        XCTAssertTrue(s.contains("Plain link text"))
        XCTAssertFalse(s.hasSuffix("\n"))
        // Bold really is bold, link really links.
        var sawBold = false, sawLink = false
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { attrs, range, _ in
            if (attrs[.font] as? NSFont) == Typo.bodyStrong, (s as NSString).substring(with: range) == "bold" { sawBold = true }
            if attrs[.link] != nil { sawLink = true }
        }
        XCTAssertTrue(sawBold); XCTAssertTrue(sawLink)
    }

    func testMarkdownWithUnbalancedMarkersDoesNotLoseText() {
        let a = MarkdownLite.render("a ** b ` c [d](e", theme: theme, width: 300)
        XCTAssertEqual(a.string, "a ** b ` c [d](e")
    }

    func testEmptyMarkdown() {
        XCTAssertEqual(MarkdownLite.render("", theme: theme, width: 300).length, 0)
    }

    // MARK: Keychain masking

    func testMaskingNeverRevealsTheMiddle() {
        XCTAssertEqual(KeychainStore.masked("sk-ant-EXAMPLE-NOT-A-REAL-KEY-h7Qa"), "sk-ant-…h7Qa")
        XCTAssertEqual(KeychainStore.masked("short"), "•••••")
    }
}
