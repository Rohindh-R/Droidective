import Testing
@testable import ADBKit

@Suite struct DeviceOverviewTests {
    @Test func parsesMeminfo() {
        let output = """
        MemTotal:        3882924 kB
        MemFree:          172004 kB
        MemAvailable:    1265432 kB
        """
        let (total, available) = DeviceOverview.parseMeminfo(output)
        #expect(total == 3_882_924)
        #expect(available == 1_265_432)
    }

    @Test func parsesDf() {
        let output = """
        Filesystem      1K-blocks     Used Available Use% Mounted on
        /dev/block/dm-5  56371708 22152504  34057940  40% /data
        """
        let (total, used, available) = DeviceOverview.parseDf(output)
        #expect(total == 56_371_708)
        #expect(used == 22_152_504)
        #expect(available == 34_057_940)
    }

    @Test func parsesBatteryWithHealthAndCycles() {
        let output = """
        Current Battery Service state:
          level: 64
          health: 2
          Cycle count: 137
        """
        let (level, health, cycles) = DeviceOverview.parseBattery(output)
        #expect(level == 64)
        #expect(health == "Good")
        #expect(cycles == 137)
    }

    @Test func missingCycleCountIsNil() {
        let (level, health, cycles) = DeviceOverview.parseBattery("level: 80\nhealth: 3")
        #expect(level == 80)
        #expect(health == "Overheat")
        #expect(cycles == nil)
    }

    @Test func countsPackages() {
        #expect(DeviceOverview.countPackages("package:com.a\npackage:com.b\n\njunk") == 2)
        #expect(DeviceOverview.countPackages("") == 0)
    }

    @Test func ramUsedDerived() {
        var overview = DeviceOverview()
        overview.ramTotalKb = 4000
        overview.ramAvailableKb = 1500
        #expect(overview.ramUsedKb == 2500)
    }
}

@Suite struct FileStatParsingTests {
    @Test func parsesStatFields() {
        let info = FileExplorerService.parseStat(
            "regular file|66500000|u0_a123|-rw-rw----|2026-06-12 18:03:11.123456789 +0530|2026-06-12 18:05:00.000000000 +0530"
        )
        #expect(info?.type == "Regular File")
        #expect(info?.sizeBytes == 66_500_000)
        #expect(info?.owner == "u0_a123")
        #expect(info?.permissions == "-rw-rw----")
        #expect(info?.modified == "2026-06-12 18:03:11 +0530")
    }

    @Test func malformedStatIsNil() {
        #expect(FileExplorerService.parseStat("garbage") == nil)
    }
}

@Suite struct EmulatorParsingTests {
    @Test func parsesAvdListSkippingNoise() {
        let output = """
        INFO    | Storing crashdata in: /tmp/android-user
        Pixel_7_API_34
        Tablet_API_33

        """
        #expect(EmulatorService.parseAvdList(output) == ["Pixel_7_API_34", "Tablet_API_33"])
    }

    @Test func avdDisplayNameHumanizes() {
        #expect(Avd(name: "Pixel_7_API_34").displayName == "Pixel 7 API 34")
    }

    @Test func parsesAvdListWithCrlf() {
        #expect(EmulatorService.parseAvdList("Pixel_7\r\nMedium_Tablet\r\n") == ["Pixel_7", "Medium_Tablet"])
    }
}

@Suite struct AppsExplorerParsingTests {
    @Test func parsesVersionsPerPackageBlock() {
        let dump = """
        Packages:
          Package [com.first] (abc):
            userId=10001
            versionName=1.2.3
          Package [com.second] (def):
            versionName=9.0
            versionName=ignored-second-occurrence
        """
        let versions = AppsExplorerService.parseVersions(dump)
        #expect(versions["com.first"] == "1.2.3")
        #expect(versions["com.second"] == "9.0")
    }

    @Test func listingSearchMatchesNameVersionAndBundle() {
        let listing = AppListing(packageId: "com.example.weather", versionName: "2.4.1", isSystem: false)
        #expect(listing.displayName == "Weather")
        #expect(listing.matches("weath"))
        #expect(listing.matches("2.4"))
        #expect(listing.matches("example"))
        #expect(!listing.matches("nomatch"))
    }
}
