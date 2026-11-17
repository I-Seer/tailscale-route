import Foundation

public enum NetworkChangeReason: String, Sendable {
    case pathChanged
    case systemConfigurationChanged
    case routeTableChanged
    case wokeFromSleep
}

public enum NetworkReconciliationAction: Sendable, Equatable {
    case ignore
    case deferUntilOperationFinishes
    case refreshOnly
    case reconcile
}

/// Result of comparing an authoritative external-network scan with the last
/// accepted snapshot. This is intentionally a decision only; it performs no
/// route or Tailscale writes.
public enum ExternalProtectionReconciliationDecision: Sendable, Equatable {
    /// The scan was incomplete or otherwise unsafe to interpret. Existing
    /// external protection must be retained until an authoritative scan.
    case deferUntilAuthoritativeScan
    /// There is no prior accepted key. Record the baseline, but do not infer a
    /// network change and do not write routes from this decision alone.
    case establishBaseline(ExternalNetworkSnapshotKey)
    /// The authoritative key is identical to the accepted key.
    case unchanged(ExternalNetworkSnapshotKey)
    /// The authoritative key changed. The caller may enqueue the independent
    /// external-protection write transaction.
    case writeCandidate(previous: ExternalNetworkSnapshotKey, current: ExternalNetworkSnapshotKey)

    public var isWriteCandidate: Bool {
        if case .writeCandidate = self { return true }
        return false
    }

    public var currentKey: ExternalNetworkSnapshotKey? {
        switch self {
        case .deferUntilAuthoritativeScan:
            return nil
        case let .establishBaseline(key), let .unchanged(key):
            return key
        case let .writeCandidate(_, current):
            return current
        }
    }
}

public enum NetworkReconciliationPolicy {
    public static let maximumRetryAttempts = 5
    public static let maximumDelaySeconds = 30

    /// `failedAttempts` excludes the retry that is about to be scheduled.
    public static func retryDelaySeconds(after failedAttempts: Int) -> Int? {
        guard failedAttempts >= 0, failedAttempts < maximumRetryAttempts else { return nil }
        return min(2 << failedAttempts, maximumDelaySeconds)
    }

    /// Determines whether an external-protection write is even eligible to
    /// run. Only an authoritative change in the normalized four-field key is
    /// a write candidate. In particular, a gateway/default-route change or a
    /// Tailscale/NWPath fact that is not part of the key cannot qualify.
    public static func externalProtectionDecision(
        previousKey: ExternalNetworkSnapshotKey?,
        detection: ExternalDirectNetworkDetection
    ) -> ExternalProtectionReconciliationDecision {
        guard detection.isAuthoritative else {
            return .deferUntilAuthoritativeScan
        }

        let currentKey = detection.snapshotKey
        guard let previousKey else {
            return .establishBaseline(currentKey)
        }
        guard previousKey != currentKey else {
            return .unchanged(currentKey)
        }
        return .writeCandidate(previous: previousKey, current: currentKey)
    }

    public static func action(
        for reason: NetworkChangeReason,
        isOperating: Bool,
        autoFollowNetwork: Bool,
        lifecycle: RouteLifecycleState,
        retryPaused: Bool,
        suppressRouteEventsUntil: Date? = nil,
        now: Date = Date()
    ) -> NetworkReconciliationAction {
        if reason == .routeTableChanged {
            if isOperating || (suppressRouteEventsUntil.map { now < $0 } ?? false) {
                return .ignore
            }
            // Route-monitor notifications include the routes written by this
            // app and by other local services. They are evidence for a status
            // check, not evidence that the physical network changed.
            return .refreshOnly
        }
        if isOperating { return .deferUntilOperationFinishes }
        guard autoFollowNetwork,
              lifecycle == .enabled || lifecycle == .partial || lifecycle == .networkChanging || retryPaused
        else { return .refreshOnly }
        return .reconcile
    }

    public static func isRouteMutationEvent(_ line: String) -> Bool {
        ["RTM_ADD", "RTM_DELETE", "RTM_CHANGE", "RTM_REDIRECT", "RTM_IFINFO", "RTM_NEWADDR", "RTM_DELADDR"]
            .contains(where: { line.contains($0) })
    }
}
