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
    /// The last launch's outcome, for the line on the sync screen.
    private static let lastResultAtKey = "overnight.last-result-at"
    private static let lastResultKey = "overnight.last-result"

    /// "Last overnight sync …" for the sync screen, nil until the task has run once.
    static var lastResultLine: String? {
        let at = UserDefaults.standard.double(forKey: lastResultAtKey)
        guard at > 0, let text = UserDefaults.standard.string(forKey: lastResultKey) else { return nil }
        let when = Date(timeIntervalSince1970: at).formatted(.relative(presentation: .named))
        return "Last overnight sync \(when): \(text)"
    }

    private static func record(_ text: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastResultAtKey)
        UserDefaults.standard.set(text, forKey: lastResultKey)
    }

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
        // DiagStore files the previous session by its last lifecycle state, and a
        // launch straight into the background never posts one: without this line every
        // overnight run would surface the next morning as an "interrupted" incident.
        dlog("lifecycle", "state=background (overnight task)")
        guard Keychain.loadKey() != nil else {
            // Nothing to drain with, and rescheduling would just wake the app all night.
            dlog("overnight", "launched but the ring key is unreadable; not rescheduling")
            record("skipped, the ring key could not be read. Open the app to re-enable.")
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
                record(report.inserted == 0 ? "nothing new on the ring"
                       : "\(report.inserted.formatted()) new readings saved")
            } else if Task.isCancelled {
                record("iOS ended it partway; the rest syncs on the next run")
            } else {
                record("didn’t finish. \(ring.status.isEmpty ? "See Technical reports." : ring.status)")
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
