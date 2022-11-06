//
//  MulticolorGradientViewController.swift
//  
//
//  Created by Arthur Guibert on 31/10/2022.
//

import UIKit
import MetalKit
import SwiftUI

struct CompilerErrorMessage {
    let lineNumber: Int
    let columnNumber: Int
    let error: String
    let message: String
}

struct Uniforms {
    let pointCount: simd_int1
    
    let bias: simd_float1
    let power: simd_float1
    
    let point0: simd_float2
    let point1: simd_float2
    let point2: simd_float2
    let point3: simd_float2
    let point4: simd_float2
    let point5: simd_float2
    let point6: simd_float2
    let point7: simd_float2
    
    let color0: simd_float3
    let color1: simd_float3
    let color2: simd_float3
    let color3: simd_float3
    let color4: simd_float3
    let color5: simd_float3
    let color6: simd_float3
    let color7: simd_float3
}

public class MulticolorGradientViewController: UIViewController, MTKViewDelegate {
    var mtkView: MTKView!
    var computePipelineState: MTLComputePipelineState?
    var commandQueue: MTLCommandQueue! = nil

    struct GradientParameters {
        var points: [ColorStop] = []
        var bias: Float = 0.001
        var power: Float = 2
    }
    var colorInterpolation: MulticolorGradient.ColorInterpolation = .rgb
    var current: GradientParameters = .init()
    var nextGradient: GradientParameters?
    
    var duration: TimeInterval?
    var elapsed: TimeInterval = 0.0
    var timeDirection: Double = 1
    var repeatForever: Bool = false
    var previousFrameTime: Date = .init()
    
    var finishedCompiling: ((Bool, [CompilerErrorMessage]?) -> ())?
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        let mtkView = MTKView()
        view.addSubview(mtkView)
        mtkView.frame = view.bounds
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Select the device to render with.  We choose the default device
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return
        }
        
        mtkView.device = defaultDevice
        mtkView.delegate = self
        mtkView.preferredFramesPerSecond = 60
        mtkView.device = defaultDevice
        mtkView.framebufferOnly = false
        
        //start paused
        mtkView.isPaused = false
        
        if setComputePipeline(device: defaultDevice) == nil {
            fatalError("Default fragment shader has problem compiling")
        }
        
        commandQueue = defaultDevice.makeCommandQueue()
    }
    
    public func setComputePipeline(device: MTLDevice) -> MTLComputePipelineState? {
        if let computeProgram = loadShaders(device: device) {
            computePipelineState = try? device.makeComputePipelineState(function: computeProgram)
            
            return computePipelineState
        }
        
        return nil
    }
    
    fileprivate func loadShaders(device: MTLDevice) -> MTLFunction? {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module)
              else { fatalError("Unable to create default library") }
        let computeProgram = library.makeFunction(name: "gradient")
        
        if let onCompilerResult = finishedCompiling {
            onCompilerResult(true, nil)
        }
        
        return computeProgram
    }
    
    func animate(to parameters: GradientParameters, animation: MirrorAnimation) {
        current = computeParameters()
        nextGradient = parameters
        duration = animation.duration
        timeDirection = 1.0
        repeatForever = animation.repeatAnimation != nil && animation.repeatAnimation!.count == nil
        elapsed = -animation.delay
    }
    
    public func mtkView(_ view: MTKView,
                 drawableSizeWillChange size: CGSize) {
        
    }
    
    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        
        let timeStep = Date().timeIntervalSince(previousFrameTime)
        previousFrameTime = Date()
        
        updateAnimationIfNeeded(timeStep)
        draw(with: computeParameters(), in: drawable)
    }
    
    func draw(with parameters: GradientParameters, in drawable: CAMetalDrawable) {
        var shaderPoints: [(simd_float2, simd_float3)] = Array(repeating: (simd_float2(0.0, 0.0), simd_float3(0.0, 0.0, 0.0)),
                                                               count: 8)
        
        for i in 0..<parameters.points.count {
            let point = parameters.points[i]
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            
            guard UIColor(point.color).getRed(&r, green: &g, blue: &b, alpha: nil) else {
                continue
            }
            
            shaderPoints[i] = (simd_float2(Float(point.position.x), Float(point.position.y)), simd_float3(Float(r), Float(g), Float(b)))
        }
        
        var uniforms = Uniforms(pointCount: simd_int1(parameters.points.count),
                                bias: parameters.bias,
                                power: parameters.power,
                                point0: shaderPoints[0].0,
                                point1: shaderPoints[1].0,
                                point2: shaderPoints[2].0,
                                point3: shaderPoints[3].0,
                                point4: shaderPoints[4].0,
                                point5: shaderPoints[5].0,
                                point6: shaderPoints[6].0,
                                point7: shaderPoints[7].0,
                                color0: shaderPoints[0].1,
                                color1: shaderPoints[1].1,
                                color2: shaderPoints[2].1,
                                color3: shaderPoints[3].1,
                                color4: shaderPoints[4].1,
                                color5: shaderPoints[5].1,
                                color6: shaderPoints[6].1,
                                color7: shaderPoints[7].1)
        
        let commandBuffer = commandQueue.makeCommandBuffer()
        let computeEncoder = commandBuffer?.makeComputeCommandEncoder()
        computeEncoder?.setComputePipelineState(computePipelineState!)
        computeEncoder?.setBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        computeEncoder?.setTexture(drawable.texture, index: 4)
        
        let threadGroupCount = MTLSizeMake(8, 8, 1)
        let threadGroups = MTLSizeMake(drawable.texture.width / threadGroupCount.width,
                                       drawable.texture.height / threadGroupCount.height,
                                       1)
        
        computeEncoder?.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupCount)
        computeEncoder?.endEncoding()
        
        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }
    
    func parseCompilerOutput(_ compilerOutput: String) -> [CompilerErrorMessage] {
        let components = compilerOutput.components(separatedBy: "program_source")
        var outMessages = [CompilerErrorMessage]()
        
        for index in components.indices.dropFirst() {
            let splitted = components[index].split(separator: ":")
            
            if splitted.count < 4 {
                return outMessages
            }
            
            if let line: Int = Int(splitted[0]),
               let column: Int = Int(splitted[1]) {
                let compilerMessage = CompilerErrorMessage(lineNumber: line, columnNumber: column, error: String(splitted[2]), message: String(splitted[3]))
                
                outMessages.append(compilerMessage)
            }
        }
        
        return outMessages
    }
}

