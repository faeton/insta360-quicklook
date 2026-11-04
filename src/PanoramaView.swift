// A draggable view of an equirectangular panorama. Each pixel is mapped back to a
// position on the sphere in a fragment shader, so the same approach can later take
// live, stitched video instead of a still.
//
// The shader compiles from source at runtime because build.sh has no metallib step.
import AppKit
import Metal
import MetalKit

struct PanoramaCamera {
    var yaw: Float = 0      // radians, positive turns right
    var pitch: Float = 0    // radians, positive looks up
    var fov: Float = 100    // vertical field of view, degrees

    mutating func drag(dx: Float, dy: Float, viewHeight: Float) {
        let perPoint = fov * .pi / 180 / max(viewHeight, 1)
        yaw -= dx * perPoint
        pitch = max(-.pi / 2, min(.pi / 2, pitch - dy * perPoint))
    }

    mutating func zoom(by delta: Float) {
        fov = max(30, min(120, fov - delta))
    }
}

final class PanoramaRenderer {
    private struct Uniforms {
        var yaw: Float, pitch: Float, tanHalfFov: Float, aspect: Float
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float yaw, pitch, tanHalfFov, aspect; };
    struct VertexOut { float4 position [[position]]; float2 ndc; };

    vertex VertexOut panoramaVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2) * 2.0 - 1.0;
        return { float4(p, 0, 1), p };
    }

    fragment float4 panoramaFragment(VertexOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(address::repeat, filter::linear);
        float3 d = normalize(float3(in.ndc.x * u.aspect * u.tanHalfFov,
                                    in.ndc.y * u.tanHalfFov, 1.0));
        float cp = cos(u.pitch), sp = sin(u.pitch);
        d = float3(d.x, d.y * cp + d.z * sp, -d.y * sp + d.z * cp);
        float cy = cos(u.yaw), sy = sin(u.yaw);
        d = float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
        float2 uv = float2(atan2(d.x, d.z) / (2.0 * M_PI_F) + 0.5,
                           0.5 - asin(clamp(d.y, -1.0, 1.0)) / M_PI_F);
        // An explicit level avoids a visible line where the longitude wraps.
        return image.sample(s, uv, level(0));
    }
    """

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let texture: MTLTexture

    init?(image: CGImage, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let vertex = library.makeFunction(name: "panoramaVertex"),
              let fragment = library.makeFunction(name: "panoramaFragment"),
              let texture = try? MTKTextureLoader(device: device).newTexture(
                  cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        else { return nil }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = vertex
        description.fragmentFunction = fragment
        description.colorAttachments[0].pixelFormat = pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: description) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.texture = texture
    }

    func commandBuffer(camera: PanoramaCamera, pass: MTLRenderPassDescriptor, aspect: Float) -> MTLCommandBuffer? {
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }
        var uniforms = Uniforms(yaw: camera.yaw, pitch: camera.pitch,
                                tanHalfFov: tan(camera.fov * .pi / 360), aspect: aspect)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return buffer
    }
}

final class PanoramaView: MTKView, MTKViewDelegate {
    private let renderer: PanoramaRenderer
    private var camera = PanoramaCamera()

    init?(image: CGImage) {
        guard let renderer = PanoramaRenderer(image: image) else { return nil }
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        // Draw only when the view changes, so an idle preview uses no GPU.
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        camera.drag(dx: Float(event.deltaX), dy: -Float(event.deltaY), viewHeight: Float(bounds.height))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        camera.zoom(by: Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.2 : 2))
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable, bounds.height > 0,
              let buffer = renderer.commandBuffer(
                  camera: camera, pass: pass, aspect: Float(bounds.width / bounds.height))
        else { return }
        buffer.present(drawable)
        buffer.commit()
    }
}
