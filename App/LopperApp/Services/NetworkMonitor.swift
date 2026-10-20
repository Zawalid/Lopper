import Network

/// Tells the app when the Mac gets a connection back, so pull requests skipped while offline are checked without
/// anyone pressing Rescan. It reports only the change from no connection to a connection, never the starting state.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lopper.network-monitor")
    private var wasReachable: Bool?

    /// `onReachable` runs on the main actor each time the connection returns.
    func start(onReachable: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            let returned = self.wasReachable == false && reachable
            self.wasReachable = reachable
            if returned { Task { @MainActor in onReachable() } }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
