import Foundation
import Testing
@testable import ShipwatchCore

@Suite struct LineClassifierTests {
    @Test(arguments: [
        ("Sources/ShipwatchCore/Git.swift", LineKind.code),
        ("web/index.html", .code),
        ("web/styles/site.css", .code),
        ("app/components/Button.tsx", .code),
        ("Dockerfile", .code),
        ("deploy/Dockerfile.prod", .code),
        ("Makefile", .code),
        ("infra/main.tf", .code),
        ("scripts/release.sh", .code),
        ("db/migrations/001_init.sql", .code),
        ("CMakeLists.txt", .code),
        ("src/latest.js", .code),
        ("src/contest/Testimonial.tsx", .code),
        ("Tests/ShipwatchCoreTests/RepoTests.swift", .tests),
        ("Tests/Support.swift", .tests),
        ("src/__tests__/api.ts", .tests),
        ("src/api.test.ts", .tests),
        ("src/api.spec.js", .tests),
        ("pkg/client/client_test.go", .tests),
        ("tests/conftest.py", .tests),
        ("app/test_models.py", .tests),
        ("spec/models/user_spec.rb", .tests),
        ("App/AppUITests/LaunchTests.swift", .tests),
        ("e2e/login.ts", .tests),
        ("src/test/java/com/acme/ApiTest.java", .tests),
        ("README.md", .markdown),
        ("docs/guide.mdx", .markdown),
        ("Tests/README.md", .markdown),
    ])
    func counted(_ path: String, _ expected: LineKind) {
        #expect(LineClassifier.kind(of: path) == expected)
    }

    @Test(arguments: [
        "package.json", "package-lock.json", "pnpm-lock.yaml", "Cargo.lock", "go.sum",
        ".github/workflows/ci.yml", "config/settings.toml", "Info.plist", "assets/logo.svg", "notes.txt", "LICENSE",
        ".bashrc", "web/node_modules/react/index.js", "vendor/github.com/pkg/errors/errors.go", "dist/app.js",
        "public/app.min.js", "api/v1/service.pb.go", "Pods/Alamofire/Source/Session.swift",
    ])
    func notCounted(_ path: String) {
        #expect(LineClassifier.kind(of: path) == nil)
    }

    @Test func splitsWords() {
        #expect(LineClassifier.words(in: "XMLParserTests") == ["xml", "parser", "tests"])
        #expect(LineClassifier.words(in: "__tests__") == ["tests"])
        #expect(LineClassifier.words(in: "client_test.go") == ["client", "test", "go"])
        #expect(LineClassifier.words(in: "e2e-flows") == ["e2e", "flows"])
    }
}

@Suite struct LineCountReportTests {
    static let commit = "1f5adfb1e8dd6dc18064c2824d733f45effcd8fc"

    @Test func talliesGrepOutputByKind() {
        let output = [
            "\(Self.commit):Sources/App.swift\u{0}120\n",
            "\(Self.commit):Tests/AppTests.swift\u{0}40\n",
            "\(Self.commit):docs/a: b.md\u{0}7\n",
            "\(Self.commit):package-lock.json\u{0}9000\n",
            "\(Self.commit):web/index.html\u{0}30\n",
            "other:Sources/Ignored.swift\u{0}5\n",
        ].joined()
        #expect(LineCounter.tally(output, commit: Self.commit) == LineCounts(code: 150, tests: 40, markdown: 7))
        #expect(LineCounter.tally("", commit: Self.commit) == LineCounts())
    }

    @Test func growthIsRelativeToTheEarlierCount() {
        let growth = LineGrowth(from: 831, to: 4440)
        #expect(growth.lines == 3609)
        #expect(String(format: "%.2f", growth.percent ?? 0) == "434.30")
        let shrink = LineGrowth(from: 200, to: 150)
        #expect(shrink.lines == -50 && shrink.percent == -25)
        #expect(LineGrowth(from: 0, to: 12).percent == nil)
    }

