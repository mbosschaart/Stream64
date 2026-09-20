import SwiftUI
import MetalKit

/// One colour mapping for native Metal scenes and SwiftUI instruments.
/// Quantise after feedback, so Echo Tunnel still fades smoothly internally.
enum SIDVisualizationPalette {
    private static func resource(_ extensionName: String) -> URL {
        (Bundle.main.url(forResource: "SIDVisualizationPalette", withExtension: extensionName)
            ?? (ResourceBundle.isPackagedApp ? nil : Bundle.module.url(
                forResource: "SIDVisualizationPalette", withExtension: extensionName)))!
    }
    static let libraryURL = resource("metallib")
    static let colorEffect = ShaderLibrary(url: libraryURL).sidC64ColorEffect()
    static let source = try! String(contentsOf: resource("metal"), encoding: .utf8)
}

final class SIDVisualizationPalettePass {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private static let lock = NSLock()
    private static var pipelines: [UInt64: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let cached = Self.pipelines[device.registryID] {
            pipeline = cached
        } else {
            let library = try device.makeLibrary(URL: SIDVisualizationPalette.libraryURL)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "sidPaletteVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "sidPaletteFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            Self.pipelines[device.registryID] = pipeline
        }
    }

    func sourceTexture(width: Int, height: Int) -> MTLTexture? {
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
        }
        return texture
    }

    func encode(command: MTLCommandBuffer, source: MTLTexture, target: MTLTexture) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}
