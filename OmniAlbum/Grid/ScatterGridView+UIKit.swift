import os
#if os(iOS)
import UIKit

/// iOS input for `ScatterGridView`: tap opens (or closes), long-press shows the tile's context menu, pinch zooms the
/// opened tile. Hover, keys, drag and drop are macOS-only. Host it inside a `UIScrollView` (or use `ScatterGrid`).
extension ScatterGridView {
    var root: CALayer { layer }
    var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    var scale: CGFloat { window?.screen.scale ?? 3 }
    var scrollView: UIScrollView? { superview as? UIScrollView }
    var visibleRect: CGRect { scrollView?.bounds ?? bounds }
    var viewportHeight: CGFloat { scrollView?.bounds.height ?? 0 }
    var needsLayout: Bool { get { false } set { if newValue { setNeedsLayout() } } }

    func setFrameSize(_ s: CGSize) { frame.size = s; scrollView?.contentSize = s }
    func setHover(_ t: CALayer?) {}

    public override func layoutSubviews() { super.layoutSubviews(); relayout() }
    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scrollWatch = scrollView?.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateVisible() } } // KVO fires on main (scrolling)
    }

    func addGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self; tap.name = "tap" // touch-down starts the full-size decode
        addGestureRecognizer(tap)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped)) // zoom; only while open (the single tap waits only then)
        double.numberOfTapsRequired = 2; double.name = "zoom"; double.delegate = self
        addGestureRecognizer(double)
        addInteraction(UIContextMenuInteraction(delegate: self))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        let up = UISwipeGestureRecognizer(target: self, action: #selector(swipedUp)) // the scroll view is off while a tile is open
        up.direction = .up; up.delegate = self
        addGestureRecognizer(up)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        down.direction = .down; down.delegate = self
        addGestureRecognizer(down)
        let side = UIPanGestureRecognizer(target: self, action: #selector(swipedSideways)) // next / previous while open
        side.name = "step"; side.maximumNumberOfTouches = 1; side.delegate = self
        addGestureRecognizer(side)
        NotificationCenter.default.addObserver(self, selector: #selector(contentSizeChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
    }

    /// Dynamic Type changed: rebuild the link badges at the new size.
    @objc func contentSizeChanged() {
        for (i, t) in tiles.enumerated() where items[i].external { setBadge(items[i], on: t) }
        relayout()
    }

    /// VoiceOver two-finger scrub closes the open tile.
    public override func accessibilityPerformEscape() -> Bool {
        guard opened != nil else { return false }
        close()
        return true
    }

    /// The sideways pan only begins on an open tile: zoomed it pans the image, else it needs a mostly horizontal start
    /// (or, info panel down, a downward one: drag to close), so swipe-up and pinch still work. Double-tap zoom only begins on an open tile.
    public override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g.name == "zoom" { return opened != nil }
        guard g.name == "step", let p = g as? UIPanGestureRecognizer else { return super.gestureRecognizerShouldBegin(g) }
        // root cause: UIKit strips the pan's hysteresis, so translation here (and at .began) is ~0 and jitter picks the axis:
        // a downward drag failed `t.y > 0` or began as a sideways page. Velocity carries the real direction.
        let v = p.velocity(in: self)
        return opened != nil && (zoom > 1 || abs(v.x) > abs(v.y) || (!infoShown && v.y > 0))
    }

    /// Double tap: 2× at the tap point, again back to fit.
    @objc func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoom > 1 { return setZoom(1, .zero, animated: true) }
        setZoom(2, zoomed(2, at: g.location(in: self)), animated: true)
        sharpen()
    }

    /// With the info panel up: the top 42 % of the viewport below the bars (the host's panel covers the rest).
    var stageArea: CGRect {
        let v = visibleRect
        guard infoShown else { return v }
        let top = (scrollView?.adjustedContentInset.top ?? 0) + 20 - config.stageMargin // stageFrame adds the margin back: 20 pt under the bar
        return CGRect(x: v.minX, y: v.minY + top, width: v.width, height: v.height * 0.42 - top)
    }

    /// The open tile springs to its stage for the current `infoShown` (unzoomed), re-decoding at that size.
    func restage() {
        guard let t = opened, let i = tiles.firstIndex(of: t) else { return }
        staged?.removeFromSuperlayer(); staged = nil
        setZoom(1, .zero, animated: zoom != 1)
        let r = stageRect(i)
        move(t, to: r, config.openDuration)
        stageOverlay?.frame = r
        loadFull(t, id: items[i].id, maxPixel: fullPixels(r))
    }

    /// Photos-style pager: the open tile and its staged neighbour follow the finger 1:1 (see `drag` / `release`).
    @objc func swipedSideways(_ g: UIPanGestureRecognizer) {
        guard let o = opened else { return }
        if zoom > 1 { // zoomed: one finger pans the image, edges clamped
            let d = g.translation(in: self); g.setTranslation(.zero, in: self)
            return setZoom(zoom, clamp(CGPoint(x: pan.x + d.x, y: pan.y + d.y), zoom))
        }
        let t = g.translation(in: self)
        if g.state == .began { let v = g.velocity(in: self); dismissing = abs(v.y) > abs(v.x); bumped = false; haptic("prepare") } // velocity: see gestureRecognizerShouldBegin
        if dismissing { // Photos-style drag down: the image follows the finger 1:1 (upward rubber-bands at 0.35×), shrinking to 0.6× over a screen height
            switch g.state {
            case .began, .changed:
                setZoom(1 - min(max(t.y, 0) / visibleRect.height, 1) * 0.4, CGPoint(x: t.x, y: max(t.y, t.y * 0.35)))
                if (t.y > 80) != bumped { bumped.toggle(); if bumped { haptic("select") } } // past here, letting go closes (close plays success)
            case .ended where t.y > 80 || g.velocity(in: self).y > 500:
                CATransaction.begin(); CATransaction.setDisableActions(true) // close springs home from where the finger left it
                let f = o.frame; o.transform = CATransform3DIdentity; o.frame = f
                CATransaction.commit()
                close()
            default: dismissing = false; setZoom(1, .zero, animated: true) // not far enough: springs back, no cue
            }
            return
        }
        switch g.state {
        case .began:
            let t0 = CACurrentMediaTime()
            haptic("prepare")
            dragBase = tx(o) // catch a tile still sliding in
            o.removeAnimation(forKey: "page")
            stageOverlay?.isHidden = true
            drag(dragBase + g.translation(in: self).x)
            Self.log.notice("pager staged in \((CACurrentMediaTime() - t0) * 1000, format: .fixed(precision: 2)) ms")
        case .changed: drag(dragBase + g.translation(in: self).x)
        default:
            release(dragBase + g.translation(in: self).x, vx: g.state == .ended ? g.velocity(in: self).x : 0)
            if opened !== o { haptic("snap") } // committed to the neighbour
        }
    }

    @objc func swipedUp(_ g: UISwipeGestureRecognizer) {
        if let t = opened, zoom <= 1, let i = tiles.firstIndex(of: t) { haptic("tick"); onInfo?(items[i].id) }
    }

    @objc func swipedDown(_ g: UISwipeGestureRecognizer) {
        if opened != nil, zoom <= 1 { if infoShown { onInfo?(nil) } else { close() } } // ponytail: flick closes like Esc; the follow-finger pan stays for slow drags
    }

    /// Photos-style corner badge on `external` tiles so a link never passes for an image: favicon (else a link
    /// glyph) + `subtitle` (else `title`). A sublayer of the tile, so it rides every spring.
    // A dark capsule rather than Liquid Glass: glass needs a UIView and tiles are bare layers.
    func setBadge(_ item: ScatterItem, on t: CALayer) {
        badge(t)?.removeFromSuperlayer()
        guard item.external else { return }
        let b = CALayer(), icon = CALayer(), text = CATextLayer()
        b.name = "badge"; b.zPosition = 2; b.backgroundColor = CGColor(gray: 0, alpha: 0.65) // white 11 pt text ≥ 4.5:1 even over a white tile
        icon.contentsGravity = .resizeAspect; icon.cornerRadius = 3; icon.masksToBounds = true
        let font = badgeFont
        icon.contents = tileIcon(item.id) ?? UIImage(systemName: "link", withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold))
            .flatMap { g in UIGraphicsImageRenderer(size: g.size).image { _ in g.withTintColor(.white).draw(at: .zero) }.cgImage }
        text.string = NSAttributedString(string: item.subtitle.isEmpty ? item.title : item.subtitle,
                                         attributes: [.font: font, .foregroundColor: UIColor.white])
        text.truncationMode = .end
        for l in [b, icon, text] { l.contentsScale = scale }
        b.addSublayer(icon); b.addSublayer(text); t.addSublayer(b)
    }

    func placeBadge(on t: CALayer, size: CGSize) {
        guard let b = badge(t), let icon = b.sublayers?.first, let text = b.sublayers?.last as? CATextLayer,
              let s = text.string as? NSAttributedString else { return }
        let k = badgeFont.pointSize / 11 // every metric scales with the text
        let lead = mark(t).map { $0.bounds.width + 4 } ?? 0 // the symbol chip goes first
        let tw = min(ceil(s.size().width), max(size.width - 16 - lead - (6 + 14 + 4 + 8) * k, 0)), h = 22 * k
        b.frame = CGRect(x: 8 + lead, y: size.height - 8 - h, width: (6 + 14 + 4 + 8) * k + tw, height: h); b.cornerRadius = h / 2
        icon.frame = CGRect(x: 6 * k, y: 4 * k, width: 14 * k, height: 14 * k)
        text.frame = CGRect(x: 24 * k, y: 4 * k, width: tw, height: 14 * k)
    }

    /// 11 pt semibold scaled with Dynamic Type (caption2), capped at 2×.
    var badgeFont: UIFont {
        UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11, weight: .semibold), maximumPointSize: 22)
    }

    func tile(at p: CGPoint) -> CALayer? { tiles.first { $0.frame.contains(p) } }

    @objc func tapped(_ g: UITapGestureRecognizer) {
        if opened != nil { if infoShown { onInfo?(nil) } else { close() }; return } // tap the image: back from info first
        guard let t = tile(at: g.location(in: self)), let i = tiles.firstIndex(of: t) else { if !selecting { selected = [] }; return }
        if selecting { haptic("select"); let id = items[i].id; return selected.contains(id) ? selected.removeAll { $0 == id } : selected.append(id) }
        if items[i].external { return onActivate(items[i].id) }
        haptic("tick"); open(t)
    }

    /// Same rules as the trackpad pinch (`pinch`).
    @objc func pinched(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { pinchRaw = opened == nil ? 1 : zoom; bumped = false; swiped = false; haptic("prepare") }
        guard opened != nil else { // pinch out over a tile opens it, once per gesture (the Mac's `magnify`)
            pinchRaw *= g.scale; g.scale = 1
            if !swiped, !selecting, pinchRaw > 1.15, let t = tile(at: g.location(in: self)), let i = tiles.firstIndex(of: t), !items[i].external {
                swiped = true; haptic("tick"); open(t)
            }
            return
        }
        guard !swiped else { return } // the rest of the pinch that opened it doesn't zoom
        pinchRaw *= g.scale; g.scale = 1
        if !bumped, pinchRaw < config.minZoom || pinchRaw > config.maxZoom { bumped = true; haptic("select") } // hit the rubber band, once
        pinch(pinchRaw, at: g.location(in: self), ended: g.state == .ended || g.state == .cancelled)
    }
}

