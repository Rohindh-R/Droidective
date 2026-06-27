import Foundation
import Testing
@testable import ADBKit

@Suite struct ApkBadgingTests {
    /// A representative slice of `aapt2 dump badging` output.
    private let sample = """
    package: name='com.example.myapp' versionCode='42' versionName='2.1.0' compileSdkVersion='34' compileSdkVersionCodename='14'
    sdkVersion:'24'
    targetSdkVersion:'34'
    uses-permission: name='android.permission.INTERNET'
    application-label:'My Example App'
    application-label-en-US:'My Example App'
    application-label-fr:'Mon App'
    application: label='My Example App' icon='res/mipmap-anydpi-v26/ic_launcher.xml'
    launchable-activity: name='com.example.myapp.MainActivity'  label='My Example App'
    """

    @Test func parsesAllIdentifyingFields() {
        let fields = ApkBadging.parse(sample)
        #expect(fields.packageName == "com.example.myapp")
        #expect(fields.versionName == "2.1.0")
        #expect(fields.versionCode == "42")
        #expect(fields.label == "My Example App")
        #expect(fields.minSdk == "24")
        #expect(fields.targetSdk == "34")
    }

    @Test func packageNameIsNotConfusedWithPermissionOrActivityNames() {
        // `name='…'` also appears on uses-permission / launchable-activity lines;
        // only the `package:` line's name is the package id.
        #expect(ApkBadging.parse(sample).packageName == "com.example.myapp")
    }

    @Test func minSdkIsNotShadowedByTargetSdk() {
        // `targetSdkVersion` must not be misread as `sdkVersion` (case matters).
        let fields = ApkBadging.parse(sample)
        #expect(fields.minSdk == "24")
        #expect(fields.targetSdk == "34")
    }

    @Test func fallsBackToApplicationLineLabel() {
        let output = """
        package: name='com.x' versionCode='1' versionName='1.0'
        application: label='Fallback Label' icon='res/ic.png'
        """
        #expect(ApkBadging.parse(output).label == "Fallback Label")
    }

    @Test func emptyValuesAndGarbageYieldNil() {
        let fields = ApkBadging.parse("package: name='' versionName='' \nnonsense line")
        #expect(fields.packageName == nil)
        #expect(fields.versionName == nil)
        #expect(fields.label == nil)
        #expect(fields.minSdk == nil)
    }

    @Test func apkInfoHasDetailsReflectsBadging() {
        let bare = ApkInfo(fileName: "app.apk", fileSizeBytes: 1024)
        #expect(!bare.hasDetails)
        let rich = ApkInfo(fileName: "app.apk", fileSizeBytes: 1024, packageName: "com.x")
        #expect(rich.hasDetails)
    }
}
