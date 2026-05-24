//
//  FITSImageView.swift
//  AstrophotoKit
//
//  Created by Dieudonné Willems on 31/12/2025.
//

import SwiftUI
import Metal
import MetalKit
import os
import AppKit

/// Display mode for FITS images
public enum FITSImageDisplayMode {
    case normal
    case inverse
}

/// Custom MTKView that handles mouse tracking
class FITSMTKView: MTKView {
    weak var renderer: FITSImageRenderer?
    
    override func resetCursorRects() {
        super.resetCursorRects()
        // Set crosshair cursor for the entire view
        addCursorRect(bounds, cursor: .crosshair)
    }
    
    override func mouseMoved(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let viewSize = bounds.size
        
        // Check if mouse is within view bounds
        if locationInView.x >= 0 && locationInView.x <= viewSize.width &&
           locationInView.y >= 0 && locationInView.y <= viewSize.height {
            // Convert to normalized coordinates matching the pan handler
            // macOS view coordinates: (0,0) at bottom-left, but pan handler uses gesture coords (y=0 at top)
            // The pan handler uses: normalizedY = 1.0 - (viewY / viewHeight) * 2.0
            // To match: convert from macOS coords (y=0 at bottom) to gesture-like coords (y=0 at top)
            let gestureY = viewSize.height - locationInView.y
            let normalizedX = (Float(locationInView.x) / Float(viewSize.width)) * 2.0 - 1.0
            let normalizedY = 1.0 - (Float(gestureY) / Float(viewSize.height)) * 2.0
            let cursorPos = SIMD2<Float>(normalizedX, normalizedY)
            renderer?.cursorPosition = cursorPos
            renderer?.onCursorPositionChanged?(cursorPos)
            needsDisplay = true
        } else {
            renderer?.cursorPosition = nil
            renderer?.onCursorPositionChanged?(nil)
            needsDisplay = true
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        renderer?.cursorPosition = nil
        renderer?.onCursorPositionChanged?(nil)
        needsDisplay = true
    }
    
    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let viewSize = bounds.size
        
        // Check if mouse is within view bounds
        if locationInView.x >= 0 && locationInView.x <= viewSize.width &&
           locationInView.y >= 0 && locationInView.y <= viewSize.height {
            // Convert to normalized coordinates matching the pan handler
            // macOS view coordinates: (0,0) at bottom-left, but pan handler uses gesture coords (y=0 at top)
            // The pan handler uses: normalizedY = 1.0 - (viewY / viewHeight) * 2.0
            // To match: convert from macOS coords (y=0 at bottom) to gesture-like coords (y=0 at top)
            let gestureY = viewSize.height - locationInView.y
            let normalizedX = (Float(locationInView.x) / Float(viewSize.width)) * 2.0 - 1.0
            let normalizedY = 1.0 - (Float(gestureY) / Float(viewSize.height)) * 2.0
            let clickPos = SIMD2<Float>(normalizedX, normalizedY)
            renderer?.onClick?(clickPos)
        }
    }
}

/// Metal renderer for displaying FITS images
public class FITSImageRenderer: NSObject, MTKViewDelegate {
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var normalPipelineState: MTLRenderPipelineState!
    var inversePipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var texture: MTLTexture?
    var displayMode: FITSImageDisplayMode = .normal
    var zoom: Float = 1.0
    var panOffset: SIMD2<Float> = SIMD2<Float>(0, 0)
    var previousZoom: Float = 1.0
    var onZoomChanged: ((Float) -> Void)?
    var onPanChanged: ((SIMD2<Float>) -> Void)?
    var onCursorPositionChanged: ((SIMD2<Float>?) -> Void)?  // Normalized coordinates (-1 to 1)
    var onAspectRatioChanged: ((SIMD2<Float>) -> Void)?
    var onClick: ((SIMD2<Float>) -> Void)?  // Normalized coordinates (-1 to 1) on click
    weak var mtkView: MTKView?
    
    // Track world position for cursor-locked pan/zoom
    var panStartWorldPos: SIMD2<Float>?
    
    // Track cursor position in normalized coordinates
    var cursorPosition: SIMD2<Float>? = nil
    
    // Track tracking area for mouse events
    var trackingArea: NSTrackingArea?
    
    // Image dimensions for aspect ratio calculation
    var imageWidth: Int = 1
    var imageHeight: Int = 1
    var aspectRatio: SIMD2<Float> = SIMD2<Float>(1.0, 1.0)
    
