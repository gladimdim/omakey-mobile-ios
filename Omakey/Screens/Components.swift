import SwiftUI

/// "SELECT COMPUTER TO USE": small, bold, spaced out.
struct SectionHeader: View {
    let title: String
    let palette: Palette

    var body: some View {
        Text(title)
            .font(.mono(12, bold: true))
            .kerning(1.4)
            .foregroundStyle(palette.fgDim)
            .padding(.top, 28)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A tappable card with a title and a detail line; [border] outlines it.
struct Card: View {
    let title: String
    let detail: String
    var detailColor: Color?
    var border: Color?
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.mono(16, bold: true))
                .foregroundStyle(palette.fg)
            Text(detail)
                .font(.mono(13))
                .foregroundStyle(detailColor ?? palette.fgDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if let border { RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1.5) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The app's buttons: filled with the accent, or outlined in it.
struct OmakeyButtonStyle: ButtonStyle {
    var primary = false
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mono(15, bold: true))
            .foregroundStyle(primary ? palette.bg : palette.accent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                if primary {
                    RoundedRectangle(cornerRadius: 10).fill(palette.accent)
                } else {
                    RoundedRectangle(cornerRadius: 10).stroke(palette.accent, lineWidth: 1.5)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A message that slides up from the bottom for a few seconds, like Android's toast.
struct ToastView: View {
    let text: String
    let palette: Palette

    var body: some View {
        Text(text)
            .font(.mono(13))
            .foregroundStyle(palette.fg)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.surface, in: Capsule())
            .overlay(Capsule().stroke(palette.fgDim.opacity(0.4), lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
