import Foundation
import Testing
@testable import CRTerminal

struct Item: JumpSearchable, Equatable {
    var name: String
    var facets: [SessionFacet]
}

private func item(
    _ name: String, sessionName: String? = nil, title: String? = nil,
    command: String? = nil, directory: String? = nil, branch: String? = nil
) -> Item {
    var facets: [SessionFacet] = []
    // The user's custom name outweighs the inferred title (matches nameFacets).
    if let sessionName {
        facets.append(SessionFacet(kind: "name", text: sessionName, weight: 2.5))
    }
    if let title { facets.append(SessionFacet(kind: "title", text: title, weight: 2)) }
    if let command { facets.append(SessionFacet(kind: "command", text: command, weight: 1.5)) }
    if let directory { facets.append(SessionFacet(kind: "directory", text: directory)) }
    if let branch { facets.append(SessionFacet(kind: "branch", text: branch)) }
    return Item(name: name, facets: facets)
}

struct JumpSearchTests {
    let items = [
        item("a", title: "vim", command: "vim", directory: "~/dev/kmono", branch: "main"),
        item("b", title: "zsh", command: "zsh", directory: "~/dev/mcq-master", branch: "fix/parser"),
        item("c", title: "claude", command: "claude", directory: "~/Documents/CRTerminal", branch: "main"),
    ]

    @Test func emptyQueryReturnsEverythingInOrder() {
        #expect(JumpSearch.rank(items, query: "").map(\.name) == ["a", "b", "c"])
        #expect(JumpSearch.rank(items, query: "   ").map(\.name) == ["a", "b", "c"])
    }

    @Test func substringFiltersAcrossAllFacets() {
        #expect(JumpSearch.rank(items, query: "mcq").map(\.name) == ["b"])
        #expect(JumpSearch.rank(items, query: "claude").map(\.name) == ["c"])
        #expect(JumpSearch.rank(items, query: "parser").map(\.name) == ["b"])
        #expect(JumpSearch.rank(items, query: "nothing-matches").isEmpty)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(JumpSearch.rank(items, query: "CRTERMINAL").map(\.name) == ["c"])
        #expect(JumpSearch.rank(items, query: "Main").map(\.name) == ["a", "c"])
    }

    @Test func tokensAndAcrossDifferentFacets() {
        // "main" is a branch, "kmono" a directory — both on item a only.
        #expect(JumpSearch.rank(items, query: "main kmono").map(\.name) == ["a"])
        #expect(JumpSearch.rank(items, query: "main mcq").isEmpty)
    }

    @Test func textStartOutranksMidWordMatch() {
        let ranked = JumpSearch.rank([
            item("mid", directory: "~/dev/unmask"),
            item("start", branch: "mask-fix"),
        ], query: "mask")
        #expect(ranked.map(\.name) == ["start", "mid"])
    }

    @Test func facetWeightBreaksTies() {
        // Same match quality; title (weight 2) beats directory (weight 1).
        let ranked = JumpSearch.rank([
            item("dir", directory: "vim-config"),
            item("titled", title: "vim-config"),
        ], query: "vim")
        #expect(ranked.map(\.name) == ["titled", "dir"])
    }

    @Test func unknownFacetKindsAreSearchable() {
        // The extensibility contract: a future provider can add any kind
        // (say, a forwarded port) and it ranks with zero matcher changes.
        let withPort = Item(name: "ported", facets: [
            SessionFacet(kind: "port", text: "localhost:8080"),
        ])
        #expect(JumpSearch.rank([withPort], query: "8080").map(\.name) == ["ported"])
    }

    @Test func customNameIsSearchable() {
        let named = [
            item("a", sessionName: "build server", command: "zsh", directory: "~/dev/api"),
            item("b", command: "vim", directory: "~/dev/web"),
        ]
        #expect(JumpSearch.rank(named, query: "build").map(\.name) == ["a"])
        #expect(JumpSearch.rank(named, query: "server").map(\.name) == ["a"])
    }

    @Test func customNameOutranksTitleOnTie() {
        // Same match quality; the name facet (weight 2.5) beats title (2).
        let ranked = JumpSearch.rank([
            item("titled", title: "deploy"),
            item("named", sessionName: "deploy"),
        ], query: "deploy")
        #expect(ranked.map(\.name) == ["named", "titled"])
    }

    @Test func inferredFacetsStillMatchAfterNaming() {
        // Renaming a session must not hide its process/cwd/branch from search.
        let renamed = item(
            "x", sessionName: "my build", command: "claude",
            directory: "~/dev/widget", branch: "main")
        #expect(JumpSearch.rank([renamed], query: "claude").map(\.name) == ["x"])
        #expect(JumpSearch.rank([renamed], query: "widget").map(\.name) == ["x"])
        #expect(JumpSearch.rank([renamed], query: "main").map(\.name) == ["x"])
    }

    @Test func tieBreaksPreserveOriginalOrder() {
        let twins = [
            item("first", directory: "~/dev/app"),
            item("second", directory: "~/dev/app"),
        ]
        #expect(JumpSearch.rank(twins, query: "app").map(\.name) == ["first", "second"])
    }
}

struct GitBranchProbeTests {
    private func makeRepo(head: String) throws -> String {
        let root = NSTemporaryDirectory() + "jump-test-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: root + "/.git", withIntermediateDirectories: true)
        try head.write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        return root
    }

    @Test func readsBranchFromHead() throws {
        let repo = try makeRepo(head: "ref: refs/heads/fix/ctrl-c\n")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(SessionInfo.gitBranch(near: repo) == "fix/ctrl-c")
    }

    @Test func walksUpToTheRepoRoot() throws {
        let repo = try makeRepo(head: "ref: refs/heads/main\n")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let nested = repo + "/deeply/nested/dir"
        try FileManager.default.createDirectory(
            atPath: nested, withIntermediateDirectories: true)
        #expect(SessionInfo.gitBranch(near: nested) == "main")
    }

    @Test func detachedHeadYieldsShortHash() throws {
        let repo = try makeRepo(head: "0123456789abcdef0123456789abcdef01234567\n")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(SessionInfo.gitBranch(near: repo) == "01234567")
    }

    @Test func followsWorktreeGitdirPointer() throws {
        let main = try makeRepo(head: "ref: refs/heads/main\n")
        defer { try? FileManager.default.removeItem(atPath: main) }
        let worktree = NSTemporaryDirectory() + "jump-wt-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        try "gitdir: \(main)/.git\n"
            .write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        #expect(SessionInfo.gitBranch(near: worktree) == "main")
    }

    @Test func nonRepoReturnsNil() {
        #expect(SessionInfo.gitBranch(near: "/private/tmp") == nil
                    || SessionInfo.gitBranch(near: "/") == nil)
    }
}
