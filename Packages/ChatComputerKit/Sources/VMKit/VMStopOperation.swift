#if os(macOS)
import Virtualization

/// The framework documents `.error` as a terminated VM after an internal stop failure.
/// Never proceed with file replacement while it is still in a live/transitional state.
@MainActor
enum VMStopOperation {
    static func run(_ stop: @MainActor () async throws -> Void,
                    state: @MainActor () -> VZVirtualMachine.State) async throws -> Error? {
        do {
            try await stop()
            return nil
        } catch {
            switch state() {
            case .stopped, .error: return error
            default: throw error
            }
        }
    }
}
#endif
