//
//  UpdateChecker.swift
//  DynoPrompt
//
//  Created by Fatih Kadir Akın on 9.02.2026.
//

import AppKit

class UpdateChecker {
    static let shared = UpdateChecker()

    /// "owner/repo" read from Info.plist (`DPUpdateRepository`).
    ///
    /// Empty means no update source is configured, which is the shipped
    /// default: this app is a rename, and querying the upstream project's
    /// releases would offer users a different application under a version
    /// number that looks newer. Set the key once you publish your own
    /// releases.
    private var repository: String {
        (Bundle.main.infoDictionary?["DPUpdateRepository"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether an update source is configured at all.
    var isConfigured: Bool {
        let parts = repository.split(separator: "/")
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check GitHub for the latest release and prompt the user if an update is available.
    func checkForUpdates(silent: Bool = false) {
        guard isConfigured else {
            if !silent {
                self.showError(
                    "No update source is configured for this build.\n\n"
                    + "Set DPUpdateRepository in Info.plist to your GitHub "
                    + "\"owner/repo\" to enable update checks."
                )
            }
            return
        }
        let urlString = "https://api.github.com/repos/\(repository)/releases/latest"
        guard let url = URL(string: urlString),
              // Guard against a malformed Info.plist value producing a request
              // to somewhere other than the GitHub API.
              url.host?.lowercased() == "api.github.com" else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            DispatchQueue.main.async {
                if let error {
                    if !silent {
                        self.showError("Could not check for updates.\n\(error.localizedDescription)")
                    }
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else {
                    if !silent {
                        self.showError("Could not parse the release information.")
                    }
                    return
                }

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                if self.isVersion(latestVersion, newerThan: self.currentVersion) {
                    self.showUpdateAvailable(latestVersion: latestVersion, releaseURL: htmlURL)
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
    }

    // MARK: - Version comparison

    private func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Alerts

    private func showUpdateAvailable(latestVersion: String, releaseURL: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "DynoPrompt \(latestVersion) is available. You are currently running \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            // `html_url` is attacker-influenced in principle: it comes from a
            // parsed network response. Opening it unchecked would let a
            // manipulated response launch a `file://` path or hand a custom
            // scheme to another app, so only an https GitHub release URL is
            // ever passed to the workspace.
            if let url = ReleaseURLValidator.safeReleaseURL(releaseURL) {
                NSWorkspace.shared.open(url)
            } else {
                self.showError("The release link looked unsafe and was not opened.")
            }
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "DynoPrompt \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
