import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// Where a running emulator's gRPC control service listens. Read from the emulator's
/// discovery file (`grpc.port`, `grpc.token`); the service binds to 127.0.0.1 only.
public struct EmulatorEndpoint: Sendable, Hashable {
    public var port: Int
    public var token: String

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
    }
}

/// A frame written by the emulator into a `SharedFrameBuffer`.
public struct FrameInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var sequence: UInt32
    public var timestampMicroseconds: UInt64
}

/// A file-backed shared-memory region the emulator writes RGBA8888 frames into
/// (`ImageTransport.MMAP`), so pixels never travel over the gRPC socket.
public final class SharedFrameBuffer: @unchecked Sendable {
    public let url: URL
    public let capacity: Int
    public let bytes: UnsafeMutableRawPointer
    private let fd: Int32

    /// - Parameter capacity: bytes; must hold width × height × 4 of the largest frame requested.
    public init(capacity: Int, directory: URL = FileManager.default.temporaryDirectory) throws {
        let url = directory.appendingPathComponent("moorbox-frames-\(UUID().uuidString).rgba")
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard ftruncate(fd, off_t(capacity)) == 0,
              let map = mmap(nil, capacity, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), map != MAP_FAILED
        else {
            let code = errno
            close(fd)
            unlink(url.path)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        self.url = url
        self.capacity = capacity
        bytes = map
        self.fd = fd
    }

    deinit {
        munmap(bytes, capacity)
        close(fd)
        unlink(url.path)
    }

    /// The handle format the emulator expects for file-backed mmap transport.
    var handle: String {
        url.absoluteString
    }
}

public enum EmulatorControlError: LocalizedError, Equatable {
    case frameTooLarge(width: Int, height: Int, capacity: Int)

    public var errorDescription: String? {
        switch self {
        case let .frameTooLarge(w, h, capacity):
            "A \(w)×\(h) frame doesn't fit the \(capacity)-byte frame buffer."
        }
    }
}

/// One gRPC connection to a running emulator's `EmulatorController` service.
public final class EmulatorConnection: Sendable {
    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let controller: Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>
    private let metadata: Metadata
    private let connections: Task<Void, Never>

    public init(endpoint: EmulatorEndpoint) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: endpoint.port),
            transportSecurity: .plaintext // loopback only; requests carry the emulator's auth token
        )
        let client = GRPCClient(transport: transport)
        self.client = client
        controller = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
        metadata = ["authorization": "Bearer \(endpoint.token)"]
        connections = Task { try? await client.runConnections() }
    }

    deinit { close() }

    public func close() {
        client.beginGracefulShutdown()
    }

    private var options: CallOptions {
        var options = CallOptions.defaults
        options.maxResponseMessageBytes = 64 * 1_048_576 // only matters without MMAP
        return options
    }

    public func status() async throws -> Android_Emulation_Control_EmulatorStatus {
        try await controller.getStatus(request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata), options: options)
    }

    /// Streams frames scaled to `width`×`height` into `buffer`. Each element announces that a
    /// complete new frame is in the buffer. The stream ends when the task is cancelled.
    public func frames(width: Int, height: Int, into buffer: SharedFrameBuffer) -> AsyncThrowingStream<FrameInfo, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard width * height * 4 <= buffer.capacity else {
                        throw EmulatorControlError.frameTooLarge(width: width, height: height, capacity: buffer.capacity)
                    }
                    var format = Android_Emulation_Control_ImageFormat()
                    format.format = .rgba8888
                    format.width = UInt32(width)
                    format.height = UInt32(height)
                    format.transport.channel = .mmap
                    format.transport.handle = buffer.handle
                    try await controller.streamScreenshot(request: ClientRequest(message: format, metadata: metadata), options: options) { response in
                        for try await image in response.messages {
                            continuation.yield(FrameInfo(
                                width: Int(image.format.width), height: Int(image.format.height),
                                sequence: image.seq, timestampMicroseconds: image.timestampUs
                            ))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Input

    /// A mouse event in device pixels. `buttons`: 1 = primary (touch), 0 = released.
    public func sendMouse(x: Int, y: Int, buttons: Int) async throws {
        var event = Android_Emulation_Control_MouseEvent()
        event.x = Int32(x)
        event.y = Int32(y)
        event.buttons = Int32(buttons)
        _ = try await controller.sendMouse(request: ClientRequest(message: event, metadata: metadata), options: options)
    }

    /// Scroll in device pixels (positive dy scrolls content down).
    public func sendWheel(dx: Int, dy: Int) async throws {
        var event = Android_Emulation_Control_WheelEvent()
        event.dx = Int32(dx)
        event.dy = Int32(dy)
        let wheel = event
        _ = try await controller.injectWheel(request: StreamingClientRequest(of: Android_Emulation_Control_WheelEvent.self, metadata: metadata) { writer in
            try await writer.write(wheel)
        }, options: options)
    }

    /// Presses and releases a key by its W3C `KeyboardEvent.key` name ("GoHome", "GoBack",
    /// "AppSwitch", "Enter", "Backspace", "AudioVolumeUp"…).
    public func pressKey(_ key: String) async throws {
        var event = Android_Emulation_Control_KeyboardEvent()
        event.eventType = .keypress
        event.key = key
        _ = try await controller.sendKey(request: ClientRequest(message: event, metadata: metadata), options: options)
    }

    /// Types text (UTF-8) as key presses.
    public func type(_ text: String) async throws {
        var event = Android_Emulation_Control_KeyboardEvent()
        event.eventType = .keypress
        event.text = text
        _ = try await controller.sendKey(request: ClientRequest(message: event, metadata: metadata), options: options)
    }
}
