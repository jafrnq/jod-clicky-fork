import Cocoa

@MainActor
class RegionSelectionOverlayManager {
    static let shared = RegionSelectionOverlayManager()
    private var panels: [NSPanel] = []
    private var activeContinuation: CheckedContinuation<CGRect?, Never>?
    private var isFinished = false
    private(set) var lastCompletedRect: CGRect?
    
    func startSelection() async -> CGRect? {
        lastCompletedRect = nil
        guard panels.isEmpty else { return nil }
        self.isFinished = false
        return await withCheckedContinuation { continuation in
            self.activeContinuation = continuation
            
            let finish = { (rect: CGRect?) in
                guard !self.isFinished else { return }
                self.isFinished = true
                self.closePanels()
                let cont = self.activeContinuation
                self.activeContinuation = nil
                cont?.resume(returning: rect)
            }
            
            for screen in NSScreen.screens {
                let panel = NSPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
                panel.isFloatingPanel = true
                panel.ignoresMouseEvents = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                
                let view = RegionSelectionNSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.onComplete = { rect in
                    // rect is in view coordinates (bottom-left origin).
                    // Convert to global AppKit coordinates.
                    let globalRect = panel.convertToScreen(rect)
                    self.lastCompletedRect = globalRect
                    finish(globalRect)
                }
                view.onCancel = {
                    finish(nil)
                }
                
                panel.contentView = view
                panel.orderFrontRegardless()
                panel.makeFirstResponder(view)
                panels.append(panel)
            }
        }
    }
    
    /// Returns the rect from the most recent completed drag and clears it, so a
    /// later non-shift turn can never re-capture a stale region.
    func takeLastCompletedRect() -> CGRect? {
        let rect = lastCompletedRect
        lastCompletedRect = nil
        return rect
    }
    
    func cancelSelection() {
        guard !self.isFinished else { return }
        self.isFinished = true
        closePanels()
        let cont = self.activeContinuation
        self.activeContinuation = nil
        cont?.resume(returning: nil)
    }

    private func closePanels() {
        for panel in panels {
            panel.close()
        }
        panels.removeAll()
    }
}

class RegionSelectionNSView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    
    override var acceptsFirstResponder: Bool { true }
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor
        
        let tracker = NSTrackingArea(rect: frame, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil)
        self.addTrackingArea(tracker)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .crosshair)
    }
    
    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }
    
    override func mouseDragged(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        currentPoint = point
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let end = currentPoint else {
            onCancel?()
            return
        }
        
        let rect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        
        if rect.width > 10 && rect.height > 10 {
            onComplete?(rect)
        } else {
            onCancel?()
        }
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let start = startPoint, let current = currentPoint else { return }
        
        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        
        NSColor.white.withAlphaComponent(0.1).setFill()
        rect.fill()
        
        NSColor.blue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }
}
