import SwiftUI

struct SorenoLogoMark: View {
    var primaryColor: Color = .primary
    var accentColor: Color = Color(red: 0.831, green: 0.635, blue: 0.416)
    var showDot: Bool = true

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 100, geo.size.height / 140)
            let width = 100 * scale
            let height = 140 * scale
            let originX = (geo.size.width - width) / 2
            let originY = (geo.size.height - height) / 2

            ZStack(alignment: .topLeading) {
                SorenoQuoteShape()
                    .fill(primaryColor)
                    .frame(width: 100 * scale, height: 140 * scale)
                    .offset(x: originX, y: originY)

                if showDot {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 22 * scale, height: 22 * scale)
                        .offset(x: originX + 7 * scale, y: originY + 29 * scale)
                }
            }
        }
        .aspectRatio(100.0 / 140.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct SorenoMenuBarLogo: View {
    var body: some View {
        SorenoLogoMark(primaryColor: .primary, accentColor: .primary, showDot: false)
            .frame(width: 18, height: 18)
    }
}

private struct SorenoQuoteShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + (x / 100) * rect.width,
                y: rect.minY + (y / 140) * rect.height
            )
        }

        var path = Path()
        path.move(to: point(22, 0))
        path.addCurve(to: point(-6, 42), control1: point(6, 0), control2: point(-6, 18))
        path.addCurve(to: point(34, 82), control1: point(-6, 66), control2: point(12, 82))
        path.addCurve(to: point(45, 80), control1: point(38, 82), control2: point(42, 81))
        path.addCurve(to: point(2, 130), control1: point(41, 105), control2: point(22, 123))
        path.addLine(to: point(14, 140))
        path.addCurve(to: point(82, 50), control1: point(56, 128), control2: point(82, 92))
        path.addCurve(to: point(34, 0), control1: point(82, 20), control2: point(58, 0))
        path.closeSubpath()
        return path
    }
}
