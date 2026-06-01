import SwiftUI

/// Vector country flag (NOT emoji) for the small set of countries this app
/// exits through. Drawn with SwiftUI shapes so it's crisp at any size and
/// renders identically on iOS and macOS — emoji flags look different per
/// platform and read poorly in the small home badge. `code` is a lowercase
/// two-letter key ("nl","de","fr","us","ru"); nil → globe (Auto/unknown).
struct CountryFlag: View {
    let code: String?
    /// Flag width in points. Height is derived at the standard 3:2 ratio.
    var width: CGFloat = 30
    var corner: CGFloat = 3

    private var height: CGFloat { (width * 2.0 / 3.0).rounded() }

    var body: some View {
        content
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .stroke(.white.opacity(0.25), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var content: some View {
        switch code {
        case "nl": horizontal([Self.nlRed, .white, Self.nlBlue])
        case "de": horizontal([.black, Self.deRed, Self.deGold])
        case "ru": horizontal([.white, Self.ruBlue, Self.ruRed])
        case "fr": vertical([Self.frBlue, .white, Self.frRed])
        case "us": usFlag
        default:
            ZStack {
                Rectangle().fill(.white.opacity(0.08))
                Image(systemName: "globe")
                    .resizable().scaledToFit()
                    .padding(height * 0.12)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func horizontal(_ colors: [Color]) -> some View {
        VStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { Rectangle().fill(colors[$0]) }
        }
    }

    private func vertical(_ colors: [Color]) -> some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { Rectangle().fill(colors[$0]) }
        }
    }

    private var usFlag: some View {
        let cantonW = width * 0.4
        let cantonH = height * (7.0 / 13.0)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<13, id: \.self) { i in
                    Rectangle().fill(i % 2 == 0 ? Self.usRed : .white)
                }
            }
            ZStack {
                Rectangle().fill(Self.usBlue)
                starGrid(w: cantonW, h: cantonH)
            }
            .frame(width: cantonW, height: cantonH)
        }
    }

    /// A simplified star field — a small dot grid that reads as "stars" at
    /// badge size without trying to render 50 precise five-pointed stars.
    private func starGrid(w: CGFloat, h: CGFloat) -> some View {
        let cols = 5, rows = 4
        let d = max(0.6, min(w / CGFloat(cols), h / CGFloat(rows)) * 0.5)
        return VStack(spacing: max(0.4, (h - CGFloat(rows) * d) / CGFloat(rows + 1))) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: max(0.4, (w - CGFloat(cols) * d) / CGFloat(cols + 1))) {
                    ForEach(0..<cols, id: \.self) { _ in
                        Circle().fill(.white).frame(width: d, height: d)
                    }
                }
            }
        }
        .frame(width: w, height: h)
    }

    // MARK: - Official-ish flag colors
    private static let nlRed  = Color(red: 0.682, green: 0.110, blue: 0.157)
    private static let nlBlue = Color(red: 0.129, green: 0.275, blue: 0.545)
    private static let deRed  = Color(red: 0.867, green: 0.0,   blue: 0.0)
    private static let deGold = Color(red: 1.0,   green: 0.808, blue: 0.0)
    private static let ruBlue = Color(red: 0.0,   green: 0.224, blue: 0.651)
    private static let ruRed  = Color(red: 0.835, green: 0.169, blue: 0.118)
    private static let frBlue = Color(red: 0.0,   green: 0.333, blue: 0.643)
    private static let frRed  = Color(red: 0.937, green: 0.255, blue: 0.208)
    private static let usRed  = Color(red: 0.698, green: 0.133, blue: 0.204)
    private static let usBlue = Color(red: 0.235, green: 0.231, blue: 0.431)
}