    // Black and white point adjustments (in original pixel value range)
    var originalMinValue: Float = 0.0
    var originalMaxValue: Float = 1.0
    var blackPoint: Float = 0.0  // In original pixel value range
    var whitePoint: Float = 1.0  // In original pixel value range

    // Full-screen quad vertices
    let vertices: [Float] = [
        // Position (x, y)    Texture (u, v)
        -1.0, -1.0, 0.0, 1.0,  // Bottom-left
        1.0, -1.0, 1.0, 1.0,  // Bottom-right
        -1.0, 1.0, 0.0, 0.0,  // Top-left
        1.0, 1.0, 1.0, 0.0   // Top-right
    ]

    public override init() {
        super.init()
        setupMetal()
    }

    func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Could not create command queue")
        }
        self.commandQueue = commandQueue

        setupRenderPipeline()
        setupVertexBuffer()
        setupUniformBuffer()
    }
    
    func setupUniformBuffer() {
        // Create buffer for uniforms - use a struct to ensure proper alignment
        // Metal aligns structs to 8-byte boundaries, so we need 40 bytes total
        // 3x SIMD2<Float> (24 bytes) + padding (4 bytes) + 3x Float (12 bytes) = 40 bytes
        struct Uniforms {
            var scale: SIMD2<Float>        // 8 bytes, offset 0
            var offset: SIMD2<Float>      // 8 bytes, offset 8
            var aspectRatio: SIMD2<Float>  // 8 bytes, offset 16
            var _padding: Float            // 4 bytes padding, offset 24
            var blackPoint: Float          // 4 bytes, offset 28
            var whitePoint: Float          // 4 bytes, offset 32
            var isGrayscale: Float         // 4 bytes, offset 36
        }
        let uniformSize = MemoryLayout<Uniforms>.size
        uniformBuffer = device.makeBuffer(length: uniformSize, options: [])
        updateUniforms()
    }
    
    func updateUniforms() {
        guard let uniformBuffer = uniformBuffer, let view = mtkView else { return }
        
        // Define struct matching Metal shader struct for proper alignment
        // Metal aligns structs to 8-byte boundaries, so we need padding
        struct Uniforms {
            var scale: SIMD2<Float>        // 8 bytes, offset 0
            var offset: SIMD2<Float>      // 8 bytes, offset 8
            var aspectRatio: SIMD2<Float>  // 8 bytes, offset 16
            var _padding: Float            // 4 bytes padding, offset 24
            var blackPoint: Float          // 4 bytes, offset 28
            var whitePoint: Float        // 4 bytes, offset 32
            var isGrayscale: Float         // 4 bytes, offset 36
        }
        
        let scale = SIMD2<Float>(zoom, zoom)
        let offset = panOffset
        
        // Calculate aspect ratio correction to keep pixels square
        let viewSize = view.bounds.size
        let aspectRatio: SIMD2<Float>
        if viewSize.width > 0 && viewSize.height > 0 && imageWidth > 0 && imageHeight > 0 {
            let imageAspect = Float(imageWidth) / Float(imageHeight)
            let viewAspect = Float(viewSize.width) / Float(viewSize.height)
            
            // Calculate aspect ratio correction
            // If view is wider than image aspect, we need to scale down X
            // If view is taller than image aspect, we need to scale down Y
            if viewAspect > imageAspect {
                // View is wider - scale down X to fit
                aspectRatio = SIMD2<Float>(imageAspect / viewAspect, 1.0)
            } else {
                // View is taller - scale down Y to fit
                aspectRatio = SIMD2<Float>(1.0, viewAspect / imageAspect)
            }
        } else {
            // Fallback if dimensions are invalid
            aspectRatio = SIMD2<Float>(1.0, 1.0)
        }
        
        // Convert black/white points from original range to normalized (0-1)
        let range = originalMaxValue - originalMinValue
        let normalizedBlackPoint: Float
        let normalizedWhitePoint: Float
        if range > 0 {
            normalizedBlackPoint = (blackPoint - originalMinValue) / range
            normalizedWhitePoint = (whitePoint - originalMinValue) / range
        } else {
            normalizedBlackPoint = 0.0
            normalizedWhitePoint = 1.0
        }
        
        // Determine if texture is grayscale based on pixel format
        let isGrayscale: Float = (texture?.pixelFormat == .r32Float) ? 1.0 : 0.0
        
        // Write entire struct at once to ensure proper alignment
        let uniforms = Uniforms(
            scale: scale,
            offset: offset,
            aspectRatio: aspectRatio,
            _padding: 0.0,  // Padding to match Metal alignment
            blackPoint: normalizedBlackPoint,
            whitePoint: normalizedWhitePoint,
            isGrayscale: isGrayscale
        )
        
        let pointer = uniformBuffer.contents().bindMemory(to: Uniforms.self, capacity: 1)
        pointer[0] = uniforms
        
        // Store aspect ratio for use by rulers
        self.aspectRatio = aspectRatio
        onAspectRatioChanged?(aspectRatio)
    }
    
    func setZoom(_ newZoom: Float, zoomCenter: SIMD2<Float>? = nil) {
        let oldZoom = zoom
        let clampedZoom = max(0.1, min(10.0, newZoom)) // Clamp between 0.1x and 10x
        
        if let center = zoomCenter, oldZoom > 0 {
            // Zoom around a specific point (e.g., cursor position)
            // The transform is: screenPos = worldPos * zoom + panOffset
            // So: worldPos = (screenPos - panOffset) / zoom
            let normalizedX = center.x
            let normalizedY = center.y
            
            // Calculate the world position at the cursor before zoom
            // Note: panOffset.y is stored inverted, so we use -panOffset.y when calculating world position
            let worldX = (normalizedX - panOffset.x) / oldZoom
            let worldY = (normalizedY - (-panOffset.y)) / oldZoom
            
            // Set new zoom
            zoom = clampedZoom
            
            // Adjust pan to keep the same world point under the cursor
            // screenPos = worldPos * zoom + panOffset
            // So: panOffset = screenPos - worldPos * zoom
            panOffset.x = normalizedX - worldX * zoom
            // Store panOffset.y inverted
            panOffset.y = -(normalizedY - worldY * zoom)
        } else {
            // Zoom from center of viewport (for slider)
            // The center of the viewport in normalized coordinates is (0, 0)
            // Use exactly the same logic as cursor zoom but with center point (0, 0)
            if oldZoom > 0 {
                let normalizedX: Float = 0.0
                let normalizedY: Float = 0.0
                
                // Calculate the world position at the center before zoom
                // Transform: screenPos = worldPos * zoom + panOffset
                // So: worldPos = (screenPos - panOffset) / zoom
                // Note: panOffset.y is stored inverted, so we use -panOffset.y when calculating world position
                let worldX = (normalizedX - panOffset.x) / oldZoom
                let worldY = (normalizedY - (-panOffset.y)) / oldZoom
                
                // Set new zoom
                zoom = clampedZoom
                
                // Adjust pan to keep the same world point at the center
                // screenPos = worldPos * zoom + panOffset
                // So: panOffset = screenPos - worldPos * zoom
                panOffset.x = normalizedX - worldX * zoom
                // Store panOffset.y inverted
                panOffset.y = -(normalizedY - worldY * zoom)
            } else {
                zoom = clampedZoom
            }
        }
        
        updateUniforms()
        onZoomChanged?(zoom)
        mtkView?.needsDisplay = true
    }
    
    func setPanOffset(_ offset: SIMD2<Float>) {
        panOffset = offset
        updateUniforms()
        onPanChanged?(panOffset)
        mtkView?.needsDisplay = true
    }
    
    func updateAspectRatio() {
        updateUniforms()
        mtkView?.needsDisplay = true
    }
    
    func resetZoomAndPan() {
        zoom = 1.0
        panOffset = SIMD2<Float>(0, 0)
        updateUniforms()
        mtkView?.needsDisplay = true
    }

    @objc func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        guard let view = gesture.view else { return }
        let magnification = Float(gesture.magnification)
        let newZoom = zoom * (1.0 + magnification)
        
        // Get the point where the user is zooming (in view coordinates)
        let locationInView = gesture.location(in: view)
        let viewSize = view.bounds.size
        let normalizedX = (Float(locationInView.x) / Float(viewSize.width)) * 2.0 - 1.0
        let normalizedY = 1.0 - (Float(locationInView.y) / Float(viewSize.height)) * 2.0 // Flip Y
        
        // Zoom around the cursor position
        setZoom(newZoom, zoomCenter: SIMD2<Float>(normalizedX, normalizedY))
        onPanChanged?(panOffset)
        
        gesture.magnification = 0 // Reset for incremental zooming
    }

    @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let locationInView = gesture.location(in: view)
        let viewSize = view.bounds.size
        let normalizedX = (Float(locationInView.x) / Float(viewSize.width)) * 2.0 - 1.0
        // Flip Y: view coordinates have y=0 at top, NDC has y=-1 at bottom
        // So: y=0 (top) -> normalizedY=1, y=height (bottom) -> normalizedY=-1
        let normalizedY = 1.0 - (Float(locationInView.y) / Float(viewSize.height)) * 2.0
        
        switch gesture.state {
        case .began:
            // Calculate the world position under the cursor at the start of the drag
            // The transform is: screenPos = worldPos * zoom + panOffset
            // So: worldPos = (screenPos - panOffset) / zoom
            // Note: panOffset.y is inverted, so we need to account for that
            panStartWorldPos = SIMD2<Float>(
                (normalizedX - panOffset.x) / zoom,
                (normalizedY - (-panOffset.y)) / zoom
            )
            
        case .changed:
            // Keep the same world position under the cursor
            // screenPos = worldPos * zoom + panOffset
            // So: panOffset = screenPos - worldPos * zoom
            if let worldPos = panStartWorldPos {
                panOffset.x = normalizedX - worldPos.x * zoom
                // Invert Y to fix vertical pan direction (drag up = image moves up)
                panOffset.y = -(normalizedY - worldPos.y * zoom)
                updateUniforms()
                onPanChanged?(panOffset)
                mtkView?.needsDisplay = true
            }
            
        case .ended, .cancelled:
            panStartWorldPos = nil
            
        default:
            break
        }
    }

    func setupRenderPipeline() {
        // Use the helper function from AstrophotoKit to load the Metal library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            fatalError("Could not create Metal library. Make sure Metal shaders are compiled. " +
                      "If using as a Swift package, you may need to add the Metal shader files to your app target.")
        }

        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let normalFragmentFunction = library.makeFunction(name: "fragment_main"),
              let inverseFragmentFunction = library.makeFunction(name: "fragment_inverse") else {
            // Provide helpful error message
            let availableFunctions = library.functionNames
            fatalError("Could not load shader functions. Available functions: \(availableFunctions)")
        }

        // Create vertex descriptor matching the shader input
        let vertexDescriptor = MTLVertexDescriptor()
        // Position attribute (attribute 0): float2 at offset 0
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        // Texture coordinate attribute (attribute 1): float2 at offset 8 (2 floats * 4 bytes)
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = 8
        vertexDescriptor.attributes[1].bufferIndex = 0
        // Stride: 4 floats * 4 bytes = 16 bytes
        vertexDescriptor.layouts[0].stride = 16
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        // Create normal pipeline
        let normalPipelineDescriptor = MTLRenderPipelineDescriptor()
        normalPipelineDescriptor.vertexFunction = vertexFunction
        normalPipelineDescriptor.fragmentFunction = normalFragmentFunction
        normalPipelineDescriptor.vertexDescriptor = vertexDescriptor
        normalPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        normalPipelineDescriptor.colorAttachments[0].isBlendingEnabled = false

        // Create inverse pipeline
        let inversePipelineDescriptor = MTLRenderPipelineDescriptor()
        inversePipelineDescriptor.vertexFunction = vertexFunction
        inversePipelineDescriptor.fragmentFunction = inverseFragmentFunction
        inversePipelineDescriptor.vertexDescriptor = vertexDescriptor
        inversePipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        inversePipelineDescriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            normalPipelineState = try device.makeRenderPipelineState(descriptor: normalPipelineDescriptor)
            inversePipelineState = try device.makeRenderPipelineState(descriptor: inversePipelineDescriptor)
        } catch {
            fatalError("Could not create render pipeline state: \(error)")
        }
    }

    func setupVertexBuffer() {
        let vertexDataSize = vertices.count * MemoryLayout<Float>.size
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexDataSize, options: [])
    }

    func loadFITSImage(_ fitsImage: FITSImage) {
        do {
            // Keep texture as grayscale for memory efficiency - shader handles both formats
            texture = try fitsImage.createMetalTexture(device: device, pixelFormat: .r32Float)
            imageWidth = fitsImage.width
            imageHeight = fitsImage.height
            originalMinValue = fitsImage.originalMinValue
            originalMaxValue = fitsImage.originalMaxValue
            // Initialize black/white points to full range
            blackPoint = originalMinValue
            whitePoint = originalMaxValue
            updateUniforms()
            // Trigger a redraw - MTKView will automatically redraw on next frame
            // Since isPaused = false, it will render continuously
            if let view = mtkView {
                view.needsDisplay = true
            }
        } catch {
            Logger.ui.error("Error creating Metal texture from FITS image: \(error)")
        }
    }
    
    /// Load a Metal texture directly (for pipeline results)
    /// Accepts both grayscale (r32Float) and RGBA (rgba32Float) textures
    /// The shader handles both formats automatically
    func loadTexture(_ texture: MTLTexture, originalMinValue: Float = 0.0, originalMaxValue: Float = 1.0) {
        // Use texture directly - shader handles both grayscale and RGBA formats
        self.texture = texture
        self.imageWidth = texture.width
        self.imageHeight = texture.height
        self.originalMinValue = originalMinValue
        self.originalMaxValue = originalMaxValue
        // Initialize black/white points to full range
        self.blackPoint = originalMinValue
        self.whitePoint = originalMaxValue
        updateUniforms()
        // Trigger a redraw
        if let view = mtkView {
            view.needsDisplay = true
        }
    }
    
    func setBlackPoint(_ value: Float) {
        blackPoint = max(originalMinValue, min(value, whitePoint))
        updateUniforms()
        mtkView?.needsDisplay = true
    }
    
    func setWhitePoint(_ value: Float) {
        whitePoint = max(blackPoint, min(value, originalMaxValue))
        updateUniforms()
        mtkView?.needsDisplay = true
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Update uniforms when view size changes to recalculate aspect ratio
        updateUniforms()
    }

    public func setDisplayMode(_ mode: FITSImageDisplayMode) {
        displayMode = mode
        mtkView?.needsDisplay = true
    }

    public func draw(in view: MTKView) {
        guard let texture = texture,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        // Set background color to system background (lighter dark grey for dark mode)
        // macOS dark mode uses approximately RGB(0.22, 0.22, 0.24) for content areas
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.22,
            green: 0.22,
            blue: 0.24,
            alpha: 1.0
        )
        renderPassDescriptor.colorAttachments[0].loadAction = .clear

        let renderPipelineState = displayMode == .normal ? normalPipelineState : inversePipelineState
        guard let pipelineState = renderPipelineState else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentTexture(texture, index: 0)

        // Draw the full-screen quad
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// SwiftUI wrapper for Metal view
public struct FITSImageView: NSViewRepresentable {
    let fitsImage: FITSImage?
    let texture: MTLTexture?
    let textureMinValue: Float
    let textureMaxValue: Float
    let displayMode: FITSImageDisplayMode
    @Binding var zoom: Float
    @Binding var panOffset: SIMD2<Float>
    @Binding var blackPoint: Float
    @Binding var whitePoint: Float
    @Binding var cursorPosition: SIMD2<Float>?
    @Binding var aspectRatio: SIMD2<Float>
    let onClick: ((SIMD2<Float>) -> Void)?
    let isInteractive: Bool

