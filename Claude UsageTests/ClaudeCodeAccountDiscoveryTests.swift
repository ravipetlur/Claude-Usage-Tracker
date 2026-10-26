import XCTest
@testable import Claude_Usage

final class ClaudeCodeAccountDiscoveryTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - Helpers

    private func svc(forDir name: String) -> String {
        let path = tempHome.appendingPathComponent(name).path
        return "Claude Code-credentials-\(ClaudeCodeSyncService.shared.sha256HexPrefix(path, length: 8))"
    }

    private func oauthAccount(email: String, account: String, org: String, orgName: String = "Org") -> [String: Any] {
        ["emailAddress": email, "accountUuid": account, "organizationUuid": org, "organizationName": orgName]
    }

    /// Writes `.claude.json` for a config dir. `nil` dir name = default install
    /// (`~/.claude/` plus `~/.claude.json` in home).
    private func writeConfig(dir: String?, oauth: [String: Any]) throws {
        let configFile: URL
        if let dir = dir {
            let url = tempHome.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            configFile = url.appendingPathComponent(".claude.json")
        } else {
            try FileManager.default.createDirectory(at: tempHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            configFile = tempHome.appendingPathComponent(".claude.json")
        }
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": oauth, "theme": "dark"])
        try data.write(to: configFile)
    }

    private func discovery(_ entries: [String: Date]) -> ClaudeCodeAccountDiscovery {
        ClaudeCodeAccountDiscovery(homeDirectory: tempHome, keychainEntries: { entries })
    }

    // MARK: - Discovery

    func testFindsDefaultAndNamedConfigDirsWithKeychainEntries() throws {
        try writeConfig(dir: nil, oauth: oauthAccount(email: "me@gmail.com", account: "u1", org: "o1"))
        try writeConfig(dir: ".claude-verloop", oauth: oauthAccount(email: "ravi@verloop.io", account: "u2", org: "o2"))
        try writeConfig(dir: ".claude-devops", oauth: oauthAccount(email: "devops@verloop.io", account: "u3", org: "o2"))

        let found = discovery([
            "Claude Code-credentials": Date(),
            svc(forDir: ".claude-verloop"): Date(),
            svc(forDir: ".claude-devops"): Date(),
        ]).discover()

        XCTAssertEqual(found.map(\.emailAddress), ["me@gmail.com", "devops@verloop.io", "ravi@verloop.io"])
        XCTAssertEqual(found[0].keychainServiceName, "Claude Code-credentials")
        XCTAssertEqual(found[1].keychainServiceName, svc(forDir: ".claude-devops"))
        XCTAssertEqual(found[2].configDirectory, tempHome.appendingPathComponent(".claude-verloop").path)
    }

    func testSkipsDirsThatAreNotSignedIn() throws {
        try writeConfig(dir: ".claude-verloop", oauth: oauthAccount(email: "ravi@verloop.io", account: "u2", org: "o2"))
        try writeConfig(dir: ".claude-empty", oauth: oauthAccount(email: "x@y.z", account: "u9", org: "o9"))
        // No keychain entry for .claude-empty; no .claude.json for the default install.
        let found = discovery([
            "Claude Code-credentials": Date(),
            svc(forDir: ".claude-verloop"): Date(),
        ]).discover()

        XCTAssertEqual(found.map(\.emailAddress), ["ravi@verloop.io"])
    }

    func testIgnoresFilesNamedLikeConfigDirs() throws {
        try Data("key".utf8).write(to: tempHome.appendingPathComponent(".claude-session-key"))
        XCTAssertTrue(discovery([svc(forDir: ".claude-session-key"): Date()]).discover().isEmpty)
    }

    func testSameAccountInTwoDirsKeepsMostRecentlyUsedLogin() throws {
        let devops = oauthAccount(email: "devops@verloop.io", account: "u3", org: "o2")
        try writeConfig(dir: ".claude-team", oauth: devops)
        try writeConfig(dir: ".claude-devops", oauth: devops)

        let found = discovery([
            svc(forDir: ".claude-team"): Date(timeIntervalSinceNow: -86_400),
            svc(forDir: ".claude-devops"): Date(),
        ]).discover()

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.keychainServiceName, svc(forDir: ".claude-devops"))
    }

    func testSameUserInDifferentOrgsAreSeparateAccounts() throws {
        try writeConfig(dir: ".claude-a", oauth: oauthAccount(email: "me@x.io", account: "u1", org: "personal"))
        try writeConfig(dir: ".claude-b", oauth: oauthAccount(email: "me@x.io", account: "u1", org: "team"))

        let found = discovery([svc(forDir: ".claude-a"): Date(), svc(forDir: ".claude-b"): Date()]).discover()

        XCTAssertEqual(found.count, 2)
    }

    // MARK: - Import plan

    private func account(_ email: String, svc: String, identity: String) -> DiscoveredClaudeCodeAccount {
        DiscoveredClaudeCodeAccount(
            configDirectory: "/tmp/\(email)", keychainServiceName: svc, emailAddress: email,
            organizationName: nil, identity: identity, oauthAccountJSON: "{}", lastModified: Date()
        )
    }

    func testPlanCreatesProfilesForUntrackedAccounts() {
        let a = account("a@x.io", svc: "Claude Code-credentials", identity: "u1|o1")
        let b = account("b@x.io", svc: "Claude Code-credentials-1234abcd", identity: "u2|o2")

        XCTAssertEqual(ClaudeCodeAccountDiscovery.planImport([a, b], existing: [Profile(name: "Blank")]), [.create(a), .create(b)])
    }

    func testPlanPinsUnpinnedProfileWithSameAccount() {
        let a = account("a@x.io", svc: "Claude Code-credentials", identity: "u1|o1")
        let existing = Profile(
            name: "Personal",
            oauthAccountJSON: #"{"accountUuid":"u1","organizationUuid":"o1","emailAddress":"a@x.io"}"#
        )

        XCTAssertEqual(ClaudeCodeAccountDiscovery.planImport([a], existing: [existing]), [.pin(profileId: existing.id, a)])
    }

    func testPlanLeavesAlreadyPinnedProfilesAlone() {
        let a = account("a@x.io", svc: "Claude Code-credentials-1234abcd", identity: "u1|o1")
        let samePin = Profile(name: "Pinned", customKeychainServiceName: "Claude Code-credentials-1234abcd")
        let b = account("b@x.io", svc: "Claude Code-credentials-ffff0000", identity: "u2|o2")
        let pinnedElsewhere = Profile(
            name: "Old dir",
            customKeychainServiceName: "Claude Code-credentials-00000000",
            oauthAccountJSON: #"{"accountUuid":"u2","organizationUuid":"o2"}"#
        )

        XCTAssertEqual(
            ClaudeCodeAccountDiscovery.planImport([a, b], existing: [samePin, pinnedElsewhere]),
            [.alreadyTracked(profileId: samePin.id, a), .alreadyTracked(profileId: pinnedElsewhere.id, b)]
        )
    }

    func testPlanIgnoresNonAnthropicProfiles() {
        let a = account("a@x.io", svc: "Claude Code-credentials", identity: "u1|o1")
        let codex = Profile(
            name: "Codex", provider: .codex,
            customKeychainServiceName: "Claude Code-credentials"
        )

        XCTAssertEqual(ClaudeCodeAccountDiscovery.planImport([a], existing: [codex]), [.create(a)])
    }

    // MARK: - Pinning

    func testOnlyHashedPinsCountAsOwnConfigDir() {
        XCTAssertFalse(Profile(name: "x").isPinnedToOwnConfigDir)
        XCTAssertFalse(Profile(name: "x", customKeychainServiceName: "Claude Code-credentials").isPinnedToOwnConfigDir)
        XCTAssertTrue(Profile(name: "x", customKeychainServiceName: "Claude Code-credentials-bc5aba98").isPinnedToOwnConfigDir)
    }
}
