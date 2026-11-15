// Renders the README screenshots from mocked data, fully offline, plus the app icon and installer background for packaging.
import AppKit
import ShipwatchCore
import ShipwatchUI
import SwiftUI

/// Answers `/user` for the mocked `gh` sign-in check and refuses everything else.
struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.path == "/user" else {
            throw GitHubError.network("Snapshots run offline.")
        }
        let body = Data(#"{"login":"octocat","name":"Mona Octocat"}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (body, response)
    }
}

/// Looks installed so the Workspace tab renders normally, but never touches a real clone.
struct OfflineGit: GitRunning {
    func run(_ arguments: [String], in directory: URL, environment: [String: String], timeout: TimeInterval) throws -> GitOutput {
        throw GitError.notInstalled
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case render(String)
    var description: String {
        switch self {
        case .render(let name): "Could not render \(name)"
        }
    }
}

let now = Date()
func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
let minute: TimeInterval = 60, hour: TimeInterval = 3600, day: TimeInterval = 86400

func ref(_ fullName: String) -> RepoRef { RepoRef(parsing: fullName)! }

func run(
    _ id: Int, _ name: String, number: Int, status: String, conclusion: String? = nil,
    branch: String = "main", event: String = "push", startedAgo: TimeInterval, repo: RepoRef
) -> WorkflowRun {
    WorkflowRun(
        id: id, name: name, workflowId: id / 10, runNumber: number, status: status, conclusion: conclusion,
        headBranch: branch, event: event, htmlUrl: URL(string: "https://github.com/\(repo)/actions/runs/\(id)")!,
        createdAt: ago(startedAgo), updatedAt: ago(max(startedAgo - 3 * minute, 0)),
        runStartedAt: status == "queued" ? nil : ago(startedAgo)
    )
}

func release(_ tag: String, _ repo: RepoRef, daysAgo: Double, pre: Bool = false) -> Release {
    Release(tagName: tag, url: URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!, publishedAt: ago(daysAgo * day), isPrerelease: pre)
}

func mockStatuses() -> [RepoStatus] {
    let api = ref("octocat/api-server")
    let apiCI = run(4820, "CI", number: 482, status: "in_progress", startedAgo: 134, repo: api)
    let codeQL = run(3011, "CodeQL", number: 301, status: "queued", branch: "dependabot/npm_and_yarn/express-4.21.2", event: "pull_request", startedAgo: 20, repo: api)
    let website = ref("octocat/website")
    let cli = ref("octocat/cli-tool")
    let infra = ref("acme-org/infra")
    var terraformPlan = run(6400, "Terraform plan", number: 640, status: "completed", conclusion: "failure", startedAgo: 26 * hour, repo: infra)
    terraformPlan.jobsNeverStarted = true
    return [
        RepoStatus(
            ref: api, isPrivate: true, defaultBranch: "main", latestRelease: release("v2.4.1", api, daysAgo: 3),
            openIssues: 4, openPullRequests: 11, dependabotPullRequests: 5, pushedAt: ago(12 * minute),
            ci: CISummary(state: .running, running: [apiCI, codeQL], latestOnDefault: [
                apiCI,
                run(3010, "CodeQL", number: 300, status: "completed", conclusion: "success", startedAgo: 5 * hour, repo: api),
                run(5710, "Release", number: 57, status: "completed", conclusion: "success", event: "release", startedAgo: 3 * day + hour, repo: api),
            ])
        ),
        RepoStatus(
            ref: website, defaultBranch: "main", latestRelease: release("v1.8.0", website, daysAgo: 14),
            openIssues: 2, openPullRequests: 3, dependabotPullRequests: 2, pushedAt: ago(2 * day),
            ci: CISummary(state: .passing, running: [], latestOnDefault: [
                run(1200, "Deploy", number: 120, status: "completed", conclusion: "success", startedAgo: 2 * day, repo: website),
            ])
        ),
        RepoStatus(
            ref: cli, defaultBranch: "main", latestRelease: release("v0.9.3-beta.2", cli, daysAgo: 1, pre: true),
            openIssues: 12, openPullRequests: 1, pushedAt: ago(5 * hour),
            ci: CISummary(state: .failing, running: [], latestOnDefault: [
                run(9050, "Test", number: 905, status: "completed", conclusion: "failure", startedAgo: 5 * hour, repo: cli),
            ])
        ),
        RepoStatus(
            ref: infra, isPrivate: true, defaultBranch: "main", openIssues: 7, openPullRequests: 4,
            dependabotPullRequests: 1, pushedAt: ago(26 * hour),
            ci: CISummary(state: .notStarted, running: [], latestOnDefault: [terraformPlan])
        ),
        RepoStatus(ref: ref("octocat/dotfiles"), defaultBranch: "main", pushedAt: ago(41 * day), ci: .empty),
        RepoStatus(ref: ref("octocat/old-blog"), isArchived: true, defaultBranch: "main", latestRelease: release("v1.0.0", ref("octocat/old-blog"), daysAgo: 700), pushedAt: ago(620 * day), ci: .empty),
        RepoStatus(ref: ref("octocat/experiments"), defaultBranch: "main", openIssues: 1, pushedAt: ago(9 * day), ci: .empty),
        RepoStatus(ref: ref("acme-org/legacy-api"), problem: .noAccess),
    ]
}

@MainActor
func makeModel(defaults: UserDefaults, signedIn: Bool) -> AppModel {
    let prefs = Preferences(defaults: defaults)
    let hidden: Set = ["octocat/old-blog", "octocat/experiments"]
    let statuses = mockStatuses()
    var repos = RepoList(statuses.map { TrackedRepo(ref: $0.ref, hidden: hidden.contains($0.ref.fullName)) })
    repos.addGroup(named: "Tools", members: ["octocat/cli-tool", "octocat/dotfiles", "octocat/experiments"])
    prefs.repos = repos
    prefs.cliFallback = true

    let cli = GitHubCLI(executable: URL(fileURLWithPath: "/opt/homebrew/bin/gh")) { _, _ in "gho_snapshot_mock" }
    let model = AppModel(
        prefs: prefs,
        bundled: AppConfig(clientID: "Iv23liSNAPSHOTMOCK00", appSlug: "shipwatch"),
        store: MemoryTokenStore(),
        cli: cli,
        transport: OfflineTransport(),
        git: OfflineGit()
    )
    model.loginItemAvailable = true
    model.launchAtLogin = true
    model.cliStatus = .signedIn("octocat")
    guard signedIn else { return model }

    model.authMethod = .githubApp
    model.user = GitHubUser(login: "octocat", name: "Mona Octocat")
    model.installations = [
        AppInstallation(id: 1, appSlug: "shipwatch", account: "octocat", repositorySelection: "selected", permissions: [
            "actions": "read", "contents": "read", "issues": "read", "metadata": "read", "pull_requests": "read",
        ]),
        AppInstallation(id: 2, appSlug: "shipwatch", account: "acme-org", repositorySelection: "all", permissions: [
            "actions": "read", "contents": "read", "issues": "read", "metadata": "read", "pull_requests": "read",
        ]),
    ]
    model.installationRepoCounts = [1: 6, 2: 14]
    model.statuses = Dictionary(uniqueKeysWithValues: statuses.map { ($0.ref.key, $0) })
    model.expanded = ["octocat/api-server"]
    model.lastUpdated = ago(40)
    model.nextRefresh = now.addingTimeInterval(20)
    return model
}

/// Fills the Workspace tab with clones under `~/Developer` in every sync state.
@MainActor
func configureWorkspace(_ model: AppModel) {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer", isDirectory: true)
    let prefs = model.prefs
    prefs.workspacePath = root.path
    prefs.excludedFolders = [root.appendingPathComponent("archive").path, root.appendingPathComponent("forks").path]
    prefs.syncClones = true
    prefs.cloneSyncOptOut = ["octocat/dotfiles"]

    func clone(_ relative: String, _ repo: String, on branch: String = "main") -> LocalClone {
        LocalClone(path: root.appendingPathComponent(relative, isDirectory: true), ref: ref(repo), remote: "origin", headBranch: branch)
    }
    let clones = [
        clone("acme/infra", "acme-org/infra"),
        clone("api-server", "octocat/api-server"),
        clone("cli-tool", "octocat/cli-tool"),
        clone("dotfiles", "octocat/dotfiles"),
        clone("scratch/infra", "acme-org/infra"),
        clone("web/website", "octocat/website", on: "feat/nav"),
    ]
    let workspace = model.workspace
    workspace.scan = WorkspaceScan(clones: clones, untracked: [
        clone("acme/handbook", "acme-org/handbook"),
        clone("playground", "octocat/playground"),
        clone("Spoon-Knife", "octocat/Spoon-Knife"),
    ])
    workspace.scannedAt = ago(40)
    let head = String(repeating: "a", count: 40)
    func result(_ outcome: CloneSyncOutcome, fastForward: FastForward? = nil) -> CloneSyncResult {
        CloneSyncResult(outcome: outcome, branch: "main", remoteHead: head, date: ago(40), lastFastForward: fastForward)
    }
    workspace.results = [
        clones[0].path: result(.skipped(.diverged)),
        clones[1].path: result(.upToDate),
        clones[2].path: result(.skipped(.uncommittedChanges)),
        clones[4].path: result(.upToDate),
        clones[5].path: result(.upToDate, fastForward: FastForward(date: ago(3 * minute), commits: 4)),
    ]
    workspace.lastSync = WorkspaceSyncSummary(date: ago(40), updated: 1, skipped: 2)
}

/// A stand-in for the transparent title bar the real Settings window draws.
struct TitleBar: View {
    let title: String

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(white: 0.38)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}

struct SettingsWindowFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: title)
            content
        }
        .background(Color(white: 0.17))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func render(_ view: some View, dark: Bool, name: String, into directory: URL) throws {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light).environment(\.controlActiveState, .key)))
    host.appearance = appearance
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = host
    defer { window.close() }

    for _ in 0..<3 {
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        spin(0.4)
    }
    guard host.bounds.width > 1, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw SnapshotError.render(name)
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.render(name) }
    let url = directory.appending(path: "\(name).png")
    try png.write(to: url)
    print("Wrote \(url.path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh))")
}

