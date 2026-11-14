import SwiftUI
import MetalKit

public struct MetalViewRepresentable: UIViewRepresentable {
    
    @ObservedObject var engine: MetalVisionAndLiDAREngine
    
    public init(engine: MetalVisionAndLiDAREngine) {
        self.engine = engine
    }
    
    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = engine.device
        mtkView.delegate = engine
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.contentMode = .scaleAspectFill
        return mtkView
    }
    
    public func updateUIView(_ uiView: MTKView, context: Context) {
        // Redraw is handled automatically by MTKView at 60 FPS
    }
}
