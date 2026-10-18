import Foundation
import Testing

@testable import NotProtonApp

@Suite("DXVK layer")
struct DXVKLayerTests {

    // A layer whose files are fixture bytes, so these tests do not depend on the real DLLs.
    static func fixtureLayer(_ bytes: [String: Data]) -> DXVKLayer {
        let files = bytes.keys.sorted().map { path in
            DXVKFile(
                archivePath: path,
                prefixDirectory: path.hasPrefix("x64") ? "system32" : "syswow64",
                name: String(path.split(separator: "/").last ?? ""),
                sha256: Digest.sha256(of: bytes[path]!)
            )
        }
        return DXVKLayer(download: DXVKLayer.pinned.download, files: files)
    }

    @Test("The pinned layer is the archive and the four DLLs the spec pins")
    func pinnedLayerMatchesTheSpec() {
        let layer = DXVKLayer.pinned
        #expect(layer.download.file == "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")
        #expect(layer.download.sha256 == "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477")
        #expect(layer.download.rootInArchive == "dxvk-macOS-async-v1.10.3-20230507-repack")
        #expect(layer.download.bases.map(\.absoluteString)
            == ["https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/"])
        let triples = layer.files.map { [$0.archivePath, $0.prefixDirectory, $0.sha256] }
        #expect(triples == [
            ["x64/d3d11.dll", "system32", "0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4"],
            ["x64/d3d10core.dll", "system32", "0fa08bba860c63e3abeeabfc96d0e7aa327411a975f8f23d2dc63594ef5f796e"],
            ["x32/d3d11.dll", "syswow64", "f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0"],
            ["x32/d3d10core.dll", "syswow64", "2277187a4e13fc2049fe28cb8dd05b34b48c68031c386c3597ba0e18b0c3d327"],
        ])
    }

    @Test("Installed needs every file, with its pinned hash")
    func installedNeedsEveryFileAndItsHash() throws {
        let root = try scratchDirectory("dxvk-installed")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes: [String: Data] = [
            "x64/d3d11.dll": Data("a".utf8), "x64/d3d10core.dll": Data("b".utf8),
            "x32/d3d11.dll": Data("c".utf8), "x32/d3d10core.dll": Data("d".utf8),
        ]
        let layer = Self.fixtureLayer(bytes)
        #expect(!layer.installed(in: root))

        for (path, data) in bytes {
            let file = layer.directory(in: root).appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        #expect(layer.installed(in: root))

        // One flipped byte in one file is enough to make the layer not installed.
        var flipped = Data("a".utf8)
        flipped[flipped.startIndex] ^= 0xff
        try flipped.write(to: layer.directory(in: root).appending(path: "x64/d3d11.dll"))
        #expect(!layer.installed(in: root))
    }

    @Test("The layer lives under the support directory and the caches")
    func pathsAreUnderSupportAndCaches() {
        #expect(SupportPaths.dxvk.path(percentEncoded: false).hasSuffix("notproton/dxvk"))
        #expect(SupportPaths.dxvkDownloads.path(percentEncoded: false).hasSuffix("Library/Caches/notproton/dxvk"))
    }

    // A tiny .tar.gz laid out like the real archive, with a layer whose pins are that archive's own
    // hashes. pinnedText replaces the text a file is pinned to, to make a DLL that does not match.
    private static let root = "dxvk-fixture"
    private static let file = "dxvk-fixture.tar.gz"
    private static let texts: [String: String] = [
        "x64/d3d11.dll": "x64 d3d11", "x64/d3d10core.dll": "x64 d3d10core",
        "x32/d3d11.dll": "x32 d3d11", "x32/d3d10core.dll": "x32 d3d10core",
    ]

    private struct Fixture {
        let work: URL
        let downloads: URL
        let host: URL
        let root: URL
        let layer: DXVKLayer
    }

    private func makeFixture(pinnedText: [String: String] = [:], requiredFreeBytes: Int64 = 1_000) throws -> Fixture {
        let work = try scratchDirectory("dxvk-layer")
        let tree = work.appending(path: "tree")
        for (path, text) in Self.texts {
            let file = tree.appending(path: Self.root).appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        let host = work.appending(path: "host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let archive = host.appending(path: Self.file)
        try Shell.check(
            "/usr/bin/tar",
            ["-czf", archive.path(percentEncoded: false), "-C", tree.path(percentEncoded: false), Self.root])

        let files = ["x64/d3d11.dll", "x64/d3d10core.dll", "x32/d3d11.dll", "x32/d3d10core.dll"].map { path in
            DXVKFile(
                archivePath: path,
                prefixDirectory: path.hasPrefix("x64") ? "system32" : "syswow64",
                name: String(path.split(separator: "/").last ?? ""),
                sha256: Digest.sha256(of: Data((pinnedText[path] ?? Self.texts[path]!).utf8))
            )
        }
        let layer = DXVKLayer(
            download: WineDownload(
                file: Self.file,
                sha256: try #require(Digest.sha256IfPresent(archive)),
                bases: [host],
                rootInArchive: Self.root,
                approximateBytes: 1_000,
                requiredFreeBytes: requiredFreeBytes
            ),
            files: files
        )
        return Fixture(
            work: work, downloads: work.appending(path: "downloads"), host: host,
            root: work.appending(path: "dxvk"), layer: layer)
    }

    @Test("A good archive is installed, and nothing is left beside it")
    func installsAGoodArchive() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        try await fixture.layer.run(
            downloads: fixture.downloads, root: fixture.root, availableBytes: { _ in 1_000_000_000 })

        #expect(fixture.layer.installed(in: fixture.root))
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixture.root, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        #expect(entries == [fixture.layer.directoryName])
    }

    @Test("A tampered archive installs nothing and leaves no download behind")
    func tamperedArchiveInstallsNothing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        try Data("not the layer".utf8).write(to: fixture.host.appending(path: Self.file))

        await #expect(throws: StepFailure.self) {
            try await fixture.layer.run(
                downloads: fixture.downloads, root: fixture.root, availableBytes: { _ in 1_000_000_000 })
        }

        #expect(!fixture.layer.installed(in: fixture.root))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.downloads.appending(path: Self.file).path(percentEncoded: false)))
    }

    @Test("An archive whose DLL does not match its pin installs nothing")
    func wrongDLLInsideTheArchiveInstallsNothing() async throws {
        let fixture = try makeFixture(pinnedText: ["x64/d3d10core.dll": "not the real dll"])
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        await #expect(throws: StepFailure.self) {
            try await fixture.layer.run(
                downloads: fixture.downloads, root: fixture.root, availableBytes: { _ in 1_000_000_000 })
        }

        #expect(!fixture.layer.installed(in: fixture.root))
        let staging = try? FileManager.default.contentsOfDirectory(
            at: fixture.root, includingPropertiesForKeys: nil)
        #expect((staging ?? []).isEmpty)
    }

    @Test("An installed layer is left alone, with no network access")
    func alreadyInstalledIsNoOp() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.work) }
        try await fixture.layer.run(
            downloads: fixture.downloads, root: fixture.root, availableBytes: { _ in 1_000_000_000 })

        // The base is an empty folder, so any attempt to download would fail.
        let empty = fixture.work.appending(path: "empty-host")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let offline = DXVKLayer(
            download: WineDownload(
                file: fixture.layer.download.file,
                sha256: fixture.layer.download.sha256,
                bases: [empty],
                rootInArchive: fixture.layer.download.rootInArchive,
                approximateBytes: fixture.layer.download.approximateBytes,
                requiredFreeBytes: fixture.layer.download.requiredFreeBytes
            ),
            files: fixture.layer.files
        )
        try await offline.run(
            downloads: fixture.work.appending(path: "other-downloads"), root: fixture.root,
            availableBytes: { _ in 1_000_000_000 })

        #expect(offline.installed(in: fixture.root))
    }

    @Test("Too little free space is refused before anything is downloaded")
    func lowDiskIsRefusedBeforeDownload() async throws {
        let fixture = try makeFixture(requiredFreeBytes: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.work) }

        await #expect(throws: StepFailure.self) {
            try await fixture.layer.run(
                downloads: fixture.downloads, root: fixture.root, availableBytes: { _ in 1 })
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.downloads.path(percentEncoded: false)))
    }

    @Test("The real archive downloads, verifies and installs",
          .enabled(if: ProcessInfo.processInfo.environment["NOTPROTON_TEST_WINE_DOWNLOAD"] == "1"))
    func realArchiveDownloads() async throws {
        let work = try scratchDirectory("dxvk-real")
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appending(path: "dxvk")

        try await DXVKLayer.pinned.run(downloads: work.appending(path: "downloads"), root: root)

        #expect(DXVKLayer.pinned.installed(in: root))
    }

    @Test("Only a downloaded Wine that is ready and missing the layer offers a repair")
    func dxvkDetailAppearsOnlyForAMissingLayer() {
        #expect(StatusView.directXNeedsRepair(isDownloadable: true, copy: .ready, installed: false))
        #expect(!StatusView.directXNeedsRepair(isDownloadable: true, copy: .ready, installed: true))
        #expect(!StatusView.directXNeedsRepair(isDownloadable: true, copy: .none, installed: false))
        #expect(!StatusView.directXNeedsRepair(isDownloadable: true, copy: .unpatched, installed: false))
        #expect(!StatusView.directXNeedsRepair(isDownloadable: false, copy: .ready, installed: false))
    }

    @Test("Only the downloaded Wine's row states the DirectX limits")
    func limitNoteAppearsOnlyForTheFreeWine() {
        #expect(StatusView.directXLimitNote(isDownloadable: true)
            == "DirectX 12 and DirectX 9 games are not supported on this runtime.")
        #expect(StatusView.directXLimitNote(isDownloadable: false) == nil)
    }
}
