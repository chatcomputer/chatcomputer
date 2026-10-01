#if os(macOS)
import Foundation
import Virtualization

/// Onboarding steps 1–3: check the host, fetch the restore image, create the platform files, install macOS.
@MainActor
public final class MacOSInstaller {
    public enum Progress: Sendable, Equatable {
        case checkingHost
        case downloading(fraction: Double)
        case preparing
        case installing(fraction: Double)
        case done
    }

    public let bundle: VMBundle
    private let network = NetworkProvider()
    private var observation: NSKeyValueObservation?

    public init(bundle: VMBundle) {
        self.bundle = bundle
    }

    /// Runs the whole install. Resumable at the step level: a downloaded IPSW is reused.
    public func install(spec: VMSpec, onProgress: @escaping @MainActor (Progress) -> Void) async throws -> VMSpec {
        var spec = spec
        onProgress(.checkingHost)
        try checkHost(spec: spec)
        try bundle.create()

        let ipswURL = bundle.url.appendingPathComponent("RestoreImage.ipsw")
        if !FileManager.default.fileExists(atPath: ipswURL.path) {
            let latest = try await Self.latestSupportedImage()
            try await download(latest.url, to: ipswURL) { onProgress(.downloading(fraction: $0)) }
        }

        onProgress(.preparing)
        let image = try await Self.loadImage(at: ipswURL)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VMError.noSupportedConfiguration
        }
        spec.cpuCount = max(spec.cpuCount, requirements.minimumSupportedCPUCount)
        spec.memoryBytes = max(spec.memoryBytes, requirements.minimumSupportedMemorySize)
        spec.restoreImageBuild = image.buildVersion

        try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL,
                                      hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        try DiskStack(bundle: bundle).createBlankBase(bytes: spec.diskBytes)
        try bundle.save(spec)

        let configuration = try VMConfigurationFactory(bundle: bundle, network: network).make(spec: spec)
        let machine = VZVirtualMachine(configuration: configuration)
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: ipswURL)
        observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in onProgress(.installing(fraction: fraction)) }
        }
        defer { observation = nil }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            installer.install { result in continuation.resume(with: result) }
        }

        spec.stage = .installed
        try bundle.save(spec)
        onProgress(.done)
        return spec
    }

    private func checkHost(spec: VMSpec) throws {
        #if !arch(arm64)
        throw VMError.unsupportedHost("Apple silicon is required")
        #endif
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) else {
            throw VMError.unsupportedHost("macOS 27 or later is required")
        }
        let reservedForHost: UInt64 = 8 << 30
        guard ProcessInfo.processInfo.physicalMemory >= spec.memoryBytes + reservedForHost else {
            throw VMError.unsupportedHost("at least \((spec.memoryBytes + reservedForHost) >> 30) GB of memory is needed")
        }
        let parent = bundle.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let free = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        // IPSW (~20 GB) + installed system (~30 GB) + headroom; the 80 GB disk is sparse.
        let needed: Int64 = 70 << 30
        guard free >= needed else {
            throw VMError.unsupportedHost("\(needed >> 30) GB of free disk space is needed, \(free >> 30) GB available")
        }
    }

    private static func latestSupportedImage() async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { continuation.resume(with: $0) }
        }
    }

    private static func loadImage(at url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { continuation.resume(with: $0) }
        }
    }

    private func download(_ remote: URL, to local: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (temporary, _) = try await URLSession.shared.download(from: remote, delegate: delegate)
        try FileManager.default.moveItem(at: temporary, to: local)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @MainActor (Double) -> Void

    init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.onProgress(fraction) }
    }

    // The async `download(from:delegate:)` call delivers the file; nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
#endif
