import Foundation
import Testing
@testable import LidwakeKit

/// The full XPC authorization path needs a live peer, so it can't be unit-tested here. These cover
/// the decisions: the identifier allow-list (team-signed builds) and the install-path trust that is
/// the entire gate for an unsigned build.
@Suite("CallerVerifier identifier allow-list")
struct CallerVerifierTests {
    @Test
    func `reverse-DNS identifiers under our prefix are accepted`() {
        #expect(CallerVerifier.isLidwakeComponent("io.github.nikitashakhbazyan.lidwake"))
        #expect(CallerVerifier.isLidwakeComponent("io.github.nikitashakhbazyan.lidwake.daemon"))
        #expect(CallerVerifier.isLidwakeComponent("io.github.nikitashakhbazyan.lidwake.helper"))
    }

    @Test
    func `the tool names are accepted exactly`() {
        #expect(CallerVerifier.isLidwakeComponent("lidwake-daemon"))
        #expect(CallerVerifier.isLidwakeComponent("lidwake-helper"))
    }

    @Test
    func `look-alikes are rejected`() {
        #expect(!CallerVerifier.isLidwakeComponent("lidwake-daemon-55554944572a111aa4e631978f328488fa7c4992"))
        #expect(!CallerVerifier.isLidwakeComponent("io.github.nikitashakhbazyan.lidwakeevil"))
        #expect(!CallerVerifier.isLidwakeComponent("com.evil.lidwake"))
        #expect(!CallerVerifier.isLidwakeComponent(""))
    }
}

@Suite("CallerVerifier authorization decision")
struct CallerVerifierDecisionTests {
    private let team = "52K336H235"
    private let installed = "/usr/local/libexec/lidwake/lidwake-daemon"
    private let rootOnly: (String) -> Bool = { _ in true }

    private func caller(
        _ identifier: String = "lidwake-daemon",
        team: String? = nil,
        path: String? = "/usr/local/libexec/lidwake/lidwake-daemon",
        hardened: Bool = true,
    ) -> CallerVerifier.Caller {
        .init(identifier: identifier, team: team, path: path, hardenedRuntime: hardened)
    }

    @Test
    func `team-signed self rejects a caller with no team or another team`() {
        #expect(!CallerVerifier.isAuthorizedDecision(ownTeam: team, caller: caller(), isRootOnly: rootOnly))
        #expect(!CallerVerifier.isAuthorizedDecision(ownTeam: team, caller: caller(team: "EVILTEAM00"), isRootOnly: rootOnly))
    }

    @Test
    func `team-signed self accepts its own component and rejects a foreign identifier`() {
        #expect(CallerVerifier.isAuthorizedDecision(ownTeam: team, caller: caller(team: team), isRootOnly: rootOnly))
        #expect(!CallerVerifier.isAuthorizedDecision(ownTeam: team, caller: caller("com.example.other", team: team), isRootOnly: rootOnly))
    }

    @Test
    func `unsigned self trusts a hardened binary from the root-only install directory`() {
        #expect(CallerVerifier.isAuthorizedDecision(ownTeam: nil, caller: caller(), isRootOnly: rootOnly))
    }

    @Test
    func `unsigned self ignores the claimed identifier and checks the location`() {
        // Any ad-hoc binary can call itself lidwake-daemon; where it runs from is what counts.
        #expect(!CallerVerifier.isAuthorizedDecision(ownTeam: nil, caller: caller(path: "/Users/me/.build/debug/lidwake-daemon"), isRootOnly: rootOnly))
        #expect(!CallerVerifier.isAuthorizedDecision(ownTeam: nil, caller: caller(path: nil), isRootOnly: rootOnly))
    }

    @Test
    func `unsigned self requires the hardened runtime`() {
        #expect(!CallerVerifier.isAuthorizedDecision(ownTeam: nil, caller: caller(hardened: false), isRootOnly: rootOnly))
    }

    @Test
    func `a writable component anywhere on the path breaks trust`() {
        for writable in [installed, "/usr/local/libexec/lidwake", "/usr/local/libexec", "/usr/local", "/usr", "/"] {
            #expect(!CallerVerifier.isTrustedInstallPath(installed) { $0 != writable }, "writable: \(writable)")
        }
        #expect(CallerVerifier.isTrustedInstallPath(installed) { _ in true })
    }

    @Test
    func `dot segments and look-alike directories are rejected`() {
        #expect(!CallerVerifier.isTrustedInstallPath("/usr/local/libexec/lidwake/../evil/lidwake-daemon") { _ in true })
        #expect(!CallerVerifier.isTrustedInstallPath("/usr/local/libexec/lidwake-evil/lidwake-daemon") { _ in true })
        #expect(!CallerVerifier.isTrustedInstallPath("/usr/local/libexec/lidwake") { _ in true })
    }

    @Test
    func `the real file system check refuses user-writable paths`() {
        #expect(CallerVerifier.isWritableByRootOnly("/usr/bin/true"))
        #expect(!CallerVerifier.isWritableByRootOnly(NSTemporaryDirectory()))
        #expect(!CallerVerifier.isWritableByRootOnly("/no/such/file"))
    }
}
