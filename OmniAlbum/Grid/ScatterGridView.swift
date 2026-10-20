#if os(macOS)
import AppKit
public typealias ScatterPlatformView = NSView
#else
import UIKit
public typealias ScatterPlatformView = UIView
#endif
import SwiftUI
import os

/// A justified image grid. Clicking a tile stages it centred in the viewport while the other tiles scatter
/// away with an exponential distance falloff and fade; clicking again springs everything back.
/// Host it as the document view of an `NSScrollView` (or use `ScatterGrid` from SwiftUI).
public final class ScatterGridView: ScatterPlatformView {
    public var config = ScatterConfig() {
        didSet {
            needsLayout = true
            #if os(iOS)
            root.backgroundColor = config.background
            #else
            layer?.backgroundColor = config.background
            #endif
        }
    }
    public var content: TileContentProvider = { _, _, _ in nil }

    public var onOpen: (String?) -> Void = { _ in }
    /// Haptic cue by name ("select" / "tick" / "snap" / "success", "prepare" at a gesture's start); the host plays it, so ScatterCore carries no haptics API. Static: one hook for every grid.
    public static var onHaptic: ((String) -> Void)?
    func haptic(_ kind: String) { Self.onHaptic?(kind) }
    /// Plain click on an `external` tile.
    public var onActivate: (String) -> Void = { _ in }
    public var onSelect: ([String]) -> Void = { _ in }
    /// ⌫ / ⌦. With a selection it gets one selected id: act on the whole selection.
    public var onDelete: (String) -> Void = { _ in }
    /// Dropped file and web URLs.
    public var onDropURLs: ([URL]) -> Void = { _ in }
    public var onPaste: () -> Void = {}
    #if os(macOS)
    /// Edit ▸ Copy (⌘C) with the tile it applies to (see `targetID`).
    public var onCopy: (String?) -> Void = { _ in }
    /// Called before built-in key handling with the tile the key applies to (open, else last selected,
    /// else hovered). Return true to consume the event.
    public var onKey: (NSEvent, String?) -> Bool = { _, _ in false }
    /// Context menu for a right-clicked tile.
    public var tileMenu: (String) -> NSMenu? = { _ in nil }
    #else
    /// iOS: swipe up on the opened tile asks for that tile's info; nil (swipe down / tap while `infoShown`) asks to hide it.
    public var onInfo: ((String?) -> Void)?
    /// iOS: the host's info panel is up (Photos): the open tile springs into the space above it, and back when false.
    public var infoShown = false { didSet { if infoShown != oldValue { restage() } } }
    /// iOS: select mode (Photos' Select): taps toggle selection instead of opening.
    public var selecting = false
    /// iOS: long-press menu for a tile (the native context menu, previewing the tile); nil shows none.
    public var tileMenu: (ScatterItem) -> UIMenu? = { _ in nil }
    /// The long-press menu's actions for VoiceOver (a tile's stand-in element can't open the context menu).
    public var tileActions: (ScatterItem) -> [UIAccessibilityCustomAction] = { _ in [] }
    #endif
    /// File to hand over when a tile is dragged out of the grid; nil disables dragging for it. Dragging a selected tile
    /// drags the whole selection; each item also carries its id under `dragIDType` (drop targets in the host app).
    public var dragURL: (String) -> URL? = { _ in nil }
    /// Icon for a tile's hover pill (e.g. a favicon); nil shows the default photo glyph.
    public var tileIcon: (String) -> CGImage? = { _ in nil }
    /// SwiftUI laid over the hovered tile (e.g. a glass ⓘ button), fading in with the hover spring. The second
    /// argument stages the tile. Only NSView-backed controls take clicks; the rest passes through to the grid (macOS: a plain
    /// SwiftUI Button has no view of its own, so it hit-tests as the host and the click lands on the tile).
    public var hoverOverlay: ((ScatterItem, @escaping () -> Void) -> AnyView)?
    #if os(macOS)
    let hoverHost: PassthroughHostingView = {
        let h = PassthroughHostingView(rootView: AnyView(EmptyView()))
        h.sizingOptions = [] // sized by the tile: a new overlay never re-proposes sizes up the window (no grid relayout per hover)
        return h
    }()
    #else
    var scrollWatch: NSKeyValueObservation?
    #endif
    #if os(macOS)
    /// Scrolls with the grid above the first row (a large page title, say); dims to 15 % while a tile is open.
    public var headerView: NSView? {
        didSet { if oldValue !== headerView { oldValue?.removeFromSuperview(); headerView.map(addSubview) }; needsLayout = true }
    }
    /// The visible rect's top y in grid coordinates (0 at rest), on every scroll; e.g. to fade in an inline title once `headerView` slides under a bar.
    public var onScroll: ((CGFloat) -> Void)?
    #endif
    /// Laid over the opened tile once it has landed (e.g. a Live Text overlay); hidden while zoomed.
    public var stageOverlay: ScatterPlatformView?

    /// The tile keyboard and context actions apply to: the open one, else the last selected, else the hovered.
    public var targetID: String? {
        if let t = opened ?? hovered, let i = tiles.firstIndex(of: t), opened != nil || selected.isEmpty { return items[i].id }
        return selected.last
    }

    /// Diffed by id: reorders and filters reuse layers and glide into place; the first load snaps.
    public var items: [ScatterItem] = [] {
        didSet {
            let ids = Set(items.map(\.id))
            for (id, t) in layers where !ids.contains(id) {
                if poofIDs.contains(id) { poof(t) } else { t.removeFromSuperlayer() }
                layers[id] = nil
                if t === hovered { hovered = nil }
                if t === opened { opened = nil }
            }
            tiles = items.map { it in
                if let t = layers[it.id] { return t }
                let t = CALayer()
                t.cornerRadius = config.cornerRadius; t.masksToBounds = true
                t.contentsGravity = .resizeAspectFill
                t.borderWidth = 0.5; t.borderColor = CGColor(gray: 0, alpha: 0.12) // hairline: white images on a light canvas; invisible on dark
                root.addSublayer(t); layers[it.id] = t
                return t
            }
            if selected.contains(where: { !ids.contains($0) }) { selected.removeAll { !ids.contains($0) } }
            let old = Dictionary(oldValue.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for it in items {
                guard let t = layers[it.id] else { continue }
                t.backgroundColor = it.placeholder ?? CGColor(gray: 0.5, alpha: 0.2) // grey reads on light and dark backgrounds
                if let o = old[it.id], o.revision != it.revision, t !== opened { fading.insert(it.id); setContents(t, nil) }
                setSpinner(it.loading || fullWait.contains(t), on: t)
                #if os(iOS)
                setBadge(it, on: t)
                #endif
                if old[it.id]?.symbol != it.symbol { setMark(it, on: t) }
            }
            glide = !oldValue.isEmpty; poofIDs = []
            needsLayout = true
        }
    }
    /// Ids the next `items` change removes as a delete: they poof (see `TilePoof`) instead of vanishing. Cleared by that change.
    public var poofIDs = Set<String>()

    /// Shift-click toggles; Esc clears. Selected tiles keep the hover lift and get a white ring.
    public var selected: [String] = [] {
        didSet {
            for id in Set(oldValue).subtracting(selected) { if let t = layers[id] {
                t.borderWidth = 0.5; t.borderColor = CGColor(gray: 0, alpha: 0.12)
                if t !== hovered { spring(t, "transform.scale", to: 1.0, config.hover) }
            } }
            for id in Set(selected).subtracting(oldValue) { if let t = layers[id] {
                t.borderWidth = 3; t.borderColor = CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1) // ≥ 3:1 on white and black tiles (white 0.6 vanished on light images)
                spring(t, "transform.scale", to: config.hoverScale, config.hover)
            } }
            if selected != oldValue { onSelect(selected) }
        }
    }

    /// Make the next width change(s) within `seconds` glide instead of snap, e.g. when a side panel toggles.
    public func glideNextLayout(within seconds: Double = 0.35) { glideUntil = CACurrentMediaTime() + seconds }

