import SwiftUI

enum PaulineCursorShape: String, CaseIterable, Identifiable {
    case circle = "circle"
    case square = "square"
    case hexagon = "hexagon"
    
    var id: String { rawValue }
    
    func makeShape() -> AnyShape {
        switch self {
        case .circle:
            return AnyShape(Circle())
        case .square:
            return AnyShape(RoundedRectangle(cornerRadius: 2))
        case .hexagon:
            return AnyShape(Hexagon())
        }
    }
}

struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let a = width / 4.0
        
        path.move(to: CGPoint(x: a, y: 0))
        path.addLine(to: CGPoint(x: width - a, y: 0))
        path.addLine(to: CGPoint(x: width, y: height / 2.0))
        path.addLine(to: CGPoint(x: width - a, y: height))
        path.addLine(to: CGPoint(x: a, y: height))
        path.addLine(to: CGPoint(x: 0, y: height / 2.0))
        path.closeSubpath()
        return path
    }
}
