import Darwin
import Foundation
import Security

/// Authorizes incoming XPC clients: the privileged helper must only accept the daemon.
///
/// The audit token is the canonical identifier for an XPC peer; the caller's code is resolved
/// from it with the `SecCode` APIs.
///
/// - **Team-signed build** (someone shipping with a Developer ID): the caller must share our Team
///   Identifier and be one of our components by code identifier.
/// - **Unsigned build** (the default — built from source, ad-hoc signed): there is no certificate
///   to anchor trust in, and an ad-hoc binary can claim any identifier. Trust comes from *where*
///   the caller runs instead: its executable must sit in `trustedInstallDirectory` with every path
///   component writable by root alone, so only root could have put it there. It must also run
///   with the hardened runtime, which keeps a user-editable LaunchAgent plist from injecting a
///   library through `DYLD_INSERT_LIBRARIES`.
public enum CallerVerifier {
    public static let allowedPrefix = "io.github.nikitashakhbazyan.lidwake"
    public static let trustedInstallDirectory = "/usr/local/libexec/lidwake"

    /// `kSecCodeSignatureRuntime`: the code was signed with the hardened runtime.
    static let hardenedRuntimeFlag: UInt32 = 0x10000

    struct Caller {
        let identifier: String
        let team: String?
        let path: String?
        let hardenedRuntime: Bool
    }

    public static func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        guard let caller = caller(for: connection) else { return false }
        return isAuthorizedDecision(ownTeam: ownTeamIdentifier(), caller: caller, isRootOnly: isWritableByRootOnly)
    }

    /// The pure authorization decision, separated from the Security-framework plumbing so it is
    /// unit-testable. When this process is team-signed, a caller without that exact team is
    /// rejected — including one with **no** team: its identifier would be unanchored.
    static func isAuthorizedDecision(ownTeam: String?, caller: Caller, isRootOnly: (String) -> Bool) -> Bool {
        if let ownTeam {
            return caller.team == ownTeam && isLidwakeComponent(caller.identifier)
        }
        guard caller.hardenedRuntime, let path = caller.path else { return false }
        return isTrustedInstallPath(path, isRootOnly: isRootOnly)
    }

    /// Code identifiers of the command-line tools when signed without an explicit identifier.
    /// Matched exactly — a prefix test would also admit a hostile `lidwake-daemon-evil`.
    static let componentIdentifiers: Set<String> = ["lidwake-daemon", "lidwake-helper"]

    static func isLidwakeComponent(_ identifier: String) -> Bool {
        identifier == allowedPrefix || identifier.hasPrefix(allowedPrefix + ".") || componentIdentifiers.contains(identifier)
    }

    /// True for a file inside the install directory whose every path component, up to `/`, only
    /// root can modify.
    static func isTrustedInstallPath(_ path: String, isRootOnly: (String) -> Bool) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix(trustedInstallDirectory + "/"),
              !components.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        var current = path
        while true {
            guard isRootOnly(current) else { return false }
            if current == "/" { return true }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Owned by root, not writable by group or others, and not a symlink.
    static func isWritableByRootOnly(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
        return info.st_uid == 0 && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func caller(for connection: NSXPCConnection) -> Caller? {
        // Fail closed: if the peer's audit token can't be read, we can't identify the caller, so
        // there is no safe way to authorize it. A zeroed token would resolve via
        // `SecCodeCopyGuestWithAttributes` to an unintended guest (pid 0 / self), so it must never
        // be substituted for a missing one.
        guard var token = connection.lidwake_auditToken else { return nil }
        let tokenData = Data(bytes: &token, count: MemoryLayout.size(ofValue: token))
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var codeRef: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              let stat = staticCode(for: code) else { return nil }
        return caller(of: stat)
    }

    /// Team Identifier of the *current* process, used as the reference for the caller's team.
    private static func ownTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let code = selfCode,
              let stat = staticCode(for: code) else { return nil }
        return caller(of: stat)?.team
    }

    private static func staticCode(for code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private static func caller(of staticCode: SecStaticCode) -> Caller? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String else { return nil }
        var url: CFURL?
        let path = SecCodeCopyPath(staticCode, [], &url) == errSecSuccess ? (url as URL?)?.path : nil
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return Caller(
            identifier: identifier,
            team: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            path: path,
            hardenedRuntime: flags & hardenedRuntimeFlag != 0,
        )
    }
}

private extension NSXPCConnection {
    /// `auditToken` is private on NSXPCConnection; KVC reach is the standard workaround. Returns nil
    /// when the value can't be read so the caller can fail closed rather than trust a zeroed token.
    var lidwake_auditToken: audit_token_t? {
        (value(forKey: "auditToken") as? NSValue)?.lidwake_audit_token_t_value
    }
}

private extension NSValue {
    /// NSValue wraps `audit_token_t` in some macOS releases; if not, return nil and the caller falls back.
    var lidwake_audit_token_t_value: audit_token_t? {
        var token = audit_token_t()
        let size = MemoryLayout<audit_token_t>.size
        let ok = withUnsafeMutableBytes(of: &token) { ptr -> Bool in
            (self as NSValue).getValue(ptr.baseAddress!, size: size)
            return true
        }
        return ok ? token : nil
    }
}
