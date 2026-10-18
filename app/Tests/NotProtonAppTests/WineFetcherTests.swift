import Foundation
import Testing

@testable import NotProtonApp

// A tiny .tar.xz laid out like the Gcenx archive, with a build whose pins are that archive's own
// hashes. Hosts are file URLs, so none of this needs the network.
@Suite("Wine fetcher")
struct WineFetcherTests {

    private static let root = "Wine Devel.app/Contents/Resources/wine"
    private static let file = "wine-fixture.tar.xz"

    private struct Fixture {
        let work: URL
        let runners: URL
        let downloads: URL
        let host: URL
        let build: RunnerBuild
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // loader is what goes in the archive. pinnedLoader is what the build claims it is.
    private func makeFixture(
        loader: String = "wine loader", pinnedLoader: String = "wine loader",
        requiredFreeBytes: Int64 = 1_000
    ) throws -> Fixture {
        let work = try scratchDirectory("winefetch")
        let tree = work.appending(path: "tree")
        let wine = tree.appending(path: Self.root).appending(path: "lib/wine")
        try write(loader, to: wine.appending(path: "x86_64-unix/wine"))
        try write("ntdll 64", to: wine.appending(path: "x86_64-windows/ntdll.dll"))
        try write("ntdll 32", to: wine.appending(path: "i386-windows/ntdll.dll"))

        let host = work.appending(path: "host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let archive = host.appending(path: Self.file)
        try Shell.check(
            "/usr/bin/tar",
            ["-cJf", archive.path(percentEncoded: false), "-C", tree.path(percentEncoded: false),
             "Wine Devel.app"])

        func hash(_ text: String) -> String { Digest.sha256(of: Data(text.utf8)) }
        let build = RunnerBuild(
            bundleVersion: "11.15",
            releaseVersion: "11.15",
            flavor: nil,
            loaderSHA256: hash(pinnedLoader),
            cleanNtdll: [.x86_64Windows: hash("ntdll 64"), .i386Windows: hash("ntdll 32")],
            patchedNtdll: [:],
            origin: .downloadedWine(WineDownload(
                file: Self.file,
                sha256: try #require(Digest.sha256IfPresent(archive)),
                bases: [host],
                rootInArchive: Self.root,
                approximateBytes: 100,
                requiredFreeBytes: requiredFreeBytes
            ))
        )
        return Fixture(
            work: work, runners: work.appending(path: "runners"),
            downloads: work.appending(path: "downloads"), host: host, build: build)
    }

    // The same build, served from a base that has nothing in it.
    private func unserved(_ build: RunnerBuild, under work: URL) throws -> RunnerBuild {
        let empty = work.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        var download = try #require(build.download)
        download = WineDownload(
            file: download.file, sha256: download.sha256, bases: [empty],
            rootInArchive: download.rootInArchive, approximateBytes: download.approximateBytes,
            requiredFreeBytes: download.requiredFreeBytes)
        var copy = build
        copy.origin = .downloadedWine(download)
        return copy
    }

    private func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func run(
        _ fixture: Fixture, build: RunnerBuild? = nil, replacingExisting: Bool = false,
        availableBytes: @escaping (URL) -> Int64? = { _ in Int64.max },
        running: @escaping (URL) -> Bool = { _ in false }
    ) async throws -> RunnerBuild {
        try await WineFetcher.run(
            build ?? fixture.build, replacingExisting: replacingExisting,
            runners: fixture.runners, downloads: fixture.downloads,
            availableBytes: availableBytes, running: running)
    }

    @Test("A good archive is installed under crossover-<id>/CrossOver and passes verification")
    func installs() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.work) }

        let returned = try await run(f)

        #expect(returned.id == f.build.id)
        let cloned = SupportPaths.clonedRoot(forBuild: f.build.id, runners: f.runners)
        #expect(exists(cloned.appending(path: "lib/wine/x86_64-unix/wine")))
        #expect(RunnerInstaller.hasClone(forBuild: f.build.id, runners: f.runners))
        #expect(names(in: f.runners) == ["crossover-\(f.build.id)"])
        try RunnerInstaller.verifyClone(build: f.build, root: cloned)
    }

    @Test("A tampered archive installs nothing")
    func tamperedLeavesNothing() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.work) }
        try write("not the archive", to: f.host.appending(path: Self.file))

        await #expect(throws: StepFailure.self) { _ = try await run(f) }

        #expect(names(in: f.runners).isEmpty)
        #expect(!exists(f.downloads.appending(path: Self.file)))
    }

    @Test("An archive whose loader is not the pinned one installs nothing")
    func wrongLoaderLeavesNothing() async throws {
        let f = try makeFixture(loader: "a different loader", pinnedLoader: "wine loader")
        defer { try? FileManager.default.removeItem(at: f.work) }

        await #expect(throws: StepFailure.self) { _ = try await run(f) }

        #expect(names(in: f.runners).isEmpty)
    }

    @Test("An unreachable host fails without touching runners")
    func unreachable() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.work) }

        await #expect(throws: StepFailure.self) {
            _ = try await run(f, build: unserved(f.build, under: f.work))
        }

        #expect(names(in: f.runners).isEmpty)
    }

    @Test("Already set up is a no-op that never touches the network")
    func reuse() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.work) }
        _ = try await run(f)
        // Drop the cached archive too, so only a fetch could make the second run succeed.
        try? FileManager.default.removeItem(at: f.downloads)

        let again = try await run(f, build: unserved(f.build, under: f.work))

        #expect(again.id == f.build.id)
        #expect(!exists(f.downloads))
        #expect(names(in: f.runners) == ["crossover-\(f.build.id)"])
    }

    @Test("replacingExisting swaps the clone")
    func replaces() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.work) }
        _ = try await run(f)
        let target = SupportPaths.runnerRoot(forBuild: f.build.id, runners: f.runners)
        try write("left behind", to: target.appending(path: "marker"))

        _ = try await run(f, replacingExisting: true)

        #expect(!exists(target.appending(path: "marker")))
        #expect(RunnerInstaller.hasClone(forBuild: f.build.id, runners: f.runners))
        #expect(names(in: f.runners) == ["crossover-\(f.build.id)"])
    }

    @Test("Too little free space is refused before any download")
    func lowDisk() async throws {
        let f = try makeFixture(requiredFreeBytes: 5_000)
        defer { try? FileManager.default.removeItem(at: f.work) }

        await #expect(throws: StepFailure.self) {
            _ = try await run(f, availableBytes: { _ in 4_999 })
        }

        #expect(!exists(f.downloads))
        #expect(!exists(f.runners))
    }

    @Test("A running game on the build refuses a replace")
    func runningRefused() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.work) }
        _ = try await run(f)
        let target = SupportPaths.runnerRoot(forBuild: f.build.id, runners: f.runners)
        try write("still here", to: target.appending(path: "marker"))

        await #expect(throws: StepFailure.self) {
            _ = try await run(f, replacingExisting: true, running: { _ in true })
        }

        #expect(exists(target.appending(path: "marker")))
        #expect(RunnerInstaller.hasClone(forBuild: f.build.id, runners: f.runners))
    }
}
