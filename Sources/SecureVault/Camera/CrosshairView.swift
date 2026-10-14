import SwiftUI

struct CrosshairView: View {
    let color: String

    private var lineColor: Color {
        switch color {
        case "red": return .red
        case "green": return .green
        case "yellow": return .yellow
        default: return .white
        }
    }

    var body: some View {
        ZStack {
            // Горизонтальная линия — короткая
            Rectangle()
                .fill(lineColor)
                .frame(width: 40, height: 2)

            // Вертикальная линия — короткая
            Rectangle()
                .fill(lineColor)
                .frame(width: 2, height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
