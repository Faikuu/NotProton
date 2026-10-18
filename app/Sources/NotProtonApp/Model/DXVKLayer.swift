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

extension DXVKLayer {
    static let step = String(localized: "Download DirectX layer")

    // Downloads the archive (or reuses the verified copy), checks every DLL against its pin, and
    // only then moves the layer into place. Nothing partial is left under root.
    func run(
        downloads: URL = SupportPaths.dxvkDownloads,
        root: URL = SupportPaths.dxvk,
        session: URLSession = PinnedDownload.session,
        availableBytes: (URL) -> Int64? = WineFetcher.availableBytes(at:),
        report: @Sendable (String) -> Void = { _ in }
    ) async throws {
        if installed(in: root) { return }

        let fm = FileManager.default
        if let free = availableBytes(WineFetcher.nearestExisting(root)), free < download.requiredFreeBytes {
            let needed = ByteCountFormatter.string(fromByteCount: download.requiredFreeBytes, countStyle: .file)
            throw StepFailure(
                step: Self.step,
                detail: String(localized: "Not enough free disk space. Setting up the DirectX layer needs \(needed).")
            )
        }

        let archive = try await PinnedDownload.obtain(
            file: download.file, sha256: download.sha256, bases: download.bases,
            into: downloads, step: Self.step, from: "GitHub", session: session
        ) { progress in report(progress.label) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let extract = root.appending(path: ".dxvk-extract")
        try? fm.removeItem(at: extract)
        defer { try? fm.removeItem(at: extract) }
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)

        report(String(localized: "Unpacking the DirectX layer"))
        let untar = try Shell.run(
            "/usr/bin/tar",
            ["-xf", archive.path(percentEncoded: false), "-C", extract.path(percentEncoded: false)])
        guard untar.succeeded else {
            throw StepFailure(
                step: Self.step,
                detail: String(localized: "Unpacking \(archive.lastPathComponent) failed. \(untar.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            )
        }

        let unpacked = extract.appending(path: directoryName)
        for file in files where Digest.sha256IfPresent(unpacked.appending(path: file.archivePath)) != file.sha256 {
            AppLog.note("dxvk fetch: \(file.archivePath) does not match its pin")
            throw StepFailure(
                step: Self.step,
                detail: String(localized: "Something is wrong with the downloaded files. Please check for a NotProton update.")
            )
        }

        report(String(localized: "Installing the DirectX layer"))
        try RunnerInstaller.swapIn(staging: unpacked, target: directory(in: root))
    }
}
