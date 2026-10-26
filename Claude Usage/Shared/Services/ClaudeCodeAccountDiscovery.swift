//
//  ClaudeCodeAccountDiscovery.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-10-26.
//

import Foundation

/// A Claude Code login found on this Mac: a config dir whose `.claude.json`
/// names an account AND whose keychain entry exists (i.e. it is signed in).
struct DiscoveredClaudeCodeAccount: Equatable {
    /// Absolute config dir path (`~/.claude` for the default install).
    let configDirectory: String
    /// The keychain entry Claude Code keeps this login's tokens in.
    let keychainServiceName: String
    let emailAddress: String
    let organizationName: String?
    /// `accountUuid` + `organizationUuid` — one user can sit in several orgs
    /// (personal + Team) with separate logins, so the user id alone is not enough.
    let identity: String
    /// Raw `oauthAccount` object, stored on the profile like a CLI sync would.
    let oauthAccountJSON: String
    /// Keychain item's last-modified date; newer means in active use.
    let lastModified: Date
}

/// Finds every signed-in Claude Code config dir (`~/.claude` and `~/.claude-*`)
/// so each can become its own Tracker profile pinned to that dir's keychain entry.
///
/// Read-only: only `.claude.json` `oauthAccount` metadata and keychain item
/// attributes are read — never token payloads.
struct ClaudeCodeAccountDiscovery {
    static let defaultKeychainServiceName = "Claude Code-credentials"

    let homeDirectory: URL
    /// Claude Code keychain service names → last-modified date.
    let keychainEntries: () -> [String: Date]

    init(
        homeDirectory: URL = Constants.ClaudePaths.homeDirectory,
        keychainEntries: @escaping () -> [String: Date] = { ClaudeCodeSyncService.shared.claudeCodeKeychainEntries() }
    ) {
        self.homeDirectory = homeDirectory
        self.keychainEntries = keychainEntries
    }

    /// One entry per distinct account. When the same account is signed in under
    /// several config dirs, the one whose keychain entry changed most recently wins.
    func discover() -> [DiscoveredClaudeCodeAccount] {
        let entries = keychainEntries()
        var byIdentity: [String: DiscoveredClaudeCodeAccount] = [:]

        for (dir, configFiles, svc) in candidates() {
            guard let modified = entries[svc],
                  let account = readAccount(configFiles: configFiles) else {
                continue
            }
            let found = DiscoveredClaudeCodeAccount(
                configDirectory: dir.path,
                keychainServiceName: svc,
                emailAddress: account.email,
                organizationName: account.organizationName,
                identity: account.identity,
                oauthAccountJSON: account.json,
                lastModified: modified
            )
            if let existing = byIdentity[found.identity], existing.lastModified >= modified {
                continue
            }
            byIdentity[found.identity] = found
        }

        return byIdentity.values.sorted {
            // Default install first, then alphabetical by config dir.
            if ($0.keychainServiceName == Self.defaultKeychainServiceName) != ($1.keychainServiceName == Self.defaultKeychainServiceName) {
                return $0.keychainServiceName == Self.defaultKeychainServiceName
            }
            return $0.configDirectory < $1.configDirectory
        }
    }

    /// The identity key used for discovered accounts, derived from a stored
    /// `oauthAccount` JSON string so existing profiles can be matched against them.
    static func identity(fromOAuthAccountJSON json: String?) -> String? {
        guard let data = json?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return identity(fromOAuthAccount: obj)
    }

    enum ImportAction: Equatable {
        /// No profile tracks this account yet — make one.
        case create(DiscoveredClaudeCodeAccount)
        /// An unpinned profile already holds this account — pin it in place.
        case pin(profileId: UUID, DiscoveredClaudeCodeAccount)
        /// A profile is already pinned to this account; leave it as the user set it.
        case alreadyTracked(profileId: UUID, DiscoveredClaudeCodeAccount)
    }

    /// Decides what importing `accounts` should do given the current profiles.
    /// Never creates a second profile for an account an existing profile covers.
    static func planImport(_ accounts: [DiscoveredClaudeCodeAccount], existing: [Profile]) -> [ImportAction] {
        let candidates = existing.filter { $0.provider == .anthropic }
        var claimed: Set<UUID> = []

        return accounts.map { account in
            if let pinned = candidates.first(where: { $0.customKeychainServiceName == account.keychainServiceName }) {
                claimed.insert(pinned.id)
                return .alreadyTracked(profileId: pinned.id, account)
            }
            if let match = candidates.first(where: {
                !claimed.contains($0.id) && identity(fromOAuthAccountJSON: $0.oauthAccountJSON) == account.identity
            }) {
                claimed.insert(match.id)
                return match.customKeychainServiceName == nil
                    ? .pin(profileId: match.id, account)
                    : .alreadyTracked(profileId: match.id, account)
            }
            return .create(account)
        }
    }

    // MARK: - Private

    /// (config dir, `.claude.json` locations to try in order, keychain service).
    private func candidates() -> [(URL, [URL], String)] {
        let fm = FileManager.default
        let defaultDir = homeDirectory.appendingPathComponent(".claude")
        // Without CLAUDE_CONFIG_DIR, Claude Code keeps `.claude.json` in $HOME.
        var result: [(URL, [URL], String)] = [(
            defaultDir,
            [homeDirectory.appendingPathComponent(".claude.json"), defaultDir.appendingPathComponent(".claude.json")],
            Self.defaultKeychainServiceName
        )]

        let names = (try? fm.contentsOfDirectory(atPath: homeDirectory.path)) ?? []
        for name in names.sorted() where name.hasPrefix(".claude-") {
            let dir = homeDirectory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Claude Code hashes the absolute CLAUDE_CONFIG_DIR path (see discoverAccountLabels).
            let hash = ClaudeCodeSyncService.shared.sha256HexPrefix(dir.path, length: 8)
            result.append((dir, [dir.appendingPathComponent(".claude.json")], "\(Self.defaultKeychainServiceName)-\(hash)"))
        }
        return result
    }

    private func readAccount(configFiles: [URL]) -> (email: String, organizationName: String?, identity: String, json: String)? {
        for file in configFiles {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["oauthAccount"] as? [String: Any],
                  let email = oauth["emailAddress"] as? String, !email.isEmpty,
                  let identity = Self.identity(fromOAuthAccount: oauth),
                  let jsonData = try? JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys]),
                  let json = String(data: jsonData, encoding: .utf8) else {
                continue
            }
            return (email, oauth["organizationName"] as? String, identity, json)
        }
        return nil
    }

    private static func identity(fromOAuthAccount obj: [String: Any]) -> String? {
        let org = (obj["organizationUuid"] as? String) ?? ""
        if let uuid = obj["accountUuid"] as? String, !uuid.isEmpty {
            return "\(uuid)|\(org)"
        }
        if let email = obj["emailAddress"] as? String, !email.isEmpty {
            return "\(email.lowercased())|\(org)"
        }
        return nil
    }
}
