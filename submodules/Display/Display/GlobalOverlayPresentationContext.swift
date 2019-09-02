import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit

private func isViewVisibleInHierarchy(_ view: UIView, _ initial: Bool = true) -> Bool {
    guard let window = view.window else {
        return false
    }
    if view.isHidden || view.alpha == 0.0 {
        return false
    }
    if view.superview === window {
        return true
    } else if let superview = view.superview {
        if initial && view.frame.minY >= superview.frame.height {
            return false
        } else {
            return isViewVisibleInHierarchy(superview, false)
        }
    } else {
        return false
    }
}

private final class HierarchyTrackingNode: ASDisplayNode {
    private let f: (Bool) -> Void
    
    init(_ f: @escaping (Bool) -> Void) {
        self.f = f
        
        super.init()
        
        self.isLayerBacked = true
    }
    
    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        
        self.f(true)
    }
    
    override func didExitHierarchy() {
        super.didExitHierarchy()
        
        self.f(false)
    }
}

final class GlobalOverlayPresentationContext {
    private let statusBarHost: StatusBarHost?
    private weak var parentView: UIView?
    
    private(set) var controllers: [ContainableController] = []
    
    private var presentationDisposables = DisposableSet()
    private var layout: ContainerViewLayout?
    
    private var ready: Bool {
        return self.currentPresentationView(underStatusBar: false) != nil && self.layout != nil
    }
    
    init(statusBarHost: StatusBarHost?, parentView: UIView) {
        self.statusBarHost = statusBarHost
        self.parentView = parentView
    }
    
    private var currentTrackingNode: HierarchyTrackingNode?
    
    private func currentPresentationView(underStatusBar: Bool) -> UIView? {
        if let statusBarHost = self.statusBarHost {
            if let keyboardWindow = statusBarHost.keyboardWindow, let keyboardView = statusBarHost.keyboardView, !keyboardView.frame.height.isZero, isViewVisibleInHierarchy(keyboardView) {
                var updateTrackingNode = false
                if let trackingNode = self.currentTrackingNode {
                    if trackingNode.layer.superlayer !== keyboardView.layer {
                        updateTrackingNode = true
                    }
                } else {
                    updateTrackingNode = true
                }
                
                if updateTrackingNode {
                    /*self.currentTrackingNode?.removeFromSupernode()
                    let trackingNode = HierarchyTrackingNode({ [weak self] value in
                        guard let strongSelf = self else {
                            return
                        }
                        if !value {
                            strongSelf.addViews(justMove: true)
                        }
                    })
                    
                    self.currentTrackingNode = trackingNode
                    keyboardView.layer.addSublayer(trackingNode.layer)*/
                }
                return keyboardWindow
            } else {
                if underStatusBar, let view = self.parentView {
                    return view
                } else {
                    return statusBarHost.statusBarWindow
                }
            }
        }
        return nil
    }
    
