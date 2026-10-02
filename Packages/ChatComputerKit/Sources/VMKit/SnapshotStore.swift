#if os(macOS)
import Foundation

/// A saved state of the whole virtual Mac that it can return to at any time.
///
/// It holds the writable disk layers, the auxiliary storage (NVRAM, which must match the disk) and, when it
/// was taken while the Mac was running, its memory, so restoring brings back the open apps and windows.
/// The base image, hardware model and machine identifier never change, so they are not copied.
public struct VMSnapshot: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The freshly set up Mac, recorded once after onboarding. Restoring it resets the computer.
        case initial
        case manual
        /// Taken automatically before a restore, so the state that was replaced can come back.
        case safety
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var createdAt: Date
    /// The snapshot the machine came from when this one was taken: the last one taken or restored.
    public var parentID: UUID?
    public var isProtected: Bool
    public var overlayCount: Int
    /// Size of the saved memory; nil for a disk-only snapshot, which starts up with a cold boot.
    public var memoryBytes: Int64?
    public var hasThumbnail: Bool

    public var includesMemory: Bool { memoryBytes != nil }
}

/// Snapshots of one VM bundle, stored inside it:
///
///     Snapshots/
///       state.json                    which snapshot the machine currently comes from
///       <UUID>/snapshot.json          manifest, written last: a folder without it is not a snapshot
///       <UUID>/thumbnail.jpg          the guest screen when it was taken
///       <UUID>/Disk/overlay-N.asif    APFS clones of the bundle's files, same relative paths
///       <UUID>/AuxiliaryStorage.bin
///       <UUID>/SavedState.vzvmsave    memory, only for snapshots of a running Mac
///       .staging-<UUID>/              a snapshot being taken
///       .restore/                     a restore in progress: journal.json, staged/, backup/
///
/// Files are APFS clones (`copyItem` clones on APFS), so a snapshot costs nothing until the guest writes,
/// and any snapshot can be restored or deleted on its own: the disk stack itself stays one layer deep.
///
/// Every method expects the VM to be stopped; `VirtualMachineController` suspends a running one first.
/// Restoring swaps files under a journal, so a crash midway is finished or undone on the next launch.
public struct SnapshotStore: Sendable {
    public let bundle: VMBundle

    public init(bundle: VMBundle) {
        self.bundle = bundle
    }

