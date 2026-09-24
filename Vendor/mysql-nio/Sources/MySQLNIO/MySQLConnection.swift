import NIOCore
import Logging
import NIOSSL
import NIOPosix

public final class MySQLConnection: MySQLDatabase, Sendable {
    public static func connect(
        to socketAddress: SocketAddress? = nil,
        host: String? = nil,
        port: Int = 3306,
        timeout: TimeAmount = .seconds(30),
        onChannel: @escaping @Sendable (any Channel) -> Void = { _ in },
        username: String,
        database: String,
        password: String? = nil,
        tlsConfiguration: TLSConfiguration? = .makeClientConfiguration(),
        serverHostname: String? = nil,
        additionalCertificateVerification: (@Sendable (NIOSSLCertificate, any Channel) -> EventLoopFuture<Void>)? = nil,
        logger: Logger = .init(label: "codes.vapor.mysql"),
        on eventLoop: any EventLoop
    ) -> EventLoopFuture<MySQLConnection> {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        
        logger.debug("Opening new MySQL connection")
        
        let transport = socketAddress.map { bootstrap.connect(to: $0) } ?? bootstrap.connect(host: host ?? "localhost", port: port)
        // ClientBootstrap's socket deadline does not bound asynchronous DNS.
        // Resolve the caller's future on time and close a late arriving channel.
        let resolved = eventLoop.makePromise(of: (any Channel).self)
        let state = TransportResolutionState()
        let transportDeadline = eventLoop.scheduleTask(in: timeout) {
            guard !state.completed else { return }; state.completed = true
            resolved.fail(ChannelError.connectTimeout(timeout))
        }
        transport.hop(to: eventLoop).whenComplete { result in
            transportDeadline.cancel()
            if state.completed {
                if case .success(let channel) = result { channel.close(promise: nil) }
                return
            }
            state.completed = true; resolved.completeWith(result)
        }
        return resolved.futureResult.flatMap { channel in
            onChannel(channel)
            let sequence = MySQLPacketSequence()
            let done = channel.eventLoop.makePromise(of: Void.self)
            let deadline = channel.eventLoop.scheduleTask(in: timeout) {
                done.fail(MySQLError.unsupportedServer(message: "MySQL TLS/authentication handshake timed out"))
            }
            done.futureResult.whenComplete { _ in deadline.cancel() }
            done.futureResult.whenFailure { _ in
                channel.close(mode: .all, promise: nil)
            }
            do {
                try channel.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(MySQLPacketDecoder(
                        sequence: sequence,
                        logger: logger
                    )),
                    MessageToByteHandler(MySQLPacketEncoder(
                        sequence: sequence,
                        logger: logger
                    )),
                    MySQLConnectionHandler(logger: logger, state: .handshake(.init(
                        username: username,
                        database: database,
                        password: password,
                        tlsConfiguration: tlsConfiguration,
                        serverHostname: serverHostname,
                        additionalCertificateVerification: additionalCertificateVerification,
                        done: done
                    )), sequence: sequence),
                    ErrorHandler()
                ], position: .last)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            return done.futureResult.map { MySQLConnection(channel: channel, logger: logger) }
        }
    }
    
    public let channel: any Channel
    
    public var eventLoop: any EventLoop {
        self.channel.eventLoop
    }
    
    public let logger: Logger
    
    public var isClosed: Bool {
        !self.channel.isActive
    }
    
    internal init(channel: any Channel, logger: Logger) {
        self.channel = channel
        self.logger = logger
    }
    
    public func close() -> EventLoopFuture<Void> {
        guard self.channel.isActive else {
            return self.channel.eventLoop.makeSucceededFuture(())
        }
        return self.channel.close(mode: .all)
    }
    
    public func send(_ command: any MySQLCommand, logger: Logger) -> EventLoopFuture<Void> {
        guard self.channel.isActive else {
            return self.channel.eventLoop.makeFailedFuture(MySQLError.closed)
        }

        let promise = self.eventLoop.makePromise(of: Void.self)
        
        let c = MySQLCommandContext(
            handler: command,
            promise: promise
        )
        return self.channel.write(c)
            .flatMap { promise.futureResult }
    }
    
    public func withConnection<T>(_ closure: @escaping (MySQLConnection) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }
    
    deinit {
        assert(!self.channel.isActive, "MySQLConnection not closed before deinit.")
    }
}

final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    
    init() { }
    
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        assertionFailure("uncaught error: \(error)")
    }
}

/// Accessed exclusively on the connection's EventLoop.
private final class TransportResolutionState: @unchecked Sendable {
    var completed = false
}
