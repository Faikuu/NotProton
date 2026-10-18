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

        // A second run finds the install and does not touch the network.
        let again = try await WineFetcher.run(
            build, runners: runners, downloads: work.appending(path: "no-downloads"))
        #expect(again.id == build.id)
    }
}