@MainActor
func popover(_ model: AppModel, dark: Bool) -> some View {
    PopoverView(model: model)
        .background(dark ? Color(white: 0.16) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 12))
}

@MainActor
func settings(_ model: AppModel, _ tab: SettingsTab) -> some View {
    model.settingsTab = tab
    return SettingsWindowFrame(title: tab.title) { SettingsView(model: model) }
}

@MainActor
func addSheet(_ model: AppModel) -> some View {
    let picker = RepoPickerModel()
    picker.listings = [
        RepoListing(owner: "octocat", name: "payments", isPrivate: true, pushedAt: ago(3 * hour)),
        RepoListing(owner: "octocat", name: "pay-widget", isPrivate: false, pushedAt: ago(6 * day)),
        RepoListing(owner: "octocat", name: "api-server", isPrivate: true, pushedAt: ago(12 * minute)),
        RepoListing(owner: "acme-org", name: "payroll", isPrivate: true, pushedAt: ago(2 * day)),
        RepoListing(owner: "acme-org", name: "gateway-pay", isPrivate: true, pushedAt: ago(20 * day)),
        RepoListing(owner: "acme-org", name: "infra", isPrivate: true, pushedAt: ago(26 * hour)),
    ]
    picker.query = "pay"
    picker.selected = ["octocat/payments", "acme-org/payroll"]
    return sheet(model, over: .repositories, AddRepositoriesSheet(model: model, picker: picker, loadsOnAppear: false))
}

