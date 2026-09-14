import SwiftUI

struct AboutSettingsView: View {
    private let displayName: String
    private let version: String
    private let build: String
    private let icon: NSImage?

    init(bundle: Bundle = .main) {
        displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "墨流拼音"
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        icon = bundle.image(forResource: iconName)
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            Text(displayName)
                .font(.title)
                .bold()
            Text("版本 \(version) (\(build))")
                .foregroundStyle(.secondary)
            Text("librime \(IFEngine.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