    var tiles: [CALayer] = [], frames: [CGRect] = [], layers: [String: CALayer] = [:]
    var hovered: CALayer?, opened: CALayer?
    var staged: CALayer?, dragBase: CGFloat = 0, dismissing = false // pager: the neighbour waiting beside the open tile
    var glide = false, glideUntil: CFTimeInterval = 0
    var swiped = false // this swipe already stepped / this pinch already opened, once per gesture
    var zoom: CGFloat = 1, pan = CGPoint.zero, pinchRaw: CGFloat = 1, bumped = false // pinchRaw: the gesture's unbanded zoom; bumped: this gesture's haptic played
    var fullLRU: [(key: String, img: CGImage)] = [] // the last 3 full-size decodes, newest last
    var inFlight: [String: [(CGImage?) -> Void]] = [:] // full-size decodes running, with who waits on each (nil: no pixels yet)
    var fullWait = Set<CALayer>() // open/staged layers whose full image isn't on disk yet (e.g. iCloud downloading): spinner + retry
    var frameLink: CADisplayLink?, afterFirstFrame: [() -> Void] = [] // work held until the open's first frame is up
    var clickTime: CFTimeInterval? // the click's event time, so open latency counts from the click
    var hoverPrefetch: DispatchWorkItem?
    /// Seconds from the last click (or `open`) to the first frame after the open committed (signpost "open.firstFrame").
    public private(set) var openFirstFrame: Double?
    /// Seconds from the last open to the sharp image going up (signpost "open.swap"), and whether it was decoded beforehand.
    public private(set) var openSwap: (seconds: Double, warm: Bool)?
    var pending: [String: Operation] = [:] // queued decodes; cancelled when their tile leaves nearRect
    var shown: [String: CALayer] = [:] // tiles inside nearRect last pass (plus the opened one), so updateVisible only revisits these
    var lastY: CGFloat = 0, scrollDir: CGFloat = 0 // +1 scrolling down, -1 up
    static var decodedAhead = 0
    var press: (tile: CALayer, at: CGPoint)?
    var peeking = false // open() is a force-click peek: 60% of the stage over dimmed tiles, the host not told yet
    #if os(macOS)
    var peek = Peek.idle, openOnUp = false // Force Touch: the press opens on mouse-up unless it became a peek
    #endif
    #if os(macOS)
    var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    #endif
    /// One screen either side of the viewport, plus the next 2 rows in the scroll direction.
    var nearRect: CGRect {
        var r = visibleRect.insetBy(dx: 0, dy: -visibleRect.height), ahead = 2 * (config.rowHeight + config.gap)
        if scrollDir < 0 { r.origin.y -= ahead }
        if scrollDir != 0 { r.size.height += ahead }
        return r
    }

