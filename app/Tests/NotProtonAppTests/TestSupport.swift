import Foundation

@testable import NotProtonApp

func scratchDirectory(_ label: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "np-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func isolatedValveDownloads(in work: URL) throws -> URL {
    let downloads = work.appending(path: "downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    if let bundle = try ValvePackageManifest.bundled().bundle {
        let cached = SupportPaths.packageDownloads.appending(path: bundle.file)
        let destination = downloads.appending(path: bundle.file)
        if FileManager.default.fileExists(atPath: cached.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: cached, to: destination)
        }
    }
    return downloads
}

// A downloaded Wine that is not pinned in SupportedRunners, as it is until the real entry lands.
let fixtureWine = RunnerBuild(
    bundleVersion: "11.15",
    releaseVersion: "11.15",
    flavor: "wine",
    loaderSHA256: String(repeating: "b", count: 64),
    cleanNtdll: [.x86_64Windows: String(repeating: "1", count: 64)],
    patchedNtdll: [.x86_64Windows: String(repeating: "2", count: 64)],
    origin: .downloadedWine(DownloadedWineBuildTests.download)
)
