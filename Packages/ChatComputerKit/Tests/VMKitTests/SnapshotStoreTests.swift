#if os(macOS)
import Foundation
import Testing
@testable import VMKit

/// File-level behaviour of snapshots on a fake bundle: plain files stand in for the disk layers,
/// auxiliary storage and saved memory, so no VM or DiskImageKit is needed.
@Suite struct SnapshotStoreTests {
    let bundle: VMBundle
    let store: SnapshotStore
    let spec: VMSpec

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotStoreTests-\(UUID().uuidString).vm")
        bundle = VMBundle(url: url)
        try bundle.create()
        var spec = VMSpec(macAddress: "02:00:00:00:00:01")
        spec.stage = .ready
        spec.overlayCount = 1
        try bundle.save(spec)
        self.spec = spec
        store = SnapshotStore(bundle: bundle)
        try machine(disk: "A", aux: "aux-A")
    }

    private func machine(disk: String, aux: String, memory: String? = nil) throws {
        try Data(disk.utf8).write(to: bundle.overlayURL(1))
        try Data(aux.utf8).write(to: bundle.auxiliaryStorageURL)
        if let memory {
            try Data(memory.utf8).write(to: bundle.savedStateURL)
        } else {
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
        }
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private var hiddenEntries: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bundle.snapshotsDirectory.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    @Test func captureClonesTheMachineFilesAndBecomesCurrent() throws {
        let snapshot = try store.capture(name: "First", spec: spec, thumbnail: Data("jpeg".utf8))
        #expect(store.list().map(\.id) == [snapshot.id])
        #expect(store.currentID == snapshot.id)
        #expect(!snapshot.includesMemory)
        #expect(snapshot.hasThumbnail)
        #expect(read(store.directory(snapshot.id).appendingPathComponent("Disk/overlay-1.asif")) == "A")
        #expect(read(store.directory(snapshot.id).appendingPathComponent("AuxiliaryStorage.bin")) == "aux-A")
        #expect(read(store.thumbnailURL(snapshot.id)) == "jpeg")
        #expect(hiddenEntries.isEmpty)
    }

    @Test func captureIncludesSavedMemory() throws {
        try machine(disk: "A", aux: "aux-A", memory: "memory-A")
        let snapshot = try store.capture(name: "Running", spec: spec, thumbnail: nil)
        #expect(snapshot.includesMemory)
        #expect(read(store.directory(snapshot.id).appendingPathComponent("SavedState.vzvmsave")) == "memory-A")
    }

    @Test func restoreBringsBackDiskAuxiliaryStorageAndMemory() throws {
        try machine(disk: "A", aux: "aux-A", memory: "memory-A")
        let withMemory = try store.capture(name: "A", spec: spec, thumbnail: nil)
        try machine(disk: "B", aux: "aux-B")
        let diskOnly = try store.capture(name: "B", spec: spec, thumbnail: nil)
        try machine(disk: "C", aux: "aux-C", memory: "memory-C")

        var restored = try store.restore(withMemory.id, spec: spec)
        #expect(read(bundle.overlayURL(1)) == "A")
        #expect(read(bundle.auxiliaryStorageURL) == "aux-A")
        #expect(read(bundle.savedStateURL) == "memory-A")
        #expect(store.currentID == withMemory.id)
        #expect(try bundle.loadSpec() == restored)

        restored = try store.restore(diskOnly.id, spec: restored)
        #expect(read(bundle.overlayURL(1)) == "B")
        #expect(!FileManager.default.fileExists(atPath: bundle.savedStateURL.path))
        #expect(store.currentID == diskOnly.id)
        #expect(hiddenEntries.isEmpty)
        // The snapshot itself is untouched, so it can be restored again.
        #expect(read(store.directory(withMemory.id).appendingPathComponent("Disk/overlay-1.asif")) == "A")
    }

    @Test func restoreUsesTheSnapshotsLayerCount() throws {
        var twoLayers = spec
        twoLayers.overlayCount = 2
        try Data("A2".utf8).write(to: bundle.overlayURL(2))
        let snapshot = try store.capture(name: "Two layers", spec: twoLayers, thumbnail: nil)
        try FileManager.default.removeItem(at: bundle.overlayURL(2))

        let restored = try store.restore(snapshot.id, spec: spec)
        #expect(restored.overlayCount == 2)
        #expect(read(bundle.overlayURL(2)) == "A2")

        let back = try store.restore(store.capture(name: "One layer", spec: spec, thumbnail: nil).id, spec: restored)
        #expect(back.overlayCount == 1)
        #expect(!FileManager.default.fileExists(atPath: bundle.overlayURL(2).path))
    }

    @Test func restoreRefusesADamagedSnapshotWithoutTouchingTheMachine() throws {
        let snapshot = try store.capture(name: "A", spec: spec, thumbnail: nil)
        try FileManager.default.removeItem(at: store.directory(snapshot.id).appendingPathComponent("AuxiliaryStorage.bin"))
        try machine(disk: "B", aux: "aux-B")
        #expect(throws: VMError.snapshotDamaged("AuxiliaryStorage.bin is missing")) {
            try store.restore(snapshot.id, spec: spec)
        }
        #expect(read(bundle.overlayURL(1)) == "B")
        #expect(read(bundle.auxiliaryStorageURL) == "aux-B")
    }

    @Test func snapshotsFormABranchingHistory() throws {
        let first = try store.capture(name: "1", spec: spec, thumbnail: nil)
        let second = try store.capture(name: "2", spec: spec, thumbnail: nil)
        _ = try store.restore(first.id, spec: spec)
        let third = try store.capture(name: "3", spec: spec, thumbnail: nil)
        #expect(second.parentID == first.id)
        #expect(third.parentID == first.id)

        // Deleting a snapshot in the middle keeps its children, now hanging from its parent.
        try store.delete(first.id)
        #expect(try store.snapshot(second.id).parentID == nil)
        #expect(try store.snapshot(third.id).parentID == nil)
        #expect(store.currentID == third.id)

        // Deleting the current snapshot moves "current" to its parent.
        let fourth = try store.capture(name: "4", spec: spec, thumbnail: nil)
        try store.delete(fourth.id)
        #expect(store.currentID == third.id)
        #expect(!FileManager.default.fileExists(atPath: store.directory(fourth.id).path))
    }

    @Test func protectedSnapshotsCannotBeDeleted() throws {
        let snapshot = try store.capture(name: "Keep", spec: spec, thumbnail: nil)
        try store.update(snapshot.id) { $0.isProtected = true; $0.name = "Keep me" }
        #expect(throws: VMError.snapshotProtected) { try store.delete(snapshot.id) }
        #expect(try store.snapshot(snapshot.id).name == "Keep me")
    }

    @Test func initialSnapshotIsRecordedOnceAndProtected() throws {
        var made = 0
        let initial = try store.captureInitial { url in
            made += 1
            try Data("empty".utf8).write(to: url)
        }
        #expect(initial.kind == .initial)
        #expect(initial.isProtected)
        #expect(initial.parentID == nil)
        #expect(store.currentID == initial.id)
        #expect(read(store.directory(initial.id).appendingPathComponent("Disk/overlay-1.asif")) == "empty")
        #expect(try store.captureInitial { _ in made += 1 }.id == initial.id)
        #expect(made == 1)

        let next = try store.capture(name: "Later", spec: spec, thumbnail: nil)
        #expect(next.parentID == initial.id)
        _ = try store.restore(initial.id, spec: spec)
        #expect(read(bundle.overlayURL(1)) == "empty")
        #expect(read(bundle.auxiliaryStorageURL) == "aux-A")
    }

    @Test func initialSnapshotRecordedLaterKeepsTheCurrentSnapshot() throws {
        let existing = try store.capture(name: "Before", spec: spec, thumbnail: nil)
        try store.captureInitial { url in try Data("empty".utf8).write(to: url) }
        #expect(store.currentID == existing.id)
    }

    // MARK: Interrupted restores

    /// Lays out the state a restore of `snapshot` leaves behind when it is interrupted in `phase`.
    private func interruptedRestore(of snapshot: VMSnapshot, phase: String, backedUp: [String], installed: [String: String]) throws {
        let restore = bundle.snapshotsDirectory.appendingPathComponent(".restore")
        try FileManager.default.createDirectory(at: restore.appendingPathComponent("backup/Disk"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: restore.appendingPathComponent("staged/Disk"), withIntermediateDirectories: true)
        for path in backedUp {
            try FileManager.default.moveItem(at: bundle.url.appendingPathComponent(path), to: restore.appendingPathComponent("backup/\(path)"))
        }
        for (path, content) in installed {
            try Data(content.utf8).write(to: bundle.url.appendingPathComponent(path))
        }
        let journal = """
            {"snapshotID": "\(snapshot.id.uuidString)", "phase": "\(phase)",
             "paths": ["Disk/overlay-1.asif", "AuxiliaryStorage.bin", "SavedState.vzvmsave", "spec.json"]}
            """
        try Data(journal.utf8).write(to: restore.appendingPathComponent("journal.json"))
    }

    @Test func recoveryUndoesARestoreInterruptedWhileInstalling() throws {
        try machine(disk: "A", aux: "aux-A", memory: "memory-A")
        let snapshot = try store.capture(name: "A", spec: spec, thumbnail: nil)
        let other = try store.capture(name: "B", spec: spec, thumbnail: nil)
        try machine(disk: "B", aux: "aux-B")
        // Every original moved aside; the disk and memory came in, the auxiliary storage and spec did not.
        try interruptedRestore(of: snapshot, phase: "installing",
                               backedUp: ["Disk/overlay-1.asif", "AuxiliaryStorage.bin", "spec.json"],
                               installed: ["Disk/overlay-1.asif": "A", "SavedState.vzvmsave": "memory-A"])

        try store.recoverInterruptedRestore()
        #expect(read(bundle.overlayURL(1)) == "B")
        #expect(read(bundle.auxiliaryStorageURL) == "aux-B")
        #expect(!FileManager.default.fileExists(atPath: bundle.savedStateURL.path))
        #expect(try bundle.loadSpec() == spec)
        #expect(store.currentID == other.id)
        #expect(hiddenEntries.isEmpty)
    }

    @Test func recoveryKeepsFilesNotYetBackedUp() throws {
        let snapshot = try store.capture(name: "A", spec: spec, thumbnail: nil)
        try machine(disk: "B", aux: "aux-B")
        try interruptedRestore(of: snapshot, phase: "backingUp", backedUp: ["Disk/overlay-1.asif"], installed: [:])

        try store.recoverInterruptedRestore()
        #expect(read(bundle.overlayURL(1)) == "B")
        #expect(read(bundle.auxiliaryStorageURL) == "aux-B")
        #expect(try bundle.loadSpec() == spec)
    }

    @Test func recoveryFinishesACommittedRestore() throws {
        let snapshot = try store.capture(name: "A", spec: spec, thumbnail: nil)
        _ = try store.capture(name: "B", spec: spec, thumbnail: nil)
        try interruptedRestore(of: snapshot, phase: "committed", backedUp: ["AuxiliaryStorage.bin"], installed: ["AuxiliaryStorage.bin": "aux-A"])

        try store.recoverInterruptedRestore()
        #expect(store.currentID == snapshot.id)
        #expect(read(bundle.auxiliaryStorageURL) == "aux-A")
        #expect(hiddenEntries.isEmpty)
    }

    @Test func recoveryKeepsEverythingWhenTheJournalIsUnreadable() throws {
        let restore = bundle.snapshotsDirectory.appendingPathComponent(".restore")
        try FileManager.default.createDirectory(at: restore.appendingPathComponent("backup"), withIntermediateDirectories: true)
        try Data("B".utf8).write(to: restore.appendingPathComponent("backup/overlay"))
        try Data("not json".utf8).write(to: restore.appendingPathComponent("journal.json"))

        #expect(throws: VMError.restoreJournalUnreadable) { try store.recoverInterruptedRestore() }
        #expect(read(restore.appendingPathComponent("backup/overlay")) == "B")
    }

    @Test func recoveryRemovesHalfTakenAndHalfDeletedSnapshots() throws {
        let kept = try store.capture(name: "Kept", spec: spec, thumbnail: nil)
        let staging = bundle.snapshotsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)")
        let orphan = bundle.snapshotsDirectory.appendingPathComponent(UUID().uuidString)
        for directory in [staging, orphan] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("A".utf8).write(to: directory.appendingPathComponent("AuxiliaryStorage.bin"))
        }

        try store.recoverInterruptedRestore()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(store.list().map(\.id) == [kept.id])
    }
}
#endif
