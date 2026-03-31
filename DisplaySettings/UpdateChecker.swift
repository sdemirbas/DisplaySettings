// UpdateChecker.swift
// Checks GitHub releases API for a newer version on launch.

import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String? = nil
    @Published var updateAvailable = false

    private let owner = "sdemirbas"
    private let repo  = "DisplaySettings"

    init() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.checkForUpdate()
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releasesURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    func checkForUpdate() {
        let current = currentVersion
        let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return }

            let latest   = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let isNewer  = self.isVersion(latest, newerThan: current)

            DispatchQueue.main.async {
                self.latestVersion   = latest
                self.updateAvailable = isNewer
            }
        }.resume()
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
