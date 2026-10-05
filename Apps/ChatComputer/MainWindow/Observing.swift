import Foundation
import Observation

/// Runs `update` now and again whenever an `@Observable` property it read changes, on the main actor, until the
/// returned token is released or cancelled. The AppKit parts of the main window use it to follow `AppModel`.
@MainActor
final class Observing {
    private var update: (() -> Void)?

    init(_ update: @escaping @MainActor () -> Void) {
        self.update = update
        run()
    }

    func cancel() { update = nil }

    private func run() {
        guard let update else { return }
        withObservationTracking(update) { [weak self] in
            // Called before the change lands, on whichever thread made it: read the new values on the next turn.
            Task { @MainActor in self?.run() }
        }
    }
}
