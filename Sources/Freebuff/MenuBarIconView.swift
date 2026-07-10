import SwiftUI

/// Simple all-black menu bar icon — a clean `</>` symbol.
/// No progress ring, no dot, no colors — just a readable icon
/// that fits the macOS menu bar without clipping.
struct MenuBarIconView: View {

    var body: some View {
        AngleBracketsIcon()
            .stroke(Color.primary, style: StrokeStyle(
                lineWidth: 2.0,
                lineCap: .round,
                lineJoin: .round
            ))
            .frame(width: 16, height: 14)
    }
}

// MARK: - Angle Brackets `</>` Icon

struct AngleBracketsIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        let topY    = rect.minY + h * 0.22
        let midY    = rect.midY
        let botY    = rect.maxY - h * 0.22
        let midX    = rect.midX
        let spread  = w * 0.30

        let leftInnerX  = midX - spread * 0.30
        let rightInnerX = midX + spread * 0.30
        let leftOuterX  = midX - spread
        let rightOuterX = midX + spread

        // Left bracket `<`
        p.move(to: CGPoint(x: leftInnerX, y: topY))
        p.addLine(to: CGPoint(x: leftOuterX, y: midY))
        p.addLine(to: CGPoint(x: leftInnerX, y: botY))

        // Slash `/`
        p.move(to: CGPoint(x: midX + spread * 0.25, y: topY))
        p.addLine(to: CGPoint(x: midX - spread * 0.25, y: botY))

        // Right bracket `>`
        p.move(to: CGPoint(x: rightInnerX, y: topY))
        p.addLine(to: CGPoint(x: rightOuterX, y: midY))
        p.addLine(to: CGPoint(x: rightInnerX, y: botY))

        return p
    }
}