private extension MulticolorGradientViewController {
    func updateAnimationIfNeeded(_ timeStep: TimeInterval) {
        guard let duration, let nextGradient else {
            return
        }
        
        elapsed += timeStep * timeDirection
        
        if elapsed < 0 {
            elapsed = 0
            timeDirection = 1.0
        }
        
        if elapsed > duration {
            if repeatForever {
                timeDirection = -1.0
                elapsed = duration
            } else {
                current = nextGradient
                self.duration = nil
                self.nextGradient = nil
            }
        }
    }
    
    func computeParameters() -> GradientParameters {
        if let duration, let nextGradient, elapsed >= 0 {
            var parameters: GradientParameters = .init()
            let mappedTime = elapsed / duration
            parameters.power = current.power + (nextGradient.power - current.power) * Float(mappedTime)
            parameters.bias = current.bias + (nextGradient.bias - current.bias) * Float(mappedTime)
            
            for i in 0..<nextGradient.points.count {
                let position = current.points[i].position.lerp(to: nextGradient.points[i].position, t: mappedTime)
                let p: ColorStop
                if colorInterpolation == .rgb {
                    p = ColorStop(position: position,
                                      color: current.points[i].color.lerp(to: nextGradient.points[i].color, t: mappedTime))
                } else {
                    p = ColorStop(position: position,
                                      color: current.points[i].color.lerpHSB(to: nextGradient.points[i].color, t: mappedTime))
                }
                parameters.points.append(p)
            }
            
            return parameters
        } else {
            return current
        }
    }
}

extension UnitPoint {
    func lerp(to: UnitPoint, t: Double) -> UnitPoint {
        return UnitPoint(x: x + (to.x - x) * t, y: y + (to.y - y) * t)
    }
}

extension Color {
    func lerp(to: Color, t: Double) -> Color {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        
        let uiColor2 = UIColor(to)
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        uiColor2.getRed(&r2, green: &g2, blue: &b2, alpha: nil)
        
        return Color(red: r + (r2 - r) * t,
                     green: g + (g2 - g) * t,
                     blue: b + (b2 - b) * t)
    }
    
    func lerpHSB(to: Color, t: Double) -> Color {
        let uiColor = UIColor(self)
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        
        let uiColor2 = UIColor(to)
        var h2: CGFloat = 0
        var s2: CGFloat = 0
        var b2: CGFloat = 0
        uiColor2.getHue(&h2, saturation: &s2, brightness: &b2, alpha: nil)
        
        return Color(hue: h + (h2 - h) * t,
                     saturation: s + (s2 - s) * t,
                     brightness: b + (b2 - b) * t)
    }
}
