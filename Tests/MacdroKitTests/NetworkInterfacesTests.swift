import XCTest
@testable import MacdroKit

final class NetworkInterfacesTests: XCTestCase {
    func testIPhoneUSBServiceIsClassifiedAsUSB() {
        let transport = NetworkInterfaces.classify(
            interfaceName: "en5",
            displayName: "iPhone USB",
            serviceName: "iPhone USB",
            interfaceType: "Ethernet"
        )
        XCTAssertEqual(transport, .usbTethering)
    }

    func testAndroidNCMServiceIsClassifiedAsUSB() {
        let transport = NetworkInterfaces.classify(
            interfaceName: "en7",
            displayName: "Android USB",
            serviceName: "Android NCM",
            interfaceType: "Ethernet"
        )
        XCTAssertEqual(transport, .usbTethering)
    }

    func testWiFiInterfaceIsClassifiedAsWiFi() {
        let transport = NetworkInterfaces.classify(
            interfaceName: "en0",
            displayName: "Wi-Fi",
            serviceName: "Wi-Fi",
            interfaceType: "IEEE80211"
        )
        XCTAssertEqual(transport, .wifi)
    }

    func testEthernetInterfaceIsClassifiedAsEthernet() {
        let transport = NetworkInterfaces.classify(
            interfaceName: "en1",
            displayName: "USB 10/100/1000 LAN",
            serviceName: "USB LAN",
            interfaceType: "Ethernet"
        )
        XCTAssertEqual(transport, .ethernet)
    }

    func testUnknownInterfaceDoesNotGuessTransport() {
        let transport = NetworkInterfaces.classify(
            interfaceName: "en9",
            displayName: nil,
            serviceName: nil,
            interfaceType: nil
        )
        XCTAssertEqual(transport, .unknown)
    }

    func testOptionLabelsAndSetupURL() {
        let address = NetworkInterfaces.Address(interfaceName: "en5", ipAddress: "172.20.10.2")
        let option = NetworkInterfaces.ConnectionOption(
            address: address,
            transport: .usbTethering,
            serviceName: "iPhone USB",
            displayName: "iPhone USB"
        )

        XCTAssertEqual(option.label, "iPhone USB")
        XCTAssertEqual(option.detail, "172.20.10.2 · en5")
        XCTAssertTrue(option.isWired)
        XCTAssertEqual(option.setupURL(port: 8787)?.absoluteString, "http://172.20.10.2:8787/setup")
    }

    func testTransportPriorityOrdersUSBBeforeWireless() {
        let address = NetworkInterfaces.Address(interfaceName: "en0", ipAddress: "192.168.1.10")
        let usb = NetworkInterfaces.ConnectionOption(address: address, transport: .usbTethering)
        let wifi = NetworkInterfaces.ConnectionOption(address: address, transport: .wifi)
        let ethernet = NetworkInterfaces.ConnectionOption(address: address, transport: .ethernet)
        let unknown = NetworkInterfaces.ConnectionOption(address: address, transport: .unknown)

        XCTAssertEqual([unknown, ethernet, wifi, usb].map(\.priority).sorted(), [0, 1, 2, 3])
    }

    func testPreferredConnectionMatchesSelectedHost() {
        let wifi = NetworkInterfaces.ConnectionOption(
            address: NetworkInterfaces.Address(interfaceName: "en0", ipAddress: "192.168.1.10"),
            transport: .wifi
        )
        let usb = NetworkInterfaces.ConnectionOption(
            address: NetworkInterfaces.Address(interfaceName: "en5", ipAddress: "172.20.10.2"),
            transport: .usbTethering
        )

        XCTAssertEqual(
            NetworkInterfaces.preferredConnection(from: [usb, wifi], matching: "192.168.1.10")?.id,
            wifi.id
        )
    }

    func testPreferredConnectionFallsBackToFirstAvailable() {
        let wifi = NetworkInterfaces.ConnectionOption(
            address: NetworkInterfaces.Address(interfaceName: "en0", ipAddress: "192.168.1.10"),
            transport: .wifi
        )

        XCTAssertEqual(
            NetworkInterfaces.preferredConnection(from: [wifi], matching: "10.0.0.2")?.id,
            wifi.id
        )
    }

    func testPreferredConnectionIsNilWithoutInterfaces() {
        XCTAssertNil(NetworkInterfaces.preferredConnection(from: [], matching: nil))
    }
}
