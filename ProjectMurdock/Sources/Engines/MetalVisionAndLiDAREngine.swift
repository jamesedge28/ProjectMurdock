import Foundation
import Metal
import MetalKit
import ARKit
import AVFoundation
import CoreVideo
import Combine

public final class MetalVisionAndLiDAREngine: NSObject, ObservableObject, MTKViewDelegate, ARSessionDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDepthDataOutputDelegate {
    
    // MARK: - Published Properties
    @Published public var isLiDARAvailable: Bool = false
    @Published public var isARKitRunning: Bool = false
    @Published public var currentFPS: Double = 60.0
    @Published public var currentDistanceCenter: Float = 0.0
    @Published public var isTorchActive: Bool = false
    
    // Frame notification closure for Biometric & Lip Reading engines
    public var onFrameCaptured: ((CVPixelBuffer, CVPixelBuffer?) -> Void)?
    
    // MARK: - Metal Core
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private var renderPipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    
    // Metal Textures
    private var currentColorTexture: MTLTexture?
    private var previousColorTexture: MTLTexture?
    private var currentDepthTexture: MTLTexture?
    private var uniformsBuffer: MTLBuffer?
    
    // Uniforms State
    public struct EngineUniforms {
        public var eulerianRect: SIMD4<Float> = .init(0, 0, 0, 0)
        public var resolution: SIMD2<Float> = .init(1920, 1080)
        public var audioEnergy: Float = 0.0
        public var time: Float = 0.0
        public var displayMode: Int32 = 0
        public var eulerianGain: Float = 15.0
        public var penumbralGain: Float = 40.0
        public var depthMaxDistance: Float = 5.0
        public var hasDepthTexture: Int32 = 0
        public var isTorchActive: Int32 = 0
        public var motionThreshold: Float = 0.07
        public var padding: Float = 0.0
    }
    
    public var uniforms = EngineUniforms()
    
    // MARK: - Capture Sessions
    public private(set) var arSession: ARSession?
    public private(set) var avSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.murdock.metal.capture", qos: .userInteractive)
    
    private var startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastFrameTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var frameCounter: Int = 0
    private var fpsTimer: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    
    // MARK: - Initialization
    public override init() {
        guard let defaultDevice = MTLCreateSystemDefaultDevice(),
              let queue = defaultDevice.makeCommandQueue() else {
            fatalError("CRITICAL: Metal is not supported on this iOS device architecture.")
        }
        self.device = defaultDevice
        self.commandQueue = queue
        super.init()
        
        setupTextureCache()
        setupMetalPipeline()
        setupUniformsBuffer()
        
        checkLiDARCapabilities()
    }
    
    private func setupTextureCache() {
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if result == kCVReturnSuccess, let unwrappedCache = cache {
            self.textureCache = unwrappedCache
        }
    }
    
    private func setupMetalPipeline() {
        ensurePipelineReady()
    }
    
