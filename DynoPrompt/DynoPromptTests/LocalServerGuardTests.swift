//
//  LocalServerGuardTests.swift
//  DynoPromptTests
//
//  Regression tests for the Remote Connection / Director Mode request guard.
//  Each test names the attack it prevents; if one of these starts failing, a
//  real exfiltration path has reopened.
//

import XCTest

final class LocalServerGuardTests: XCTestCase {

    private let localAddresses: Set<String> = ["192.168.1.42", "fe80::1"]
    private let httpPort: UInt16 = 7373
    private let wsPort: UInt16 = 7374

    // MARK: - Host header / DNS rebinding

    func testLoopbackHostAccepted() {
        for host in ["localhost:7373", "127.0.0.1:7373", "[::1]:7373"] {
            XCTAssertTrue(
                LocalServerGuard.isAcceptableHost(
                    headers: ["host": host],
                    expectedPort: httpPort,
                    localAddresses: localAddresses
                ),
                "\(host) should be accepted"
            )
        }
    }

    func testLanAddressAccepted() {
        XCTAssertTrue(LocalServerGuard.isAcceptableHost(
            headers: ["host": "192.168.1.42:7373"],
            expectedPort: httpPort,
            localAddresses: localAddresses
        ))
    }

    func testBonjourNameAccepted() {
        XCTAssertTrue(LocalServerGuard.isAcceptableHost(
            headers: ["host": "my-mac.local:7373"],
            expectedPort: httpPort,
            localAddresses: localAddresses
        ))
    }

    /// The DNS rebinding attack: a page on `evil.test` re-points that name at
    /// 127.0.0.1 so the browser treats our server as same-origin and lets the
    /// page read the Director token out of the response.
    func testRebindingHostRejected() {
        for host in ["evil.test:7373", "attacker.example.com:7373", "dynoprompt.evil.co:7373"] {
            XCTAssertFalse(
                LocalServerGuard.isAcceptableHost(
                    headers: ["host": host],
                    expectedPort: httpPort,
                    localAddresses: localAddresses
                ),
                "\(host) must be rejected — DNS rebinding"
            )
        }
    }

    func testMismatchedPortRejected() {
        XCTAssertFalse(LocalServerGuard.isAcceptableHost(
            headers: ["host": "localhost:9999"],
            expectedPort: httpPort,
            localAddresses: localAddresses
        ))
    }

    func testUnknownLanAddressRejected() {
        XCTAssertFalse(LocalServerGuard.isAcceptableHost(
            headers: ["host": "10.0.0.9:7373"],
            expectedPort: httpPort,
            localAddresses: localAddresses
        ))
    }

    // MARK: - Origin / cross-site WebSocket

    /// WebSocket handshakes are NOT bound by the same-origin policy, so any
    /// page the user has open could otherwise stream the live transcript.
    func testCrossSiteOriginRejected() {
        for origin in [
            "https://evil.example",
            "http://attacker.test",
            "https://docs.google.com",
        ] {
            XCTAssertFalse(
                LocalServerGuard.isAcceptableOrigin(
                    headers: ["origin": origin],
                    allowedPorts: [httpPort, wsPort],
                    localAddresses: localAddresses
                ),
                "\(origin) must not be able to open a socket"
            )
        }
    }

    func testOwnPageOriginAccepted() {
        for origin in [
            "http://localhost:7373",
            "http://127.0.0.1:7373",
            "http://192.168.1.42:7373",
        ] {
            XCTAssertTrue(
                LocalServerGuard.isAcceptableOrigin(
                    headers: ["origin": origin],
                    allowedPorts: [httpPort, wsPort],
                    localAddresses: localAddresses
                ),
                "\(origin) is our own page"
            )
        }
    }

    func testNullOriginRejected() {
        XCTAssertFalse(LocalServerGuard.isAcceptableOrigin(
            headers: ["origin": "null"],
            allowedPorts: [httpPort, wsPort],
            localAddresses: localAddresses
        ))
    }

    /// A native client (the Python director example, curl, a companion app)
    /// sends no Origin. Those stay allowed — they are still token-gated.
    func testMissingOriginAllowedForNativeClients() {
        XCTAssertTrue(LocalServerGuard.isAcceptableOrigin(
            headers: [:],
            allowedPorts: [httpPort, wsPort],
            localAddresses: localAddresses
        ))
    }

    func testLoopbackOriginOnWrongPortRejected() {
        XCTAssertFalse(LocalServerGuard.isAcceptableOrigin(
            headers: ["origin": "http://localhost:8080"],
            allowedPorts: [httpPort, wsPort],
            localAddresses: localAddresses
        ))
    }

