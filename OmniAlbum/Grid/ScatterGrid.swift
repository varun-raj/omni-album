import SwiftUI

/// Drives a `ScatterGrid` from outside: `open(id:)` takes the same spring path as a click or tap.
@MainActor public final class ScatterGridController {
    weak var grid: ScatterGridView? { didSet { if let p = pending { pending = nil; grid?.open(id: p) } } }
    var pending: String?
    /// A controller with no grid yet; calls made before the grid appears are kept (open) or dropped.
    public init() {}
    /// Opens the tile for `id`, or opens it once the grid appears.
    public func open(id: String) { if let grid { grid.open(id: id) } else { pending = id } }
    /// Closes the open tile, if any.
    public func close() { grid?.close() }
    /// While a tile is open: stage the adjacent one (layout order).
    public func openNext() { grid?.openNext() }
    /// While a tile is open: stage the previous one (layout order).
    public func openPrevious() { grid?.openPrevious() }
    /// Scrolls so the tile for `id` sits mid-viewport.
    public func scrollTo(id: String) { grid?.scrollTo(id: id) }
    /// Replaces the selection (Select All, Deselect); onSelect reports it back.
    public func select(_ ids: [String]) { grid?.selected = ids }
    /// Call right before deleting these ids from `items`: their tiles poof (Dock-style) instead of vanishing.
    public func poof(_ ids: [String]) { grid?.poofIDs = Set(ids) }
    /// The image a tile is showing right now (thumbnail or full), already decoded; nil before it lands.
    public func image(_ id: String) -> CGImage? { grid?.layers[id]?.contents.map { $0 as! CGImage } }
    #if os(macOS)
    /// Fit (false) or Fill (true) the open tile; remembered for later opens.
    public func setFill(_ on: Bool) { grid?.setFill(on) }
    /// Plays the drop-acceptance effect without a real drag (`.enter`, then `.land` or `.exit`).
    public func dropEffect(_ phase: DropEffectPhase) { grid?.dropEffect(phase) }
    #endif
    #if os(iOS)
    /// The host's info panel went up (true) or down: the open tile springs into the space above it, or back.
    public func showInfo(_ on: Bool) { grid?.infoShown = on }
    #endif
}

#if os(macOS)

/// SwiftUI wrapper: a scrolling `ScatterGridView`.
public struct ScatterGrid: NSViewRepresentable {
    var items: [ScatterItem], config: ScatterConfig
    nonisolated var content: TileContentProvider // a View is main-actor; keeps the closure @Sendable
    var glideKey: AnyHashable
    var onActivate: (String) -> Void = { _ in }
    var onOpen: (String?) -> Void, onSelect: ([String]) -> Void, onDelete: (String) -> Void
    var onDropURLs: ([URL]) -> Void, onPaste: () -> Void, onCopy: (String?) -> Void
    var onKey: (NSEvent, String?) -> Bool
    var tileMenu: (String) -> NSMenu?, dragURL: (String) -> URL?
    var stageOverlay: NSView?
    var tileIcon: (String) -> CGImage?
    var hoverOverlay: ((ScatterItem, @escaping () -> Void) -> AnyView)?
    var controller: ScatterGridController?
    var header: AnyView?
    var onScroll: ((CGFloat) -> Void)?

