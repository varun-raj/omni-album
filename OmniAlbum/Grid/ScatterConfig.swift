import QuartzCore

/// Tunables for `ScatterGridView`. Distances are in points at a 156 pt row height and scale with `rowHeight`.
public struct ScatterConfig: Sendable, Equatable {
    /// Spring for open, close, scatter and re-layout (bounce 0.1; `springItem` is the earlier fixed spring);
    /// `hover` drives the hover lift, selection and title pill.
    public var item = SpringMotion.item, hover = SpringMotion.hover
    /// The earlier item spring (mass 1.89, stiffness 200.67, damping 31.86), for `item` if you prefer it.
    public static let springItem = SpringMotion(mass: 1.89, stiffness: 200.67, damping: 31.86)
    /// Scale of a hovered or selected tile (1 = no lift).
    public var hoverScale: CGFloat = 1.02
    /// Show the dark title pill on the hovered tile (macOS). The lift and the VoiceOver label stay either way.
    public var showsHoverTitle = true
    /// Peak scatter distance for the tiles nearest the opened one.
    public var push: CGFloat = 800
    /// Falloff length: offset = push · exp(-distance / reach).
    public var reach: CGFloat = 1000
    /// Above this many on-screen tiles the push weakens by threshold / count (0 = never).
    public var densityThreshold = 80
    /// Seconds each animation takes to land: open, close, the scatter of the other tiles, the corner-radius change.
    public var openDuration = 0.30, closeDuration = 0.30, scatterDuration = 0.35, cornerDuration = 0.34
    /// Scattered tiles fade out (linear) well before they stop moving; on close they fade back in (ease-out).
    public var scatterFade = 0.13, closeFade = 0.30
    /// Target row height, gap between tiles and tile corner radius, in points.
    public var rowHeight: CGFloat = 150, gap: CGFloat = 14, cornerRadius: CGFloat = 6
    /// Pinch zoom range on the opened tile, as multiples of its staged size; a pinch rubber-bands past either end.
    public var minZoom: CGFloat = 0.25, maxZoom: CGFloat = 8
    /// OmniAlbum: background while a tile is open (nil = `background`).
    public var openBackground: CGColor?
    /// OmniAlbum: space kept clear around an opened tile (was a fixed 50; 0 = photo fills the viewport).
    public var stageMargin: CGFloat = 50
    /// OmniAlbum: outer margin around the tiles (nil = `gap`, the original behaviour; 0 = edge to edge).
    public var edgeInset: CGFloat?
    /// OmniAlbum: > 0 lays tiles out as squares in this many fixed columns; opened tiles keep their real aspect.
    public var columns = 0
    /// Fill behind the tiles.
    public var background = CGColor(gray: 0x1e / 255.0, alpha: 1)

    /// The defaults above.
    public init() {}
}
