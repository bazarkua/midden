import Foundation

/// Xcode's DeviceSupport folders hold one subfolder of debug symbols per OS
/// version it copied from a device, named like `17.0 (21A329)`,
/// `17.0 (21A329) arm64e` or `iPhone15,2 17.0 (21A329)`. The newest version
/// is most likely the one on the device you debug with now, so it stays
/// Review; older ones are Safe. When the names don't settle which is newest
/// (a name Midden can't read), every version stays Review.
enum DeviceSupportVersions {
    /// A version folder's OS version and build.
    struct Version: Hashable, Comparable {
        var numbers: [Int]
        var build: String

        static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.numbers.count, rhs.numbers.count)
            for index in 0..<count {
                let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
                let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
                if left != right { return left < right }
            }
            return false
        }

        /// Same OS version, whatever the build: 17.0 and 17.0.0 are equal.
        func sameVersion(as other: Version) -> Bool { !(self < other) && !(other < self) }
    }

    /// Reads `[<model> ]<version> (<build>)[ <arch>]`. Nil for anything else.
    static func parse(_ name: String) -> Version? {
        guard let open = name.firstIndex(of: "("), let close = name[open...].firstIndex(of: ")") else {
            return nil
        }
        let build = name[name.index(after: open)..<close]
        guard !build.isEmpty, build.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let before = name[..<open].trimmingCharacters(in: .whitespaces)
        guard let versionText = before.split(separator: " ").last else { return nil }
        let parts = versionText.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return Version(numbers: numbers, build: String(build))
    }

    /// The names of the version folders that must stay Review: those with
    /// the highest version (all of them on a tie), or every folder when
    /// one name can't be read.
    static func keepForReview(_ entries: [DirectoryEntry]) -> Set<String> {
        let folders = entries.filter { $0.kind == .directory }
        let parsed = folders.map { ($0.name, parse($0.name)) }
        if parsed.contains(where: { $0.1 == nil }) {
            return Set(folders.map(\.name))
        }
        let versions = parsed.compactMap { name, version in version.map { (name, $0) } }
        guard let newest = versions.map(\.1).max() else { return [] }
        return Set(versions.filter { $0.1.sameVersion(as: newest) }.map(\.0))
    }
}