    public init(fitsImage: FITSImage? = nil, texture: MTLTexture? = nil, textureMinValue: Float = 0.0, textureMaxValue: Float = 1.0, displayMode: FITSImageDisplayMode = .normal, zoom: Binding<Float> = .constant(1.0), panOffset: Binding<SIMD2<Float>> = .constant(SIMD2<Float>(0, 0)), blackPoint: Binding<Float> = .constant(0.0), whitePoint: Binding<Float> = .constant(1.0), cursorPosition: Binding<SIMD2<Float>?> = .constant(nil), aspectRatio: Binding<SIMD2<Float>> = .constant(SIMD2<Float>(1.0, 1.0)), onClick: ((SIMD2<Float>) -> Void)? = nil, isInteractive: Bool = true) {
        self.fitsImage = fitsImage
        self.texture = texture
        self.textureMinValue = textureMinValue
        self.textureMaxValue = textureMaxValue
        self.displayMode = displayMode
        self._zoom = zoom
        self._panOffset = panOffset
        self._blackPoint = blackPoint
        self._whitePoint = whitePoint
        self._cursorPosition = cursorPosition
        self._aspectRatio = aspectRatio
        self.onClick = onClick
        self.isInteractive = isInteractive
    }

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = FITSMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.renderer = context.coordinator
        context.coordinator.mtkView = mtkView
        mtkView.delegate = context.coordinator
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = false
        mtkView.framebufferOnly = false
        // Set background to match system background (lighter dark grey)
        // Use a lighter grey that matches content areas in dark mode
        mtkView.layer?.backgroundColor = NSColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1.0).cgColor
        mtkView.layer?.isOpaque = true
        mtkView.clearColor = MTLClearColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)

        // Set up callbacks to update bindings (defer to avoid modifying state during view update)
        context.coordinator.onZoomChanged = { newZoom in
            DispatchQueue.main.async {
                zoom = newZoom
            }
        }
        context.coordinator.onPanChanged = { newOffset in
            DispatchQueue.main.async {
                panOffset = newOffset
            }
        }
        context.coordinator.onCursorPositionChanged = { newPosition in
            DispatchQueue.main.async {
                cursorPosition = newPosition
            }
        }
        context.coordinator.onAspectRatioChanged = { newAspectRatio in
            DispatchQueue.main.async {
                aspectRatio = newAspectRatio
            }
        }
        context.coordinator.onClick = onClick

        // Add gesture recognizers for zoom and pan only if interactive
        if isInteractive {
            let magnificationGesture = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(FITSImageRenderer.handleMagnification(_:)))
            mtkView.addGestureRecognizer(magnificationGesture)

            let panGesture = NSPanGestureRecognizer(target: context.coordinator, action: #selector(FITSImageRenderer.handlePan(_:)))
            mtkView.addGestureRecognizer(panGesture)
        }
        
        // Add mouse tracking for cursor position only if interactive
        if isInteractive {
            updateTrackingArea(for: mtkView, coordinator: context.coordinator)
        }

        if let texture = texture {
            context.coordinator.loadTexture(texture, originalMinValue: textureMinValue, originalMaxValue: textureMaxValue)
        } else if let fitsImage = fitsImage {
            context.coordinator.loadFITSImage(fitsImage)
        }

        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        if let texture = texture {
            context.coordinator.loadTexture(texture, originalMinValue: textureMinValue, originalMaxValue: textureMaxValue)
        } else if let fitsImage = fitsImage {
            context.coordinator.loadFITSImage(fitsImage)
        }
        context.coordinator.setDisplayMode(displayMode)
        // Update aspect ratio when view size changes
        context.coordinator.updateAspectRatio()
        // Update tracking area if view size changed and interactive
        if isInteractive {
            updateTrackingArea(for: nsView, coordinator: context.coordinator)
        }
        // setZoom may update panOffset internally (for center zoom), so call it first
        // Then only update panOffset if it hasn't been changed by setZoom
        let oldPanOffset = context.coordinator.panOffset
        context.coordinator.setZoom(zoom)
        // Only update pan offset if it wasn't changed by setZoom (i.e., for cursor zoom or manual pan)
        // For slider zoom (center zoom), setZoom already updated the pan offset correctly
        if context.coordinator.panOffset == oldPanOffset {
            context.coordinator.setPanOffset(panOffset)
        } else {
            // setZoom updated panOffset, so sync it back to the binding
            panOffset = context.coordinator.panOffset
        }
        context.coordinator.setBlackPoint(blackPoint)
        context.coordinator.setWhitePoint(whitePoint)
        // Sync cursor position
        if context.coordinator.cursorPosition != cursorPosition {
            context.coordinator.cursorPosition = cursorPosition
        }
        // Update onClick callback
        context.coordinator.onClick = onClick
    }
    
    private func updateTrackingArea(for view: MTKView, coordinator: FITSImageRenderer) {
        // Remove old tracking area if it exists
        if let oldTrackingArea = coordinator.trackingArea {
            view.removeTrackingArea(oldTrackingArea)
        }
        
        // Create new tracking area - owner is the view itself since it's a responder
        let newTrackingArea = NSTrackingArea(
            rect: view.bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: view,
            userInfo: nil
        )
        view.addTrackingArea(newTrackingArea)
        coordinator.trackingArea = newTrackingArea
    }

    public func makeCoordinator() -> FITSImageRenderer {
        FITSImageRenderer()
    }
}

