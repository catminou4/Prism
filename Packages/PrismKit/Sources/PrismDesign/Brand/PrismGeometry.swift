import SwiftUI

/// Geometry of the Prism mark in a unit square: a right-pointing "play" triangle, optically
/// centred, split into three facets that meet at the centroid.
nonisolated enum PrismGeometry {
    static let a = CGPoint(x: 0.215, y: 0.105) // top-left
    static let b = CGPoint(x: 0.215, y: 0.895) // bottom-left
    static let c = CGPoint(x: 0.900, y: 0.500) // tip
    static let cornerRadius: CGFloat = 0.115
    static var centroid: CGPoint { CGPoint(x: (a.x + b.x + c.x) / 3, y: (a.y + b.y + c.y) / 3) }

    static func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
}

/// Rounded play triangle.
nonisolated public struct PrismTriangle: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let a = PrismGeometry.point(PrismGeometry.a, in: rect)
        let b = PrismGeometry.point(PrismGeometry.b, in: rect)
        let c = PrismGeometry.point(PrismGeometry.c, in: rect)
        let r = PrismGeometry.cornerRadius * min(rect.width, rect.height)
        var path = Path()
        // Start mid-edge so every vertex gets a tangent arc.
        path.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        path.addArc(tangent1End: b, tangent2End: c, radius: r)
        path.addArc(tangent1End: c, tangent2End: a, radius: r * 0.9)
        path.addArc(tangent1End: a, tangent2End: b, radius: r)
        path.closeSubpath()
        return path
    }
}

/// One facet: centroid + two vertices of the play triangle (extended past the outline;
/// the mark masks it with `PrismTriangle`).
nonisolated struct PrismFacet: Shape {
    enum Kind: CaseIterable {
        case top, left, bottom

        var vertices: (CGPoint, CGPoint) {
            switch self {
            case .top: (PrismGeometry.a, PrismGeometry.c)
            case .left: (PrismGeometry.b, PrismGeometry.a)
            case .bottom: (PrismGeometry.c, PrismGeometry.b)
            }
        }

        /// Unit direction pushing the facet away from the centroid (assembly animation).
        var outward: CGVector {
            let (p, q) = vertices
            let g = PrismGeometry.centroid
            let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
            let dx = mid.x - g.x, dy = mid.y - g.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            return CGVector(dx: dx / length, dy: dy / length)
        }
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let g = PrismGeometry.point(PrismGeometry.centroid, in: rect)
        let (p, q) = kind.vertices
        let pp = PrismGeometry.point(p, in: rect), qq = PrismGeometry.point(q, in: rect)
        // Extend the outer vertices away from the centroid so the mask defines the outline.
        func extend(_ v: CGPoint) -> CGPoint { CGPoint(x: g.x + (v.x - g.x) * 1.25, y: g.y + (v.y - g.y) * 1.25) }
        var path = Path()
        path.move(to: g)
        path.addLine(to: extend(pp))
        path.addLine(to: extend(qq))
        path.closeSubpath()
        return path
    }
}
