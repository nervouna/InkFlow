import Foundation
@testable import InkFlowAppleEngine
import InkFlowEngine
import XCTest

final class EngineConfigurationTests: XCTestCase {
    func testNativeConfigurationBorrowsEveryUTF8StringForSynchronousCall() throws {
        let configuration = EngineConfiguration(
            sharedDataURL: URL(fileURLWithPath: "/tmp/InkFlow/共享"),
            userDataURL: URL(fileURLWithPath: "/tmp/InkFlow/用户"),
            prebuiltDataURL: URL(fileURLWithPath: "/tmp/InkFlow/预编译"),
            stagingDataURL: URL(fileURLWithPath: "/tmp/InkFlow/暂存"),
            distributionName: "墨流",
            distributionCodeName: "inkflow-配置",
            distributionVersion: "测试-1",
            applicationName: "rime.inkflow.生命周期"
        )

        let captured = try EngineRuntime.withBorrowedRuntimeConfig(configuration) { config in
            XCTAssertEqual(config.struct_size, MemoryLayout<InkFlowRuntimeConfig>.size)
            XCTAssertEqual(config.minimum_log_level, 3)
            return try [
                String(cString: XCTUnwrap(config.shared_data_dir)),
                String(cString: XCTUnwrap(config.user_data_dir)),
                String(cString: XCTUnwrap(config.prebuilt_data_dir)),
                String(cString: XCTUnwrap(config.staging_data_dir)),
                String(cString: XCTUnwrap(config.distribution_name)),
                String(cString: XCTUnwrap(config.distribution_code_name)),
                String(cString: XCTUnwrap(config.distribution_version)),
                String(cString: XCTUnwrap(config.application_name)),
            ]
        }

        XCTAssertEqual(captured, [
            configuration.sharedDataURL.path,
            configuration.userDataURL.path,
            configuration.prebuiltDataURL.path,
            configuration.stagingDataURL.path,
            configuration.distributionName,
            configuration.distributionCodeName,
            configuration.distributionVersion,
            configuration.applicationName,
        ])
    }
}