    private var root: URL { bundle.snapshotsDirectory }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var restoreRoot: URL { root.appendingPathComponent(".restore", isDirectory: true) }
    private var journalURL: URL { restoreRoot.appendingPathComponent("journal.json") }
    private var stagedRoot: URL { restoreRoot.appendingPathComponent("staged", isDirectory: true) }
    private var backupRoot: URL { restoreRoot.appendingPathComponent("backup", isDirectory: true) }

    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func thumbnailURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("thumbnail.jpg") }
    private func manifestURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("snapshot.json") }

    // MARK: Reading

    /// All snapshots, oldest first. Folders without a valid manifest are ignored.
    public func list() -> [VMSnapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            guard let id = UUID(uuidString: name),
                  let data = try? Data(contentsOf: manifestURL(id)),
                  let snapshot = try? VMBundle.decoder().decode(VMSnapshot.self, from: data),
                  snapshot.id == id else { return nil }
            return snapshot
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func snapshot(_ id: UUID) throws -> VMSnapshot {
        guard let snapshot = list().first(where: { $0.id == id }) else { throw VMError.snapshotNotFound }
        return snapshot
    }

    /// The snapshot the machine's current state descends from.
    public var currentID: UUID? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return (try? VMBundle.decoder().decode(State.self, from: data))?.currentID
    }

    public var initial: VMSnapshot? { list().first { $0.kind == .initial } }

    // MARK: Taking

    /// Records the bundle's current files as a snapshot and makes it current. When the bundle holds saved
    /// memory (`SavedState.vzvmsave`), the snapshot includes it.
    @discardableResult
    public func capture(name: String, kind: VMSnapshot.Kind = .manual, spec: VMSpec, thumbnail: Data?) throws -> VMSnapshot {
        let includesMemory = FileManager.default.fileExists(atPath: bundle.savedStateURL.path)
        let paths = Self.machinePaths(bundle, overlayCount: spec.overlayCount, savedState: includesMemory)
        return try commit(name: name, kind: kind, overlayCount: spec.overlayCount, protected: false,
                          parentID: currentID, thumbnail: thumbnail) { staging in
            for path in paths {
                try FileManager.default.copyItem(at: bundle.url.appendingPathComponent(path),
                                                 to: staging.appendingPathComponent(path))
            }
        }
    }

    /// Records the freshly set up Mac once: an empty overlay on the golden base, made by `makeOverlay`
    /// (`DiskStack.createOverlay`), with the current auxiliary storage. Returns the existing one if present.
    @discardableResult
    public func captureInitial(makeOverlay: (URL) throws -> Void) throws -> VMSnapshot {
        if let initial { return initial }
        let auxiliary = Self.relativePath(bundle.auxiliaryStorageURL, in: bundle)
        let current = currentID
        let snapshot = try commit(name: "Freshly set up", kind: .initial, overlayCount: 1, protected: true,
                                  parentID: nil, thumbnail: nil) { staging in
            try makeOverlay(staging.appendingPathComponent(Self.relativePath(bundle.overlayURL(1), in: bundle)))
            try FileManager.default.copyItem(at: bundle.url.appendingPathComponent(auxiliary),
                                             to: staging.appendingPathComponent(auxiliary))
        }
        // The machine still comes from whatever it came from; only a first snapshot ever becomes current here.
        try setCurrent(current ?? snapshot.id)
        return snapshot
    }

    /// Fills a staging folder, writes the manifest last, and moves the folder into place in one rename.
    private func commit(name: String, kind: VMSnapshot.Kind, overlayCount: Int, protected: Bool, parentID: UUID?,
                        thumbnail: Data?, fill: (URL) throws -> Void) throws -> VMSnapshot {
        let id = UUID()
        let staging = root.appendingPathComponent(".staging-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Disk"), withIntermediateDirectories: true)
        do {
            try fill(staging)
            let savedState = staging.appendingPathComponent(Self.relativePath(bundle.savedStateURL, in: bundle))
            let memoryBytes = FileManager.default.fileExists(atPath: savedState.path) ? Self.allocatedSize(savedState) : nil
            if let thumbnail { try thumbnail.write(to: staging.appendingPathComponent("thumbnail.jpg")) }
            let snapshot = VMSnapshot(id: id, name: name, kind: kind, createdAt: Date(), parentID: parentID,
                                      isProtected: protected, overlayCount: overlayCount, memoryBytes: memoryBytes,
                                      hasThumbnail: thumbnail != nil)
            try VMBundle.encode(snapshot).write(to: staging.appendingPathComponent("snapshot.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: directory(id))
            if kind != .initial { try setCurrent(id) }
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: Restoring

    /// Puts the machine's files back to snapshot `id` and makes it current. Returns `spec` with the
    /// snapshot's layer count, which is also what the bundle's spec.json now holds.
    ///
    /// The snapshot's files are cloned into a staging folder first, while the machine is untouched. Then,
    /// under a journal, every file the swap can touch moves aside to a backup folder and the staged files
    /// move in. All moves are renames within the bundle's volume.
    public func restore(_ id: UUID, spec: VMSpec) throws -> VMSpec {
        try recoverInterruptedRestore()
        let snapshot = try self.snapshot(id)
        let source = directory(id)
        let incoming = Self.machinePaths(bundle, overlayCount: snapshot.overlayCount, savedState: snapshot.includesMemory)
        for path in incoming where !FileManager.default.fileExists(atPath: source.appendingPathComponent(path).path) {
            throw VMError.snapshotDamaged("\(path) is missing")
        }
        var restored = spec
        restored.overlayCount = snapshot.overlayCount

        let specPath = Self.relativePath(bundle.specURL, in: bundle)
        let touched = Self.machinePaths(bundle, overlayCount: max(spec.overlayCount, snapshot.overlayCount), savedState: true) + [specPath]
        try FileManager.default.createDirectory(at: stagedRoot.appendingPathComponent("Disk"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupRoot.appendingPathComponent("Disk"), withIntermediateDirectories: true)
        do {
            for path in incoming {
                try FileManager.default.copyItem(at: source.appendingPathComponent(path), to: stagedRoot.appendingPathComponent(path))
            }
            try VMBundle.encode(restored).write(to: stagedRoot.appendingPathComponent(specPath), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: restoreRoot)
            throw error
        }

        var journal = Journal(snapshotID: id, paths: touched, phase: .backingUp)
        try write(journal)
        do {
            for path in touched where FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(path).path) {
                try FileManager.default.moveItem(at: bundle.url.appendingPathComponent(path), to: backupRoot.appendingPathComponent(path))
            }
            journal.phase = .installing
            try write(journal)
            for path in touched where FileManager.default.fileExists(atPath: stagedRoot.appendingPathComponent(path).path) {
                try FileManager.default.moveItem(at: stagedRoot.appendingPathComponent(path), to: bundle.url.appendingPathComponent(path))
            }
            journal.phase = .committed
            try write(journal)
        } catch {
            try rollBack(journal)
            throw error
        }
        try finish(journal)
        return restored
    }

    /// Finishes or undoes a restore that was interrupted, and removes half-taken snapshots.
    /// Run before the VM starts. Throws, keeping every file, if the journal can't be read.
    public func recoverInterruptedRestore() throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let url = root.appendingPathComponent(name)
            if name.hasPrefix(".staging-") {
                try? FileManager.default.removeItem(at: url)
            } else if let id = UUID(uuidString: name), !FileManager.default.fileExists(atPath: manifestURL(id).path) {
                // A deletion that removed the manifest but not the files.
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            // Staged files without a journal: the swap never began.
            try? FileManager.default.removeItem(at: restoreRoot)
            return
        }
        guard let data = try? Data(contentsOf: journalURL), let journal = try? VMBundle.decoder().decode(Journal.self, from: data) else {
            throw VMError.restoreJournalUnreadable
        }
        if journal.phase == .committed {
            try finish(journal)
        } else {
            try rollBack(journal)
        }
    }

    private func rollBack(_ journal: Journal) throws {
        for path in journal.paths {
            let target = bundle.url.appendingPathComponent(path)
            let saved = backupRoot.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: saved.path) {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: saved, to: target)
            } else if journal.phase == .installing, FileManager.default.fileExists(atPath: target.path) {
                // Every original was backed up before installing began, so a file without a backup came from the snapshot.
                try FileManager.default.removeItem(at: target)
            }
        }
        try FileManager.default.removeItem(at: restoreRoot)
    }

    private func finish(_ journal: Journal) throws {
        try setCurrent(journal.snapshotID)
        try FileManager.default.removeItem(at: restoreRoot)
    }

    // MARK: Managing

    /// Deletes a snapshot. Its children now come from its parent, and so does the machine if it came from it.
    public func delete(_ id: UUID) throws {
        let snapshot = try self.snapshot(id)
        guard !snapshot.isProtected else { throw VMError.snapshotProtected }
        for child in list() where child.parentID == id {
            try update(child.id) { $0.parentID = snapshot.parentID }
        }
        if currentID == id { try setCurrent(snapshot.parentID) }
        // Without its manifest the folder is no longer a snapshot, even if removing the files is interrupted.
        try FileManager.default.removeItem(at: manifestURL(id))
        try? FileManager.default.removeItem(at: directory(id))
    }

    public func update(_ id: UUID, _ change: (inout VMSnapshot) -> Void) throws {
        var snapshot = try self.snapshot(id)
        change(&snapshot)
        snapshot.id = id
        try VMBundle.encode(snapshot).write(to: manifestURL(id), options: .atomic)
    }

    // MARK: Helpers

    /// Free space for new files on the bundle's volume.
    public static func availableCapacity(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func allocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    /// Bundle files that make up the machine's changing state, relative to the bundle.
    static func machinePaths(_ bundle: VMBundle, overlayCount: Int, savedState: Bool) -> [String] {
        var urls = (0..<max(overlayCount, 0)).map { bundle.overlayURL($0 + 1) }
        urls.append(bundle.auxiliaryStorageURL)
        if savedState { urls.append(bundle.savedStateURL) }
        return urls.map { relativePath($0, in: bundle) }
    }

    static func relativePath(_ url: URL, in bundle: VMBundle) -> String {
        String(url.standardizedFileURL.path.dropFirst(bundle.url.standardizedFileURL.path.count + 1))
    }

    private func setCurrent(_ id: UUID?) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try VMBundle.encode(State(currentID: id)).write(to: stateURL, options: .atomic)
    }

    private func write(_ journal: Journal) throws {
        try VMBundle.encode(journal).write(to: journalURL, options: .atomic)
    }

    private struct State: Codable {
        var currentID: UUID?
    }

    private struct Journal: Codable {
        enum Phase: String, Codable { case backingUp, installing, committed }
        var snapshotID: UUID
        /// Every bundle path the swap may touch, so an interrupted swap can be undone exactly.
        var paths: [String]
        var phase: Phase
    }
}
#endif
