import Foundation
import Testing
@testable import ADBKit

/// Real-process tests: the runner must never park cooperative threads, so
/// heavy concurrency here both validates behavior and acts as a starvation
/// regression net (the v1 runner deadlocked the async runtime under ~4
/// concurrent invocations).
@Suite struct SystemProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test func capturesStdoutAndExitCode() async {
        let output = await runner.run(executable: "/bin/echo", arguments: ["hello"], timeout: .seconds(5))
        #expect(output.exitCode == 0)
        #expect(output.stdoutText == "hello\n")
        #expect(!output.timedOut)
    }

    @Test func capturesStderrAndNonZeroExit() async {
        let output = await runner.run(
            executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"], timeout: .seconds(5)
        )
        #expect(output.exitCode == 3)
        #expect(output.stderrText == "oops\n")
    }

    @Test func launchFailureReportsNilExit() async {
        let output = await runner.run(executable: "/no/such/binary", arguments: [], timeout: .seconds(5))
        #expect(output.exitCode == nil)
        #expect(output.stderrText.contains("failed to launch"))
    }

    @Test func timeoutKillsAndFlags() async {
        let clock = ContinuousClock()
        let started = clock.now
        let output = await runner.run(
            executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300)
        )
        #expect(output.timedOut)
        #expect(output.exitCode == nil)
        #expect(clock.now - started < .seconds(10))
    }

    @Test func largeOutputIsCappedNotDeadlocked() async {
        // 2 MB of output with a 64 KB cap — the old blocking design risks a
        // full-pipe deadlock if draining stalls; the cap must also hold.
        let output = await runner.run(
            executable: "/usr/bin/yes", arguments: [], timeout: .seconds(3), maxOutputBytes: 64 * 1024
        )
        #expect(output.stdout.count == 64 * 1024)
    }

    @Test func manyConcurrentInvocationsDoNotStarveTheRuntime() async {
        // 16 concurrent slow-ish processes — far past the old failure point.
        // A canary task must keep making progress while they run.
        let canaryTicks = LockedBox(0)
        let canary = Task {
            while !Task.isCancelled {
                canaryTicks.set(canaryTicks.get() + 1)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        await withTaskGroup(of: Int32?.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let output = await runner.run(
                        executable: "/bin/sh", arguments: ["-c", "sleep 0.3; echo done"], timeout: .seconds(10)
                    )
                    return output.exitCode
                }
            }
            for await code in group {
                #expect(code == 0)
            }
        }
        canary.cancel()
        #expect(canaryTicks.get() > 5, "canary task starved — runner is blocking cooperative threads")
    }

    @Test func cancellationKillsChildAndReturnsPromptly() async {
        // A long-running child under a generous timeout: cancelling the calling
        // Task must kill it and return now, not block until the 60s timeout.
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            await runner.run(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(60))
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let output = await task.value
        #expect(clock.now - started < .seconds(10), "cancellation did not tear the child down promptly")
        #expect(!output.timedOut, "a cancelled run is not a timeout")
        #expect(output.exitCode == nil, "a killed child has no clean exit code")
    }
}