    /// `header` scrolls with the grid above the first row.
    /// `glideKey`: change it alongside something that resizes the grid (a side panel, say) and the
    /// re-justified tiles glide to their new frames instead of snapping.
    public init(items: [ScatterItem], config: ScatterConfig = ScatterConfig(), glideKey: AnyHashable = 0,
                content: @escaping TileContentProvider,
                onActivate: @escaping (String) -> Void = { _ in },
                onOpen: @escaping (String?) -> Void = { _ in }, onSelect: @escaping ([String]) -> Void = { _ in },
                onDelete: @escaping (String) -> Void = { _ in }, onDropURLs: @escaping ([URL]) -> Void = { _ in },
                onPaste: @escaping () -> Void = {}, onCopy: @escaping (String?) -> Void = { _ in }, onKey: @escaping (NSEvent, String?) -> Bool = { _, _ in false },
                tileMenu: @escaping (String) -> NSMenu? = { _ in nil }, dragURL: @escaping (String) -> URL? = { _ in nil },
                stageOverlay: NSView? = nil, tileIcon: @escaping (String) -> CGImage? = { _ in nil },
                hoverOverlay: ((ScatterItem, @escaping () -> Void) -> AnyView)? = nil, controller: ScatterGridController? = nil,
                header: AnyView? = nil, onScroll: ((CGFloat) -> Void)? = nil) {
        self.header = header; self.onScroll = onScroll
        self.items = items; self.config = config; self.glideKey = glideKey; self.content = content
        self.onActivate = onActivate; self.onOpen = onOpen; self.onSelect = onSelect; self.onDelete = onDelete
        self.onDropURLs = onDropURLs; self.onPaste = onPaste; self.onCopy = onCopy; self.onKey = onKey
        self.tileMenu = tileMenu; self.dragURL = dragURL; self.stageOverlay = stageOverlay
        self.tileIcon = tileIcon; self.hoverOverlay = hoverOverlay; self.controller = controller
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.automaticallyAdjustsContentInsets = false // the host places `header` itself; a titlebar inset on top of it doubles the gap
        sv.backgroundColor = NSColor(cgColor: config.background) ?? .black // fills below short content
        sv.drawsBackground = config.background.alpha > 0 // a clear background lets the host paint the stage
        let grid = ScatterGridView(frame: .zero)
        grid.autoresizingMask = [.width]
        sv.documentView = grid
        return sv
    }

    public func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let grid = sv.documentView as? ScatterGridView else { return }
        grid.content = content
        grid.onOpen = onOpen; grid.onActivate = onActivate
        grid.onSelect = { ids in Task { @MainActor in onSelect(ids) } } // may fire during a view update
        grid.onDelete = onDelete; grid.onDropURLs = onDropURLs; grid.onPaste = onPaste; grid.onCopy = onCopy; grid.onKey = onKey
        grid.tileMenu = tileMenu; grid.dragURL = dragURL; grid.stageOverlay = stageOverlay
        grid.tileIcon = tileIcon; grid.hoverOverlay = hoverOverlay; grid.onScroll = onScroll
        if grid.config.rowHeight != config.rowHeight || grid.config.gap != config.gap || grid.config.columns != config.columns || grid.config.edgeInset != config.edgeInset || grid.config.background != config.background { grid.config = config }
        if context.coordinator.glideKey != glideKey { context.coordinator.glideKey = glideKey; grid.glideNextLayout() }
        if grid.frame.width != sv.contentSize.width { grid.setFrameSize(NSSize(width: sv.contentSize.width, height: grid.frame.height)) }
        if grid.items != items { grid.items = items }
        if controller?.grid !== grid { controller?.grid = grid }
        if let header {
            let h = context.coordinator.header
            h.rootView = header
            if grid.headerView !== h { grid.headerView = h }
            if abs(h.fittingSize.height - h.frame.height) > 0.5 { grid.needsLayout = true }
        } else if grid.headerView != nil { grid.headerView = nil }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(glideKey: glideKey) }
    @MainActor public final class Coordinator {
        var glideKey: AnyHashable
        let header = NSHostingView(rootView: AnyView(EmptyView()))
        init(glideKey: AnyHashable) { self.glideKey = glideKey }
    }
}
#else
/// SwiftUI wrapper: a scrolling `ScatterGridView`. Tap opens, long-press selects, pinch zooms.
/// A view controller, not a bare view, so it can hand its scroll view to the navigation and tab bars
/// (`setContentScrollView`): that is what drives the large-title collapse and the scroll edge effect.
public struct ScatterGrid: UIViewControllerRepresentable {
    var items: [ScatterItem], config: ScatterConfig
    nonisolated var content: TileContentProvider // a View is main-actor; keeps the closure @Sendable
    var onActivate: (String) -> Void, onOpen: (String?) -> Void, onSelect: ([String]) -> Void
    var stageOverlay: UIView?, onInfo: ((String?) -> Void)?, tileIcon: (String) -> CGImage?
    var tileMenu: (ScatterItem) -> UIMenu?, tileActions: (ScatterItem) -> [UIAccessibilityCustomAction]
    var controller: ScatterGridController?
    var selecting = false

