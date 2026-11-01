import Foundation

/// Folders a build tool or package manager recreates, recognized by name plus
/// a marker file next to them: `target` is only Rust's build output when the
/// folder holding it has a Cargo.toml.
enum BuildFolderKind: Sendable, Hashable {
    case nodeModules
    /// Build output or cache of a JavaScript tool, e.g. Next.js for `.next`.
    case javaScriptBuild(tool: String)
    case cargoTarget
    case pythonEnvironment
    case pods
    case gradleCache
    case gradleBuild
    case dartTool
    case flutterBuild
    /// Cache of a Python tool, e.g. mypy for `.mypy_cache`.
    case pythonToolCache(tool: String)

    /// Every name that can be a build folder. A project's last change ignores
    /// these, so a fresh `npm install` doesn't make an old project look active.
    static let names: Set<String> = [
        "node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular",
        "target", ".venv", "venv", "Pods", ".gradle", "build", ".dart_tool",
        ".mypy_cache", ".pytest_cache", ".ruff_cache",
    ]

    private static let javaScriptTools: [String: String] = [
        ".next": "Next.js", ".nuxt": "Nuxt", ".svelte-kit": "SvelteKit", ".turbo": "Turborepo",
        ".parcel-cache": "Parcel", ".angular": "Angular CLI",
    ]

    private static let pythonTools: [String: String] = [
        ".mypy_cache": "mypy", ".pytest_cache": "pytest", ".ruff_cache": "Ruff",
    ]

    /// - Parameters:
    ///   - name: the folder's name.
    ///   - parent: facts from the listing of the folder holding it (the project).
    ///   - entries: the folder's own listing.
    ///   - path: the folder's path, to read a Python environment's
    ///     pyvenv.cfg when the name doesn't say what it is.
    static func detect(
        name: String, parent: ProjectFacts, entries: [DirectoryEntry], path: String? = nil
    ) -> BuildFolderKind? {
        // A Python environment is never a build folder by its name: one
        // named node_modules beside a package.json, or target beside a
        // Cargo.toml, is still an environment, whose hand-installed
        // packages nothing records. Any pyvenv.cfg stops a name-based
        // verdict: an environment when its layout is plausible or its name
        // is one a build folder has, even when pyvenv.cfg can't be read.
        if entries.contains(where: { $0.name == "pyvenv.cfg" }) {
            if let path, isPythonEnvironment(path: path, entries: entries) { return .pythonEnvironment }
            return names.contains(name) ? .pythonEnvironment : nil
        }
        let markers = parent.markers
        switch name {
        case "node_modules":
            return markers.contains(.packageJSON) ? .nodeModules : nil
        case ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular":
            return markers.contains(.packageJSON) ? .javaScriptBuild(tool: javaScriptTools[name]!) : nil
        case "target":
            return markers.contains(.cargoToml) ? .cargoTarget : nil
        case ".venv", "venv":
            // Without a pyvenv.cfg (handled above), not an environment.
            return nil
        case "Pods":
            return markers.contains(.podfile) ? .pods : nil
        case ".gradle":
            return markers.contains(.gradle) ? .gradleCache : nil
        case "build":
            if markers.contains(.gradle) { return .gradleBuild }
            if markers.contains(.pubspec) { return .flutterBuild }
            return nil
        case ".dart_tool":
            return markers.contains(.pubspec) ? .dartTool : nil
        case ".mypy_cache", ".pytest_cache", ".ruff_cache":
            return .pythonToolCache(tool: pythonTools[name]!)
        default:
            if let path, isPythonEnvironment(path: path, entries: entries) { return .pythonEnvironment }
            return nil
        }
    }

    /// What `python -m venv` makes, under any name: a pyvenv.cfg file
    /// (not a symlink) saying which Python it was made from (`home = ...`),
    /// next to real bin and lib folders.
    static func isPythonEnvironment(path: String, entries: [DirectoryEntry]) -> Bool {
        func has(_ name: String, _ kind: DirectoryEntry.Kind) -> Bool {
            entries.contains { $0.name == name && $0.kind == kind }
        }
        guard has("pyvenv.cfg", .file), has("bin", .directory), has("lib", .directory),
            let config = Classifier.readSmallFile(path + "/pyvenv.cfg")
        else { return false }
        return config.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == "home"
                && !parts[1].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Whether recreating it needs more than one command. Virtual
    /// environments need to know which packages were installed.
    var alwaysReview: Bool {
        self == .pythonEnvironment
    }

    /// What the folder is, for a project named `project`.
    func explanation(project: String, markers: ProjectFacts.Markers) -> String {
        switch self {
        case .nodeModules:
            "Packages installed for the project “\(project)”. \(rebuild(markers)) puts them back."
        case .javaScriptBuild(let tool):
            "Build output and cache of \(tool) for “\(project)”. The next build or dev server run recreates it."
        case .cargoTarget:
            "Rust build output for “\(project)”. `cargo build` recreates it; a full rebuild can take a while."
        case .pythonEnvironment:
            """
            A Python virtual environment for “\(project)”. To recreate it you need the list of \
            packages it had: \(rebuild(markers)). Packages installed into it by hand, and files \
            changed inside it, aren't recorded anywhere and are lost; scripts that run with its \
            Python stop working until you recreate it.
            """
        case .pods:
            "CocoaPods dependencies of “\(project)”. `pod install` puts them back."
        case .gradleCache:
            "Gradle's cache for the project “\(project)”. Gradle recreates it on the next build."
        case .gradleBuild:
            "Gradle build output for “\(project)”. The next build (`./gradlew build`) recreates it."
        case .dartTool:
            "Dart and Flutter tool data for “\(project)”. `flutter pub get` (or `dart pub get`) recreates it."
        case .flutterBuild:
            "Flutter build output for “\(project)”. The next `flutter build` or `flutter run` recreates it."
        case .pythonToolCache(let tool):
            "\(tool)'s cache for “\(project)”. \(tool) recreates it on its next run."
        }
    }

    /// The command that recreates the folder.
    func rebuild(_ markers: ProjectFacts.Markers) -> String {
        switch self {
        case .nodeModules:
            if markers.contains(.pnpmLock) { return "`pnpm install`" }
            if markers.contains(.yarnLock) { return "`yarn install`" }
            if markers.contains(.bunLock) { return "`bun install`" }
            return "`npm install`"
        case .pythonEnvironment:
            if markers.contains(.uvLock) { return "`uv sync`" }
            if markers.contains(.pythonRequirements) {
                return "create it with `python3 -m venv` and reinstall from the project's requirements or pyproject.toml"
            }
            return "note them with `pip freeze` first, since the project has no requirements file"
        case .cargoTarget: return "`cargo build`"
        case .pods: return "`pod install`"
        case .gradleCache, .gradleBuild: return "`./gradlew build`"
        case .dartTool: return "`flutter pub get`"
        case .flutterBuild: return "`flutter build`"
        case .javaScriptBuild: return "the next build"
        case .pythonToolCache(let tool): return "the next \(tool) run"
        }
    }
}

/// A build folder found in a project.
struct BuildFolderMatch: Sendable, Hashable {
    var kind: BuildFolderKind
    var projectPath: String
    var markers: ProjectFacts.Markers
    /// Newest modification time in the project folder, seconds since 1970.
    var projectLastChange: Double?

    var projectName: String { (projectPath as NSString).lastPathComponent }
}
