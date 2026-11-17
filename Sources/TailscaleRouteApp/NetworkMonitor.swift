import AppKit
import Foundation
import Network
import SystemConfiguration
import TailscaleRouteCore

@MainActor
final class NetworkChangeMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.tailscale-route.network-monitor", qos: .utility)
    private var dynamicStore: SCDynamicStore?
    private var dynamicStoreSource: CFRunLoopSource?
    private var routeMonitorProcess: Process?
    private var routeMonitorReaderTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastPathSignature: String?
    var onChange: ((NetworkChangeReason) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = [
                String(describing: path.status),
                path.availableInterfaces.map(\.name).sorted().joined(separator: ","),
                path.isExpensive ? "expensive" : "standard",
                path.isConstrained ? "constrained" : "open"
            ].joined(separator: "|")
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.lastPathSignature != signature else { return }
                let hadPrevious = self.lastPathSignature != nil
                self.lastPathSignature = signature
                if hadPrevious { self.onChange?(.pathChanged) }
            }
        }
        monitor.start(queue: queue)
        startSystemConfigurationMonitor()
        startRouteMonitor()

        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?(.wokeFromSleep) }
        }
        workspaceObservers.append(token)
    }

    func stop() {
        monitor.cancel()
        routeMonitorReaderTask?.cancel()
        routeMonitorReaderTask = nil
        if let routeMonitorProcess, routeMonitorProcess.isRunning { routeMonitorProcess.terminate() }
        routeMonitorProcess = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let dynamicStoreSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), dynamicStoreSource, .commonModes)
        }
        dynamicStoreSource = nil
        dynamicStore = nil
    }

    private func startSystemConfigurationMonitor() {
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor [weak monitor] in monitor?.onChange?(.systemConfigurationChanged) }
        }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            kCFAllocatorDefault,
            "com.tailscale-route.network-monitor" as CFString,
            callback,
            &context
        ) else { return }

        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6"
        ]
        let patterns = [
            "Setup:/Network/Service/.*/IPv4",
            "Setup:/Network/Service/.*/IPv6"
        ]
        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, store, 0)
        else { return }
        dynamicStore = store
        dynamicStoreSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func startRouteMonitor() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "monitor"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return
        }
        routeMonitorProcess = process
        routeMonitorReaderTask = Task { @MainActor [weak self] in
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard let self, NetworkReconciliationPolicy.isRouteMutationEvent(line) else { continue }
                    self.onChange?(.routeTableChanged)
                }
            } catch {
                // The periodic full snapshot remains the fallback if the
                // routing socket stream closes unexpectedly.
            }
        }
    }
}
