import SwiftUI

/// The tile, sized by its content like the expanded screen.
struct __NAME__TileView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.title2)
            Text("__NAME__")
                .font(.caption)
        }
        .padding(8)
    }
}
