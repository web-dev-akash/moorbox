import AppKit
import EmulatorControl
import MoorboxCore
import Observation
import OSLog

/// Connects one player window to one running emulator over its local gRPC service:
/// frames arrive in shared memory, input goes back as gRPC calls.
@MainActor @Observable
final class PlayerSession {
    enum Phase: Equatable {
        case waiting // the emulator hasn't published its gRPC endpoint yet
        case connecting
        case streaming
        case failed(String)
    }

    let deviceID: String
    private(set) var phase: Phase = .waiting
    /// The latest frame, ready to hand to a CALayer.
    private(set) var image: CGImage?
    /// Device display size in pixels (for mapping input).
    private(set) var deviceSize = CGSize(width: 1080, height: 2400)
    private(set) var framesPerSecond = 0

    private var connection: EmulatorConnection?
    private var buffer: SharedFrameBuffer?
    private var streamTask: Task<Void, Never>?
    private var requestedSize = CGSize.zero
    private var frameTimes: [Date] = []
    private let logger = Logger(subsystem: "io.github.web-dev-akash.Moorbox", category: "player")

    init(deviceID: String) {
        self.deviceID = deviceID
    }

    /// Called whenever the running-instance registry changes.
    func update(instance: RunningInstance?, device: VirtualDevice?) {
        if let device, let w = device.config["hw.lcd.width"].flatMap(Double.init),
           let h = device.config["hw.lcd.height"].flatMap(Double.init) {
            deviceSize = CGSize(width: w, height: h)
        }
        guard connection == nil else { return }
        guard let instance, let port = instance.grpcPort, let token = instance.grpcToken else {
            phase = .waiting
            return
        }
        phase = .connecting
        do {
            connection = try EmulatorConnection(endpoint: EmulatorEndpoint(port: port, token: token))
            // Room for a full-resolution frame in either orientation.
            let longest = Int(max(deviceSize.width, deviceSize.height))
            buffer = try SharedFrameBuffer(capacity: longest * longest * 4)
            restartStream()
        } catch {
            phase = .failed(error.localizedDescription)
            logger.error("Player connection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The view's size in pixels changed; ask the emulator for frames that fit it.
    func viewPixelSizeChanged(_ size: CGSize) {
        let target = Self.streamSize(device: deviceSize, view: size)
        guard target != requestedSize, target.width >= 16 else { return }
        requestedSize = target
        restartStream()
    }

    /// Largest size with the device's aspect ratio that fits the view, never above native.
    static func streamSize(device: CGSize, view: CGSize) -> CGSize {
        guard device.width > 0, device.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let scale = min(1, view.width / device.width, view.height / device.height)
        return CGSize(width: (device.width * scale).rounded(.down), height: (device.height * scale).rounded(.down))
    }

    private func restartStream() {
        streamTask?.cancel()
        guard let connection, let buffer, requestedSize.width > 0 else { return }
        let (width, height) = (Int(requestedSize.width), Int(requestedSize.height))
        streamTask = Task.detached { [weak self] in
            do {
                for try await frame in connection.frames(width: width, height: height, into: buffer) {
                    let image = Self.makeImage(frame, from: buffer)
                    await self?.present(image)
                }
            } catch is CancellationError {
            } catch {
                await self?.streamFailed(error)
            }
        }
    }

    /// Copies the frame out of shared memory (the emulator overwrites it with the next one).
    nonisolated static func makeImage(_ frame: FrameInfo, from buffer: SharedFrameBuffer) -> CGImage? {
        let count = frame.width * frame.height * 4
        guard count > 0, count <= buffer.capacity else { return nil }
        let data = Data(bytes: buffer.bytes, count: count) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func present(_ image: CGImage?) {
        guard let image else { return }
        self.image = image
        phase = .streaming
        let now = Date()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        framesPerSecond = frameTimes.count
    }

    private func streamFailed(_ error: Error) {
        phase = .failed(error.localizedDescription)
        logger.error("Frame stream ended: \(error.localizedDescription, privacy: .public)")
    }

    func close() {
        streamTask?.cancel()
        streamTask = nil
        connection?.close()
        connection = nil
        buffer = nil
        image = nil
    }

    // MARK: Input (fire-and-forget; failures are logged, not surfaced per event)

    /// `point` is in the displayed frame's coordinate space, already mapped to device pixels.
    func mouse(at point: CGPoint, pressed: Bool) {
        send { try await $0.sendMouse(x: Int(point.x), y: Int(point.y), buttons: pressed ? 1 : 0) }
    }

    func scroll(dx: Int, dy: Int) {
        send { try await $0.sendWheel(dx: dx, dy: dy) }
    }

    func key(_ name: String) {
        send { try await $0.pressKey(name) }
    }

    func type(_ text: String) {
        send { try await $0.type(text) }
    }

    private func send(_ body: @escaping @Sendable (EmulatorConnection) async throws -> Void) {
        guard let connection else { return }
        let logger = logger
        Task.detached {
            do { try await body(connection) } catch {
                logger.error("Input event failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
