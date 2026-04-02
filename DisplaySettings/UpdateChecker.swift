// UpdateChecker.swift
// Checks GitHub releases API for a newer version and auto-installs via DMG download.

import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?  = nil
    @Published var updateAvailable         = false
    @Published var isChecking              = false
    @Published var isUpdating              = false
    @Published var updateInstalled         = false
    @Published var downloadProgress: Double = 0   // 0.0 – 1.0 while downloading

    private let owner = "sdemirbas"
    private let repo  = "Nit"

    private var progressObserver: NSKeyValueObservation?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releasesURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    private var dmgDownloadURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/Nit.dmg")!
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

    // MARK: - Install (automated: download DMG → mount → copy → strip quarantine)

    func installUpdate() {
        guard !isUpdating else { return }
        isUpdating = true
        downloadProgress = 0

        let destPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("Nit-update.dmg")

        let downloadTask = URLSession.shared.downloadTask(with: dmgDownloadURL) { [weak self] tempURL, _, error in
            guard let self else { return }

            // Move downloaded file to a stable temp path
            var dmgURL: URL? = nil
            if let tempURL, error == nil {
                let dest = URL(fileURLWithPath: destPath)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: tempURL, to: dest)) != nil {
                    dmgURL = dest
                }
            }

            guard let dmgFile = dmgURL else {
                Task { @MainActor [weak self] in self?.fallbackToManual() }
                return
            }

            // Run install script on this background thread
            let script = """
            set -e
            MOUNT=$(hdiutil attach '\(dmgFile.path)' -nobrowse -readonly -noverify 2>/dev/null \
                | awk 'END{print $NF}')
            [ -d "/Applications/Nit.app" ] && rm -rf "/Applications/Nit.app"
            cp -R "$MOUNT/Nit.app" "/Applications/Nit.app"
            xattr -dr com.apple.quarantine "/Applications/Nit.app" 2>/dev/null || true
            hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
            rm -f '\(dmgFile.path)'
            """

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments     = ["-c", script]

            do {
                try proc.run()
                proc.waitUntilExit()
                let ok = proc.terminationStatus == 0
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if ok {
                        self.updateInstalled = true
                        self.updateAvailable = false
                    } else {
                        self.fallbackToManual()
                    }
                    self.isUpdating       = false
                    self.downloadProgress = 0
                }
            } catch {
                Task { @MainActor [weak self] in self?.fallbackToManual() }
            }
        }

        // Track download progress via KVO
        progressObserver = downloadTask.progress
            .observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                }
            }

        downloadTask.resume()
    }

    // MARK: - Relaunch

    func relaunch() {
        let appPath = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4 && open -n \"\(appPath)\""]
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Private

    private func fallbackToManual() {
        NSWorkspace.shared.open(releasesURL)
        updateInstalled = true
        updateAvailable = false
        isUpdating      = false
        downloadProgress = 0
    }

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
