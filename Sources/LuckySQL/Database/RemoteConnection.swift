import Foundation
import Darwin
import NIOCore
import NIOSSL
import Security

final class ConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: (any Channel)?
    private var cancelled = false
    func register(_ channel: any Channel) {
        lock.lock(); self.channel = channel; let close = cancelled; lock.unlock()
        if close { channel.close(promise: nil) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let channel = channel; lock.unlock()
        channel?.close(promise: nil)
    }
}

enum RemoteConnection {
    // NIOSSL accepts a matching peer IP SAN even when an explicit DNS name was
    // supplied. Apply the requested identity policy separately, after NIOSSL has
    // verified the complete chain. Trusting the leaf here checks identity only;
    // it never replaces the preceding CA/chain verification.
    static func verifyIdentity(_ certificate: NIOSSLCertificate, hostname: String) throws {
        let bytes = try certificate.toDERBytes()
        guard let leaf = SecCertificateCreateWithData(nil, Data(bytes) as CFData) else { throw UpdateFailure("TLS: invalid peer certificate") }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        guard SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess, let trust,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { throw UpdateFailure("TLS: cannot verify server identity") }
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { throw UpdateFailure("TLS: certificate does not verify for \(hostname): \(error.map { CFErrorCopyDescription($0) as String } ?? "identity mismatch")") }
    }

    static func tls(_ options: TLSOptions?) throws -> TLSConfiguration? {
        guard let options, options.enabled else { return nil }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        if !options.caFile.isEmpty { configuration.trustRoots = .file(options.caFile) }
        guard options.certificateFile.isEmpty == options.privateKeyFile.isEmpty else {
            throw UpdateFailure("TLS: both client certificate and private key are required.")
        }
        if !options.certificateFile.isEmpty {
            configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(options.certificateFile).map { .certificate($0) }
            configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: options.privateKeyFile, format: .pem))
        }
        return configuration
    }
}

/// Uses the system SSH implementation and its agent/keychain support. Host keys
/// are always checked, never automatically accepted or removed by LuckySQL.
final class SSHTunnel: @unchecked Sendable {
    let port: Int
    private let process: Process
    private let temporary: URL
    private let closeLock = NSLock()
    private var closed = false
    private init(port: Int, process: Process, temporary: URL) { self.port = port; self.process = process; self.temporary = temporary }
    deinit { close() }
    func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        guard !closed else { return }; closed = true
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: temporary)
    }
    static func start(options: SSHOptions, destination: String, destinationPort: Int, password: String, timeout: Int) async throws -> SSHTunnel {
        let port = try availablePort()
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("LuckySQL-ssh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let control = root.appendingPathComponent("control"), askpass = root.appendingPathComponent("askpass")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$LUCKYSQL_SSH_SECRET\"\n".utf8).write(to: askpass)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let remote = destination.contains(":") ? "[\(destination)]" : destination
        var arguments = ["-F", "/dev/null", "-N", "-M", "-S", control.path, "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes",
                         "-o", "ConnectTimeout=\(timeout)", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "NumberOfPasswordPrompts=1",
                         "-p", String(options.port), "-l", options.username, "-L", "127.0.0.1:\(port):\(remote):\(destinationPort)"]
        if !options.identityFile.isEmpty { arguments += ["-i", options.identityFile, "-o", "IdentitiesOnly=yes"] }
        if !options.knownHostsFile.isEmpty { arguments += ["-o", "UserKnownHostsFile=\(options.knownHostsFile)"] }
        arguments += ["--", options.host]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path; environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "LuckySQL"; environment["LUCKYSQL_SSH_SECRET"] = password
        process.environment = environment
        let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        let tunnel = SSHTunnel(port: port, process: process, temporary: root)
        do {
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            while !FileManager.default.fileExists(atPath: control.path) {
                try Task.checkCancellation()
                if !process.isRunning {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(4096), as: UTF8.self)
                    throw UpdateFailure("SSH: \(message)")
                }
                if ContinuousClock.now >= deadline { throw UpdateFailure("SSH connection/authentication timed out.") }
                try await Task.sleep(for: .milliseconds(30))
            }
            return tunnel
        } catch { tunnel.close(); throw error }
    }
    private static func availablePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw UpdateFailure("SSH: could not allocate a loopback port.") }
        defer { Darwin.close(socket) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw UpdateFailure("SSH: could not bind a loopback port.") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) } }
        guard result == 0 else { throw UpdateFailure("SSH: could not inspect a loopback port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
