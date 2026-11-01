import AppKit

/// Names the app a cache folder belongs to, and tells whether it's running.
enum Apps {
    /// Folder names whose app isn't obvious from the name.
    static let known: [String: AppHint] = [
        "Google": AppHint(name: "Google Chrome", bundleID: "com.google.Chrome"),
        "com.google.Chrome": AppHint(name: "Google Chrome", bundleID: "com.google.Chrome"),
        "Mozilla": AppHint(name: "Firefox", bundleID: "org.mozilla.firefox"),
        "Firefox": AppHint(name: "Firefox", bundleID: "org.mozilla.firefox"),
        "com.spotify.client": AppHint(name: "Spotify", bundleID: "com.spotify.client"),
        "com.tinyspeck.slackmacgap": AppHint(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        "Slack": AppHint(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        "com.microsoft.VSCode": AppHint(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        "Code": AppHint(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        "com.todesktop.230313mzl4w4u92": AppHint(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        "Cursor": AppHint(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        "cursor-compile-cache": AppHint(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        "com.hnc.Discord": AppHint(name: "Discord", bundleID: "com.hnc.Discord"),
        "discord": AppHint(name: "Discord", bundleID: "com.hnc.Discord"),
        "com.openai.codex": AppHint(name: "Codex", bundleID: "com.openai.codex"),
        "com.openai.chat": AppHint(name: "ChatGPT", bundleID: "com.openai.chat"),
        "com.anthropic.claudefordesktop": AppHint(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
        "Claude": AppHint(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
        "claude-cli-nodejs": AppHint(name: "Claude Code"),
        "us.zoom.xos": AppHint(name: "Zoom", bundleID: "us.zoom.xos"),
        "zoom.us": AppHint(name: "Zoom", bundleID: "us.zoom.xos"),
        "company.thebrowser.Browser": AppHint(name: "Arc", bundleID: "company.thebrowser.Browser"),
        "Arc": AppHint(name: "Arc", bundleID: "company.thebrowser.Browser"),
        "com.brave.Browser": AppHint(name: "Brave", bundleID: "com.brave.Browser"),
        "BraveSoftware": AppHint(name: "Brave", bundleID: "com.brave.Browser"),
        "com.microsoft.edgemac": AppHint(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        "Docker Desktop": AppHint(name: "Docker Desktop", bundleID: "com.docker.docker"),
        "obsidian": AppHint(name: "Obsidian", bundleID: "md.obsidian"),
        "JetBrains": AppHint(name: "JetBrains IDEs"),
        "Yarn": AppHint(name: "Yarn"),
        "node-gyp": AppHint(name: "node-gyp"),
        "typescript": AppHint(name: "TypeScript"),
        "deno": AppHint(name: "Deno"),
    ]

    /// The app a folder in ~/Library/Caches or Application Support belongs
    /// to, and a label for titles. Squirrel's `<bundle id>.ShipIt` folders
    /// hold an Electron app's downloaded updates.
    static func app(forFolder name: String) -> (hint: AppHint, label: String) {
        var base = name
        var suffix = ""
        if base.hasSuffix(".ShipIt") {
            base.removeLast(".ShipIt".count)
            suffix = " update"
        }
        if let hint = known[base] {
            return (hint, (hint.name ?? base) + suffix)
        }
        if looksLikeBundleID(base) {
            let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: base)
                .map { $0.deletingPathExtension().lastPathComponent }
            return (AppHint(name: appName ?? base, bundleID: base), (appName ?? base) + suffix)
        }
        return (AppHint(name: base), base + suffix)
    }

    /// Reverse-DNS names like com.spotify.client.
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3
            && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            }
    }

    /// The name of a running app matching the hint, if any.
    static func running(_ hint: AppHint) -> String? {
        let apps = NSWorkspace.shared.runningApplications
        if let bundleID = hint.bundleID,
            let app = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame })
        {
            return app.localizedName ?? hint.name ?? bundleID
        }
        if let name = hint.name,
            let app = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame })
        {
            return app.localizedName ?? name
        }
        return nil
    }
}