    /// `content` decodes pixels off the main thread; the callbacks mirror `ScatterGridView`'s. `selecting` turns taps into selection toggles.
    public init(items: [ScatterItem], config: ScatterConfig = ScatterConfig(), content: @escaping TileContentProvider,
                onActivate: @escaping (String) -> Void = { _ in }, onOpen: @escaping (String?) -> Void = { _ in },
                onSelect: @escaping ([String]) -> Void = { _ in }, stageOverlay: UIView? = nil, onInfo: ((String?) -> Void)? = nil,
                tileIcon: @escaping (String) -> CGImage? = { _ in nil }, tileMenu: @escaping (ScatterItem) -> UIMenu? = { _ in nil },
                tileActions: @escaping (ScatterItem) -> [UIAccessibilityCustomAction] = { _ in [] },
                controller: ScatterGridController? = nil, selecting: Bool = false) {
        self.tileActions = tileActions
        self.items = items; self.config = config; self.content = content; self.selecting = selecting
        self.onActivate = onActivate; self.onOpen = onOpen; self.onSelect = onSelect; self.stageOverlay = stageOverlay
        self.onInfo = onInfo; self.tileIcon = tileIcon; self.tileMenu = tileMenu; self.controller = controller
    }

    public final class Controller: UIViewController {
        let scrollView = UIScrollView(), grid = ScatterGridView(frame: .zero)
        public override func loadView() { view = scrollView }
        public override func viewDidLoad() {
            super.viewDidLoad()
            grid.autoresizingMask = [.flexibleWidth]
            scrollView.addSubview(grid)
            #if compiler(>=6.2) // iOS 26 SDK (Xcode 26+)
            if #available(iOS 26, *) { scrollView.topEdgeEffect.style = .soft }
            #endif
            setContentScrollView(scrollView, for: .top)
            setContentScrollView(scrollView, for: .bottom)
        }
        // Hardware keyboards: arrows step between tiles while one is open (first responder only then, so search fields keep focus).
        public override var canBecomeFirstResponder: Bool { true }
        public override var keyCommands: [UIKeyCommand]? {
            guard grid.opened != nil else { return nil }
            return [(UIKeyCommand.inputLeftArrow, #selector(stepPrevious)), (UIKeyCommand.inputUpArrow, #selector(stepPrevious)),
                    (UIKeyCommand.inputRightArrow, #selector(stepNext)), (UIKeyCommand.inputDownArrow, #selector(stepNext))].map { k, s in
                let c = UIKeyCommand(input: k, modifierFlags: [], action: s); c.wantsPriorityOverSystemBehavior = true; return c
            }
        }
        @objc func stepNext() { grid.openNext() }
        @objc func stepPrevious() { grid.openPrevious() }
    }

    public func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.scrollView.backgroundColor = UIColor(cgColor: config.background)
        return c
    }

    public func updateUIViewController(_ c: Controller, context: Context) {
        let (sv, grid) = (c.scrollView, c.grid)
        grid.content = content
        grid.onOpen = { [weak c] id in // the grid behind an open tile never scrolls
            sv.isScrollEnabled = id == nil
            if id != nil { c?.becomeFirstResponder() }
            onOpen(id)
        }
        grid.onActivate = onActivate
        grid.onSelect = { ids in Task { @MainActor in onSelect(ids) } } // may fire during a view update
        grid.stageOverlay = stageOverlay
        grid.onInfo = onInfo; grid.tileIcon = tileIcon; grid.tileMenu = tileMenu; grid.tileActions = tileActions
        if grid.selecting != selecting { grid.selecting = selecting; if !selecting { grid.selected = [] } }
        if grid.config.rowHeight != config.rowHeight || grid.config.gap != config.gap || grid.config.columns != config.columns || grid.config.edgeInset != config.edgeInset || grid.config.background != config.background { grid.config = config }
        if grid.items != items { grid.items = items }
        if controller?.grid !== grid { controller?.grid = grid }
    }
}
#endif