    func present(_ controller: ContainableController) {
        let controllerReady = controller.ready.get()
        |> filter({ $0 })
        |> take(1)
        |> deliverOnMainQueue
        |> timeout(2.0, queue: Queue.mainQueue(), alternate: .single(true))
        
        var underStatusBar = false
        if let controller = controller as? ViewController {
            if case .Hide = controller.statusBar.statusBarStyle {
                underStatusBar = true
            }
        }
        if let presentationView = self.currentPresentationView(underStatusBar: underStatusBar), let initialLayout = self.layout {
            controller.view.frame = CGRect(origin: CGPoint(x: presentationView.bounds.width - initialLayout.size.width, y: 0.0), size: initialLayout.size)
            controller.containerLayoutUpdated(initialLayout, transition: .immediate)
            
            self.presentationDisposables.add(controllerReady.start(next: { [weak self] _ in
                if let strongSelf = self {
                    if strongSelf.controllers.contains(where: { $0 === controller }) {
                        return
                    }
                    
                    strongSelf.controllers.append(controller)
                    if let view = strongSelf.currentPresentationView(underStatusBar: underStatusBar), let layout = strongSelf.layout {
                        (controller as? UIViewController)?.navigation_setDismiss({ [weak controller] in
                            if let strongSelf = self, let controller = controller {
                                strongSelf.dismiss(controller)
                            }
                        }, rootController: nil)
                        (controller as? UIViewController)?.setIgnoreAppearanceMethodInvocations(true)
                        if layout != initialLayout {
                            controller.view.frame = CGRect(origin: CGPoint(x: view.bounds.width - layout.size.width, y: 0.0), size: layout.size)
                            view.addSubview(controller.view)
                            controller.containerLayoutUpdated(layout, transition: .immediate)
                        } else {
                            view.addSubview(controller.view)
                        }
                        (controller as? UIViewController)?.setIgnoreAppearanceMethodInvocations(false)
                        view.layer.invalidateUpTheTree()
                        controller.viewWillAppear(false)
                        controller.viewDidAppear(false)
                    }
                }
            }))
        } else {
            self.controllers.append(controller)
        }
    }
    
    deinit {
        self.presentationDisposables.dispose()
    }
    
    private func dismiss(_ controller: ContainableController) {
        if let index = self.controllers.firstIndex(where: { $0 === controller }) {
            self.controllers.remove(at: index)
            controller.viewWillDisappear(false)
            controller.view.removeFromSuperview()
            controller.viewDidDisappear(false)
        }
    }
    
    public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let wasReady = self.ready
        self.layout = layout
        
        if wasReady != self.ready {
            self.readyChanged(wasReady: wasReady)
        } else if self.ready {
            for controller in self.controllers {
                controller.containerLayoutUpdated(layout, transition: transition)
            }
        }
    }
    
    private func readyChanged(wasReady: Bool) {
        if !wasReady {
            self.addViews(justMove: false)
        } else {
            self.removeViews()
        }
    }
    
    private func addViews(justMove: Bool) {
        if let layout = self.layout {
            for controller in self.controllers {
                var underStatusBar = false
                if let controller = controller as? ViewController {
                    if case .Hide = controller.statusBar.statusBarStyle {
                        underStatusBar = true
                    }
                }
                if let view = self.currentPresentationView(underStatusBar: underStatusBar) {
                    if !justMove {
                        controller.viewWillAppear(false)
                    }
                    view.addSubview(controller.view)
                    if !justMove {
                        controller.view.frame = CGRect(origin: CGPoint(x: view.bounds.width - layout.size.width, y: 0.0), size: layout.size)
                        controller.containerLayoutUpdated(layout, transition: .immediate)
                        controller.viewDidAppear(false)
                    }
                }
            }
        }
    }
    
    private func removeViews() {
        for controller in self.controllers {
            controller.viewWillDisappear(false)
            controller.view.removeFromSuperview()
            controller.viewDidDisappear(false)
        }
    }
    
    func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for controller in self.controllers.reversed() {
            if controller.isViewLoaded {
                if let result = controller.view.hitTest(point, with: event) {
                    return result
                }
            }
        }
        return nil
    }
    
    func updateToInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        if self.ready {
            for controller in self.controllers {
                controller.updateToInterfaceOrientation(orientation)
            }
        }
    }
    
    func combinedSupportedOrientations(currentOrientationToLock: UIInterfaceOrientationMask) -> ViewControllerSupportedOrientations {
        var mask = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .all)
        
        for controller in self.controllers {
            mask = mask.intersection(controller.combinedSupportedOrientations(currentOrientationToLock: currentOrientationToLock))
        }
        
        return mask
    }
    
    func combinedDeferScreenEdgeGestures() -> UIRectEdge {
        var edges: UIRectEdge = []
        
        for controller in self.controllers {
            edges = edges.union(controller.deferScreenEdgeGestures)
        }
        
        return edges
    }
}