    @Test func newCountIsDueInTheNextIsoWeek() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Wednesday.
        let report = LineCountReport(latest: count(at: "2026-11-11T09:00:00Z", code: 10))
        #expect(!report.isDue(at: Fixtures.date("2026-11-11T09:00:00Z"), calendar: calendar))
        #expect(!report.isDue(at: Fixtures.date("2026-11-15T23:59:59Z"), calendar: calendar))
        #expect(report.isDue(at: Fixtures.date("2026-11-16T00:00:00Z"), calendar: calendar))
        #expect(report.isDue(at: Fixtures.date("2026-12-30T12:00:00Z"), calendar: calendar))
    }

    @Test func keepsOnlyThisWeekAndTheWeekBefore() {
        let first = count(at: "2026-11-04T09:00:00Z", code: 100, tests: 10, markdown: 5)
        let second = count(at: "2026-11-11T09:00:00Z", code: 120, tests: 12, markdown: 5)
        let third = count(at: "2026-11-18T09:00:00Z", code: 90, tests: 14, markdown: 8)
        let report = LineCountReport(latest: first)
        #expect(report.growth(\.total) == nil)

        let later = report.adding(second).adding(third)
        #expect(later == LineCountReport(latest: third, previous: second))
        #expect(later.growth(\.code) == LineGrowth(from: 120, to: 90))
        #expect(later.growth(\.total)?.lines == -28)
        #expect(later.growth(\.markdown)?.lines == 3)
    }

    @Test func cacheDropsOtherVersions() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let cache = LineCountCache(url: directory.url("Shipwatch/LineCounts.json"))
        #expect(try cache.load() == nil)

        let snapshot = LineCountSnapshot(reports: ["octocat/api-server": LineCountReport(latest: count(at: "2026-11-11T09:00:00Z", code: 1))])
        try cache.save(snapshot)
        #expect(try cache.load() == snapshot)

        var old = snapshot
        old.version = LineCountSnapshot.currentVersion - 1
        try cache.save(old)
        #expect(try cache.load() == nil)
    }

    private func count(at date: String, code: Int, tests: Int = 0, markdown: Int = 0) -> LineCount {
        LineCount(date: Fixtures.date(date), branch: "main", commit: Self.commit, counts: LineCounts(code: code, tests: tests, markdown: markdown))
    }
}

@Suite(.enabled(if: ProcessGit.locate() != nil, "git is not installed"))
struct LineCounterTests {
    @Test func countsCommittedLinesOnTheLocalBranchOnly() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let local = fixture.local
        try local.write("Sources/App/main.swift", "import Foundation\n\n// Entry point\nprint(1)\n   \n\tlet x = 2\r\n\r\n")
        try local.write("web/index.html", "<html>\n<body></body>\n</html>")
        try local.write("Tests/AppTests/MainTests.swift", "import Testing\n\n@Test func works() {}\n")
        try local.write("docs/guide.md", "# Guide\n\nRead me.\n")
        try local.write("package-lock.json", "{\n}\n")
        try local.write("node_modules/dep/index.js", "module.exports = 1\n")
        try "\u{0}\u{1}binary.swift".write(to: local.url("Sources/App/blob.swift"), atomically: true, encoding: .utf8)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "--quiet", "-m", "Add sources"])
        let head = try fixture.rev("refs/heads/main")

        // Neither uncommitted changes nor another branch count.
        try fixture.git(["switch", "--quiet", "-c", "feat/more"])
        try fixture.commit(in: local, file: "Sources/App/extra.swift")
        try local.write("Sources/App/main.swift", "changed\n")

        let date = Fixtures.now
        let count = try LineCounter(git: fixture.runner).count(fixture.clone, branch: "main", date: date)
        // The fixture's README.md adds one Markdown line.
        #expect(count == LineCount(date: date, branch: "main", commit: head, counts: LineCounts(code: 7, tests: 2, markdown: 3)))
    }

    @Test func missingBranchHasNoCount() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        #expect(try LineCounter(git: fixture.runner).count(fixture.clone, branch: "trunk") == nil)
    }

    @Test func refusesPartialClones() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.git(["config", "extensions.partialClone", "origin"])
        #expect(throws: LineCountError.partialClone) {
            try LineCounter(git: fixture.runner).count(fixture.clone, branch: "main")
        }
    }

    @Test func rejectsOptionLikeBranch() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        #expect(throws: GitError.self) {
            try LineCounter(git: fixture.runner).count(fixture.clone, branch: "--output=x")
        }
    }
}
