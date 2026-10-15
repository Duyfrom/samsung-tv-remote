import XCTest
@testable import TVKit

final class GuardTests: XCTestCase {
    func testLocalAddressesAreCanonicalDottedQuadsOnly() {
        for ok in ["192.168.50.25", "10.0.0.7", "172.16.4.2", "172.31.255.254", "169.254.1.1", "127.0.0.1"] {
            XCTAssertTrue(RemoteChannel.isLocalAddress(ok), ok)
        }
        // Public, or written so that inet_aton / the URL layer would read a different address.
        for bad in ["172.32.0.1", "8.8.8.8", "tv.example.com", "localhost", "::1", "[::1]", "",
                    "010.1.1.1", "0172.16.0.1", "192.168.050.1", "0xC0.0xA8.0.1", "192.168.1", "127.1", "3232235777",
                    "192.168.1.1 ", " 192.168.1.1", "192.168.1.1\n", "192.168.1.256", "192.168.1.1.evil.com",
                    "192.168.0.1@8.8.8.8", "192.168.0.1#.8.8.8.8", "192.168.0.1/x", "+1.2.3.4", "١٩٢.١٦٨.١.١"] {
            XCTAssertFalse(RemoteChannel.isLocalAddress(bad), "\(bad.debugDescription)")
        }
    }

    func testSecureTransportIsRefusedForNonLocalHostsBeforeAnyConnection() async {
        for host in ["8.8.8.8", "010.1.1.1", "192.168.0.1@8.8.8.8", "tv.example.com"] {
            let channel = RemoteChannel(host: host, transport: .secure, token: "SECRET")
            do {
                _ = try await channel.connect()
                XCTFail("connected to \(host)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Refusing an unverified TLS connection"), "\(host): \(error)")
            }
        }
    }

    func testPlainURLNeverCarriesTheToken() {
        XCTAssertFalse(RemoteChannel(host: "192.168.0.5", transport: .plain, token: "SECRET").url.absoluteString.contains("SECRET"))
        XCTAssertTrue(RemoteChannel(host: "192.168.0.5", transport: .secure, token: "SECRET").url.absoluteString.hasSuffix("&token=SECRET"))
    }

    func testToolHelpers() {
        XCTAssertEqual(TVKey.code(for: "volumeUp"), "KEY_VOLUP")
        XCTAssertEqual(TVKey.code(for: "ok"), "KEY_ENTER")
        XCTAssertEqual(TVKey.code(for: "5"), "KEY_5")
        XCTAssertEqual(YouTube.videoID(from: "https://youtu.be/QVv3mQzlrN0?si=x"), "QVv3mQzlrN0")
        XCTAssertNil(YouTube.videoID(from: "@mkbhd"))
    }
}