/// The settings window on `tab`, dimmed, with `content` shown as its sheet.
@MainActor
func sheet(_ model: AppModel, over tab: SettingsTab, _ content: some View) -> some View {
    model.settingsTab = tab
    return SettingsWindowFrame(title: tab.title) {
        ZStack(alignment: .top) {
            SettingsView(model: model)
            Color.black.opacity(0.3)
            content
                .background(Color(white: 0.2))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .padding(.top, 6)
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
Usage: ShipwatchSnapshots [output-dir]          Render README screenshots (default docs/screenshots).
       ShipwatchSnapshots --iconset <dir>       Write the AppIcon.iconset used by packaging.
       ShipwatchSnapshots --dmg-background <dir> Write the installer background (@1x and @2x PNG).
"""

MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--iconset" || arguments.first == "--dmg-background" {
        guard arguments.count == 2 else { fail(usage) }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        do {
            if arguments[0] == "--iconset" {
                try AppIcon.writeIconset(to: directory)
            } else {
                try DMGBackground.write(to: directory)
            }
        } catch {
            fail("Packaging artwork failed: \(error)")
        }
        return
    }
    guard arguments.count <= 1, !(arguments.first?.hasPrefix("-") ?? false) else { fail(usage) }

    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let output = URL(fileURLWithPath: arguments.first ?? "docs/screenshots")
    let suite = "dev.mbianchi.shipwatch.snapshots.\(ProcessInfo.processInfo.processIdentifier)"
    guard let defaults = UserDefaults(suiteName: suite) else { fail("Could not open defaults suite \(suite)") }
    defer { defaults.removePersistentDomain(forName: suite) }

    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = makeModel(defaults: defaults, signedIn: true)
        try render(popover(model, dark: true), dark: true, name: "popover-dark", into: output)
        try render(popover(model, dark: false), dark: false, name: "popover-light", into: output)
        try render(settings(model, .repositories), dark: true, name: "settings-repositories", into: output)
        try render(addSheet(model), dark: true, name: "settings-add", into: output)
        try render(settings(model, .account), dark: true, name: "settings-account", into: output)
        try render(settings(model, .general), dark: true, name: "settings-general", into: output)
        configureWorkspace(model)
        try render(settings(model, .workspace), dark: true, name: "settings-workspace", into: output)
        let trackFound = TrackFoundRepositoriesSheet(model: model, clones: model.workspace.untracked) {}
        try render(sheet(model, over: .workspace, trackFound), dark: true, name: "settings-track-found", into: output)

        let signedOut = makeModel(defaults: defaults, signedIn: false)
        try render(popover(signedOut, dark: true), dark: true, name: "onboarding", into: output)
    } catch {
        defaults.removePersistentDomain(forName: suite)
        fail("Snapshot failed: \(error)")
    }
}
