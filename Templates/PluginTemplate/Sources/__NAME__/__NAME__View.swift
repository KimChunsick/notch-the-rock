import SwiftUI

/// The expanded screen. The host sizes the notch to this view, so it keeps a size of its own: no
/// `maxHeight: .infinity`. Under a band wider than the view the host offers more width; the
/// `Spacer` takes it, so the symbol and the text reach the two edges and the margins stay equal.
/// The host also adds the 18 pt edge margin, so the outermost view has no `.padding()` and no fixed
/// outer frame.
struct __NAME__View: View {
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "sparkles")
            Spacer(minLength: 12)
            Text("__NAME__ 플러그인이에요.")
        }
    }
}
