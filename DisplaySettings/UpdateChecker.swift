// UpdateChecker.swift
// Checks GitHub releases API for a newer version and handles in-app updates via Homebrew.

import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?  = nil
    @Published var updateAvailable         = false
    @Published var isChecking              = false
    @Published var isUpdating              = false
    @Published var updateInstalled         = false

    private let owner = "sdemirbas"
    private let repo  = "DisplaySettings"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releasesURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    // MARK: - Check

    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true
        let current = currentVersion
        let apiURL  = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            let finish: (String?, Bool) -> Void = { latest, newer in
                DispatchQueue.main.async {
                    self.latestVersion   = latest
                    self.updateAvailable = newer
                    self.isChecking      = false
                }
            }
            guard let data,
                  let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String
            else { finish(nil, false); return }

            let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            finish(latest, self.isVersion(latest, newerThan: current))
        }.resume()
    }

    // MARK: - Install via Homebrew

    func installViaBrew() {
        let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brewPath = brewCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            NSWorkspace.shared.open(releasesURL)
            return
        }

        isUpdating      = true
        updateInstalled = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments     = ["upgrade", "--cask", "displaybrightness"]

        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isUpdating = false
                if p.terminationStatus == 0 {
                    self.updateInstalled = true
                    self.updateAvailable = false
                } else {
                    NSWorkspace.shared.open(self.releasesURL)
                }
            }
        }

        do    { try process.run() }
        catch { isUpdating = false; NSWorkspace.shared.open(releasesURL) }
    }

    // MARK: - Relaunch

    func relaunch() {
        let appName  = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DisplaySettings"
        let appURL   = URL(fileURLWithPath: "/Applications/\(appName).app")
        let config   = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Private

    private nonisolated func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count  = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
