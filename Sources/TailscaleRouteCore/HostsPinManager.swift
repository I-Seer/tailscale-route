import Foundation

/// Rewrites the app-managed section of `/etc/hosts`.
///
/// While a Tailscale exit node is active, macOS scopes system DNS queries
/// through the tunnel, so browsers resolve domestic CDN domains to overseas
/// edges. `/etc/hosts` lookups are checked by `getaddrinfo` before DNS and
/// are not scoped, so pinning the domestic answers there makes browsers
/// connect to the nearby edges that the split-route table already directs
/// through the physical gateway.
public enum HostsPinManager {
    public static let beginMarker = "# BEGIN tailscale-route managed (自动生成，请勿手动编辑)"
    public static let endMarker = "# END tailscale-route managed"

    /// One pin line per address: `"<ip> <domain> [www.<domain>...]"`.
    /// Tailscale's own control, login and DERP domains. Pinning them to an
    /// answer from a domestic resolver can break login and coordination, so
    /// they are never written to /etc/hosts even if a user adds them.
    static let tailscaleOwnedDomainSuffixes = ["tailscale.com", "tailscale.io", "tailscale.net", "ts.net"]

    public static func isTailscaleOwnedDomain(_ domain: String) -> Bool {
        let name = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return tailscaleOwnedDomainSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    public static func pinLines(for domainAddresses: [HostAddress]) -> [String] {
        var lines: [String] = []
        for host in domainAddresses where !isTailscaleOwnedDomain(host.domain) {
            let names = [host.domain, "www.\(host.domain)"]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            for address in host.ipv4Addresses where !address.isEmpty {
                lines.append("\(address) \(names)")
            }
            for address in host.ipv6Addresses where !address.isEmpty {
                lines.append("\(address) \(names)")
            }
        }
        return lines
    }

    /// Returns the new full hosts file content with the managed section
    /// replaced by `pinLines` (removed entirely when the list is empty).
    public static func renderedHosts(currentHosts: String, pinLines: [String]) -> String {
        // A damaged managed block must never make us drop the rest of the
        // user's hosts file. `apply` reports this as an error; this pure
        // renderer also stays conservative for callers that use it directly.
        guard hasWellFormedManagedSection(currentHosts) else { return currentHosts }

        var kept: [String] = []
        var skippingManagedSection = false
        var removedSection = false

        for line in currentHosts.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker {
                skippingManagedSection = true
                removedSection = true
                continue
            }
            if trimmed == endMarker {
                skippingManagedSection = false
                continue
            }
            if !skippingManagedSection {
                kept.append(String(line))
            }
        }

        // Drop the empty line right before a removed section so repeated
        // refreshes do not accumulate blank lines.
        if removedSection, let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeLast()
        }

        let base = kept.joined(separator: "\n")
        guard !pinLines.isEmpty else {
            return base
        }
        var section = [beginMarker]
        section.append(contentsOf: pinLines)
        section.append(endMarker)
        let separator = base.hasSuffix("\n") ? "" : "\n"
        return base + separator + section.joined(separator: "\n") + "\n"
    }

    /// Reads the hosts file at `path`, rewrites its managed section with the
    /// given domain addresses, and reports how many pin lines are active.
    @discardableResult
    public static func apply(
        domainAddresses: [HostAddress],
        hostsPath: String = "/etc/hosts"
    ) throws -> Int {
        let url = URL(fileURLWithPath: hostsPath)
        // Do not replace an unreadable hosts file with a generated-only file:
        // that could silently erase system or user-managed entries.
        let current = try String(contentsOf: url, encoding: .utf8)
        guard hasWellFormedManagedSection(current) else {
            throw HostsPinManagerError.malformedManagedSection
        }
        let lines = pinLines(for: domainAddresses)
        let rendered = renderedHosts(currentHosts: current, pinLines: lines)
        if rendered != current {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            // mDNSResponder keeps serving answers it cached earlier (for
            // example overseas CDN edges from the Exit Node's DNS), and an
            // atomic replace of /etc/hosts is not always picked up. Flush so
            // browsers and other apps switch to the pinned addresses now.
            if hostsPath == "/etc/hosts" {
                flushSystemDNSCache()
            }
        }
        return lines.count
    }

    /// Equivalent of `dscacheutil -flushcache; killall -HUP mDNSResponder`.
    /// Requires root (the Helper); failures are harmless and ignored.
    static func flushSystemDNSCache(runner: any CommandRunning = ProcessCommandRunner()) {
        _ = runner.run("/usr/bin/dscacheutil", arguments: ["-flushcache"])
        _ = runner.run("/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    }

    private static func hasWellFormedManagedSection(_ currentHosts: String) -> Bool {
        var insideManagedSection = false
        var foundSection = false

        for line in currentHosts.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker {
                guard !insideManagedSection, !foundSection else { return false }
                insideManagedSection = true
                foundSection = true
            } else if trimmed == endMarker {
                guard insideManagedSection else { return false }
                insideManagedSection = false
            }
        }

        return !insideManagedSection
    }
}

private enum HostsPinManagerError: LocalizedError {
    case malformedManagedSection

    var errorDescription: String? {
        "检测到 /etc/hosts 中 tailscale-route 管理标记缺失、重复或顺序错误；为保护其他 hosts 内容，未做修改"
    }
}
