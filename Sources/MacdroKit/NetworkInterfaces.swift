import Foundation
import SystemConfiguration

public enum NetworkInterfaces {
    public struct Address: Sendable, Hashable {
        public let interfaceName: String
        public let ipAddress: String

        public init(interfaceName: String, ipAddress: String) {
            self.interfaceName = interfaceName
            self.ipAddress = ipAddress
        }
    }

    public struct ConnectionOption: Sendable, Hashable, Identifiable {
        public enum Transport: String, Sendable, CaseIterable {
            case usbTethering
            case wifi
            case ethernet
            case unknown
        }

        public let address: Address
        public let transport: Transport
        public let serviceName: String?
        public let displayName: String?

        public var id: String {
            "\(address.interfaceName)-\(address.ipAddress)"
        }

        public var label: String {
            switch transport {
            case .usbTethering:
                return serviceName ?? displayName ?? "USB tethering"
            case .wifi:
                return "Wi-Fi"
            case .ethernet:
                return "Ethernet"
            case .unknown:
                return serviceName ?? displayName ?? address.interfaceName
            }
        }

        public var detail: String {
            "\(address.ipAddress) · \(address.interfaceName)"
        }

        public var isWired: Bool {
            transport == .usbTethering || transport == .ethernet
        }

        public var priority: Int {
            switch transport {
            case .usbTethering: return 0
            case .wifi: return 1
            case .ethernet: return 2
            case .unknown: return 3
            }
        }

        public func setupURL(port: Int) -> URL? {
            URL(string: "http://\(address.ipAddress):\(port)/setup")
        }

        public init(
            address: Address,
            transport: Transport,
            serviceName: String? = nil,
            displayName: String? = nil
        ) {
            self.address = address
            self.transport = transport
            self.serviceName = serviceName
            self.displayName = displayName
        }
    }

    private struct InterfaceMetadata {
        let displayName: String?
        let serviceName: String?
        let interfaceType: String?
    }

    private static let excludedPrefixes = [
        "lo", "awdl", "llw", "utun", "bridge", "ap", "gif", "stf", "nan"
    ]

    public static func ipv4Addresses() -> [Address] {
        var results: [Address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)

            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard !excludedPrefixes.contains(where: { name.hasPrefix($0) }) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            results.append(Address(interfaceName: name, ipAddress: ip))
        }

        return results.sorted { lhs, rhs in
            if lhs.interfaceName == "en0" { return true }
            if rhs.interfaceName == "en0" { return false }
            return lhs.interfaceName < rhs.interfaceName
        }
    }

    public static func primaryIPv4() -> Address? {
        ipv4Addresses().first
    }

    public static func connectionOptions() -> [ConnectionOption] {
        let metadata = interfaceMetadata()
        return ipv4Addresses()
            .map { address in
                let info = metadata[address.interfaceName]
                let transport = classify(
                    interfaceName: address.interfaceName,
                    displayName: info?.displayName,
                    serviceName: info?.serviceName,
                    interfaceType: info?.interfaceType
                )
                return ConnectionOption(
                    address: address,
                    transport: transport,
                    serviceName: info?.serviceName,
                    displayName: info?.displayName
                )
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                if lhs.address.interfaceName != rhs.address.interfaceName {
                    return lhs.address.interfaceName < rhs.address.interfaceName
                }
                return lhs.address.ipAddress < rhs.address.ipAddress
            }
    }

    public static func preferredConnection(
        from options: [ConnectionOption],
        matching host: String? = nil
    ) -> ConnectionOption? {
        if let host, let match = options.first(where: { $0.address.ipAddress == host }) {
            return match
        }
        return options.first
    }

    public static func classify(
        interfaceName: String,
        displayName: String?,
        serviceName: String?,
        interfaceType: String?
    ) -> ConnectionOption.Transport {
        let names = [displayName, serviceName]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if names.contains("iphone")
            || names.contains("android")
            || names.contains("usb tether")
            || names.contains("ncm")
            || names.contains("rndis")
        {
            return .usbTethering
        }

        if interfaceType == "IEEE80211"
            || names.contains("wi-fi")
            || names.contains("wifi")
            || names.contains("airport")
        {
            return .wifi
        }

        if interfaceType == "Ethernet"
            || names.contains("ethernet")
            || names.contains("lan")
        {
            return .ethernet
        }

        return .unknown
    }

    private static func interfaceMetadata() -> [String: InterfaceMetadata] {
        var metadata: [String: InterfaceMetadata] = [:]

        if let preferences = SCPreferencesCreate(nil, "Macdro" as CFString, nil),
           let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
        {
            for service in services {
                guard let interface = SCNetworkServiceGetInterface(service),
                      let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?
                else {
                    continue
                }
                let serviceName = SCNetworkServiceGetName(service) as String?
                let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String?
                metadata[bsdName] = InterfaceMetadata(
                    displayName: displayName,
                    serviceName: serviceName,
                    interfaceType: interfaceType
                )
            }
        }

        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                      metadata[bsdName] == nil
                else {
                    continue
                }
                metadata[bsdName] = InterfaceMetadata(
                    displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                    serviceName: nil,
                    interfaceType: SCNetworkInterfaceGetInterfaceType(interface) as String?
                )
            }
        }

        return metadata
    }

    public static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if parts[0] == 10 { return true }
        if parts[0] == 127 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 169, parts[1] == 254 { return true }
        return false
    }

    public static func isAllowedRemote(_ ip: String) -> Bool {
        if ip == "::1" { return true }
        if isPrivateIPv4(ip) { return true }
        let lower = ip.lowercased()
        return lower.hasPrefix("fe80:") || lower.hasPrefix("fd") || lower.hasPrefix("fc")
    }
}
