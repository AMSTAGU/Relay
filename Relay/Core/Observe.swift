import Observation

/// Runs `body` now and again every time something it read changes.
func observeChanges(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking {
        body()
    } onChange: {
        Task { @MainActor in observeChanges(body) }
    }
}
