import SwiftUI

/// Simple scrollable text view for Terms of Service / Privacy Policy.
/// Copy lives in Localizable.strings (legal.terms.body / legal.privacy.body).
struct LegalView: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    init(title: LocalizedStringKey, body: LocalizedStringKey) {
        self.title = title
        self.text = body
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .navigationTitle(Text(title))
        .iosInlineNavTitle()
    }
}
