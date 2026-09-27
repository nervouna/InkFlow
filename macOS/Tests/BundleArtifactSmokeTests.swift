import Foundation
@testable import InkFlowDomain
@testable import InkFlowRime

private struct BundleArtifactSmokeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct BundleArtifactSmokeTests {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw BundleArtifactSmokeFailure(description: "Usage: bundle-artifact-smoke-tests APP USER_DIR")
        }
        let files = FileManager.default
        let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let user = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let resources = app.appendingPathComponent("Contents/Resources/Rime")
        let frameworks = app.appendingPathComponent("Contents/Frameworks").standardizedFileURL
        let runtime = frameworks.appendingPathComponent("librime.1.dylib")
        let lua = frameworks.appendingPathComponent("rime-plugins/librime-lua.dylib")
        try require(files.isReadableFile(atPath: runtime.path), "Missing bundled librime")
        try require(files.isReadableFile(atPath: lua.path), "Missing bundled Lua plugin")
        let libraryPath = ProcessInfo.processInfo.environment["DYLD_LIBRARY_PATH"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        try require(libraryPath == frameworks, "Smoke must load the app's bundled frameworks")

        let descriptor = try IFPackagedCache.descriptor(resources: resources)
        let ranker = try IFContextRanker(
            dictionary: resources.appendingPathComponent(IFDictionaryCatalog.dictionaryFilename).path
        )
        let configuration = IFEngineConfiguration(
            shared: resources,
            cache: descriptor.cache,
            user: user.path,
            ranker: ranker
        )
        try IFEngine.start(configuration)
        defer { IFEngine.stop() }
        guard let engine = IFEngine() else {
            throw BundleArtifactSmokeFailure(description: "Bundled engine session unavailable")
        }

        type(engine, "nihao")
        try select("你好", from: engine, label: "Chinese")
        type(engine, "hello")
        try select("hello", from: engine, label: "English Lua")

        print("PASS bundle artifact smoke: app resources, packaged cache, bundled librime/Lua, Chinese and English engine")
    }

    @MainActor private static func type(_ engine: IFEngine, _ text: String) {
        for code in text.utf16 { _ = engine.key(Int32(code)) }
    }

    @MainActor private static func select(_ expected: String, from engine: IFEngine, label: String) throws {
        let candidates = engine.snapshot().candidates
        guard let index = candidates.firstIndex(of: expected) else {
            throw BundleArtifactSmokeFailure(description: "\(label) candidate missing: \(candidates)")
        }
        engine.select(index)
        try require(engine.takeCommit() == expected, "\(label) commit mismatch")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BundleArtifactSmokeFailure(description: message) }
    }
}