    func testNonHttpOriginSchemeRejected() {
        XCTAssertFalse(LocalServerGuard.isAcceptableOrigin(
            headers: ["origin": "file://localhost"],
            allowedPorts: [httpPort, wsPort],
            localAddresses: localAddresses
        ))
    }

    // MARK: - Request parsing

    func testParsesRequestHead() {
        let raw = "GET /index.html HTTP/1.1\r\nHost: localhost:7373\r\nOrigin: http://localhost:7373\r\n\r\nbody"
        let parsed = LocalServerGuard.parseRequestHead(raw)
        XCTAssertEqual(parsed?.method, "GET")
        XCTAssertEqual(parsed?.target, "/index.html")
        XCTAssertEqual(parsed?.headers["host"], "localhost:7373")
        XCTAssertEqual(parsed?.headers["origin"], "http://localhost:7373")
    }

    func testHeaderNamesAreCaseInsensitive() {
        let raw = "GET / HTTP/1.1\r\nHOST: localhost:7373\r\n\r\n"
        XCTAssertEqual(LocalServerGuard.parseRequestHead(raw)?.headers["host"], "localhost:7373")
    }

    /// Header smuggling: a second Host must not override the first.
    func testDuplicateHostHeaderKeepsFirst() {
        let raw = "GET / HTTP/1.1\r\nHost: localhost:7373\r\nHost: evil.test\r\n\r\n"
        XCTAssertEqual(LocalServerGuard.parseRequestHead(raw)?.headers["host"], "localhost:7373")
    }

    func testMalformedRequestRejected() {
        XCTAssertNil(LocalServerGuard.parseRequestHead(""))
        XCTAssertNil(LocalServerGuard.parseRequestHead("GARBAGE"))
    }

    func testBinaryGarbageDoesNotCrashParser() {
        let raw = String(repeating: "\u{0}\u{1}\u{2}", count: 500)
        _ = LocalServerGuard.parseRequestHead(raw)
    }

    // MARK: - Token comparison

    func testSecureCompareMatchesAndRejects() {
        let token = String(repeating: "a1b2", count: 16)
        XCTAssertTrue(LocalServerGuard.secureCompare(token, token))
        XCTAssertFalse(LocalServerGuard.secureCompare(token, String(repeating: "a1b3", count: 16)))
        XCTAssertFalse(LocalServerGuard.secureCompare(token, ""))
        XCTAssertFalse(LocalServerGuard.secureCompare("", ""))
        XCTAssertFalse(LocalServerGuard.secureCompare(token, String(token.dropLast())))
    }
}

// MARK: - Archive extraction containment

/// Regression tests for the arbitrary-file-read via a malicious .pptx.
final class ExtractedFileGuardTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynoPromptExtract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testRegularFileInsideRootIsAccepted() throws {
        let file = root.appendingPathComponent("notesSlide1.xml")
        try "<xml/>".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(ExtractedFileGuard.isContainedRegularFile(file, within: root))
    }

    /// The actual attack: a ZIP entry restored as a symlink pointing at a
    /// sensitive file outside the extraction directory.
    func testSymlinkEscapingRootIsRejected() throws {
        let secret = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynoprompt-secret-\(UUID().uuidString).txt")
        try "PRIVATE KEY MATERIAL".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }

        let link = root.appendingPathComponent("notesSlide1.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        XCTAssertFalse(
            ExtractedFileGuard.isContainedRegularFile(link, within: root),
            "a symlink out of the extraction directory must never be read"
        )
    }

    /// Even a symlink that stays inside the directory is refused: there is no
    /// legitimate reason for a presentation's notes part to be one.
    func testSymlinkInsideRootIsAlsoRejected() throws {
        let real = root.appendingPathComponent("real.xml")
        try "<xml/>".write(to: real, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("notesSlide1.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertFalse(ExtractedFileGuard.isContainedRegularFile(link, within: root))
    }

    func testDirectoryIsRejected() throws {
        let directory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(ExtractedFileGuard.isContainedRegularFile(directory, within: root))
    }

    func testTraversalPathsAreRejected() {
        XCTAssertFalse(ExtractedFileGuard.isContainedPath(
            root.appendingPathComponent("../../etc/passwd"),
            within: root
        ))
        XCTAssertFalse(ExtractedFileGuard.isContainedPath(
            URL(fileURLWithPath: "/etc/passwd"),
            within: root
        ))
        XCTAssertFalse(ExtractedFileGuard.isContainedPath(root, within: root))
    }

    /// A sibling directory whose name merely starts with the root's name must
    /// not count as contained.
    func testSiblingPrefixDirectoryIsRejected() {
        let sibling = URL(fileURLWithPath: root.path + "-evil").appendingPathComponent("x.xml")
        XCTAssertFalse(ExtractedFileGuard.isContainedPath(sibling, within: root))
    }
}
