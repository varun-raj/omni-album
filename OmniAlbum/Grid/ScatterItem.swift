import Foundation
import ImageIO

/// One tile. `aspect` is width / height; layout never touches image data.
/// Bump `revision` when the tile's pixels change: the grid drops its cached image and fades the new one in.
/// `loading` shows a spinner over the tile. `subtitle` is a dim caption after the title in the hover pill.
/// `external` tiles stand for something elsewhere (a web page): a click calls `onActivate` instead of staging,
/// the pill ends in ↗, and hovering shows an ⓘ button that stages the tile.
public struct ScatterItem: Identifiable, Equatable, Sendable {
    /// Stable key, aspect ratio (width / height), hover-pill title and dim caption.
    public var id: String, aspect: CGFloat, title: String, subtitle: String
    /// Pixel version, spinner flag, and whether the tile is a link (see above).
    public var revision: Int, loading: Bool, external: Bool
    /// The original's size in pixels: staging never shows it past one pixel per screen pixel. Zero = no cap.
    public var pixelSize: CGSize
    /// Tile background until pixels arrive (e.g. the image's dominant colour). Nil = neutral grey.
    public var placeholder: CGColor?
    /// SF Symbol shown in a small chip at the tile's bottom-leading corner (e.g. "note.text" for an annotated item). Nil = none.
    public var symbol: String?
    /// Points kept clear under the tile while it's open, for a caption the host hangs below the stage overlay. 0 = none.
    public var bottomInset: CGFloat
    /// A tile; only `id` and `aspect` are required.
    public init(id: String, aspect: CGFloat, title: String = "", subtitle: String = "", revision: Int = 0,
                loading: Bool = false, external: Bool = false, pixelSize: CGSize = .zero, placeholder: CGColor? = nil, symbol: String? = nil,
                bottomInset: CGFloat = 0) {
        self.id = id; self.aspect = aspect; self.title = title; self.subtitle = subtitle; self.revision = revision
        self.loading = loading; self.external = external; self.pixelSize = pixelSize; self.placeholder = placeholder; self.symbol = symbol
        self.bottomInset = bottomInset
    }
}

/// Returns pixels for a tile, at most `maxPixel` on the long side. `full` is true for the opened (staged) tile,
/// where callers usually decode the original instead of a thumbnail. Called on a background queue.
public typealias TileContentProvider = @Sendable (_ id: String, _ maxPixel: CGFloat, _ full: Bool) -> CGImage?
