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

    func testOnlyWebLinksReachTheBrowser() throws {
        XCTAssertEqual(try TVTools.webURL("phimfly.com/tv"), "https://phimfly.com/tv")
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "intent://x#Intent;end", "", "  "] {
            XCTAssertThrowsError(try TVTools.webURL(bad), bad)
        }
    }

    func testPinScriptOnlyTakesAnIPv4AndAMAC() {
        XCTAssertEqual(WakeOnLAN.pinScript(host: "192.168.50.25", mac: "F8-77-B8-BF-DF-BB"),
                       "/usr/sbin/arp -n 192.168.50.25 | /usr/bin/grep -q permanent || /usr/sbin/arp -s 192.168.50.25 f8:77:b8:bf:df:bb")
        for (host, mac) in [("192.168.50.25; rm -rf /", "f8:77:b8:bf:df:bb"), ("8.8.8.8", "f8:77:b8:bf:df:bb"),
                            ("192.168.50.25", "f8:77:b8:bf:df:bb; id"), ("192.168.50.25", "f8:77:b8:bf:df"), ("010.1.1.1", "f8:77:b8:bf:df:bb")] {
            XCTAssertNil(WakeOnLAN.pinScript(host: host, mac: mac), "\(host) \(mac)")
        }
    }

    func testUpdatePicking() throws {
        XCTAssertTrue(Updates.isNewer("1.1.0", than: "1.0"))
        XCTAssertTrue(Updates.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(Updates.isNewer("1.1.0", than: "1.1"))
        let json = Data("""
        [{"tag_name":"windows-v9.0.0","assets":[]},
         {"tag_name":"mac-v2.0.0","draft":true,"assets":[]},
         {"tag_name":"mac-v1.2.0","assets":[{"name":"TV-Remote-mac-1.2.0.zip","browser_download_url":"https://x/a.zip"}]},
         {"tag_name":"mac-v1.1.5","html_url":"https://x/p","assets":[{"name":"TV-Remote-mac-1.1.5.zip","browser_download_url":"https://x/b.zip"},
           {"name":"TV-Remote-mac-1.1.5.zip.sha256","browser_download_url":"https://x/b.sha256"}]}]
        """.utf8)
        let u = try XCTUnwrap(Updates.pick(json, prefix: "mac-v", current: "1.1.0") { "TV-Remote-mac-\($0).zip" })
        XCTAssertEqual(u.version, "1.1.5") // 1.2.0 has no checksum, 2.0.0 is a draft
        XCTAssertNil(Updates.pick(json, prefix: "mac-v", current: "1.1.5") { "TV-Remote-mac-\($0).zip" })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertTrue(Updates.matches(file, sha256: "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"))
        XCTAssertFalse(Updates.matches(file, sha256: "00"))
    }

    func testToolHelpers() {
        XCTAssertEqual(TVKey.code(for: "volumeUp"), "KEY_VOLUP")
        XCTAssertEqual(TVKey.code(for: "ok"), "KEY_ENTER")
        XCTAssertEqual(TVKey.code(for: "5"), "KEY_5")
        XCTAssertEqual(YouTube.videoID(from: "https://youtu.be/QVv3mQzlrN0?si=x"), "QVv3mQzlrN0")
        XCTAssertNil(YouTube.videoID(from: "@mkbhd"))
    }
}
