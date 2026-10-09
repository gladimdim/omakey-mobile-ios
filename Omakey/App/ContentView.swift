import OmakeyProtocol
import SwiftUI

/// Placeholder until the connect screen (M4).
struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Omakey")
                .font(.system(size: 34, weight: .bold, design: .monospaced))
            Text("Your phone is the keyboard.")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Protocol v\(Wire.version) · port \(Wire.defaultPort)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}

#Preview {
    ContentView()
}