    private func ensurePipelineReady() {
        guard renderPipelineState == nil else { return }
        let library = device.makeDefaultLibrary() ?? (try? device.makeDefaultLibrary(bundle: Bundle.main))
        guard let lib = library else { return }
        
        let vertexFunc = lib.makeFunction(name: "vertexShader")
        let fragmentFunc = lib.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "ProjectMurdock.RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            self.renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("[MetalVision] Error compiling pipeline state: \(error.localizedDescription)")
        }
    }
    
    private func setupUniformsBuffer() {
        let bufferSize = MemoryLayout<EngineUniforms>.stride
        self.uniformsBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared])
    }
    
    public func checkLiDARCapabilities() {
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            self.isLiDARAvailable = true
        } else {
            self.isLiDARAvailable = false
        }
    }
    
    // MARK: - Session Control
    public func startEngine() {
        if isLiDARAvailable {
            startARKitSession()
        } else {
            startAVCaptureFallback()
        }
    }
    
    public func stopEngine() {
        arSession?.pause()
        if let av = avSession, av.isRunning {
            av.stopRunning()
        }
        setTorch(enabled: false)
    }
    
    public func startARKitSession() {
        stopAVCapture()
        
        let session = ARSession()
        session.delegate = self
        self.arSession = session
        
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            uniforms.hasDepthTexture = 1
        } else {
            uniforms.hasDepthTexture = 0
        }
        
        configuration.isAutoFocusEnabled = true
        configuration.providesAudioData = false
        
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        self.isARKitRunning = true
    }
    
    public func stopARKitSession() {
        arSession?.pause()
        arSession = nil
        isARKitRunning = false
    }
    
    public func startAVCaptureFallback() {
        stopARKitSession()
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .hd1920x1080
            
            // Prefer wide angle camera with torch support
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                session.commitConfiguration()
                return
            }
            
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(input) { session.addInput(input) }
                
                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
                videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                
                session.commitConfiguration()
                session.startRunning()
                
                DispatchQueue.main.async {
                    self.avSession = session
                    self.isARKitRunning = false
                    self.uniforms.hasDepthTexture = 0
                }
            } catch {
                print("[MetalVision] AVCapture setup failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func stopAVCapture() {
        if let session = avSession, session.isRunning {
            session.stopRunning()
            self.avSession = nil
        }
    }
    
    // MARK: - Torch Control (Modo Hiper-Tacto Óptico)
    public func setTorch(enabled: Bool, level: Float = 1.0) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if enabled {
                try device.setTorchModeOn(level: min(max(level, 0.1), 1.0))
                DispatchQueue.main.async { self.isTorchActive = true }
                uniforms.isTorchActive = 1
            } else {
                device.torchMode = .off
                DispatchQueue.main.async { self.isTorchActive = false }
                uniforms.isTorchActive = 0
            }
            device.unlockForConfiguration()
        } catch {
            print("[MetalVision] Error setting torch: \(error.localizedDescription)")
        }
    }
    
    // MARK: - ARSessionDelegate
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let depthBuffer = frame.sceneDepth?.depthMap
        
        processFrameTextures(colorBuffer: pixelBuffer, depthBuffer: depthBuffer)
        onFrameCaptured?(pixelBuffer, depthBuffer)
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processFrameTextures(colorBuffer: pixelBuffer, depthBuffer: nil)
        onFrameCaptured?(pixelBuffer, nil)
    }
    
    // MARK: - Texture Creation & Double Buffering
    private func processFrameTextures(colorBuffer: CVPixelBuffer, depthBuffer: CVPixelBuffer?) {
        guard let cache = self.textureCache else { return }
        
        // Cycle textures for temporal frame differencing
        self.previousColorTexture = self.currentColorTexture
        
        let width = CVPixelBufferGetWidth(colorBuffer)
        let height = CVPixelBufferGetHeight(colorBuffer)
        let formatType = CVPixelBufferGetPixelFormatType(colorBuffer)
        
        var mtlFormat: MTLPixelFormat = .bgra8Unorm
        if formatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || formatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            mtlFormat = .r8Unorm // Plane 0 luminance
        }
        
        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            colorBuffer,
            nil,
            mtlFormat,
            width,
            height,
            0,
            &cvTextureOut
        )
        
        if status == kCVReturnSuccess, let cvTex = cvTextureOut {
            self.currentColorTexture = CVMetalTextureGetTexture(cvTex)
        }
        
        // Process LiDAR Depth Buffer (Float32 in meters)
        if let depth = depthBuffer {
            let depthWidth = CVPixelBufferGetWidth(depth)
            let depthHeight = CVPixelBufferGetHeight(depth)
            
            var depthCVTextureOut: CVMetalTexture?
            let depthStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                depth,
                nil,
                .r32Float,
                depthWidth,
                depthHeight,
                0,
                &depthCVTextureOut
            )
            
            if depthStatus == kCVReturnSuccess, let dcvTex = depthCVTextureOut {
                self.currentDepthTexture = CVMetalTextureGetTexture(dcvTex)
                self.uniforms.hasDepthTexture = 1
                
                // Read center distance telemetry
                CVPixelBufferLockBaseAddress(depth, .readOnly)
                if let baseAddress = CVPixelBufferGetBaseAddress(depth) {
                    let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
                    let centerIndex = (depthHeight / 2) * depthWidth + (depthWidth / 2)
                    let centerDist = floatBuffer[centerIndex]
                    DispatchQueue.main.async {
                        self.currentDistanceCenter = centerDist
                    }
                }
                CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            }
        } else {
            self.uniforms.hasDepthTexture = 0
        }
    }
    
    // MARK: - MTKViewDelegate (60 FPS Render Loop)
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.resolution = SIMD2<Float>(Float(size.width), Float(size.height))
    }
    
    public func draw(in view: MTKView) {
        ensurePipelineReady()
        
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let pipelineState = self.renderPipelineState,
              let colorTex = self.currentColorTexture else {
            return
        }
        
        // Update FPS & Time
        let now = CFAbsoluteTimeGetCurrent()
        uniforms.time = Float(now - startTime)
        frameCounter += 1
        if now - fpsTimer >= 1.0 {
            let fps = Double(frameCounter) / (now - fpsTimer)
            DispatchQueue.main.async { self.currentFPS = fps }
            frameCounter = 0
            fpsTimer = now
        }
        
        // Copy uniforms to Metal Buffer
        if let buffer = self.uniformsBuffer {
            let contents = buffer.contents().bindMemory(to: EngineUniforms.self, capacity: 1)
            contents.pointee = uniforms
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Bind Textures
        renderEncoder.setFragmentTexture(colorTex, index: 0)
        renderEncoder.setFragmentTexture(previousColorTexture ?? colorTex, index: 1)
        if let depthTex = self.currentDepthTexture, uniforms.hasDepthTexture == 1 {
            renderEncoder.setFragmentTexture(depthTex, index: 2)
        } else {
            renderEncoder.setFragmentTexture(colorTex, index: 2)
        }
        
        // Bind Uniforms
        renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        
        // Draw fullscreen quad (4 vertices)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
