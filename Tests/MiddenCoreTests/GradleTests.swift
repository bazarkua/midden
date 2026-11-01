import Foundation
import Testing
@testable import MiddenCore

// Gradle's caches are Safe only while no Gradle daemon or build runs: a
// daemon keeps files from them open, and a build running meanwhile fails.

@Suite struct GradleTests {
    private func makeGradleHome() throws -> TempDir {
        let home = try TempDir("home")
        try home.write(".gradle/caches/modules-2/files-2.1/com.example/lib/1.0/abc/lib-1.0.jar", bytes: 200_000)
        try home.write(".gradle/wrapper/dists/gradle-8.10-bin/x/gradle-8.10/lib/gradle-launcher-8.10.jar", bytes: 100_000)
        try home.mkdir(".gradle/daemon/8.10")
        return home
    }

    @Test func gradleCachesAreSafeOnlyWithNoGradleRunning() async throws {
        let home = try makeGradleHome()
        let idle = try await scanFindings(home, processes: ProcessUsage(processes: []))
        let caches = try #require(idle[home.path(".gradle/caches")])
        #expect(caches.safety == .safe)
        #expect(caches.checks.map(\.id) == ["inUse"])
        #expect(caches.checks.first?.passed == true)

        // A daemon started from a distribution elsewhere, working in its
        // own folder: its main class names it.
        let daemon = ProcessUsage.Process(
            pid: 4242, command: "java", directory: "/", executable: "/usr/bin/java",
            arguments: ["java", "-cp", "/opt/gradle/lib/gradle-launcher.jar",
                        "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.10"])
        let running = try await scanFindings(home, processes: ProcessUsage(processes: [daemon]))
        let held = try #require(running[home.path(".gradle/caches")])
        #expect(held.safety == .info)
        #expect(held.checks.first?.detail.contains("pid 4242") == true, "\(held.checks)")
        // Anything working in ~/.gradle, or naming a file in it, counts too.
        let worker = ProcessUsage.Process(
            pid: 4343, command: "sh", directory: home.path(".gradle/daemon/8.10"), executable: "/bin/sh",
            arguments: ["sh"])
        let busy = try await scanFindings(home, processes: ProcessUsage(processes: [worker]))
        #expect(busy[home.path(".gradle/caches")]?.safety == .info)
        #expect(busy[home.path(".gradle/wrapper/dists")]?.safety == .info)
    }

    /// A real process whose arguments name a Gradle main class, and a
    /// listing that couldn't read every process: the cleaner refuses both.
    @Test func cleaningRefusesWhileGradleRunsOrProcessesAreUnknown() async throws {
        let home = try makeGradleHome()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do sleep 0.2; done", "java", "org.gradle.wrapper.GradleWrapperMain", "build"]
        try process.run()
        let result = try #require(await testCleaner(home).clean([home.path(".gradle/caches")]).results.first)
        process.terminate()
        #expect(!result.ok)
        #expect(result.message?.contains("Quit") == true, "\(result)")

        var unknown = testCleaner(home)
        unknown.processUsage = { ProcessUsage(processes: [], failure: "the system wouldn't list processes (test)") }
        let refused = try #require(await unknown.clean([home.path(".gradle/caches")]).results.first)
        #expect(!refused.ok)
        #expect(pathExists(home.path(".gradle/caches/modules-2/files-2.1/com.example/lib/1.0/abc/lib-1.0.jar")))

        var idle = testCleaner(home)
        idle.processUsage = { ProcessUsage(processes: []) }
        let cleaned = try #require(await idle.clean([home.path(".gradle/caches")]).results.first)
        #expect(cleaned.ok, "\(cleaned)")
    }
}