extension ScatterGridView: UIGestureRecognizerDelegate {
    /// Touch-down on a tile: decode its full-size image now, so it's usually ready when the tap lands.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let o = stageOverlay, o.superview === self, !o.isHidden, !o.bounds.contains(touch.location(in: o)),
           o.hitTest(touch.location(in: o), with: nil) != nil { return false } // host content hanging off the stage (a caption) takes its own touches
        if opened == nil, !selecting, let t = tile(at: touch.location(in: self)), let i = tiles.firstIndex(of: t) { prefetchFull(i) }
        return true
    }

    /// A single tap waits for a double tap only while a tile is open, so opening from the grid stays instant.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        g.name == "tap" && other.name == "zoom" && opened != nil
    }

    /// The stage overlay (Live Text) carries its own recognisers; the grid's swipes and pans run alongside them.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view != nil && other.view === stageOverlay
    }
}

extension ScatterGridView: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation p: CGPoint) -> UIContextMenuConfiguration? {
        guard opened == nil, !selecting, let t = tile(at: p), let i = tiles.firstIndex(of: t), let menu = tileMenu(items[i]) else { return nil }
        return UIContextMenuConfiguration(identifier: items[i].id as NSString, previewProvider: nil) { _ in menu }
    }

    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                       highlightPreviewForItemWithIdentifier id: any NSCopying) -> UITargetedPreview? { preview(id) }
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                       dismissalPreviewForItemWithIdentifier id: any NSCopying) -> UITargetedPreview? { preview(id) }

    /// Tiles are bare layers, so the lift preview is an image view of the tile's pixels at its frame.
    func preview(_ id: any NSCopying) -> UITargetedPreview? {
        guard let id = id as? String, let t = layers[id] else { return nil }
        let v = UIImageView(frame: CGRect(origin: .zero, size: t.frame.size))
        if let c = t.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID { v.image = UIImage(cgImage: c as! CGImage) }
        v.contentMode = .scaleAspectFill; v.clipsToBounds = true
        let params = UIPreviewParameters()
        params.visiblePath = UIBezierPath(roundedRect: v.bounds, cornerRadius: t.cornerRadius)
        return UITargetedPreview(view: v, parameters: params, target: UIPreviewTarget(container: self, center: CGPoint(x: t.frame.midX, y: t.frame.midY)))
    }
}

extension TileElement {
    /// While a tile is open it is the only element, and pressing it closes.
    override var accessibilityHint: String? {
        get { (accessibilityContainer as? ScatterGridView)?.opened != nil ? String(localized: "Double-tap to close") : super.accessibilityHint }
        set { super.accessibilityHint = newValue }
    }
}

extension NSValue {
    convenience init(point: CGPoint) { self.init(cgPoint: point) }
    convenience init(rect: CGRect) { self.init(cgRect: rect) }
}
#endif
