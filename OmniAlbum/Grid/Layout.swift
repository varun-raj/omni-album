import CoreGraphics
import Foundation

/// Justified rows: each row fills `width - 2 * gap` exactly; the last row keeps its natural height, left-aligned.
/// Returns the frames and the y just below the last row (plus gap).
///
/// OmniAlbum changes: `inset` is the outer margin (was `gap`); `columns > 0` lays out fixed-column square tiles instead.
func justifiedFrames(aspects: [CGFloat], width: CGFloat, rowHeight: CGFloat, gap: CGFloat, top: CGFloat,
                     inset: CGFloat, columns: Int = 0) -> (frames: [CGRect], bottom: CGFloat) {
    var frames: [CGRect] = []
    let avail = width - 2 * inset
    if columns > 0 {
        let side = max((avail - gap * CGFloat(columns - 1)) / CGFloat(columns), 1)
        for i in aspects.indices {
            let (r, c) = i.quotientAndRemainder(dividingBy: columns)
            frames.append(CGRect(x: inset + CGFloat(c) * (side + gap), y: inset + top + CGFloat(r) * (side + gap), width: side, height: side))
        }
        let rows = (aspects.count + columns - 1) / columns
        return (frames, inset + top + CGFloat(rows) * (side + gap))
    }
    var row: [Int] = [], w: CGFloat = 0, y = inset + top
    func flush(last: Bool) {
        let s = last ? 1 : (avail - gap * CGFloat(row.count - 1)) / w
        var x = inset
        for i in row {
            let iw = aspects[i] * rowHeight * s
            frames.append(CGRect(x: x, y: y, width: iw, height: rowHeight * s)); x += iw + gap
        }
        y += rowHeight * s + gap; row = []; w = 0
    }
    for i in aspects.indices {
        row.append(i); w += aspects[i] * rowHeight
        if w + gap * CGFloat(row.count - 1) >= avail { flush(last: false) }
    }
    if !row.isEmpty { flush(last: true) }
    return (frames, y)
}

/// Indices of `frames` (justified row order, so minY and maxY never decrease) whose vertical span meets `r`.
/// Two binary searches instead of a scan; callers still check `intersects` for x.
func rowRange(_ frames: [CGRect], _ r: CGRect) -> Range<Int> {
    func first(_ p: (CGRect) -> Bool) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi { let m = (lo + hi) / 2; if p(frames[m]) { hi = m } else { lo = m + 1 } }
        return lo
    }
    let a = first { $0.maxY > r.minY }
    return a..<max(a, first { $0.minY >= r.maxY })
}

/// Scatter offset at distance `d` from the opened tile.
func scatterOffset(distance d: CGFloat, push: CGFloat, reach: CGFloat) -> CGFloat { push * exp(-d / reach) }

/// Where the opened tile sits: centred in `view`, aspect-fit inside a `margin` pt margin per side, never larger than
/// `native` points (the original at one pixel per screen pixel; zero = no cap).
func stageFrame(aspect a: CGFloat, native: CGSize, in v: CGRect, margin m: CGFloat = 50) -> CGRect {
    var h = min(max(v.height - 2 * m, 1), max(v.width - 2 * m, 1) / a)
    if native.height > 0 { h = min(h, native.height) }
    let w = h * a
    return CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
}

/// How a tile leaves when another opens: springs out and fades, fades in place, or jumps there invisibly.
enum ScatterMove { case spring, fade, snap }

/// Targets for the tiles at home frames `frames` when the tile centred at `o` opens. Each moves straight away from `o` by
/// `push·exp(−d/reach)`, d centre to centre, push and reach scaled by rowHeight / 156 (no per-tile size factor).
/// On-screen tiles (frame meets `screen`) weaken by threshold / on-screen count above `densityThreshold`; under 1 pt
/// they only fade; only the nearest 400 movers animate. The other movers and all off-screen tiles (never weakened) snap.
func scatterPlan(_ frames: [CGRect], from o: CGPoint, screen: CGRect, _ c: ScatterConfig) -> [(to: CGRect, move: ScatterMove)] {
    let s = c.rowHeight / 156, push = c.push * s, reach = max(c.reach * s, 1)
    let on = frames.map { $0.intersects(screen) }, n = on.filter { $0 }.count, k = c.densityThreshold
    let weaken = k > 0 && n > k ? CGFloat(k) / CGFloat(n) : 1
    var d: [CGFloat] = []
    var plan = frames.indices.map { i -> (to: CGRect, move: ScatterMove) in
        let r = frames[i], dx = r.midX - o.x, dy = r.midY - o.y, dist = max(hypot(dx, dy), 0.001)
        d.append(dist)
        let off = scatterOffset(distance: dist, push: on[i] ? push * weaken : push, reach: reach)
        let to = r.offsetBy(dx: dx / dist * off, dy: dy / dist * off)
        return !on[i] ? (to, .snap) : off < 1 ? (r, .fade) : (to, .spring)
    }
    let movers = plan.indices.filter { plan[$0].move == .spring }
    if movers.count > 400 { for i in movers.sorted(by: { d[$0] < d[$1] }).dropFirst(400) { plan[i].move = .snap } }
    return plan
}

/// Live pinch zoom: free inside lo…hi; past either end it rubber-bands in log₂ space (resistance 0.5 / (1 + 2·over),
/// integrated), never more than 0.7 of a doubling past the limit.
func rubberZoom(_ z: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    let l = log2(max(z, 1e-6)), a = log2(lo), b = log2(hi)
    guard l > b || l < a else { return z }
    let band = min(0.25 * log(1 + 2 * (l > b ? l - b : a - l)), 0.7)
    return exp2(l > b ? b + band : a - band)
}

/// Pager release: a flick (> 500 pt/s) pages if it goes the way of the drag; else past a quarter page.
func pagerCommits(dx: CGFloat, vx: CGFloat, width: CGFloat) -> Bool { abs(vx) > 500 ? vx * dx > 0 : abs(dx) > min(width / 4, 80) } // ≤ 80 pt of travel on any width

/// Force click to peek (Mac). idle → lift (stage 1, pressure > 0.3) → peek (force click, stage 2) → commit (deeper:
/// stage 2 past 0.8, or a second force click after easing back to stage 1). Stage 0 (let go) from anywhere but commit → idle.
enum Peek { case idle, lift, peek, peekEased, commit }
func peekStep(_ p: Peek, stage: Int, pressure: Float) -> Peek {
    switch (p, stage) {
    case (.commit, _): return .commit
    case (_, 0): return .idle
    case (.peek, 2): return pressure > 0.8 ? .commit : .peek
    case (.peek, _), (.peekEased, 1): return .peekEased
    case (.peekEased, _): return .commit // stage 2 again: the second force click
    case (_, 2): return .peek
    default: return pressure > 0.3 ? .lift : .idle
    }
}
