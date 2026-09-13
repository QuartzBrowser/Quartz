import XCTest
@testable import Quartz

final class QuartzWebKitRuntimeTests: XCTestCase {
    private let revision = String(repeating: "a1", count: 20)
    private let systemFramework = URL(fileURLWithPath: "/System/Library/Frameworks/WebKit.framework", isDirectory: true)
    private let systemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)

    @MainActor
    func testTestProcessLoadedTheConfiguredEngine() {
        let report = QuartzWebKitRuntime.currentReport()
        XCTAssertTrue(report.valid, report.error ?? "Engine verification failed")
        XCTAssertFalse(report.loadedEngineImages.isEmpty)
        #if QUARTZ_FORK_WEBKIT
        XCTAssertEqual(report.mode, "fork")
        XCTAssertEqual(report.repository, QuartzWebKitRuntime.repository)
        XCTAssertEqual(report.loadedFrameworkPath, report.expectedFrameworkPath)
        #else
        XCTAssertEqual(report.mode, "system-development")
        #endif
    }

    func testExplicitSystemDevelopmentBuildNeedsNoMetadata() {
        let report = inspect(loaded: systemFramework, root: URL(fileURLWithPath: "/tmp/QuartzDevelopment"), requiresFork: false)
        XCTAssertTrue(report.valid)
        XCTAssertEqual(report.mode, "system-development")
        XCTAssertNil(report.repository)
        XCTAssertNil(report.expectedFrameworkPath)
    }

    func testForkBuildFailsWithoutMetadata() throws {
        try withDirectory { root in
            let report = inspect(loaded: systemFramework, root: root)
            XCTAssertFalse(report.valid)
            XCTAssertEqual(report.mode, "fork")
            XCTAssertTrue(try XCTUnwrap(report.error).contains("Missing QuartzWebKit.json"))
        }
    }

    func testDevelopmentProductsRequireMetadataEvenWithoutCompileFlag() throws {
        try withDirectory { root in
            let report = inspect(loaded: systemFramework, root: root, requiresFork: false,
                                 environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": root.path])
            XCTAssertFalse(report.valid)
            XCTAssertEqual(report.manifestPath, root.appendingPathComponent("QuartzWebKit.json").path)
        }
    }

    func testPackagedAppMatchesBundledFrameworkAndIgnoresDevelopmentOverride() throws {
        try withDirectory { root in
            let app = root.appendingPathComponent("Quartz.app")
            let resources = app.appendingPathComponent("Contents/Resources")
            let frameworks = app.appendingPathComponent("Contents/Frameworks")
            try writeManifest(to: resources)
            let loaded = frameworks.appendingPathComponent("WebKit.framework")
            let report = inspect(loaded: loaded, root: app, requiresFork: false,
                                 environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": "/other/engine"])
            XCTAssertTrue(report.valid)
            XCTAssertEqual(report.mode, "fork")
            XCTAssertEqual(report.repository, QuartzWebKitRuntime.repository)
            XCTAssertEqual(report.revision, revision)
            XCTAssertEqual(report.expectedFrameworkPath, loaded.resolvingSymlinksInPath().path)
        }
    }

    func testSystemFrameworkCannotSatisfyPackagedFork() throws {
        try withDirectory { root in
            let app = root.appendingPathComponent("Quartz.app")
            try writeManifest(to: app.appendingPathComponent("Contents/Resources"))
            let report = inspect(loaded: systemFramework, root: app)
            XCTAssertFalse(report.valid)
            XCTAssertTrue(try XCTUnwrap(report.error).contains("Quartz loaded WebKit from"))
        }
    }

    func testPackagedAppCannotUseDevelopmentManifestWhenItsManifestIsMissing() throws {
        try withDirectory { root in
            try writeManifest(to: root)
            let app = root.appendingPathComponent("Quartz.app")
            let report = inspect(loaded: root.appendingPathComponent("WebKit.framework"), root: app,
                                 environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": root.path])
            XCTAssertFalse(report.valid)
            XCTAssertTrue(try XCTUnwrap(report.error).contains("Missing QuartzWebKit.json"))
        }
    }

    func testDevelopmentFrameworkSymlinkResolvesToLoadedFramework() throws {
        try withDirectory { root in
            let products = root.appendingPathComponent("Products")
            let actual = root.appendingPathComponent("BuiltFramework/WebKit.framework")
            try writeManifest(to: products)
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: products.appendingPathComponent("WebKit.framework"), withDestinationURL: actual)
            let report = inspect(loaded: actual, root: root,
                                 environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": products.path])
            XCTAssertTrue(report.valid)
            XCTAssertEqual(report.expectedFrameworkPath, actual.resolvingSymlinksInPath().path)
        }
    }

    func testDirectDevelopmentLaunchFindsMetadataBesideLoadedFramework() throws {
        try withDirectory { root in
            let products = root.appendingPathComponent("Products")
            try writeManifest(to: products)
            let report = inspect(loaded: products.appendingPathComponent("WebKit.framework"), root: root)
            XCTAssertTrue(report.valid)
            XCTAssertEqual(report.mode, "fork")
            XCTAssertEqual(report.manifestPath, products.appendingPathComponent("QuartzWebKit.json").path)
        }
    }

    func testExplicitDevelopmentProductsTakePrecedenceOverAdjacentMetadata() throws {
        try withDirectory { root in
            let products = root.appendingPathComponent("Products")
            let otherProducts = root.appendingPathComponent("OtherProducts")
            try writeManifest(to: products)
            try writeManifest(to: otherProducts)
            let report = inspect(loaded: products.appendingPathComponent("WebKit.framework"), root: root,
                                 environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": otherProducts.path])
            XCTAssertFalse(report.valid)
            XCTAssertEqual(report.manifestPath, otherProducts.appendingPathComponent("QuartzWebKit.json").path)
        }
    }

    func testLoadedEngineImagesMayAllComeFromBundledFrameworks() throws {
        try withDirectory { root in
            let app = root.appendingPathComponent("Quartz.app")
            let frameworks = app.appendingPathComponent("Contents/Frameworks")
            try writeManifest(to: app.appendingPathComponent("Contents/Resources"))
            let images = ["WebKit", "WebCore", "JavaScriptCore"].map {
                frameworks.appendingPathComponent("\($0).framework/Versions/A/\($0)").path
            }
            let report = inspect(loaded: frameworks.appendingPathComponent("WebKit.framework"), root: app,
                                 loadedImages: images)
            XCTAssertTrue(report.valid)
            XCTAssertEqual(report.loadedEngineImages, images.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.sorted())
        }
    }

    func testPartiallyLoadedEngineAndUnrelatedSystemFrameworksAreAllowed() throws {
        try withDirectory { root in
            try writeManifest(to: root)
            let webkit = root.appendingPathComponent("WebKit.framework/Versions/A/WebKit").path
            let report = inspect(loaded: root.appendingPathComponent("WebKit.framework"), root: root,
                                 loadedImages: [webkit, "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                                                "/usr/lib/swift/libswiftWebKit.dylib"])
            XCTAssertTrue(report.valid)
            XCTAssertEqual(report.loadedEngineImages, [URL(fileURLWithPath: webkit).resolvingSymlinksInPath().path])
        }
    }

    func testSystemEngineImagesAreRejectedEvenWhenWKWebViewUsesBundledFork() throws {
        try withDirectory { root in
            try writeManifest(to: root)
            for name in ["WebKit", "WebCore", "JavaScriptCore"] {
                let systemImage = "/System/Library/Frameworks/\(name).framework/Versions/A/\(name)"
                let report = inspect(loaded: root.appendingPathComponent("WebKit.framework"), root: root,
                                     loadedImages: [systemImage])
                XCTAssertFalse(report.valid, name)
                XCTAssertTrue(try XCTUnwrap(report.error).contains("outside its configured framework directory"))
            }
        }
    }

    func testEngineImageInSimilarlyNamedNeighborDirectoryIsRejected() throws {
        try withDirectory { root in
            let products = root.appendingPathComponent("Products")
            try writeManifest(to: products)
            let image = root.appendingPathComponent("Products-other/JavaScriptCore.framework/Versions/A/JavaScriptCore")
            let report = inspect(loaded: products.appendingPathComponent("WebKit.framework"), root: root,
                                 loadedImages: [image.path])
            XCTAssertFalse(report.valid)
        }
    }

    func testEngineImageSymlinkCannotHideAnExternalFramework() throws {
        try withDirectory { root in
            let products = root.appendingPathComponent("Products")
            let external = root.appendingPathComponent("External/JavaScriptCore.framework/Versions/A")
            try writeManifest(to: products)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data().write(to: external.appendingPathComponent("JavaScriptCore"))
            try FileManager.default.createSymbolicLink(
                at: products.appendingPathComponent("JavaScriptCore.framework"),
                withDestinationURL: external.deletingLastPathComponent().deletingLastPathComponent()
            )
            let image = products.appendingPathComponent("JavaScriptCore.framework/Versions/A/JavaScriptCore")
            let report = inspect(loaded: products.appendingPathComponent("WebKit.framework"), root: root,
                                 loadedImages: [image.path])
            XCTAssertFalse(report.valid)
            XCTAssertEqual(report.loadedEngineImages, [external.appendingPathComponent("JavaScriptCore").resolvingSymlinksInPath().path])
        }
    }

    func testSystemDevelopmentDiagnosticReportsSystemEngineImages() throws {
        try withDirectory { root in
            let systemImage = systemFramework.appendingPathComponent("Versions/A/WebKit")
            let report = inspect(loaded: systemFramework, root: root, requiresFork: false,
                                 loadedImages: [systemImage.path])
            XCTAssertTrue(report.valid)
            XCTAssertEqual(report.mode, "system-development")
            XCTAssertEqual(report.loadedEngineImages, [systemImage.resolvingSymlinksInPath().path])
        }
    }

    func testNeighboringFrameworkDirectoryIsRejected() throws {
        try withDirectory { root in
            let products = root.appendingPathComponent("Products")
            try writeManifest(to: products)
            let report = inspect(loaded: root.appendingPathComponent("Products-other/WebKit.framework"), root: root,
                                 environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": products.path])
            XCTAssertFalse(report.valid)
        }
    }

    func testMalformedAndIncompleteManifestsAreRejected() throws {
        try withDirectory { root in
            for value in ["not JSON", "{}", "{\"repository\":17}", "{\"revision\":null}"] {
                try Data(value.utf8).write(to: root.appendingPathComponent("QuartzWebKit.json"))
                let report = inspect(loaded: root.appendingPathComponent("WebKit.framework"), root: root,
                                     environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": root.path])
                XCTAssertFalse(report.valid, value)
                XCTAssertTrue(try XCTUnwrap(report.error).contains("Cannot read valid WebKit metadata"))
            }
        }
    }

    func testInvalidProvenanceAndMinimumVersionsAreRejected() throws {
        try withDirectory { root in
            let invalid: [[String: String]] = [
                ["repository": "https://github.com/WebKit/WebKit.git"],
                ["revision": "abcdef1"],
                ["revision": String(repeating: "z", count: 40)],
                ["revision": revision + "\n"],
                ["minimumSystemVersion": "macOS 14"],
                ["minimumSystemVersion": "14"],
                ["minimumSystemVersion": "14.0.0.0"],
                ["minimumSystemVersion": "999999999999999999999999.0"],
                ["minimumSystemVersion": "27.0"]
            ]
            for values in invalid {
                try writeManifest(to: root, overrides: values)
                let report = inspect(loaded: root.appendingPathComponent("WebKit.framework"), root: root,
                                     environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": root.path])
                XCTAssertFalse(report.valid, "\(values)")
            }
        }
    }

    func testMinimumVersionUsesNumericComparisonIncludingPatch() throws {
        try withDirectory { root in
            for (minimum, valid) in [("14.10", true), ("26.0.1", true), ("26.0.2", false), ("26.1", false)] {
                try writeManifest(to: root, overrides: ["minimumSystemVersion": minimum])
                let report = inspect(loaded: root.appendingPathComponent("WebKit.framework"), root: root,
                                     environment: ["QUARTZ_WEBKIT_PRODUCTS_DIR": root.path])
                XCTAssertEqual(report.valid, valid, minimum)
            }
        }
    }

    private func inspect(loaded: URL, root: URL, requiresFork: Bool = true,
                         environment: [String: String] = [:], loadedImages: [String] = []) -> QuartzWebKitRuntime.Report {
        QuartzWebKitRuntime.inspect(
            loadedFrameworkURL: loaded,
            applicationBundleURL: root,
            applicationResourcesURL: root.appendingPathComponent("Contents/Resources"),
            applicationFrameworksURL: root.appendingPathComponent("Contents/Frameworks"),
            environment: environment,
            requiresFork: requiresFork,
            systemVersion: systemVersion,
            loadedImagePaths: loadedImages
        )
    }

    private func writeManifest(to directory: URL, overrides: [String: String] = [:]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = ["repository": QuartzWebKitRuntime.repository, "revision": revision, "minimumSystemVersion": "14.0"]
        values.merge(overrides) { _, replacement in replacement }
        try JSONSerialization.data(withJSONObject: values).write(to: directory.appendingPathComponent("QuartzWebKit.json"))
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuartzWebKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
}