    /// Decoded tiles, cost = bytes. The Mac keeps 300 MB; iOS 100 MB, emptied on a memory warning or going to the
    /// background (tiles on screen keep their layer contents, so the viewport stays drawn).
    static let cache: NSCache<NSString, CGImage> = {
        nonisolated(unsafe) let c = NSCache<NSString, CGImage>() // NSCache is thread-safe; it just isn't marked Sendable
        #if os(iOS)
        c.totalCostLimit = 100 << 20; c.evictsObjectsWithDiscardedContent = true
        for n in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                c.removeAllObjects(); log.notice("tile cache cleared: \(n.rawValue, privacy: .public)")
            }
        }
        #else
        c.totalCostLimit = 300 << 20
        #endif
        return c
    }()
    nonisolated static let log = Logger(subsystem: "ScatterKit", category: "scatterkit")
    /// "open" / "close" animation intervals (os_signpost, cheap when not recorded): XCTOSSignpostMetric hitch tests;
    /// "open.firstFrame" (click → first committed frame) and "open.swap" (open → sharp image) intervals.
    static let signposter = OSSignposter(subsystem: "ScatterKit", category: "animation")
    /// At most 4 decodes at once: a fast scroll over iCloud-evicted files (whose reads block) can't spawn a thread per tile.
    static let decodeQueue: OperationQueue = {
        let q = OperationQueue(); q.name = "scatterkit.decode"; q.maxConcurrentOperationCount = 4; q.qualityOfService = .userInitiated; return q
    }()

    #if os(macOS)
    let pill = CALayer(), pillIcon = CALayer(), pillText = CATextLayer() // one title pill, moved to the hovered tile
    let pillFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    let cosmos = DropCosmos() // drop-acceptance starfield (DropCosmos.swift)
    #endif

    public override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        root.backgroundColor = config.background
        addGestures()
        #else
        wantsLayer = true
        layer!.backgroundColor = config.background
        registerForDraggedTypes(Self.dropTypes)
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick) // two-stage feel for force-click peek
        pill.backgroundColor = CGColor(gray: 0, alpha: 0.9)
        pill.cornerRadius = 16; pill.opacity = 0; pill.zPosition = 2
        pillIcon.masksToBounds = true
        pillText.font = pillFont; pillText.fontSize = 14
        pillText.foregroundColor = .white; pillText.truncationMode = .end
        pill.addSublayer(pillIcon); pill.addSublayer(pillText); pill.addSublayer(pillArrow)
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    #if os(macOS)
    var root: CALayer { layer! }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func viewDidMoveToWindow() { DispatchQueue.main.async { self.window?.makeFirstResponder(self) } }
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateVisible), name: NSView.boundsDidChangeNotification, object: clip)
    }
    #endif

    // MARK: animation

    /// Springs `keyPath` from its presented value to `to` and commits the model value so it sticks.
    /// With Reduce Motion on, only opacity animates: geometry lands at once under a short crossfade of the grid.
    func spring(_ layer: CALayer, _ keyPath: String, to: Any, _ s: SpringMotion, duration: Double = 0) {
        let from = (layer.animation(forKey: keyPath) != nil ? layer.presentation() : nil)?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.setValue(to, forKeyPath: keyPath)
        CATransaction.commit()
        if reduceMotion && keyPath != "opacity" { layer.removeAnimation(forKey: keyPath); return crossfade(layer) }
        layer.add(s.animation(keyPath: keyPath, from: from, to: to, duration: duration), forKey: keyPath)
    }

    /// Reduce Motion's stand-in for a spring: the layer's superlayer fades from the old picture to the new.
    func crossfade(_ layer: CALayer) {
        guard let host = layer.superlayer, host.animation(forKey: "reduceMotionFade") == nil else { return } // one per change
        let f = CATransition(); f.type = .fade; f.duration = 0.2
        host.add(f, forKey: "reduceMotionFade")
    }

    func move(_ t: CALayer, to r: CGRect, _ duration: Double) {
        spring(t, "position", to: NSValue(point: CGPoint(x: r.midX, y: r.midY)), config.item, duration: duration)
        if t.bounds.size != r.size { spring(t, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: r.size)), config.item, duration: duration) }
    }

    /// Jumps to `r` and `opacity` with no animation (Core Animation's own actions off).
    func place(_ t: CALayer, _ r: CGRect, opacity: Float) {
        for k in ["position", "bounds", "opacity"] { t.removeAnimation(forKey: k) }
        t.position = CGPoint(x: r.midX, y: r.midY); t.bounds = CGRect(origin: .zero, size: r.size); t.opacity = opacity
    }

    /// Opacity from where it is now to `o` over `duration` on a plain timing curve; the model value sticks.
    func fade(_ t: CALayer, to o: Float, _ duration: Double, _ timing: CAMediaTimingFunctionName) {
        let from = (t.animation(forKey: "opacity") != nil ? t.presentation() : nil)?.opacity ?? t.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true); t.opacity = o; CATransaction.commit()
        guard from != o else { return t.removeAnimation(forKey: "opacity") }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = o; a.duration = duration; a.timingFunction = CAMediaTimingFunction(name: timing)
        t.add(a, forKey: "opacity")
    }

    /// Runs `f` on the first display frame after the current transaction commits (at once if the view has no window).
    func onFirstFrame(_ f: @escaping () -> Void) {
        guard window != nil else { return f() }
        afterFirstFrame.append(f)
        guard frameLink == nil else { return }
        #if os(macOS)
        frameLink = displayLink(target: self, selector: #selector(firstFrame))
        #else
        frameLink = CADisplayLink(target: self, selector: #selector(firstFrame))
        #endif
        frameLink?.add(to: .main, forMode: .common)
    }
    @objc func firstFrame(_ l: CADisplayLink) {
        l.invalidate(); frameLink = nil
        let work = afterFirstFrame; afterFirstFrame = []
        work.forEach { $0() }
    }

    var fading = Set<String>() // tiles whose next decoded image fades in

    /// A small rotating arc centred on the tile while it loads.
    func setSpinner(_ on: Bool, on t: CALayer) {
        let existing = t.sublayers?.first { $0.name == "spinner" }
        guard on != (existing != nil) else { return }
        guard on else { return existing?.removeFromSuperlayer() ?? () }
        let s = CAShapeLayer()
        s.name = "spinner"; s.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        s.path = CGPath(ellipseIn: s.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        s.fillColor = nil; s.strokeColor = CGColor(gray: 1, alpha: 0.7); s.lineWidth = 2; s.strokeEnd = 0.7; s.lineCap = .round
        s.zPosition = 3
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.toValue = -2 * Double.pi; spin.duration = 0.9; spin.repeatCount = .infinity
        s.add(spin, forKey: "spin")
        #if os(macOS)
        t.layoutManager = CAConstraintLayoutManager()
        s.addConstraint(CAConstraint(attribute: .midX, relativeTo: "superlayer", attribute: .midX))
        s.addConstraint(CAConstraint(attribute: .midY, relativeTo: "superlayer", attribute: .midY))
        #else
        s.position = CGPoint(x: 18, y: 18) // No CAConstraint on iOS, so the spinner sits in the corner rather than centred.
        #endif
        t.addSublayer(s)
    }

    /// The spinner as the item's `loading` flag and any pending full-size fetch say.
    func syncSpinner(_ t: CALayer) { if let i = tiles.firstIndex(of: t) { setSpinner(items[i].loading || fullWait.contains(t), on: t) } }

    func badge(_ t: CALayer) -> CALayer? { t.sublayers?.first { $0.name == "badge" } }
    func mark(_ t: CALayer) -> CALayer? { t.sublayers?.first { $0.name == "mark" } }
    func showChips(_ t: CALayer, _ on: Bool) { for l in t.sublayers ?? [] where l.name == "badge" || l.name == "mark" { l.isHidden = !on } }

    /// The item's `symbol` as a 22 pt dark chip. A dark capsule rather than Liquid Glass: tiles are bare layers (see `setBadge`).
    func setMark(_ item: ScatterItem, on t: CALayer) {
        mark(t)?.removeFromSuperlayer()
        guard let name = item.symbol else { return }
        #if os(macOS)
        let g = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [.white])))
        let img: Any? = g
        #else
        let g = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        let img: Any? = g.flatMap { g in UIGraphicsImageRenderer(size: g.size).image { _ in g.withTintColor(.white).draw(at: .zero) }.cgImage }
        #endif
        guard let g, let img else { return }
        let m = CALayer()
        m.name = "mark"; m.zPosition = 2; m.backgroundColor = CGColor(gray: 0, alpha: 0.65) // white glyph ≥ 4.5:1 over any tile
        m.contents = img; m.contentsGravity = .center; m.contentsScale = scale
        m.bounds = CGRect(x: 0, y: 0, width: max(22, ceil(g.size.width) + 12), height: 22); m.cornerRadius = 11
        m.isHidden = t === opened
        t.addSublayer(m)
    }

    /// Bottom-leading, 8 pt in; on iOS a link badge sits just after it.
    func placeMark(on t: CALayer, size: CGSize) {
        guard let m = mark(t) else { return }
        m.frame.origin = CGPoint(x: 8, y: size.height - 8 - 22)
    }

    func setContents(_ t: CALayer, _ img: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true); t.contents = img; CATransaction.commit()
    }

    // MARK: layout

    func gridFrame(_ i: Int) -> CGRect { i < frames.count ? frames[i] : .zero }

    /// Justified rows: each row fills the width exactly; the last row keeps its natural height, left-aligned.
    #if os(macOS)
    public override func layout() { super.layout(); relayout() }
    #endif
    func relayout() {
        guard opened == nil else { return }
        #if os(macOS)
        let header = headerView?.fittingSize.height ?? 0
        headerView?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: header)
        #else
        let header: CGFloat = 0
        #endif
        let (frames, y) = justifiedFrames(aspects: items.map(\.aspect), width: bounds.width, rowHeight: config.rowHeight, gap: config.gap, top: header, inset: config.edgeInset ?? config.gap, columns: config.columns)
        self.frames = frames
        if let p = pendingOpen, bounds.width > 0, items.contains(where: { $0.id == p }) {
            pendingOpen = nil; DispatchQueue.main.async { self.open(id: p) } // not from inside a layout pass
        }
        if CACurrentMediaTime() < glideUntil { glide = true }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, t) in tiles.enumerated() where !(glide && t.frame != .zero) { t.frame = gridFrame(i) }
        for (i, t) in tiles.enumerated() { placeMark(on: t, size: gridFrame(i).size) }
        #if os(iOS)
        for (i, t) in tiles.enumerated() { placeBadge(on: t, size: gridFrame(i).size) }
        #endif
        CATransaction.commit()
        if glide { for (i, t) in tiles.enumerated() where t.frame != gridFrame(i) { move(t, to: gridFrame(i), config.openDuration) } }
        glide = false
        let h = max(y, viewportHeight)
        if abs(frame.height - h) > 0.5 { setFrameSize(CGSize(width: frame.width, height: h)) }
        updateVisible()
    }

    /// Only tiles within one screen of the viewport hold pixels.
    @objc func updateVisible() {
        let v = visibleRect
        if v.minY != lastY {
            scrollDir = v.minY > lastY ? 1 : -1; lastY = v.minY
            #if os(macOS)
            onScroll?(v.minY)
            #endif
        }
        let near = nearRect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var now: [String: CALayer] = [:]
        if let o = opened, let id = shown.first(where: { $0.value === o })?.key { now[id] = o } // keep tracking it until it closes
        for i in rowRange(frames, near).clamped(to: tiles.indices) where tiles[i] !== opened {
            let t = tiles[i], f = gridFrame(i), id = items[i].id
            guard f.intersects(near) else { t.contents = nil; pending.removeValue(forKey: id)?.cancel(); continue }
            now[id] = t
            guard t.contents == nil else { continue }
            let px = ceil(max(f.width, f.height) * scale / 128) * 128 // bucketed so resizes reuse decodes
            let key = "\(id)#\(items[i].revision)@\(Int(px))"
            if let img = Self.cache.object(forKey: key as NSString) { t.contents = img; continue }
            guard pending[id] == nil else { continue }
            let content = content, ahead = scrollDir > 0 ? f.minY >= v.maxY : scrollDir < 0 && f.maxY <= v.minY
            let op = BlockOperation() // cancelled while queued: skipped
            op.addExecutionBlock { [weak op] in
                let img = content(id, px, false), op = op
                DispatchQueue.main.async {
                    if self.pending[id] === op { self.pending[id] = nil } // a re-queued decode for this id owns the slot now
                    guard let img else { return }
                    if ahead { Self.decodedAhead += 1; Self.log.notice("decoded ahead: \(Self.decodedAhead)") }
                    Self.cache.setObject(img, forKey: key as NSString, cost: img.bytesPerRow * img.height)
                    if let t = self.layers[id], t !== self.opened, t.frame.intersects(self.nearRect) {
                        #if os(iOS)
                        let f = CATransition(); f.duration = 0.2; t.add(f, forKey: "fade") // fades in over the grey tile instead of popping
                        #endif
                        self.setContents(t, img)
                        if self.fading.remove(id) != nil {
                            CATransaction.begin(); CATransaction.setDisableActions(true); t.opacity = 0; CATransaction.commit()
                            self.spring(t, "opacity", to: 1.0, self.config.hover)
                        }
                    }
                }
            }
            pending[id] = op; Self.decodeQueue.addOperation(op)
        }
        // Tiles that just left nearRect drop their pixels (removed layers, e.g. a poof, are left alone).
        for (id, t) in shown where now[id] == nil && layers[id] === t { t.contents = nil; pending.removeValue(forKey: id)?.cancel() }
        shown = now
        CATransaction.commit()
    }

    // MARK: hover

    #if os(macOS)
    var viewportHeight: CGFloat { enclosingScrollView?.contentSize.height ?? 0 }
    public override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    public override func mouseMoved(with e: NSEvent) {
        // An app view floating over the grid (a panel) owns the point: no hover through it.
        let ours = window?.contentView?.hitTest(e.locationInWindow).map { $0.isDescendant(of: self) } ?? true
        setHover(opened == nil && ours ? tile(at: e) : nil)
    }
    public override func mouseExited(with e: NSEvent) { setHover(nil) }

    func setHover(_ t: CALayer?) {
        guard t !== hovered else { return }
        if let h = hovered, let i = tiles.firstIndex(of: h), !selected.contains(items[i].id) { spring(h, "transform.scale", to: 1.0, config.hover) }
        if hovered != nil { spring(pill, "opacity", to: 0.0, config.hover); hideHoverOverlay() }
        hoverPrefetch?.cancel()
        if let t, let i = tiles.firstIndex(of: t) {
            prefetchFull(i, dwell: 0.25) // a full-size decode is the dearest thing hover does: a sweep across tiles decodes nothing, a rest before the click does
            spring(t, "transform.scale", to: config.hoverScale, config.hover)
            if config.showsHoverTitle, !items[i].title.isEmpty { showPill(on: t, item: items[i]) }
            showHoverOverlay(on: t, item: items[i])
        }
        hovered = t
    }

    let photoGlyph = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.75)])))

    func showPill(on t: CALayer, item: ScatterItem) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let title = NSMutableAttributedString(string: item.title, attributes: [.font: pillFont, .foregroundColor: NSColor.white])
        if !item.subtitle.isEmpty {
            title.append(NSAttributedString(string: "  " + item.subtitle, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.5)]))
        }
        if let icon = tileIcon(item.id) {
            pillIcon.contents = icon; pillIcon.contentsGravity = .resizeAspect; pillIcon.backgroundColor = nil; pillIcon.cornerRadius = 3
        } else {
            pillIcon.contents = photoGlyph; pillIcon.contentsGravity = .center
            pillIcon.backgroundColor = CGColor(gray: 1, alpha: 0.12); pillIcon.cornerRadius = 8
        }
        let arrow: CGFloat = item.external ? 14 + 10 : 0 // gap + ↗ glyph
        let maxText = t.bounds.width - 2 * 9.5 - 9.5 - 16 - 7.5 - 12 - arrow
        let tw = min(ceil(title.size().width), max(maxText, 0))
        let w = 9.5 + 16 + 7.5 + tw + arrow + 12.5
        pillArrow.isHidden = !item.external
        pill.backgroundColor = CGColor(gray: 0, alpha: item.external ? 0.92 : 0.9)
        pillArrow.frame = CGRect(x: w - 12.5 - 10, y: 11, width: 10, height: 10)
        pill.frame = CGRect(x: (t.bounds.width - w) / 2, y: t.bounds.height - 9.5 - 32, width: w, height: 32)
        pillIcon.frame = CGRect(x: 9.5, y: 8, width: 16, height: 16)
        pillText.frame = CGRect(x: 33, y: 7, width: tw, height: 18)
        pillText.string = title
        for l in [pillText, pillIcon, pillArrow] { l.contentsScale = scale }
        if pill.superlayer !== t { t.addSublayer(pill); pill.opacity = 0 }
        CATransaction.commit()
        spring(pill, "opacity", to: 1.0, config.hover)
    }

    let pillArrow: CALayer = {
        let l = CALayer()
        l.contents = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.white])))
        l.contentsGravity = .resizeAspect
        return l
    }()

    func showHoverOverlay(on t: CALayer, item: ScatterItem) {
        guard let make = hoverOverlay else { return }
        hoverHost.rootView = make(item) { [weak self, weak t] in if let self, let t { self.open(t) } }
        hoverHost.frame = t.frame
        if hoverHost.superview !== self { addSubview(hoverHost) }
        hoverHost.isHidden = false
        hoverHost.wantsLayer = true
        if let l = hoverHost.layer { l.zPosition = 5; l.opacity = 0; spring(l, "opacity", to: 1.0, config.hover) }
    }

    func hideHoverOverlay() {
        // Hidden at once (a fade-out would race the next hover); it stays attached, so the next hover reuses its views and glass.
        hoverHost.isHidden = true
    }

    func tile(at e: NSEvent) -> CALayer? {
        let p = convert(e.locationInWindow, from: nil)
        return tiles.first { $0.frame.contains(p) }
    }
    #endif

    // MARK: open / scatter / close

    #if os(macOS)
    /// Press opens (Atlas); shift-click toggles selection; clicking empty space clears it. A press that moves
    /// more than 3 pt becomes a drag and closes what it opened.
    public override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if let o = opened { // a click on the image closes once it's clearly not a double-click (Fit ⇄ Fill); elsewhere at once
            guard tile(at: e) === o else { return close() }
            pendingClose?.cancel()
            if e.clickCount == 2 { return setFill(!fill, at: convert(e.locationInWindow, from: nil)) }
            let w = DispatchWorkItem { [weak self] in if self?.opened === o { self?.close() } }
            pendingClose = w; DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: w)
            return
        }
        guard let t = tile(at: e), let i = tiles.firstIndex(of: t) else { selected = []; return }
        press = (t, convert(e.locationInWindow, from: nil))
        // Opens on the press (the host hears a frame later, see open); a press that becomes a drag takes it back.
        // External items still act on mouse-up: leaving the app can't be taken back. On a Force Touch trackpad the
        // press may become a peek, so it opens on mouse-up instead.
        peek = .idle; openOnUp = e.associatedEventsMask.contains(.pressure)
        if e.modifierFlags.isDisjoint(with: [.command, .shift]), !items[i].external, !openOnUp { clickTime = e.timestamp; open(t) }
    }
    /// Force click to peek: pressure lifts the tile (1 → 1.06), the force click peeks, deeper (or a second force click)
    /// commits to the open; letting go of a peek drops it back. Only Force Touch trackpads send these.
    public override func pressureChange(with e: NSEvent) {
        guard let p = press, let i = tiles.firstIndex(of: p.tile), !items[i].external, e.modifierFlags.isDisjoint(with: [.command, .shift]) else { return }
        let t = p.tile, was = peek
        peek = peekStep(peek, stage: e.stage, pressure: e.pressure)
        switch (was, peek) {
        case (.idle, .idle), (.idle, .lift), (.lift, .lift), (.lift, .idle):
            let s = peek == .lift ? 1 + 0.06 * CGFloat(min((e.pressure - 0.3) / 0.7, 1)) : 1
            CATransaction.begin(); CATransaction.setDisableActions(true); t.transform = CATransform3DMakeScale(s, s, 1); CATransaction.commit()
        case (.idle, .peek), (.lift, .peek):
            spring(t, "transform.scale", to: 1.0, config.item, duration: config.openDuration)
            peeking = true; clickTime = e.timestamp; open(t)
            haptic("snap")
        case (.peek, .commit), (.peekEased, .commit):
            peeking = false; open(t, scatter: false) // tells the host, sharp image at full stage size
            move(t, to: stageRect(i), config.openDuration); scatterOthers(from: i)
        case (.peek, .idle), (.peekEased, .idle): close()
        default: break
        }
    }
    public override func mouseDragged(with e: NSEvent) {
        guard let p = press, let i = tiles.firstIndex(of: p.tile) else { return }
        let at = convert(e.locationInWindow, from: nil)
        guard hypot(at.x - p.at.x, at.y - p.at.y) > 3, dragURL(items[i].id) != nil else { return }
        press = nil
        peek = .idle; p.tile.transform = CATransform3DIdentity // a lifted tile settles before it leaves
        setHover(nil)
        let ids = selected.contains(items[i].id) ? [items[i].id] + selected.filter { $0 != items[i].id } : [items[i].id] // pressed tile on top
        let js = ids.compactMap { id in items.firstIndex { $0.id == id } }
        // Grid frames, not live ones: the press may have started opening the tile. Built before close() drops its image.
        let drags = js.compactMap { j -> NSDraggingItem? in
            guard let url = dragURL(items[j].id) else { return nil }
            let item = NSDraggingItem(pasteboardWriter: TileDrag(url: url as NSURL, id: items[j].id))
            item.setDraggingFrame(gridFrame(j), contents: js.count > 1 ? nil : tiles[j].contents)
            return item
        }
        if js.count > 1, let top = drags.first { // one stacked image with a count badge stands in for all of them
            let f = gridFrame(i), imgs = js.prefix(3).compactMap { tiles[$0].contents as! CGImage? }
            top.setDraggingFrame(f.insetBy(dx: -16, dy: -16), contents: Self.dragStack(imgs, count: js.count, size: f.size))
        }
        if opened === p.tile { close() } // the press opened it; a drag takes that back
        beginDraggingSession(with: drags, event: e, source: self)
    }

    /// Up to three thumbnails stacked (each 4 pt over and 3° turned from the one above), translucent, with a
    /// bold count in a glass-like capsule on the top card's top-trailing corner. 16 pt margin all round.
    static func dragStack(_ imgs: [CGImage], count: Int, size: CGSize) -> NSImage {
        NSImage(size: CGSize(width: size.width + 32, height: size.height + 32), flipped: false) { r in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            let card = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            for (k, img) in imgs.enumerated().reversed() { // back to front
                c.saveGState()
                c.translateBy(x: r.midX + CGFloat(k) * 4, y: r.midY - CGFloat(k) * 4)
                c.rotate(by: -CGFloat(k) * 3 * .pi / 180)
                c.setAlpha(0.85)
                c.addPath(CGPath(roundedRect: card, cornerWidth: 8, cornerHeight: 8, transform: nil)); c.clip()
                c.draw(img, in: card)
                c.restoreGState()
            }
            // ponytail: a drag image is a bitmap, so "glass" is a dark translucent fill with a bright hairline edge
            let text = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
            let w = max(22, text.size().width + 14)
            let badge = CGRect(x: r.midX + size.width / 2 - w / 2, y: r.midY + size.height / 2 - 11, width: w, height: 22)
            let capsule = NSBezierPath(roundedRect: badge, xRadius: 11, yRadius: 11)
            NSColor.black.withAlphaComponent(0.55).setFill(); capsule.fill()
            NSColor.white.withAlphaComponent(0.35).setStroke(); capsule.lineWidth = 0.5; capsule.stroke()
            text.draw(at: CGPoint(x: badge.midX - text.size().width / 2, y: badge.midY - text.size().height / 2))
            return true
        }
    }
    /// Pasteboard type of a dragged tile's id.
    nonisolated public static let dragIDType = NSPasteboard.PasteboardType("com.skcript.scatterkit.item-id")
    public override func mouseUp(with e: NSEvent) {
        guard let p = press, let i = tiles.firstIndex(of: p.tile) else { return }
        press = nil
        let id = items[i].id, was = peek
        peek = .idle
        if was == .peek || was == .peekEased { return close() } // let go of a peek: back to the tile
        if was == .commit { return }
        if openOnUp { spring(p.tile, "transform.scale", to: 1.0, config.item) } // settle a lift
        if e.modifierFlags.contains(.shift), let last = selected.last, let j = items.firstIndex(where: { $0.id == last }) { // range
            let range = items[min(i, j)...max(i, j)].map(\.id)
            selected += range.filter { !selected.contains($0) }
            return
        }
        guard e.modifierFlags.contains(.command) || e.modifierFlags.contains(.shift) else {
            if items[i].external { return onActivate(id) }
            if openOnUp, opened !== p.tile { clickTime = e.timestamp; open(p.tile) } // Force Touch: no peek, so a click
            return // the rest opened on mouse-down
        }
        if selected.contains(id) { selected.removeAll { $0 == id } } else { selected.append(id) } // ⌘-click toggles
    }
    @objc public override func selectAll(_ sender: Any?) { if opened == nil { selected = items.map(\.id) } } // ⌘A
    public override func menu(for e: NSEvent) -> NSMenu? {
        guard opened == nil || tile(at: e) === opened, let t = tile(at: e), let i = tiles.firstIndex(of: t) else { return nil }
        return tileMenu(items[i].id)
    }
    #endif

    var pendingOpen: String?

    /// Opens the tile for `id` the way a click/tap does, scrolling it into view first. If the tile isn't laid out yet
    /// (items about to change, no width), it opens on the next layout that has it.
    // An id that never arrives stays pending until one does, which suits deep links.
    public func open(id: String) {
        guard bounds.width > 0, frames.count == items.count, let i = items.firstIndex(where: { $0.id == id }) else { pendingOpen = id; return }
        if opened === tiles[i] { return }
        close()
        scrollTo(id: id)
        open(tiles[i])
    }

    /// Scrolls so the tile for `id` sits in the middle of the viewport.
    public func scrollTo(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let y = max(min(gridFrame(i).midY - viewportHeight / 2, frame.height - viewportHeight), 0)
        #if os(macOS)
        scroll(NSPoint(x: 0, y: y))
        #else
        if let sv = scrollView { sv.contentOffset.y = max(y, -sv.adjustedContentInset.top) }
        #endif
    }

    func open(_ t: CALayer, scatter: Bool = true) {
        guard let i = tiles.firstIndex(of: t) else { return }
        let t0 = clickTime ?? CACurrentMediaTime(); clickTime = nil
        let first = Self.signposter.beginInterval("open.firstFrame")
        onFirstFrame { [weak self] in
            Self.signposter.endInterval("open.firstFrame", first)
            self?.openFirstFrame = CACurrentMediaTime() - t0
            Self.log.notice("open: first frame \((CACurrentMediaTime() - t0) * 1000, format: .fixed(precision: 1)) ms")
        }
        setHover(nil)
        #if os(macOS)
        pill.removeFromSuperlayer() // no title pill on the opened tile
        #endif
        opened = t
        showChips(t, false)
        let id = items[i].id // the host hears of it after the first frame: its own update (SwiftUI state, say) never delays the click frame
        onFirstFrame { [weak self] in if let self, opened === t, !peeking { onOpen(id) } }
        #if os(macOS)
        setAccessibilityIdentifier("open:\(items[i].id)")
        headerView?.animator().alphaValue = 0.15
        #else
        accessibilityIdentifier = "open:\(items[i].id)"
        #endif
        t.zPosition = 10
        #if os(macOS)
        t.wantsExtendedDynamicRangeContent = true // HDR originals render brighter than SDR white while staged
        #endif
        let fit = stageRect(i), stage = peeking ? fit.insetBy(dx: fit.width * 0.2, dy: fit.height * 0.2) : fit // peek: 60%, centred
        loadFull(t, id: items[i].id, maxPixel: fullPixels(stage), openedAt: t0) // the thumbnail stays up until this lands
        axChanged(items[i].id)
        for d in [-1, 1] { if let j = neighbour(i, d) { _ = full(items[j].id, fullPixels(stageRect(j))) { _ in } } } // swipe-ready
        DispatchQueue.main.asyncAfter(deadline: .now() + config.openDuration) { [weak self] in
            guard let self, opened === t, !peeking else { return }
            #if os(macOS)
            if fill { setFill(true) }
            #endif
            guard let o = stageOverlay else { return }
            o.frame = stage; o.isHidden = zoom != 1; addSubview(o)
            #if os(macOS)
            o.wantsLayer = true; o.layer?.zPosition = 11 // above the opened tile (10), which shares this layer
            #endif
        }
        guard scatter else { return } // paged in: already on stage
        let sp = Self.signposter.beginAnimationInterval("open")
        DispatchQueue.main.asyncAfter(deadline: .now() + config.openDuration) { Self.signposter.endInterval("open", sp) }
        move(t, to: stage, config.openDuration)
        spring(t, "cornerRadius", to: config.cornerRadius * 2, config.item, duration: config.cornerDuration)
        guard peeking else { return scatterOthers(from: i) }
        for l in shown.values where l !== t { fade(l, to: 0.25, config.scatterFade, .linear) } // dimmed backdrop; close() restores
    }

    /// Where tile `i` sits while open: centred in the viewport, `config.stageMargin` clear of each edge, at most one pixel per screen pixel.
    func stageRect(_ i: Int) -> CGRect {
        let p = items[i].pixelSize
        #if os(iOS)
        var v = stageArea
        let bar = max((scrollView?.adjustedContentInset.bottom ?? 0) - 38, 0) // stageFrame's 50 pt margin less 12: the caption clears the bar by 12
        if items[i].bottomInset > 0, !infoShown { v.size.height -= items[i].bottomInset + bar } // the info panel hides the caption
        #else
        var v = visibleRect
        v.size.height -= items[i].bottomInset // room for the host's caption under the image
        #endif
        return stageFrame(aspect: items[i].aspect, native: CGSize(width: p.width / scale, height: p.height / scale), in: v, margin: config.stageMargin)
    }
    /// Starts the full-size decode for tile `i` after `dwell` seconds (hover / touch-down) so it's usually ready by the click.
    func prefetchFull(_ i: Int, dwell: Double = 0) {
        guard !items[i].external else { return }
        let id = items[i].id, px = fullPixels(stageRect(i))
        let w = DispatchWorkItem { [weak self] in _ = self?.full(id, px) { _ in } }
        hoverPrefetch?.cancel(); hoverPrefetch = w
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: w)
    }
    func fullPixels(_ r: CGRect) -> CGFloat { max(r.width, r.height) * scale }
    /// The next non-link tile from `i` in direction `d`.
    func neighbour(_ i: Int, _ d: Int) -> Int? {
        stride(from: i + d, to: d > 0 ? items.count : -1, by: d).first { !items[$0].external }
    }

    // MARK: pager (Photos-style): the neighbour waits one page to the side and slides in with the open tile

    var pageWidth: CGFloat { visibleRect.width + 24 }
    func tx(_ l: CALayer) -> CGFloat {
        ((l.animation(forKey: "page") != nil ? l.presentation() : nil) ?? l).value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
    }

    /// Puts the neighbour in direction `d` (full image if cached, else its thumbnail until the decode lands) at its open
    /// size one page to the side. False at either end.
    @discardableResult func stage(_ d: Int) -> Bool {
        guard let o = opened, let i = tiles.firstIndex(of: o), let j = neighbour(i, d) else {
            staged?.removeFromSuperlayer(); staged = nil; return false
        }
        let id = items[j].id, r = stageRect(j)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if staged?.name != id {
            staged?.removeFromSuperlayer()
            let l = CALayer()
            l.name = id; l.masksToBounds = true; l.contentsGravity = .resizeAspectFill; l.zPosition = 10
            l.cornerRadius = config.cornerRadius * 2; l.backgroundColor = tiles[j].backgroundColor
            l.contents = tiles[j].contents
            root.addSublayer(l); staged = l
            loadFull(l, id: id, maxPixel: fullPixels(r))
        }
        staged!.removeAnimation(forKey: "page")
        staged!.transform = CATransform3DIdentity; staged!.frame = r
        staged!.transform = CATransform3DMakeTranslation(CGFloat(d) * pageWidth + tx(o), 0, 0)
        CATransaction.commit()
        return true
    }

    /// Finger at `dx`: the open tile and the staged neighbour move 1:1; past either end it rubber-bands at 0.35×.
    func drag(_ dx: CGFloat) {
        guard let o = opened, let i = tiles.firstIndex(of: o) else { return }
        let d = dx < 0 ? 1 : -1
        setZoom(1, CGPoint(x: neighbour(i, d) == nil ? dx * 0.35 : dx, y: 0))
        stage(d)
    }

    /// Release at `dx` with velocity `vx`: past a quarter page, or a flick (> 500 pt/s) the same way, pages; else springs back.
    func release(_ dx: CGFloat, vx: CGFloat) {
        let d = dx < 0 ? 1 : -1
        let go = staged != nil && pagerCommits(dx: dx, vx: vx, width: visibleRect.width)
        if go { return commit(d, v: vx) }
        guard let o = opened else { return }
        zoom = 1; pan = .zero
        page(o, to: 0, v: vx)
        if let s = staged { page(s, to: CGFloat(d) * pageWidth, v: vx) }
        stageOverlay?.isHidden = false
    }

    /// Pager spring (damping ratio 0.9, ~0.35 s settle) on transform.translation.x, starting at velocity `v` pt/s.
    @discardableResult func page(_ l: CALayer, to: CGFloat, v: CGFloat, done: (() -> Void)? = nil) -> Double {
        let from = tx(l)
        CATransaction.begin(); CATransaction.setDisableActions(true); CATransaction.setCompletionBlock(done)
        l.removeAnimation(forKey: "transform")
        l.setValue(to, forKeyPath: "transform.translation.x")
        var settle = 0.0
        if !reduceMotion && abs(to - from) > 0.5 {
            let a = CASpringAnimation(keyPath: "transform.translation.x")
            a.mass = 1; a.stiffness = 640; a.damping = 2 * 0.9 * sqrt(640)
            a.initialVelocity = min(max(v / (to - from), 0), 12) // toward the target only
            a.fromValue = from; a.toValue = to; a.duration = a.settlingDuration; settle = a.duration
            l.add(a, forKey: "page")
        } else if reduceMotion { crossfade(l) }
        CATransaction.commit()
        return settle
    }

    /// The staged neighbour becomes the open tile: the real tile takes its place and pixels, the staged layer
    /// carries the outgoing picture off, and the outgoing tile goes home unseen into the new scatter.
    func commit(_ d: Int, v: CGFloat) {
        guard let o = opened, let i = tiles.firstIndex(of: o), let s = staged, let j = neighbour(i, d) else { return }
        let n = tiles[j], from = tx(o), into = tx(s), old = o.frame, pixels = o.contents
        staged = nil
        stageOverlay?.removeFromSuperview()
        zoom = 1; pan = .zero
        let y0 = visibleRect.minY
        if !visibleRect.contains(gridFrame(j)) { scrollTo(id: items[j].id) }
        let dy = visibleRect.minY - y0 // keep both pictures where they are on screen
        scatterOthers(from: j, duration: 0.25) // the field settles around the new tile (all faded)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for t in [n, o] { t.removeAllAnimations(); t.transform = CATransform3DIdentity }
        n.frame = stageRect(j); n.transform = CATransform3DMakeTranslation(into, 0, 0)
        n.contents = s.contents; n.opacity = 1; n.cornerRadius = config.cornerRadius * 2
        s.removeAllAnimations(); s.transform = CATransform3DIdentity
        s.frame = old.offsetBy(dx: 0, dy: dy); s.contents = pixels; s.transform = CATransform3DMakeTranslation(from, 0, 0)
        o.opacity = 0; o.zPosition = 0; o.cornerRadius = config.cornerRadius; o.contents = nil // updateVisible refills the thumbnail
        showChips(o, true)
        #if os(macOS)
        o.wantsExtendedDynamicRangeContent = false
        #endif
        CATransaction.commit()
        open(n, scatter: false)
        let t0 = CACurrentMediaTime()
        let settle = page(n, to: 0, v: v)
        page(s, to: from - into, v: v) {
            s.removeFromSuperlayer()
            Self.log.notice("pager commit: spring \(settle, format: .fixed(precision: 3)) s, landed in \(CACurrentMediaTime() - t0, format: .fixed(precision: 3)) s")
        }
        updateVisible()
    }

    /// While a tile is open, slides in the next / previous tile in layout order (links skipped), exactly like a swipe
    /// with a brisk programmatic flick; at either end the open tile nudges.
    public func openNext() { step(1) }
    public func openPrevious() { step(-1) }

    func step(_ d: Int) {
        guard let o = opened else { return }
        guard stage(d) else {
            if reduceMotion { return }
            let a = CAKeyframeAnimation(keyPath: "position.x")
            a.values = [0, CGFloat(d) * -24, 0]; a.isAdditive = true; a.duration = 0.25
            return o.add(a, forKey: "nudge")
        }
        commit(d, v: -CGFloat(d) * pageWidth * 2)
    }

    /// Full-size decode off the main thread, kept in a 3-image LRU; a hit returns at once, otherwise `done` gets it on main.
    /// A decode already running for the same key is joined, not repeated.
    func full(_ id: String, _ px: CGFloat, _ done: @escaping (CGImage?) -> Void) -> CGImage? {
        guard px.isFinite, px > 0 else { return nil } // no viewport (headless)
        let key = "\(id)#\(items.first { $0.id == id }?.revision ?? 0)@full\(Int(px))"
        if let i = fullLRU.firstIndex(where: { $0.key == key }) { let e = fullLRU.remove(at: i); fullLRU.append(e); return e.img }
        if inFlight[key] != nil { inFlight[key]!.append(done); return nil }
        inFlight[key] = [done]
        let content = content
        let op = BlockOperation {
            let img = content(id, px, true)
            DispatchQueue.main.async {
                let waiting = self.inFlight.removeValue(forKey: key) ?? []
                guard let img else { return waiting.forEach { $0(nil) } }
                self.fullLRU.append((key, img)); if self.fullLRU.count > 3 { self.fullLRU.removeFirst() }
                waiting.forEach { $0(img) }
            }
        }
        op.queuePriority = .veryHigh // the open tile's full image jumps the thumbnail backlog
        Self.decodeQueue.addOperation(op)
        return nil
    }

    /// The full image replaces the thumbnail on the open or staged layer under a 0.1 s crossfade. `openedAt`: this is an
    /// open; an image that's already decoded goes up on the first frame (the click frame never uploads it), so the fade
    /// lands inside the spring; one still decoding swaps when it lands.
    func loadFull(_ t: CALayer, id: String, maxPixel: CGFloat, openedAt t0: CFTimeInterval? = nil) {
        let swap = t0.map { _ in Self.signposter.beginInterval("open.swap") }
        let set = { [weak self] (img: CGImage?, warm: Bool) in
            guard let self, opened === t || staged === t else { return } // closed or paged away: a late result is dropped
            guard let img else { // not on disk yet: thumbnail + spinner, ask again in 1 s until it lands or the tile closes
                fullWait.insert(t); setSpinner(true, on: t)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    guard opened === t || staged === t else { fullWait.remove(t); return syncSpinner(t) }
                    loadFull(t, id: id, maxPixel: maxPixel)
                }
                return
            }
            if fullWait.remove(t) != nil { syncSpinner(t) }
            if t.contents != nil && !reduceMotion {
                let f = CATransition()
                #if os(iOS)
                f.duration = 0.2
                #else
                f.duration = 0.1
                #endif
                t.add(f, forKey: "fade")
            }
            setContents(t, img)
            guard let t0, let swap else { return }
            Self.signposter.endInterval("open.swap", swap)
            openSwap = (CACurrentMediaTime() - t0, warm)
            Self.log.notice("open: sharp image at \((CACurrentMediaTime() - t0) * 1000, format: .fixed(precision: 1)) ms (\(warm ? "warm" : "cold", privacy: .public))")
        }
        guard let img = full(id, maxPixel, { set($0, false) }) else { return }
        if t0 != nil { onFirstFrame { set(img, true) } } else { set(img, true) }
    }

    func scatterOthers(from origin: Int, duration: Double? = nil) {
        let c0 = gridFrame(origin), near = nearRect, v = visibleRect
        let idx = tiles.indices.filter { $0 != origin && gridFrame($0).intersects(near) } // the rest hold no pixels and stay put
        let plan = scatterPlan(idx.map(gridFrame), from: CGPoint(x: c0.midX, y: c0.midY),
                               screen: v.insetBy(dx: -v.width * 0.05, dy: -v.height * 0.05), config)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (k, i) in idx.enumerated() {
            let t = tiles[i], (to, how) = plan[k]
            if how == .snap { place(t, to, opacity: 0); continue }
            if t.frame != to { move(t, to: to, duration ?? config.scatterDuration) } // fade-only: back home after a step
            fade(t, to: 0, config.scatterFade, .linear)
        }
        CATransaction.commit()
    }

    public func close() {
        guard let o = opened else { return }
        peeking = false
        #if os(iOS)
        haptic(dismissing ? "success" : "snap"); dismissing = false // drag-to-close lands: success; tap / flick / pinch close: snap
        #endif
        stageOverlay?.removeFromSuperview()
        staged?.removeFromSuperlayer(); staged = nil
        zoom = 1; pan = .zero
        CATransaction.begin(); CATransaction.setDisableActions(true)
        o.removeAnimation(forKey: "transform"); o.removeAnimation(forKey: "page"); o.transform = CATransform3DIdentity
        #if os(macOS)
        o.wantsExtendedDynamicRangeContent = false
        #endif
        CATransaction.commit()
        let sp = Self.signposter.beginAnimationInterval("close")
        DispatchQueue.main.asyncAfter(deadline: .now() + config.closeDuration) { Self.signposter.endInterval("close", sp) }
        spring(o, "cornerRadius", to: config.cornerRadius, config.item, duration: config.cornerDuration)
        let v = visibleRect, screen = v.insetBy(dx: -v.width * 0.05, dy: -v.height * 0.05)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, t) in tiles.enumerated() where t.opacity < 1 || t === o { // springs home; opacity returns a little slower
            let home = gridFrame(i)
            guard home.intersects(screen) else { place(t, home, opacity: 1); continue } // off-screen: just put back
            if t.frame != home { move(t, to: home, config.closeDuration) }
            fade(t, to: 1, config.closeFade, .easeOut)
        }
        CATransaction.commit()
        o.zPosition = 0
        fullWait.remove(o); syncSpinner(o) // a pending full-size fetch stops retrying (its late result is dropped)
        o.contents = nil // drop the full-size image; updateVisible refills from the thumbnail cache
        showChips(o, true)
        opened = nil
        onOpen(nil)
        #if os(macOS)
        setAccessibilityIdentifier(nil)
        headerView?.animator().alphaValue = 1
        #else
        accessibilityIdentifier = nil
        #endif
        updateVisible()
        if let i = tiles.firstIndex(of: o) { axChanged(items[i].id) }
    }

    // MARK: keys, paste, drop

    #if os(macOS)
    public override func keyDown(with e: NSEvent) {
        if onKey(e, targetID) { return }
        switch e.keyCode {
        case 53: if opened != nil { close() } else { selected = [] } // Esc
        case 123, 126: if opened != nil { openPrevious() } else { moveSelection(e.keyCode) } // ← ↑
        case 124, 125: if opened != nil { openNext() } else { moveSelection(e.keyCode) } // → ↓
        case 49, 36: // Space / ↩ opens the selected tile
            guard opened == nil, let i = items.firstIndex(where: { $0.id == selected.last }) else { return super.keyDown(with: e) }
            items[i].external ? onActivate(items[i].id) : open(id: items[i].id)
        case 51, 117: // ⌫ / ⌦: the opened tile, else the selection, else the hovered tile
            if let t = opened, let i = tiles.firstIndex(of: t) { onDelete(items[i].id) }
            else if let last = selected.last { onDelete(last) } // the host expands a selected id to the whole selection
            else if let t = hovered, let i = tiles.firstIndex(of: t) { onDelete(items[i].id) }
        default: super.keyDown(with: e)
        }
    }
    /// ← → step by index, ↑ ↓ to the nearest tile in the row above / below; the first press selects the hovered or first tile.
    func moveSelection(_ key: UInt16) {
        guard !items.isEmpty else { return }
        guard let i = items.firstIndex(where: { $0.id == selected.last }) ?? hovered.flatMap({ tiles.firstIndex(of: $0) }) else {
            selected = [items[0].id]; return
        }
        var j = i
        switch key {
        case 123: j = max(i - 1, 0)
        case 124: j = min(i + 1, items.count - 1)
        default:
            let f = gridFrame(i), rows = Set(frames.map(\.minY)).sorted()
            guard let r = rows.firstIndex(of: f.minY), rows.indices.contains(r + (key == 125 ? 1 : -1)) else { return }
            let y = rows[r + (key == 125 ? 1 : -1)]
            j = frames.indices.filter { frames[$0].minY == y }.min { abs(frames[$0].midX - f.midX) < abs(frames[$1].midX - f.midX) } ?? i
        }
        selected = [items[j].id]
        scrollToVisible(gridFrame(j).insetBy(dx: 0, dy: -config.gap))
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged) // VoiceOver follows arrow-key selection
        if let e = axTiles().first(where: { $0.accessibilityIdentifier() == items[j].id }) { NSAccessibility.post(element: e, notification: .focusedUIElementChanged) }
    }
    @objc public func paste(_ sender: Any?) { onPaste() } // Edit ▸ Paste reaches us via the responder chain
    @objc public func copy(_ sender: Any?) { onCopy(targetID) }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? ScatterGridView !== self else { return [] } // own tiles: not a re-import
        cosmos.begin(in: self); return .copy
    }
    public override func draggingExited(_ sender: NSDraggingInfo?) { cosmos.end() }
    public override func draggingEnded(_ sender: NSDraggingInfo) { cosmos.end() } // cancelled over the grid
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        cosmos.land()
        Self.dropURLs(from: sender.draggingPasteboard) { [weak self] in if !$0.isEmpty { self?.onDropURLs($0) } }
        return true
    }
    /// Drag types the grid (and host drop targets) accept: file URLs, web URLs, file promises (Photos, Mail), raw PNG/TIFF.
    public static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }
    /// URLs first; else file promises received into a temp `ScatterDrop-` dir; else raw image data written there as PNG.
    /// `done` runs on main. The temp dir is the receiver's to delete after import.
    public static func dropURLs(from pb: NSPasteboard, _ done: @escaping @MainActor @Sendable ([URL]) -> Void) {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty { return done(urls) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScatterDrop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard !promises.isEmpty else {
            let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            let url = dir.appendingPathComponent("Dropped.png")
            guard let png, (try? png.write(to: url)) != nil else { try? FileManager.default.removeItem(at: dir); return done([]) }
            return done([url])
        }
        let group = DispatchGroup(), got = OSAllocatedUnfairLock<[URL]>(initialState: [])
        for p in promises {
            for _ in 0..<max(p.fileTypes.count, 1) { group.enter() } // reader runs once per promised file
            p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .init()) { url, error in
                if error == nil { got.withLock { $0.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = got.withLock { $0 }
            if urls.isEmpty { try? FileManager.default.removeItem(at: dir) }
            MainActor.assumeIsolated { done(urls) }
        }
    }
    #endif

    // MARK: accessibility: tiles are bare layers, so VoiceOver gets one stand-in element per on-screen tile

    var axKey: [String] = [], axCache: [TileElement] = []

    /// The tiles within a screen of the viewport (only the open one while a tile is open), rebuilt when their ids or frames change.
    func axTiles() -> [TileElement] {
        let near = nearRect
        let idx = opened.flatMap { tiles.firstIndex(of: $0) }.map { [$0] } ?? tiles.indices.filter { gridFrame($0).intersects(near) }
        let frame = { (i: Int) in self.opened === self.tiles[i] ? self.tiles[i].frame : self.gridFrame(i) }
        var key = idx.map { "\(items[$0].id)@\(frame($0))\(selected.contains(items[$0].id) ? "+" : "")" } + ["\(bounds.height)"]
        #if os(iOS)
        key.append("\(selecting)") // press toggles in Select mode; traits carry .selected
        #endif
        guard key != axKey else { return axCache }
        axKey = key
        axCache = idx.map { i in
            let it = items[i], label = it.title.isEmpty ? it.id : it.title
            let value = it.external ? String(localized: "Link, \(i + 1) of \(items.count)") // kind and position for VoiceOver
                : String(localized: "Image, \(i + 1) of \(items.count)")
            let id = it.id
            #if os(macOS)
            let e = TileElement()
            e.setAccessibilityParent(self); e.setAccessibilityRole(.button); e.setAccessibilityRoleDescription("image")
            e.setAccessibilityLabel(label); e.setAccessibilityValue(value); e.setAccessibilityHelp(it.subtitle.isEmpty ? nil : it.subtitle)
            let f = frame(i) // parent space is unflipped
            e.setAccessibilityFrameInParentSpace(CGRect(x: f.minX, y: bounds.height - f.maxY, width: f.width, height: f.height)); e.setAccessibilityIdentifier(it.id)
            e.setAccessibilitySelected(selected.contains(it.id))
            e.showMenu = { [weak self] in
                guard let self, opened == nil || opened === layers[id], let menu = tileMenu(id) else { return false }
                menu.popUp(positioning: nil, at: CGPoint(x: f.midX, y: f.midY), in: self); return true
            }
            e.reveal = { [weak self] in
                guard let self, opened == nil, let j = items.firstIndex(where: { $0.id == id }), !gridFrame(j).intersects(visibleRect) else { return }
                scrollToVisible(gridFrame(j).insetBy(dx: 0, dy: -config.gap))
            }
            #else
            let e = TileElement(accessibilityContainer: self)
            e.accessibilityLabel = label; e.accessibilityValue = value; e.accessibilityHint = it.subtitle.isEmpty ? nil : it.subtitle
            e.accessibilityTraits = selected.contains(it.id) ? [.image, .button, .selected] : [.image, .button]
            e.accessibilityFrameInContainerSpace = frame(i); e.accessibilityIdentifier = it.id
            e.actions = { [weak self] in self.map { $0.opened == nil && !$0.selecting ? $0.tileActions(it) : [] } ?? [] }
            #endif
            e.press = { [weak self] in
                guard let self, let j = items.firstIndex(where: { $0.id == id }) else { return }
                #if os(iOS)
                if selecting { return selected.contains(id) ? selected.removeAll { $0 == id } : selected.append(id) } // Select mode: toggle, like a tap
                #endif
                if opened != nil { close() } else if items[j].external { onActivate(id) } else { open(id: id) }
            }
            return e
        }
        return axCache
    }

    /// Moves VoiceOver to the tile for `id` after it opens or closes.
    func axChanged(_ id: String) {
        #if os(macOS)
        NSAccessibility.post(element: self, notification: .layoutChanged)
        #else
        UIAccessibility.post(notification: .layoutChanged, argument: axTiles().first { $0.accessibilityIdentifier == id })
        #endif
    }

    #if os(macOS)
    public override func accessibilityChildren() -> [Any]? { (super.accessibilityChildren() ?? []) + axTiles() }
    public override func accessibilitySelectedChildren() -> [Any]? { axTiles().filter { $0.isAccessibilitySelected() } }
    #else
    public override var accessibilityElements: [Any]? { get { subviews + axTiles() } set {} }
    #endif

    // MARK: zoom on the opened tile: transform = translate(pan) · scale(zoom) about its centre

    /// Zoom to `z` keeping the content under `p` fixed.
    func zoomed(_ z: CGFloat, at p: CGPoint) -> CGPoint {
        guard let t = opened else { return pan }
        let q = CGPoint(x: (p.x - t.position.x - pan.x) / zoom, y: (p.y - t.position.y - pan.y) / zoom)
        return clamp(CGPoint(x: p.x - t.position.x - z * q.x, y: p.y - t.position.y - z * q.y), z)
    }
    /// The image's edges can't move inside its staged frame.
    func clamp(_ o: CGPoint, _ z: CGFloat) -> CGPoint {
        guard let t = opened else { return o }
        let mx = max(0, t.bounds.width * (z - 1) / 2), my = max(0, t.bounds.height * (z - 1) / 2)
        return CGPoint(x: min(max(o.x, -mx), mx), y: min(max(o.y, -my), my))
    }
    func setZoom(_ z: CGFloat, _ o: CGPoint, animated: Bool = false) {
        guard let t = opened else { return }
        zoom = z; pan = o
        stageOverlay?.isHidden = z != 1
        let x = CATransform3DMakeAffineTransform(CGAffineTransform(translationX: o.x, y: o.y).scaledBy(x: z, y: z))
        if animated { spring(t, "transform", to: NSValue(caTransform3D: x), config.item) }
        else { CATransaction.begin(); CATransaction.setDisableActions(true); t.removeAnimation(forKey: "transform"); t.transform = x; CATransaction.commit() }
    }
    /// A pinch at unbanded zoom `raw`: rubber-bands past minZoom…maxZoom while live (the other tiles stay where they are).
    /// On release: below 0.8× closes, below 1× springs back, past maxZoom springs back to it.
    func pinch(_ raw: CGFloat, at p: CGPoint, ended: Bool) {
        let z = rubberZoom(raw, config.minZoom, config.maxZoom)
        setZoom(z, z < 1 ? .zero : zoomed(z, at: p))
        guard ended else { return }
        if zoom < 0.8 { return close() }
        if zoom < 1 { return setZoom(1, .zero, animated: true) }
        if zoom > config.maxZoom { setZoom(config.maxZoom, zoomed(config.maxZoom, at: p), animated: true) }
        sharpen()
    }
    /// Re-decode at the zoomed size; the current pixels stay up until it's ready.
    func sharpen() {
        guard let t = opened, zoom > 1, let i = tiles.firstIndex(of: t) else { return }
        loadFull(t, id: items[i].id, maxPixel: max(t.bounds.width, t.bounds.height) * scale * zoom)
    }

    #if os(macOS)
    var pendingClose: DispatchWorkItem?
    /// Fit (the staged frame, 40 pt clear) or Fill (zoomed to cover the viewport); the last choice sticks across opens.
    var fill: Bool {
        get { UserDefaults.standard.bool(forKey: "ScatterCore.fill") }
        set { UserDefaults.standard.set(newValue, forKey: "ScatterCore.fill") }
    }
    func setFill(_ on: Bool, at p: CGPoint? = nil) {
        fill = on
        guard let t = opened else { return }
        let v = visibleRect, z = on ? max(v.width / t.bounds.width, v.height / t.bounds.height, 1) : 1
        setZoom(z, z == 1 ? .zero : p.map { zoomed(z, at: $0) } ?? .zero, animated: true)
        sharpen()
    }
    /// Pinch zooms around the fingers; releasing below 0.8× closes, below 1× springs back.
    public override func magnify(with e: NSEvent) {
        guard opened != nil else { // pinch out over a hovered tile opens it, once per gesture
            guard let t = hovered, !e.modifierFlags.contains(.command) else { return super.magnify(with: e) }
            if e.phase == .began { pinchRaw = 0; swiped = false }
            pinchRaw += e.magnification
            if !swiped, pinchRaw > 0.15 { swiped = true; open(t) }
            return
        }
        if e.phase == .began { pinchRaw = zoom; swiped = false }
        guard !swiped else { return } // the rest of the pinch that opened it doesn't zoom
        pinchRaw *= 1 + e.magnification
        pinch(pinchRaw, at: convert(e.locationInWindow, from: nil), ended: e.phase == .ended || e.phase == .cancelled)
    }
    /// Two-finger double tap toggles 1× and 2.5× at the tap point.
    public override func smartMagnify(with e: NSEvent) {
        guard opened != nil else { return super.smartMagnify(with: e) }
        if zoom > 1 { return setZoom(1, .zero, animated: true) }
        setZoom(2.5, zoomed(2.5, at: convert(e.locationInWindow, from: nil)), animated: true)
        sharpen()
    }
    /// While a tile is open: ⌘-scroll zooms, scroll pans a zoomed image, and the grid behind never scrolls.
    public override func scrollWheel(with e: NSEvent) {
        guard opened != nil else { return super.scrollWheel(with: e) }
        if e.modifierFlags.contains(.command) {
            let z = min(max(zoom * (1 + e.scrollingDeltaY * 0.01), 1), config.maxZoom)
            setZoom(z, zoomed(z, at: convert(e.locationInWindow, from: nil)))
            if e.phase == .ended || e.momentumPhase == .ended || (e.phase == [] && e.momentumPhase == []) { sharpen() }
        } else if zoom > 1 {
            setZoom(zoom, clamp(CGPoint(x: pan.x + e.scrollingDeltaX, y: pan.y + e.scrollingDeltaY), zoom))
        } else if e.phase == .began {
            swiped = false
        } else if !swiped, e.phase == .changed, abs(e.scrollingDeltaX) > 6, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) { // two-finger swipe: one step per gesture
            swiped = true; step(e.scrollingDeltaX < 0 ? 1 : -1); haptic("tick") // Force Touch alignment
        } else if !swiped, e.phase == .changed, abs(e.scrollingDeltaY) > 6, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX),
                  (e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY) > 0 { // fingers move down: natural → +dy, classic → -dy
            swiped = true; close()
        }
    }
    #endif
}

