import Foundation
import Testing
@testable import NotchKit

@Suite struct SDKVersionTests {
    @Test func R03__sdk_version_parses_major_minor() {
        #expect(SDKVersion("1.0") == SDKVersion(major: 1, minor: 0))
        #expect(SDKVersion("2.13") == SDKVersion(major: 2, minor: 13))
        #expect(SDKVersion("1") == nil)
        #expect(SDKVersion("1.0.0") == nil)
        #expect(SDKVersion("a.b") == nil)
        #expect(SDKVersion("-1.0") == nil)
        #expect(SDKVersion(major: 1, minor: 2).description == "1.2")
    }

    @Test func R03__host_accepts_same_major_with_older_or_equal_minor() {
        let host = SDKVersion(major: 1, minor: 2)
        #expect(host.supports(SDKVersion(major: 1, minor: 0)))
        #expect(host.supports(SDKVersion(major: 1, minor: 2)))
    }

    @Test func R03__host_rejects_different_major_or_newer_minor() {
        let host = SDKVersion(major: 1, minor: 2)
        #expect(!host.supports(SDKVersion(major: 2, minor: 0)))
        #expect(!host.supports(SDKVersion(major: 0, minor: 9)))
        #expect(!host.supports(SDKVersion(major: 1, minor: 3)))
    }

    @Test func R03__sdk_starts_at_1_0() {
        #expect(NotchKitSDK.version == SDKVersion(major: 1, minor: 0))
    }

    @Test func R03__incompatible_sdk_reason_is_readable() {
        let error = PluginLoadError.incompatibleSDK(
            required: SDKVersion(major: 2, minor: 0),
            host: SDKVersion(major: 1, minor: 0)
        )
        #expect(error.description.contains("2.0"))
        #expect(error.description.contains("1.0"))
    }
}

@Suite struct PluginManifestTests {
    @Test func R03__manifest_identifier_must_be_reverse_dns() {
        #expect(PluginManifest.isValidIdentifier("com.example.sample"))
        #expect(PluginManifest.isValidIdentifier("io.github.some-dev.clock2"))
        #expect(!PluginManifest.isValidIdentifier("sample"))
        #expect(!PluginManifest.isValidIdentifier("com..sample"))
        #expect(!PluginManifest.isValidIdentifier(".com.sample"))
        #expect(!PluginManifest.isValidIdentifier("com.sample."))
        #expect(!PluginManifest.isValidIdentifier("com.exa mple"))
        #expect(!PluginManifest.isValidIdentifier("com.example/x"))
    }

    @Test func R03__layers_order_takeover_attention_hud_activity() {
        #expect(NotchLayer.liveActivity < NotchLayer.hud)
        #expect(NotchLayer.hud < NotchLayer.attention)
        #expect(NotchLayer.attention < NotchLayer.takeover)
        #expect(NotchLayer.allCases.max() == .takeover)
    }
}
