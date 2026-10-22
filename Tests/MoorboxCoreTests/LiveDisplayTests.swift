import EmulatorControl
import Foundation
@testable import MoorboxCore
import Testing

/// Opt-in: connects to an emulator that is already running with `-grpc-use-token`
/// (as Moorbox launches it) and measures the shared-memory frame stream.
///
///     MOORBOX_LIVE_GRPC=1 swift test --filter LiveDisplay
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MOORBOX_LIVE_GRPC"] == "1"))
struct LiveDisplayTests {
    @Test(.timeLimit(.minutes(2)))
    func streamsFramesThroughSharedMemory() async throws {
        let sdk = try #require(AndroidSDK.discover(preferred: nil))
        let runtime = EmulatorRuntime(sdk: sdk, avdHome: AVDStore.defaultHome(), logDirectory: FileManager.default.temporaryDirectory)
        let instance = try #require(runtime.runningInstances().first { $0.grpcToken != nil }, "start an emulator with -grpc-use-token")
        let connection = try EmulatorConnection(endpoint: EmulatorEndpoint(port: #require(instance.grpcPort), token: #require(instance.grpcToken)))
        defer { connection.close() }

        let status = try await connection.status()
        #expect(status.booted)
        print("[live] \(instance.avdID): uptime \(status.uptime) ms, booted \(status.booted)")

        let (width, height) = (540, 1200)
        let buffer = try SharedFrameBuffer(capacity: width * height * 4)
        let screen = (
            w: Int(status.hardwareConfig.entry.first { $0.key == "hw.lcd.width" }?.value ?? "1080") ?? 1080,
            h: Int(status.hardwareConfig.entry.first { $0.key == "hw.lcd.height" }?.value ?? "2400") ?? 2400
        )
        // Continuous activity: drag the launcher up and down so the display keeps changing.
        let animator = Task {
            while !Task.isCancelled {
                for step in 0 ... 10 {
                    try? await connection.sendMouse(x: screen.w / 2, y: screen.h * (8 - step / 2) / 10, buttons: 1)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                try? await connection.sendMouse(x: screen.w / 2, y: screen.h * 3 / 10, buttons: 0)
                try? await connection.pressKey("GoHome")
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { animator.cancel() }
        let counter = FrameCounter()
        let window: Duration = .seconds(5)
        let stream = Task {
            for try await frame in connection.frames(width: width, height: height, into: buffer) {
                #expect(frame.width == width && frame.height == height)
                counter.add()
            }
        }
        try await Task.sleep(for: window)
        stream.cancel()
        let count = counter.value
        let fps = Double(count) / 5
        // Pixels are really in shared memory: not all zero.
        let pixels = buffer.bytes.assumingMemoryBound(to: UInt8.self)
        let nonZero = (0 ..< width * height * 4).lazy.filter { pixels[$0] != 0 }.prefix(1000).count
        print("[live] \(count) frames in 5 s of continuous dragging ≈ \(String(format: "%.0f", fps)) fps at \(width)×\(height); non-zero bytes ≥ \(nonZero)")
        #expect(count > 10)
        #expect(nonZero >= 1000)
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }

    func add() {
        lock.withLock { count += 1 }
    }
}
