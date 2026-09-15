import Foundation
import Metal

/// Prefer the discrete GPU on dual-GPU Macs. Starting Metal on the iGPU
/// while Automatic switching is still waking the discrete card often yields
/// a lasting black screensaver.
enum MetalDevicePicker {
    static func preferredReady(
        timeoutSeconds: TimeInterval,
        log: ((String) -> Void)? = nil
    ) -> MTLDevice? {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        var attempt = 0
        var last: MTLDevice?

        repeat {
            attempt += 1
            let devices = MTLCopyAllDevices()
            let discrete = discreteCandidate(from: devices)
            let chosen = discrete ?? MTLCreateSystemDefaultDevice()
            last = chosen

            if let chosen, warmUp(chosen) {
                if chosen.isLowPower, discreteCandidate(from: MTLCopyAllDevices()) != nil {
                    log?("GPU wait attempt \(attempt): still on lowPower '\(chosen.name)'")
                } else {
                    log?("MTLDevice=\(chosen.name) lowPower=\(chosen.isLowPower) attempt=\(attempt)")
                    return chosen
                }
            } else {
                log?("GPU wait attempt \(attempt): warm-up failed for \(chosen?.name ?? "nil")")
            }

            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.08)
        } while Date() < deadline

        if let discrete = discreteCandidate(from: MTLCopyAllDevices()), warmUp(discrete) {
            log?("MTLDevice=\(discrete.name) (discrete fallback)")
            return discrete
        }
        return last
    }

    static func preferredReadyAsync(
        timeoutSeconds: TimeInterval,
        log: ((String) -> Void)? = nil,
        completion: @escaping (MTLDevice?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let device = preferredReady(timeoutSeconds: timeoutSeconds, log: log)
            DispatchQueue.main.async { completion(device) }
        }
    }

    private static func discreteCandidate(from devices: [MTLDevice]) -> MTLDevice? {
        devices.first { !$0.isLowPower && !$0.isRemovable }
            ?? devices.first { !$0.isLowPower }
    }

    private static func warmUp(_ device: MTLDevice, timeout: TimeInterval = 0.35) -> Bool {
        guard let queue = device.makeCommandQueue() else { return false }
        guard let buffer = queue.makeCommandBuffer() else { return false }
        let sema = DispatchSemaphore(value: 0)
        buffer.addCompletedHandler { _ in sema.signal() }
        buffer.commit()
        return sema.wait(timeout: .now() + timeout) == .success && buffer.status != .error
    }
}
