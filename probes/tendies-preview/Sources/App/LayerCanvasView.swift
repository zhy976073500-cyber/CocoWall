//
//  LayerCanvasView.swift
//  TendiesPreview (Phase 0 probe)
//
//  The canvas: a plain UIView whose layer hosts one container CALayer.
//  Loaded package root layers are added (wrapped in per-package "fit"
//  layers owned by PreviewViewModel) in Background -> Floating ->
//  Foreground order. Nothing here touches layer timing: package layers
//  keep speed 1 and their own beginTime, so animations hung directly
//  on layers (CAAnimationGroup & friends) start playing as soon as the
//  tree is attached — that is acceptance gate 3's whole point.
//

import SwiftUI
import UIKit

final class LayerHostView: UIView {
    /// Container for all package fit layers; clipped to the canvas.
    let canvasLayer = CALayer()
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        canvasLayer.masksToBounds = true
        layer.addSublayer(canvasLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvasLayer.frame = bounds
        onLayout?()
    }
}

struct LayerCanvasView: UIViewRepresentable {
    @ObservedObject var vm: PreviewViewModel

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.onLayout = { vm.hostDidLayout() }
        vm.attachHost(view)
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}
