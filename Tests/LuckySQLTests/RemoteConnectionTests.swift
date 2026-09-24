import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import LuckySQL

final class RemoteConnectionTests: XCTestCase {
    func testDNSFailureHonorsConnectionDeadline() async throws {
        let driver = MySQLDriver(), start = ContinuousClock.now
        do {
            let session = try await driver.connect(profile: ConnectionProfile(host: "luckysql-acceptance.invalid", port: 3306, connectTimeout: 1), password: "fixture")
            await session.close(); XCTFail("Reserved invalid DNS name must not connect")
        } catch { XCTAssertLessThan(start.duration(to: .now), .seconds(4)) }
        withExtendedLifetime(driver) {}
    }

    func testHandshakeTimeoutClosesHalfEstablishedConnection() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeSucceededFuture(())
        }.bind(host: "127.0.0.1", port: 0).get()
        let driver = MySQLDriver(), started = ContinuousClock.now
        do {
            _ = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: server.localAddress!.port!, connectTimeout: 1), password: "fixture")
            XCTFail("Unresponsive handshake must fail")
        } catch { XCTAssertLessThan(started.duration(to: .now), .seconds(4)) }
        try await server.close().get(); try await group.shutdownGracefully()
        withExtendedLifetime(driver) {}
    }
    func testRefusedEndpointFailsAndDoesNotLeaveHalfSession() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = listener.localAddress!.port!
        try await listener.close().get(); try await group.shutdownGracefully()
        let driver = MySQLDriver(), start = ContinuousClock.now
        do { _ = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, connectTimeout: 1), password: "fixture"); XCTFail("Closed endpoint must fail") }
        catch { XCTAssertLessThan(start.duration(to: .now), .seconds(4)) }
        withExtendedLifetime(driver) {}
    }
    func testLiveAuthenticationFailureThenSuccessfulRetry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Configure a MySQL fixture") }
        let driver = MySQLDriver(), profile = ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", connectTimeout: 2)
        do { let session = try await driver.connect(profile: profile, password: "deliberately-wrong-fixture-password"); await session.close(); XCTFail("Authentication must fail") } catch {}
        let session = try await driver.connect(profile: profile, password: password)
        let result = try await session.query("SELECT 1"); XCTAssertEqual(result.rows, [["1"]]); await session.close()
        withExtendedLifetime(driver) {}
    }
    func testTLSConfigurationAlwaysVerifiesAndRejectsIncompleteClientIdentity() throws {
        XCTAssertNil(try RemoteConnection.tls(nil))
        let tls = try XCTUnwrap(RemoteConnection.tls(TLSOptions(enabled: true)))
        XCTAssertEqual(tls.certificateVerification, .fullVerification)
        XCTAssertThrowsError(try RemoteConnection.tls(TLSOptions(enabled: true, certificateFile: "/missing.pem")))
    }
    func testLiveTLSMustNotFallBackToPlaintext() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["LUCKYSQL_TEST_NO_TLS_PORT"].flatMap(Int.init) else { throw XCTSkip("Set a server port with TLS disabled") }
        let driver = MySQLDriver()
        do {
            let session = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, username: "never-authenticate", tls: TLSOptions(enabled: true)), password: "never-send-this")
            await session.close(); XCTFail("TLS must not downgrade")
        } catch { XCTAssertTrue(String(describing: error).contains("TLS is required")) }
        withExtendedLifetime(driver) {}
    }
    func testLiveVerifiedTLSAndCertificateFailures() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["LUCKYSQL_TEST_TLS_PORT"].flatMap(Int.init), let ca = env["LUCKYSQL_TEST_TLS_CA"],
              let cert = env["LUCKYSQL_TEST_TLS_CERT"], let key = env["LUCKYSQL_TEST_TLS_KEY"] else { throw XCTSkip("Configure the isolated TLS fixture") }
        let driver = MySQLDriver()
        let tls = TLSOptions(enabled: true, caFile: ca, serverName: "localhost", certificateFile: cert, privateKeyFile: key)
        var profile = ConnectionProfile(host: "127.0.0.1", port: port, username: "tlsclient", tls: tls)
        let session = try await driver.connect(profile: profile, password: "fixture-password")
        do {
            let cipher = try await session.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            XCTAssertFalse(cipher.rows.first?.last?.isEmpty ?? true); await session.close()
        } catch { await session.close(); throw error }
        profile.tls?.serverName = "wrong-host.invalid"
        do { let s = try await driver.connect(profile: profile, password: "fixture-password"); await s.close(); XCTFail("Wrong hostname must fail") } catch {}
        profile.tls = TLSOptions(enabled: true, serverName: "localhost")
        do { let s = try await driver.connect(profile: profile, password: "fixture-password"); await s.close(); XCTFail("Untrusted CA must fail") } catch {}
        profile.tls = TLSOptions(enabled: true, caFile: ca, serverName: "localhost")
        do { let s = try await driver.connect(profile: profile, password: "fixture-password"); await s.close(); XCTFail("Required client certificate must fail") } catch {}
        withExtendedLifetime(driver) {}
    }
    func testLiveQueryDeadlineClosesSessionWithoutReplaying() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Configure a MySQL fixture") }
        let driver = MySQLDriver(), session = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", queryTimeout: 1), password: password)
        let start = ContinuousClock.now
        do { _ = try await session.query("SELECT SLEEP(5)"); XCTFail("Expected query deadline") }
        catch { XCTAssertTrue(error is DatabaseSessionLost); XCTAssertLessThan(start.duration(to: .now), .seconds(4)) }
        await session.close(); withExtendedLifetime(driver) {}
    }
    func testLiveSSHTunnelAndPassphrase() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sshPort = env["LUCKYSQL_TEST_SSH_PORT"].flatMap(Int.init), let user = env["LUCKYSQL_TEST_SSH_USER"],
              let key = env["LUCKYSQL_TEST_SSH_KEY"], let knownHosts = env["LUCKYSQL_TEST_SSH_HOSTS"],
              let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Configure the isolated SSH fixture") }
        let driver = MySQLDriver()
        let options = SSHOptions(enabled: true, host: "127.0.0.1", port: sshPort, username: user, identityFile: key, knownHostsFile: knownHosts)
        let session = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", ssh: options), password: password, sshPassword: "fixture-passphrase")
        do { let result = try await session.query("SELECT 1"); XCTAssertEqual(result.rows, [["1"]]); await session.close() }
        catch { await session.close(); throw error }
        var wrongIdentity = options
        let unknownHosts = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-hosts-\(UUID())")
        try Data().write(to: unknownHosts)
        defer { try? FileManager.default.removeItem(at: unknownHosts) }
        wrongIdentity.knownHostsFile = unknownHosts.path
        do {
            let bad = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", ssh: wrongIdentity, connectTimeout: 2), password: password, sshPassword: "fixture-passphrase")
            await bad.close(); XCTFail("Unknown host must be rejected")
        } catch {}
        do {
            let bad = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", ssh: options, connectTimeout: 2), password: password, sshPassword: "wrong-passphrase")
            await bad.close(); XCTFail("Wrong passphrase must be rejected")
        } catch {}
        withExtendedLifetime(driver) {}
    }
}
