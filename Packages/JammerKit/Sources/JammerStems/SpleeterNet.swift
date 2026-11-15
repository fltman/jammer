import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Spleeter's U-Net (Deezer, MIT; after spleeter/model/functions/unet.py), one per stem,
/// built on MPSGraph from the checkpoint's own tensors. Input and output are magnitude
/// spectrograms [time, 1024 bins, 2 channels]; the output is the stem's estimate.
public final class SpleeterNet {
    public static let stems4 = ["vocals", "drums", "bass", "other"]
    public static let bins = 1_024

    let graph = MPSGraph()
    let device: MPSGraphDevice
    let queue: MTLCommandQueue
    let input: MPSGraphTensor
    let outputs: [MPSGraphTensor]
    public let frames: Int

    public enum NetError: Error { case noGPU }

    /// `frames` must be a multiple of 64 (six halvings). Spleeter itself uses 512.
    public init(checkpoint ck: TFCheckpoint, stems: Int = 4, frames: Int = 512) throws {
        guard let metal = MTLCreateSystemDefaultDevice(), let q = metal.makeCommandQueue() else { throw NetError.noGPU }
        device = MPSGraphDevice(mtlDevice: metal)
        queue = q
        self.frames = frames
        let g = graph
        input = g.placeholder(shape: [1, NSNumber(value: frames), NSNumber(value: Self.bins), 2], dataType: .float32, name: "mix")
        func name(_ base: String, _ i: Int) -> String { i == 0 ? base : "\(base)_\(i)" }
        func constant(_ n: String) throws -> MPSGraphTensor {
            let (shape, values) = try ck.floats(n)
            return g.constant(values.withUnsafeBufferPointer { Data(buffer: $0) }, shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        }
        func batchNorm(_ x: MPSGraphTensor, _ i: Int) throws -> MPSGraphTensor {
            let p = name("batch_normalization", i)
            return g.normalize(x, mean: try constant(p + "/moving_mean"), variance: try constant(p + "/moving_variance"),
                               gamma: try constant(p + "/gamma"), beta: try constant(p + "/beta"), epsilon: 1e-3, name: nil)
        }
        func elu(_ x: MPSGraphTensor) -> MPSGraphTensor {
            let zero = g.constant(0, dataType: .float32), one = g.constant(1, dataType: .float32)
            let neg = g.subtraction(g.exponent(with: g.minimum(x, zero, name: nil), name: nil), one, name: nil)
            return g.select(predicate: g.greaterThan(x, zero, name: nil), trueTensor: x, falseTensor: neg, name: nil)
        }
        func conv(strides: Int, dilation: Int) -> MPSGraphConvolution2DOpDescriptor {
            MPSGraphConvolution2DOpDescriptor(strideInX: strides, strideInY: strides, dilationRateInX: dilation, dilationRateInY: dilation, groups: 1,
                                              paddingStyle: .TF_SAME, dataLayout: .NHWC, weightsLayout: .HWIO)!
        }
        var outs: [MPSGraphTensor] = []
        for s in 0..<stems {
            var convs: [MPSGraphTensor] = []
            var h = input
            for l in 0..<6 {
                let c = g.addition(g.convolution2D(h, weights: try constant(name("conv2d", 7 * s + l) + "/kernel"), descriptor: conv(strides: 2, dilation: 1), name: nil),
                                   try constant(name("conv2d", 7 * s + l) + "/bias"), name: nil)
                convs.append(c)
                h = elu(try batchNorm(c, 12 * s + l))
            }
            h = convs[5]
            var t = frames / 64, f = Self.bins / 64
            for l in 0..<6 {
                t *= 2; f *= 2
                let kName = name("conv2d_transpose", 6 * s + l)
                let k = try constant(kName + "/kernel")
                let outChannels = try ck.floats(kName + "/bias").values.count
                var u = g.convolutionTranspose2D(h, weights: k, outputShape: [1, NSNumber(value: t), NSNumber(value: f), NSNumber(value: outChannels)],
                                                 descriptor: conv(strides: 2, dilation: 1), name: nil)
                u = g.addition(u, try constant(kName + "/bias"), name: nil)
                u = try batchNorm(elu(u), 12 * s + 6 + l)
                h = l < 5 ? g.concatTensors([convs[4 - l], u], dimension: 3, name: nil) : u
            }
            var m = g.convolution2D(h, weights: try constant(name("conv2d", 7 * s + 6) + "/kernel"), descriptor: conv(strides: 1, dilation: 2), name: nil)
            m = g.addition(m, try constant(name("conv2d", 7 * s + 6) + "/bias"), name: nil)
            outs.append(g.multiplication(g.sigmoid(with: m, name: nil), input, name: nil))
        }
        outputs = outs
    }

    /// `mix`: frames × 1024 × 2 magnitudes. Returns one array of the same shape per stem.
    public func run(_ mix: [Float]) -> [[Float]] {
        precondition(mix.count == frames * Self.bins * 2)
        let shape: [NSNumber] = [1, NSNumber(value: frames), NSNumber(value: Self.bins), 2]
        let data = MPSGraphTensorData(device: device, data: mix.withUnsafeBufferPointer { Data(buffer: $0) }, shape: shape, dataType: .float32)
        let result = graph.run(with: queue, feeds: [input: data], targetTensors: outputs, targetOperations: nil)
        return outputs.map { t in
            var out = [Float](repeating: 0, count: mix.count)
            result[t]!.mpsndarray().readBytes(&out, strideBytes: nil)
            return out
        }
    }
}
