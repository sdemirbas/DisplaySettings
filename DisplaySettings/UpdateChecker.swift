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
    private let repo  = "Nit"

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

    // MARK: - Open releases page + show Relaunch

    func installViaBrew() {
        // Nit is distributed as a DMG — open the releases page so the user
        // can download and replace the app, then click Relaunch.
        NSWorkspace.shared.open(releasesURL)
        updateInstalled = true   // Show the Relaunch button immediately
        updateAvailable = false
    }

    // MARK: - Relaunch

    func relaunch() {
        // Use the running bundle's own path so this works whether the app lives
        // in /Applications, ~/Applications, or anywhere else.
        let appPath = Bundle.main.bundleURL.path

        // `open -n` forces a brand-new process even if one is already running,
        // so the freshly-replaced binary is what actually launches.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4 && open -n \"\(appPath)\""]
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
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
