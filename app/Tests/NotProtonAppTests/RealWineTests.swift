import Foundation
import Testing

@testable import NotProtonApp

// The real download of the pinned Wine from GitHub, through the real fetcher and patcher, into
// scratch directories. About 190 MB, so it only runs with NOTPROTON_TEST_WINE_DOWNLOAD=1.
@Suite("Real Wine download",
       .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_TEST_WINE_DOWNLOAD"] == "1"))
struct RealWineTests {

    @Test("The pinned archive downloads, verifies, installs and patches to the pinned hashes")
    func downloadsAndPatches() async throws {
        let build = try #require(SupportedRunners.downloadable.first)
        let work = try scratchDirectory("real-wine")
        defer { try? FileManager.default.removeItem(at: work) }
        let runners = work.appending(path: "runners")
        let bridge = work.appending(path: "bridge")

        let installed = try await WineFetcher.run(
            build, runners: runners, downloads: work.appending(path: "downloads"))
        #expect(installed.id == build.id)
        #expect(RunnerInstaller.hasClone(forBuild: build.id, runners: runners))

        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let staged = try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: bridge)
        #expect(Set(staged) == Set(build.patchedNtdll.keys))
        for arch in staged {
            #expect(Digest.sha256IfPresent(NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge))
                == build.patchedNtdll[arch])
        }

        // The patch step as setup runs it. The bridge builtins come from the app build, so
        // stand-ins do here; the loader is the real one, which ships with no entitlements.
        for builtin in RunnerPatcher.builtins(in: root) {
            let file = bridge.appending(path: "\(builtin.arch)/\(builtin.name)")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stand-in \(builtin.name)".utf8).write(to: file)
        }
        let loader = CrossOverSource.unixLoader(inRoot: root)
        #expect(RunnerPatcher.loaderProblems(in: root) == ["x86_64-unix/wine is missing the dyld entitlement"])

        let patched = try RunnerPatcher.install(build: build, root: root, bridge: bridge)
        #expect(patched.loaders == ["x86_64-unix/wine"])
        #expect(Set(patched.ntdll) == Set(build.patchedNtdll.keys))
        #expect(RunnerPatcher.loaderProblems(in: root).isEmpty)
        #expect(RunnerPatcher.verify(build: build, root: root, bridge: bridge).isEmpty)

        let path = loader.path(percentEncoded: false)
        let shown = try Shell.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", path])
        #expect(shown.stdout.contains("com.apple.security.cs.allow-dyld-environment-variables"))
        #expect(try Shell.run("/usr/bin/codesign", ["--verify", "--strict", path]).status == 0)
        #expect(Clean.copy(of: loader) != loader)
        #expect(Digest.sha256IfPresent(Clean.copy(of: loader)) == build.loaderSHA256)
        try RunnerInstaller.verifyClone(build: build, root: root)

        // The re-signed loader still starts Wine, so dyld still accepts Wine's own libraries.
        let version = try Shell.run(path, ["--version"])
        #expect(version.status == 0)
        #expect(version.stdout.contains("wine-\(build.releaseVersion)"))

        // A second run finds the patched install and does not touch the network.
        let again = try await WineFetcher.run(
            build, runners: runners, downloads: work.appending(path: "no-downloads"))
        #expect(again.id == build.id)
    }
}
