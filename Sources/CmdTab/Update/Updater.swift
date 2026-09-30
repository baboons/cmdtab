import AppKit
import Security

/// Self-updates from GitHub Releases.
///
/// Checks the latest release a few times a day, downloads the zip, and only
/// installs it if it is signed with the same certificate as the running app
/// (so a compromised download can't be installed, and macOS keeps the
/// Accessibility grant, which is tied to that signature). Installing swaps
/// the bundle in place and relaunches.
///
/// Only release builds update themselves: CI sets `CmdTabReleaseBuild`, and
/// ad-hoc signed builds are excluded because nothing could match them.
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release {
        let version: String
        let assetURL: URL
        let pageURL: URL
    }

    enum State {
        case idle
        case checking
        case downloading(version: String)
        case ready(Release, app: URL)
    }

    private(set) var state: State = .idle { didSet { onChange?() } }
    /// Called on state changes (to refresh the menu).
    var onChange: (() -> Void)?
    /// Whether it's a good moment to relaunch (switcher closed, not in use).
    var canRelaunchNow: () -> Bool = { true }

    private let repository = Bundle.main.object(forInfoDictionaryKey: "CmdTabUpdateRepository") as? String
    private static let assetName = "CmdTab-aarch64-apple-darwin.zip"
    private static let checkInterval: TimeInterval = 6 * 3600
    private var timer: Timer?

    var currentVersion: String { Bundle.main.shortVersion }

    var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CmdTabReleaseBuild") as? Bool == true
            && repository != nil && Self.ownRequirement != nil
    }

    func start() {
        guard isEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    private func tick() {
        switch state {
        case .ready:
            if Settings.shared.autoInstallUpdates, canRelaunchNow() { install() }
        case .idle:
            let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
            if Settings.shared.autoCheckUpdates, Date().timeIntervalSince1970 - last > Self.checkInterval {
                check(userInitiated: false)
            }
        default:
            break
        }
    }

    // MARK: - Checking

    func check(userInitiated: Bool) {
        guard isEnabled else {
            if userInitiated {
                alert("Updates are off in development builds",
                      "Builds from the release page (or Homebrew) update themselves. Local builds don't.")
            }
            return
        }
        if case let .ready(release, _) = state {
            if userInitiated { offerInstall(release) }
            return
        }
        guard case .idle = state else { return }
        state = .checking
        Task {
            do {
                let release = try await fetchLatest()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                guard Self.isVersion(release.version, newerThan: currentVersion) else {
                    state = .idle
                    if userInitiated { alert("You're up to date", "CmdTab \(currentVersion) is the latest version.") }
                    return
                }
                state = .downloading(version: release.version)
                let app = try await download(release)
                state = .ready(release, app: app)
                if userInitiated {
                    offerInstall(release)
                } else if Settings.shared.autoInstallUpdates, canRelaunchNow() {
                    install()
                }
            } catch {
                state = .idle
                if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        guard let repository, let api = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError("No update source configured.")
        }
        var request = URLRequest(url: api, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CmdTab/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub didn't return a release.") }

        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease,
              let asset = payload.assets.first(where: { $0.name == Self.assetName }) else {
            throw UpdateError("The latest release has no macOS download.")
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, assetURL: asset.browser_download_url, pageURL: payload.html_url)
    }

    // MARK: - Downloading

    /// Downloads and unpacks the release next to the running app (same volume,
    /// so the final swap is atomic), then verifies it.
    private func download(_ release: Release) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(from: release.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: Bundle.main.bundleURL, create: true)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        try? FileManager.default.removeItem(at: zip)

        let app = staging.appendingPathComponent("CmdTab.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError("The download didn't contain CmdTab.") }
        guard Self.isSignedLikeUs(app) else {
            throw UpdateError("The download isn't signed by CmdTab's release certificate, so it wasn't installed.")
        }
        guard Bundle(url: app)?.shortVersion == release.version else { throw UpdateError("The download has an unexpected version.") }
        return app
    }

    // MARK: - Installing

    private func offerInstall(_ release: Release) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "CmdTab \(release.version) is ready"
        alert.informativeText = "You have \(currentVersion). CmdTab will restart; it takes a second."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install()
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    func install() {
        guard case let .ready(release, app) = state else { return }
        let current = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: app, backupItemName: nil, options: [])
        } catch {
            // e.g. an app translocated by Gatekeeper, or a read-only location.
            state = .idle
            alert("Couldn't install the update", "\(error.localizedDescription)\n\nDownload it from the release page instead.")
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        Self.relaunch(current)
    }

    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"\(app.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Signatures

    /// The running app's designated requirement, unless it is ad-hoc signed
    /// (then there's no stable identity an update could be checked against).
    private static let ownRequirement: SecRequirement? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any],
              !certificates.isEmpty else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    private static func isSignedLikeUs(_ app: URL) -> Bool {
        guard let requirement = ownRequirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    // MARK: - Helpers

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let parse = { (s: String) in s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError("\(tool) failed (\(p.terminationStatus))."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
