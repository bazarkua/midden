import Foundation

/// Old VS Code extension versions that VS Code itself would delete.
///
/// When VS Code updates or uninstalls an extension it marks the version in
/// `<extensions>/.obsolete`, a JSON object of extension keys, and deletes
/// it on its next start (deleteExtensionsMarkedForRemoval in
/// extensionManagementService.ts). It deletes only an extension it
/// installed itself, one whose manifest metadata has an installedTimestamp,
/// and only when the extension's key is marked. The key is
/// `<publisher>.<name>-<version>`, lowercased publisher and name, plus
/// `-<targetPlatform>` when the metadata names one (ExtensionKey in
/// extensionManagementUtil.ts).
///
/// Midden applies a narrower version of that predicate: the ledger value
/// must be JSON `true`, the manifest must be a regular file Midden can
/// read, and no VS Code profile may still list the folder. Anything it
/// can't read makes nothing eligible. Only VS Code's own folder is checked:
/// editors built from VS Code's code aren't assumed to behave the same.
enum ObsoleteExtensions {
    /// Folder names under `extensions` that are eligible now.
    static func eligible(extensions: String, entries: [DirectoryEntry], home: String) -> Set<String> {
        guard let ledger = readJSON(extensions + "/.obsolete") as? [String: Any] else { return [] }
        let marked = Set(ledger.compactMap { key, value in isTrue(value) ? key : nil })
        guard !marked.isEmpty, let listed = listedByProfiles(extensions: extensions, home: home) else { return [] }
        var eligible: Set<String> = []
        for entry in entries where entry.kind == .directory && !listed.contains(entry.name) {
            guard let manifest = readJSON(extensions + "/" + entry.name + "/package.json") as? [String: Any],
                let key = key(manifest), marked.contains(key)
            else { continue }
            eligible.insert(entry.name)
        }
        return eligible
    }

    /// The extension's key, when its manifest says VS Code installed it.
    static func key(_ manifest: [String: Any]) -> String? {
        guard let publisher = manifest["publisher"] as? String, let name = manifest["name"] as? String,
            let version = manifest["version"] as? String, !publisher.isEmpty, !name.isEmpty, !version.isEmpty,
            let metadata = manifest["__metadata"] as? [String: Any],
            let installed = metadata["installedTimestamp"] as? NSNumber, !isBoolean(installed)
        else { return nil }
        var key = "\(publisher).\(name)".lowercased() + "-" + version
        if let platform = metadata["targetPlatform"] as? String, platform != "undefined", !platform.isEmpty {
            key += "-" + platform
        }
        return key
    }

    /// Folder names any VS Code profile still lists, or nil when a profile
    /// manifest exists but can't be read.
    static func listedByProfiles(extensions: String, home: String) -> Set<String>? {
        let user = home + "/Library/Application Support/Code/User"
        var manifests = [extensions + "/extensions.json", user + "/extensions.json"]
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: user + "/profiles") {
            manifests += profiles.map { user + "/profiles/" + $0 + "/extensions.json" }
        }
        var listed: Set<String> = []
        for path in manifests {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT { continue }
                return nil
            }
            guard let items = readJSON(path) as? [[String: Any]] else { return nil }
            for item in items {
                if let relative = item["relativeLocation"] as? String { listed.insert(relative) }
                if let location = item["location"] as? [String: Any], let path = location["path"] as? String {
                    listed.insert((path as NSString).lastPathComponent)
                }
            }
        }
        return listed
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// JSON `true`, not `1` or `"true"`.
    private static func isTrue(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, isBoolean(number) else { return false }
        return number.boolValue
    }

    /// A JSON file of at most 8 MB, not following a symlink. Nil when it's
    /// missing, not a regular file, too big or not valid JSON.
    static func readJSON(_ path: String) -> Any? {
        guard let fd = Classifier.openRegularFile(path) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= 8 << 20 else { return nil }
        var data = Data(count: Int(info.st_size))
        let read = data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress! + total, buffer.count - total)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                total += count
            }
            return total
        }
        guard read == data.count else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
