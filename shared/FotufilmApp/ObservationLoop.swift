import Foundation
import Observation

@MainActor
final class ObservationLoop {
    private var cancelled = false
    private let apply: @MainActor () -> Void

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        track()
    }

    /// Stops the loop.
    func cancel() { cancelled = true }

    private func track() {
        guard !cancelled else { return }
        withObservationTracking { [apply] in
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.track()
            }
        }
    }
}
