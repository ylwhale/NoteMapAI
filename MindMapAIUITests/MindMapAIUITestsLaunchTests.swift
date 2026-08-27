//
//  MindMapAIUITestsLaunchTests.swift
//  MindMap AIUITests
//
//  Created by Jingyu Huang on 2/17/26.
//

import XCTest

/// Verifies that MindMap AI launches successfully and captures launch artifacts.
final class MindMapAIUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    /// Prepares the test environment before each test runs.
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    /// Verifies the expected behavior covered by the `testLaunch` test.
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
