import AppKit
import InkFlowRime
import SwiftUI

struct AboutSettingsView: View {
    private let displayName: String
    private let version: String
    private let build: String
    private let icon: NSImage?
    private let licensesFolder: URL?

    init(bundle: Bundle = .main) {
        displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "墨流拼音"
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        icon = bundle.image(forResource: iconName)
        licensesFolder = bundle.resourceURL?.appendingPathComponent("Licenses", isDirectory: true)
    }

    /// Each release attaches this archive; release.sh names it after the version and build.
    private var sourceBundleURL: URL {
        URL(string: "https://github.com/nervouna/InkFlow/releases/download/v\(version)/InkFlow-\(version)-\(build)-dictionary-source.tar.gz")!
    }

    private static let dataSources: [(name: String, license: String)] = [
        ("白霜拼音 rime-frost 中文词库", "GPL-3.0"),
        ("雾凇拼音 rime-ice 中文词库、Emoji 表与技术英语选词", "GPL-3.0"),
        ("rime-pinyin-simp 兼容词库、OpenCC 简繁数据", "Apache-2.0"),
        ("rime-easy-en 英文词库", "LGPL-3.0"),
        ("wordfreq 英文词频快照", "CC BY-SA 4.0"),
        ("librime、librime-lua、Lua、Boost、Sparkle", "BSD、MIT、BSL-1.0"),
    ]

    var body: some View {
        ScrollView {
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
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("数据来源与许可")
                        .font(.headline)
                    ForEach(Self.dataSources, id: \.name) { source in
                        HStack(alignment: .firstTextBaseline) {
                            Text(source.name)
                            Spacer()
                            Text(source.license)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    Text("墨流自身代码采用 Apache-2.0 许可；编译后的词库沿用各来源的许可。每个发布版本附带对应的词库源码包，内含上游数据、墨流的修改、生成脚本和许可证全文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Link("词库源码包", destination: sourceBundleURL)
                        if let licensesFolder {
                            Button("许可证文本") { NSWorkspace.shared.open(licensesFolder) }
                                .buttonStyle(.link)
                        }
                        Link("项目主页", destination: URL(string: "https://github.com/nervouna/InkFlow")!)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: 440, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }
}
