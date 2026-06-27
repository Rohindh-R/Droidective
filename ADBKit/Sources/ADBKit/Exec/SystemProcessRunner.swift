import Foundation

/// Foundation.Process-backed runner.
///
/// Fully non-blocking: pipes are drained via `readabilityHandler` callbacks
/// and exit is observed via `terminationHandler`, so no Swift-concurrency
/// cooperative thread is ever parked. (A blocking `waitUntilExit`/
/// `availableData` design starves the cooperative pool once a few adb calls
/// overlap — device polling + a feature run is enough — wedging the whole
/// async runtime.) A watchdog escalates SIGTERM → SIGKILL on timeout.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        timeout: Duration,
        maxOutputBytes: Int
    ) async -> ProcessOutput {
        await Self.run(
            executable: executable,
            arguments: arguments,
            environment: nil,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
    }

    /// Full-control variant used by tool launchers that need env overrides
    /// (e.g. scrcpy, which resolves `adb` via PATH/ADB).
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration,
        maxOutputBytes: Int
    ) async -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdout = PipeCollector(cap: maxOutputBytes)
        let stderr = PipeCollector(cap: maxOutputBytes)
        stdout.attach(outPipe.fileHandleForReading)
        stderr.attach(errPipe.fileHandleForReading)

        let timedOut = LockedBox(false)
        let cancelled = LockedBox(false)
        let boxed = UncheckedSendable(process)

        return await withTaskCancellationHandler {
            // Started before the exit await so it runs concurrently; Task.sleep
            // parks no thread. `isRunning` is false both before launch and after
            // exit, so terminate() is only ever sent to a live process — and the
            // timedOut flag is only set when termination was actually forced
            // (a process exiting cleanly right at the deadline isn't a timeout).
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                if boxed.value.isRunning {
                    timedOut.set(true)
                    boxed.value.terminate()
                }
                try await Task.sleep(for: .seconds(2))
                if boxed.value.isRunning {
                    kill(boxed.value.processIdentifier, SIGKILL)
                }
            }

            let exitCode: Int32? = await withCheckedContinuation { continuation in
                let resumed = LockedBox(false)
                process.terminationHandler = { finished in
                    guard !resumed.swap(true) else { return }
                    let exited = finished.terminationReason == .exit
                    continuation.resume(returning: exited ? finished.terminationStatus : nil)
                }
                do {
                    try process.run()
                    // Cancelled during launch: tear the child down now so it
                    // doesn't keep running after the caller's Task is gone.
                    if cancelled.get(), boxed.value.isRunning { boxed.value.terminate() }
                } catch {
                    guard !resumed.swap(true) else { return }
                    stdout.cancel(outPipe.fileHandleForReading)
                    stderr.cancel(errPipe.fileHandleForReading)
                    stderr.injectFailure("failed to launch \(executable): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
            watchdog.cancel()

            // Bounded: a grandchild (e.g. a spawned daemon) can inherit the pipe
            // and delay EOF past the parent's exit.
            await stdout.waitUntilEOF(grace: .seconds(3))
            await stderr.waitUntilEOF(grace: .seconds(3))

            return ProcessOutput(
                stdout: stdout.data,
                stderr: stderr.data,
                exitCode: timedOut.get() ? nil : exitCode,
                timedOut: timedOut.get()
            )
        } onCancel: {
            // Cancelling the calling Task (e.g. a SwiftUI .task torn down on
            // navigation, or a .task(id:) re-keying) must kill the child so
            // run() returns promptly and no orphaned adb process lingers until
            // its timeout. SIGTERM first, then SIGKILL for anything ignoring it.
            cancelled.set(true)
            if boxed.value.isRunning { boxed.value.terminate() }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if boxed.value.isRunning { kill(boxed.value.processIdentifier, SIGKILL) }
            }
        }
    }
}

/// Accumulates one pipe's output via readabilityHandler (no blocked thread)
/// and lets a waiter await EOF.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let cap: Int

    init(cap: Int) {
        self.cap = cap
    }

    private weak var handle: FileHandle?

    func attach(_ handle: FileHandle) {
        lock.lock()
        self.handle = handle
        lock.unlock()
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                self?.finish()
            } else {
                self?.append(chunk)
            }
        }
    }

    /// Detach the handler, close the FD, and mark finished.
    func cancel(_ handle: FileHandle) {
        handle.readabilityHandler = nil
        try? handle.close()
        finish()
    }

    func injectFailure(_ message: String) {
        lock.lock()
        buffer = Data(message.utf8)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    private func currentHandle() -> FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    func waitUntilEOF(grace: Duration) async {
        // On expiry, also tear down the read source — a grandchild holding
        // the pipe's write end would otherwise keep the FD and handler alive
        // (and collecting) long after run() has returned.
        let deadline = Task { [weak self] in
            try await Task.sleep(for: grace)
            guard let self else { return }
            if let handle = self.currentHandle() {
                self.cancel(handle)
            } else {
                self.finish()
            }
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
        deadline.cancel()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        if buffer.count < cap {
            buffer.append(chunk.prefix(cap - buffer.count))
        }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        finished = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }
}

/// Confines a non-Sendable value we know is used safely across one task hop.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    /// Swap in a new value, returning the previous one (atomic test-and-set).
    @discardableResult
    func swap(_ newValue: T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
