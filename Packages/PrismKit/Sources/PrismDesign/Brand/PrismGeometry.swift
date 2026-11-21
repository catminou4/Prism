import SwiftUI

/// Geometry of the original rounded playback triangle.
nonisolated enum PrismGeometry {
    static let a = CGPoint(x: 0.215, y: 0.105) // top-left
    static let b = CGPoint(x: 0.215, y: 0.895) // bottom-left
    static let c = CGPoint(x: 0.900, y: 0.500) // tip
    static let cornerRadius: CGFloat = 0.115
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

/// Two solid planes make up the Prism P. Angled corners leave a wide counter at icon sizes.
nonisolated struct PrismMonogramPlane: Shape {
    enum Part {
        case stem
        case bowl
    }

    let part: Part

    func path(in rect: CGRect) -> Path {
        let corners: [CGPoint] = switch part {
        case .stem: [
            .init(x: 0.14, y: 0.13), .init(x: 0.37, y: 0.13), .init(x: 0.37, y: 0.69),
            .init(x: 0.19, y: 0.87), .init(x: 0.14, y: 0.87)
        ]
        case .bowl: [
            .init(x: 0.35, y: 0.13), .init(x: 0.66, y: 0.13), .init(x: 0.86, y: 0.33),
            .init(x: 0.86, y: 0.47), .init(x: 0.66, y: 0.67), .init(x: 0.35, y: 0.67),
            .init(x: 0.35, y: 0.48), .init(x: 0.58, y: 0.48), .init(x: 0.65, y: 0.41),
            .init(x: 0.65, y: 0.39), .init(x: 0.58, y: 0.32), .init(x: 0.35, y: 0.32)
        ]
        }
        var path = Path()
        path.addLines(corners.map { PrismGeometry.point($0, in: rect) })
        path.closeSubpath()
        return path
    }
}
