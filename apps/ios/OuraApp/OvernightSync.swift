import BackgroundTasks
import Foundation

/// Trickle-syncs the ring overnight: a BGProcessingTask that iOS launches only while
/// the phone is idle and on external power — in practice on the nightstand charger
/// while the ring is worn for sleep. Each launch drains whatever the ring holds, so
/// opening the app in the morning transfers minutes of data instead of a whole night.
///
/// iOS picks the moment (and may run it several times a night or skip a night); the
/// app has to have been opened since boot and not force-quit from the app switcher.
/// The drain checkpoints its cursor per batch, so a launch that iOS cuts short
/// resumes on the next one with nothing lost.
///
/// Debug: pause in the debugger after backgrounding the app, then
///   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"engineer.evanlee.openoura.overnight-sync"]
@MainActor
enum OvernightSync {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let taskID = "engineer.evanlee.openoura.overnight-sync"
    /// Gap between launches within one charging session: long enough that a night
    /// yields a few drains rather than a tight loop, short enough to keep each small.
    private static let interval: TimeInterval = 45 * 60
    /// When the task last launched (epoch seconds). `schedule()` measures the gap from
    /// it, so the app going to the background cannot reset the spacing.
    private static let lastLaunchKey = "overnight.last-launch"

    /// Register the launch handler. Apple requires this before the app finishes
    /// launching, so it is called from `OuraApp.init`.
    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: .main) { task in
            MainActor.assumeIsolated { handle(task) }
        }
        if !ok { dlog("overnight", "register FAILED; is \(taskID) in BGTaskSchedulerPermittedIdentifiers?") }
    }

    /// Ask iOS for the next launch, no sooner than `interval` after the last one.
    /// Submitting replaces any pending request for the same identifier, so calling
    /// this on every trip to the background is safe.
    static func schedule() {
        // The run needs the ring key; without one (never paired, cleared, or a key
        // from an older build that a locked phone cannot read yet) a launch would do
        // nothing. The next trip to the background after the key is readable again
        // schedules it.
        guard Keychain.loadKey() != nil else { return }
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        let notBefore = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastLaunchKey) + interval)
        request.earliestBeginDate = notBefore > Date() ? notBefore : nil
        do {
            try BGTaskScheduler.shared.submit(request)
            dlog("overnight", "scheduled" + (request.earliestBeginDate.map { " (not before +\(Int($0.timeIntervalSinceNow / 60)) min)" } ?? ""))
        } catch {
            // .unavailable on the simulator, or when Background App Refresh is off.
            dlog("overnight", "schedule FAILED: \(error)")
        }
    }

    private static func handle(_ task: BGTask) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastLaunchKey)
        guard Keychain.loadKey() != nil else {
            // Nothing to drain with, and rescheduling would just wake the app all night.
            dlog("overnight", "launched but the ring key is unreadable; not rescheduling")
            task.setTaskCompleted(success: false)
            return
        }
        // Line up the next launch first, so a crash or kill mid-drain still leaves
        // one pending.
        schedule()
        let ring = RingSync.shared
        let done = Completion(task)
        dlog("overnight", "launched; draining the ring")
        let work = Task { @MainActor in
            let report = await ring.runInBackground()
            if let report {
                dlog("overnight", "done inserted=\(report.inserted) events=\(report.eventsSynced)")
            }
            done.finish(success: report != nil)
        }
        // iOS calls this when the window closes, on a queue of its own: stop at the
        // next checkpoint. The run then returns and completes the task; the fallback
        // covers a run that does not unwind within iOS's few-second grace. Cancelling
        // `work` as well stops a run that has not got past its first checks yet, which
        // `pause()` alone would not (`run` resets the flag when it starts).
        task.expirationHandler = { @Sendable in
            Task { @MainActor in
                dlog("overnight", "expired; stopping at the next checkpoint")
                work.cancel()
                if ring.busy { ring.pause() }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                done.finish(success: false)
            }
        }
    }

    /// `setTaskCompleted` exactly once, whichever of the run and the expiration
    /// fallback gets there first.
    private final class Completion: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false
        init(_ task: BGTask) { self.task = task }
        func finish(success: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
        }
    }
}
