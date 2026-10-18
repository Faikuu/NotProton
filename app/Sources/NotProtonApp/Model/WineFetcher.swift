// Downloads the free Wine build and installs it where a cloned CrossOver would be

import Foundation

enum WineFetcher {

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case extracting
        case verifying
        case installing
        case finished

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .extracting: String(localized: "Extracting")
            case .verifying: String(localized: "Verifying")
            case .installing: String(localized: "Installing")
            case .finished: String(localized: "Done")
            }
        }
    }

    private static let step = String(localized: "Download Wine")

    static func run(
        _ build: RunnerBuild,
        replacingExisting: Bool = false,
        runners: URL = SupportPaths.runners,
        downloads: URL = SupportPaths.wineDownloads,
        session: URLSession = PinnedDownload.session,
        availableBytes: (URL) -> Int64? = WineFetcher.availableBytes(at:),
        running: (URL) -> Bool = { RunnerInstaller.isRunning(from: $0) },
        report: @Sendable (Phase) -> Void = { _ in }
    ) async throws -> RunnerBuild {
        guard let download = build.download else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(build.title) is not a download.")
            )
        }

        let fm = FileManager.default
        let target = SupportPaths.runnerRoot(forBuild: build.id, runners: runners)

        if RunnerInstaller.hasClone(forBuild: build.id, runners: runners) && !replacingExisting {
            report(.verifying)
            try RunnerInstaller.verifyClone(
                build: build, root: SupportPaths.clonedRoot(forBuild: build.id, runners: runners))
            report(.finished)
            return build
        }

        if let free = availableBytes(nearestExisting(runners)), free < download.requiredFreeBytes {
            let needed = ByteCountFormatter.string(fromByteCount: download.requiredFreeBytes, countStyle: .file)
            throw StepFailure(
                step: step,
                detail: String(localized: "Not enough free disk space. Setting up \(build.title) needs \(needed).")
            )
        }

        if replacingExisting, fm.fileExists(atPath: target.path(percentEncoded: false)), running(target) {
            throw StepFailure(
                step: step,
                detail: String(localized: "A game or Wine tool is still running on build \(build.id). Quit it first.")
            )
        }

        let archive = try await PinnedDownload.obtain(
            file: download.file, sha256: download.sha256, bases: download.bases,
            into: downloads, step: step, from: "GitHub", session: session
        ) { report(.downloading($0)) }

        let staging = runners.appending(path: ".\(target.lastPathComponent).new")
        let extracted = runners.appending(path: ".\(target.lastPathComponent).extract")
        for leftover in [staging, extracted] { try? fm.removeItem(at: leftover) }
        defer { for leftover in [staging, extracted] { try? fm.removeItem(at: leftover) } }

        report(.extracting)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let untar = try Shell.run(
            "/usr/bin/tar",
            ["-xf", archive.path(percentEncoded: false), "-C", extracted.path(percentEncoded: false)])
        guard untar.succeeded else {
            throw StepFailure(
                step: step,
                detail: String(localized: "Unpacking \(archive.lastPathComponent) failed. \(untar.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            )
        }
        let unpacked = extracted.appending(path: download.rootInArchive)
        guard fm.fileExists(atPath: unpacked.path(percentEncoded: false)) else {
            AppLog.note("wine fetch: \(download.rootInArchive) is not in \(download.file)")
            throw StepFailure(
                step: step,
                detail: String(localized: "Something is wrong with the downloaded files. Please check for a NotProton update.")
            )
        }

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let root = staging.appending(path: "CrossOver")
        try fm.moveItem(at: unpacked, to: root)
        RunnerInstaller.scrubDownloadMarkers(at: root)

        report(.verifying)
        try RunnerInstaller.verifyClone(build: build, root: root)

        report(.installing)
        try RunnerInstaller.swapIn(staging: staging, target: target)

        report(.finished)
        return build
    }

    // The volume the runner will land on is decided by the closest folder that exists.
    static func nearestExisting(_ url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path(percentEncoded: false)),
              probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return probe
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
