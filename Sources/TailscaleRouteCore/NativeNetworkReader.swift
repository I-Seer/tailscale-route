import Foundation
import Darwin
import IOKit
import SystemConfiguration
import RouteSocket

/// Read-only kernel / SystemConfiguration / IOKit queries that replace
/// short-lived subprocesses (netstat, ifconfig, networksetup, ipconfig,
/// ioreg) on the production path.
///
/// Every query returns `nil` when the native read is unavailable so callers
/// fall back to the original command. Callers only use this reader with the
/// real `ProcessCommandRunner`; test fakes keep exercising the textual
/// parsers with fixed command output.
enum NativeNetworkReader {
    struct ServiceIPv4: Sendable {
        let router: String?
    }

    struct IPv4Address: Sendable {
        let address: String
        let mask: UInt32?
    }

    struct InterfaceState: Sendable {
        var isUp: Bool
        var isActive: Bool
        var ipv4: [IPv4Address]
    }

    static func isEnabled(for runner: any CommandRunning) -> Bool {
        runner is ProcessCommandRunner
    }

    // MARK: - Routing table

    /// `netstat -rn -f inet` equivalent text from sysctl(NET_RT_DUMP2).
    static func ipv4RouteTableText() -> String? {
        guard let pointer = tailscale_route_table_ipv4_text() else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Hardware ports (networksetup -listallhardwareports)

    static func hardwarePorts() -> [HardwarePort]? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        var ports: [HardwarePort] = []
        for interface in interfaces {
            guard let device = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                  !device.isEmpty,
                  !name.isEmpty
            else { continue }
            ports.append(HardwarePort(name: name, device: device))
        }
        return ports.isEmpty ? nil : ports
    }

    // MARK: - Routers (networksetup -getinfo / ipconfig getpacket)

    /// Active IPv4 service state keyed by BSD interface name. An entry with a
    /// nil router means the service is configured without a router, which is
    /// the same answer networksetup/ipconfig would give.
    static func ipv4ServicesByInterface() -> [String: ServiceIPv4]? {
        guard let store = SCDynamicStoreCreate(nil, "tailscale-route.inspect" as CFString, nil, nil),
              let values = SCDynamicStoreCopyMultiple(
                store,
                nil,
                ["State:/Network/Service/[^/]+/IPv4"] as CFArray
              ) as? [String: Any]
        else { return nil }

        var services: [String: ServiceIPv4] = [:]
        for value in values.values {
            guard let dictionary = value as? [String: Any],
                  let interfaceName = dictionary["InterfaceName"] as? String,
                  !interfaceName.isEmpty
            else { continue }
            let router = (dictionary["Router"] as? String).flatMap { $0.isEmpty || $0 == "0.0.0.0" ? nil : $0 }
            // Prefer a service that actually carries a router when one
            // interface hosts several services.
            if let existing = services[interfaceName], existing.router != nil, router == nil { continue }
            services[interfaceName] = ServiceIPv4(router: router)
        }
        return services
    }

    // MARK: - Interfaces (ifconfig <name> / ifconfig -a)

    /// Equivalent of the `ifconfig <name>` activity probe: `false` for
    /// "status: inactive", otherwise the UP flag; `nil` if the interface
    /// cannot be queried.
    static func interfaceActiveState(_ name: String) -> Bool? {
        let flags = tailscale_interface_flags(name)
        guard flags >= 0 else { return nil }
        if tailscale_interface_media_status(name) == 0 { return false }
        return (flags & IFF_UP) != 0
    }

    /// Equivalent of the parts of `ifconfig -a` the external-network detector
    /// reads: UP flag, "status: active" and IPv4 address/netmask pairs.
    static func interfaceStates() -> [String: InterfaceState]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var result: [String: InterfaceState] = [:]
        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let rawName = entry.pointee.ifa_name else { continue }
            let name = String(cString: rawName)
            var state = result[name] ?? InterfaceState(
                isUp: (Int32(bitPattern: entry.pointee.ifa_flags) & IFF_UP) != 0,
                isActive: tailscale_interface_media_status(name) == 1,
                ipv4: []
            )
            if let address = entry.pointee.ifa_addr,
               address.pointee.sa_family == sa_family_t(AF_INET),
               let text = ipv4String(address)
            {
                state.ipv4.append(IPv4Address(address: text, mask: ipv4Mask(entry.pointee.ifa_netmask)))
            }
            result[name] = state
        }
        return result
    }

    // MARK: - IORegistry (ioreg -r -n <bsd> -l)

    /// Same decision as `ExternalDirectNetworkDetector.isExternalNetworkInterface`
    /// on ioreg output: not built in, and an Ethernet or Wi-Fi interface.
    /// Returns nil when the interface is not in the registry.
    static func isExternalNetworkInterface(_ bsdName: String) -> Bool? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let builtin = IORegistryEntryCreateCFProperty(service, "IOBuiltin" as CFString, nil, 0)?
            .takeRetainedValue() as? Bool
        let interfaceType = IORegistryEntryCreateCFProperty(service, "IOInterfaceType" as CFString, nil, 0)?
            .takeRetainedValue() as? Int
        let className = IOObjectCopyClass(service)?.takeRetainedValue() as String? ?? ""

        let isEthernetOrWiFi = className.contains("IOEthernet")
            || className.contains("IOSkywalkLegacyEthernetInterface")
            || className.contains("IO80211")
            || IOObjectConformsTo(service, "IOEthernetInterface") != 0
            || interfaceType == 6
            || interfaceType == 71
        return builtin == false && isEthernetOrWiFi
    }

    // MARK: - sockaddr helpers

    private static func ipv4String(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        guard Int(address.pointee.sa_len) >= MemoryLayout<sockaddr_in>.size else { return nil }
        var socketAddress = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in.self)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) }
        }
    }

    /// Netmask sockaddrs may be truncated after the last non-zero byte.
    private static func ipv4Mask(_ mask: UnsafeMutablePointer<sockaddr>?) -> UInt32? {
        guard let mask else { return nil }
        let length = Int(mask.pointee.sa_len)
        let raw = UnsafeRawPointer(mask)
        var value: UInt32 = 0
        for index in 0..<4 {
            let offset = 4 + index // offsetof(sockaddr_in, sin_addr)
            let byte: UInt8 = offset < length ? raw.load(fromByteOffset: offset, as: UInt8.self) : 0
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
