import Foundation
import JammerEngine

/// A plugin in its helper process, as the engine's insert chains take it: a unit whose
/// `process` sends the block down the pipe. When the helper is dead the chain is told the
/// block wasn't processed and lets the sound through (in time).
public final class PluginHostUnit: @unchecked Sendable {
    public let host: PluginHostProcess
    /// The engine's handle (`jm_unit`); chains retain it.
    public let unit: OpaquePointer

    public init(_ host: PluginHostProcess) {
        self.host = host
        unit = jm_unit_create_processor(Int32(host.channels), Unmanaged.passRetained(host).toOpaque(), { context, input, output, channels, frames in
            let host = Unmanaged<PluginHostProcess>.fromOpaque(context!).takeUnretainedValue()
            // Planar and contiguous: channel c starts at c × frames.
            return withUnsafeTemporaryAllocation(of: UnsafePointer<Float>.self, capacity: Int(channels)) { ins in
                withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: Int(channels)) { outs in
                    for c in 0..<Int(channels) {
                        ins[c] = input + c * Int(frames)
                        outs[c] = output + c * Int(frames)
                    }
                    return host.process(ins.baseAddress!, outs.baseAddress!, frames: Int(frames))
                }
            }
        }, { context in
            Unmanaged<PluginHostProcess>.fromOpaque(context!).takeUnretainedValue().reset()
        }, { context in
            Unmanaged<PluginHostProcess>.fromOpaque(context!).release()
        })
    }

    deinit { jm_unit_release(unit) }
}
