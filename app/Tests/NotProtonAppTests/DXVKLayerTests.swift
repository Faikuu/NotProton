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
}