#if os(macOS)
typealias AXElement = NSAccessibilityElement
#else
typealias AXElement = UIAccessibilityElement
#endif

/// VoiceOver stand-in for a tile layer; pressing / activating it runs `press`.
final class TileElement: AXElement {
    var press: () -> Void = {}
    #if os(macOS)
    var showMenu: () -> Bool = { false }, reveal: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { press(); return true }
    override func accessibilityPerformShowMenu() -> Bool { showMenu() } // VO-Shift-M: the host's tile menu at the tile's centre
    override func setAccessibilityFocused(_ focused: Bool) { super.setAccessibilityFocused(focused); if focused { reveal() } } // scroll an offscreen tile in
    #else
    var actions: () -> [UIAccessibilityCustomAction] = { [] }
    override func accessibilityActivate() -> Bool { press(); return true }
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? { get { actions() } set {} }
    #endif
}

#if os(macOS)

extension ScatterGridView: NSDraggingSource {
    /// Copies out; in the app only host drop targets take it (draggingEntered refuses the grid's own tiles).
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy // in-app too: host drop targets (a sidebar row) read `dragIDType`
    }
}

/// A dragged tile: the URL's own pasteboard types plus the tile id.
final class TileDrag: NSObject, NSPasteboardWriting {
    let url: NSURL, id: String
    init(url: NSURL, id: String) { self.url = url; self.id = id }
    func writableTypes(for pb: NSPasteboard) -> [NSPasteboard.PasteboardType] { url.writableTypes(for: pb) + [ScatterGridView.dragIDType] }
    func pasteboardPropertyList(forType t: NSPasteboard.PasteboardType) -> Any? { t == ScatterGridView.dragIDType ? id : url.pasteboardPropertyList(forType: t) }
}

/// An NSHostingView that only claims hits on its interactive content.
final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        guard v === self else { return v }
        // SwiftUI controls have no NSView: super answers `self` everywhere. Drawn content (a button, a chip) has its
        // own sublayer, transparent padding only the root, so the layer tree says whether this point is ours.
        // ponytail: any drawn pixel claims the press, not only controls; tag hit rects via preference if a label must pass through.
        guard let l = layer, let hit = l.hitTest(point), hit !== l else { return nil }
        return self
    }
}
#endif
