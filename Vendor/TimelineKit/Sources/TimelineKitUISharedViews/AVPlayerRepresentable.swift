import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Platform representable that hosts an AVPlayerLayer.
/// The view owns only the display layer; the AVPlayer is owned by EditorStore.
public struct AVPlayerRepresentable: TimelinePlayerRepresentable {
    public let player: AVPlayer
    
    public init(player: AVPlayer) {
        self.player = player
    }
    
#if canImport(UIKit)
    public func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.player = player
        return view
    }
    
    public func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
#else
    public func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.player = player
        return view
    }
    
    public func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
#endif
}

// MARK: -

#if canImport(UIKit)
public typealias TimelinePlayerRepresentable = UIViewRepresentable
#else
public typealias TimelinePlayerRepresentable = NSViewRepresentable
#endif

public final class PlayerHostView: TimelinePlayerPlatformView {
#if canImport(UIKit)
    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    
    public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
#else
    public override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    
    public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
#endif
    
    public var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }
    
#if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    
    public required init?(coder: NSCoder) { fatalError() }
#else
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    
    public required init?(coder: NSCoder) { fatalError() }
#endif
}

#if canImport(UIKit)
public typealias TimelinePlayerPlatformView = UIView
#else
public typealias TimelinePlayerPlatformView = NSView
#endif
