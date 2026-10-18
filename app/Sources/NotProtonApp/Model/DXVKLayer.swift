// The DXVK layer the free Wine runtime uses for Direct3D 11. It is pinned by hash like the Wine
// archive, and the run script copies it into each stock-Wine prefix at launch.

import Foundation

struct DXVKFile: Sendable, Equatable {
    // Path inside the archive's root, such as x64/d3d11.dll.
    let archivePath: String

    // Where the file goes in a prefix: system32 for x64, syswow64 for x32.
    let prefixDirectory: String

    let name: String
    let sha256: String
}

struct DXVKLayer: Sendable, Equatable {
    let download: WineDownload
    let files: [DXVKFile]

    var directoryName: String { download.rootInArchive }

    func directory(in root: URL) -> URL {
        root.appending(path: directoryName)
    }

    // Every file has to be there with its pinned hash.
    func installed(in root: URL) -> Bool {
        let dir = directory(in: root)
        return files.allSatisfy { Digest.sha256IfPresent(dir.appending(path: $0.archivePath)) == $0.sha256 }
    }

    static let pinned = DXVKLayer(
        download: WineDownload(
            file: "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
            sha256: "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477",
            bases: [URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/")!],
            rootInArchive: "dxvk-macOS-async-v1.10.3-20230507-repack",
            approximateBytes: 2_793_443,
            requiredFreeBytes: 50_000_000
        ),
        files: [
            DXVKFile(archivePath: "x64/d3d11.dll", prefixDirectory: "system32", name: "d3d11.dll",
                     sha256: "0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4"),
            DXVKFile(archivePath: "x64/d3d10core.dll", prefixDirectory: "system32", name: "d3d10core.dll",
                     sha256: "0fa08bba860c63e3abeeabfc96d0e7aa327411a975f8f23d2dc63594ef5f796e"),
            DXVKFile(archivePath: "x32/d3d11.dll", prefixDirectory: "syswow64", name: "d3d11.dll",
                     sha256: "f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0"),
            DXVKFile(archivePath: "x32/d3d10core.dll", prefixDirectory: "syswow64", name: "d3d10core.dll",
                     sha256: "2277187a4e13fc2049fe28cb8dd05b34b48c68031c386c3597ba0e18b0c3d327"),
        ]
    )
}
