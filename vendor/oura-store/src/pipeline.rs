//! Commit drained batches on a background thread so SQLite overlaps BLE.
//!
//! A history drain alternates "transfer a batch over BLE" and "commit it with its
//! cursor". Done inline, the ring sits idle for every commit, because the next
//! request is only sent once the batch callback returns. [`BatchCommitter`] takes
//! each complete batch and commits it on its own thread while the drain requests
//! the next one.
//!
//! The durability rules stay the same:
//! - batches commit strictly in order, each in one transaction with its cursor, so
//!   the stored cursor never passes data that is not in the database;
//! - at most one batch waits behind the one being committed ([`submit`] blocks
//!   until there is room), which bounds memory and keeps the drain at most one
//!   batch ahead of storage;
//! - after the first failure nothing more is committed and [`submit`] returns
//!   `false`, so the drain stops. The ring holds its history until a later request
//!   asks for it by cursor, so a sync that stops here resumes from the last
//!   committed batch.
//!
//! [`submit`]: BatchCommitter::submit

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use oura_protocol::events::RingEvent;

use crate::error::Error;
use crate::storage::Store;

/// What one committed batch did, passed to the batch's `on_commit` callback.
#[derive(Clone, Copy, Debug)]
pub struct Committed {
    /// Rows actually added; duplicates of stored events are ignored.
    pub inserted: u32,
    /// The cursor stored with this batch.
    pub cursor: u32,
    /// Time spent in SQLite for this batch.
    pub elapsed: Duration,
}

/// Everything the committer thread hands back once it has stopped.
pub struct Finished {
    /// The store, for the caller's work after the drain (cursor rebase, anchors).
    pub store: Store,
    /// Rows added across every committed batch.
    pub inserted: u32,
    /// Cursor of the last committed batch (the starting cursor if none committed).
    pub checkpoint: u32,
    /// The failure that stopped committing, if any.
    pub error: Option<Error>,
}

type OnCommit = Box<dyn FnOnce(Committed) + Send>;

struct Job {
    events: Vec<RingEvent>,
    cursor: u32,
    on_commit: OnCommit,
}

/// Background, in-order committer for one drain. See the module docs.
pub struct BatchCommitter {
    tx: Option<SyncSender<Job>>,
    failed: Arc<AtomicBool>,
    handle: Option<JoinHandle<Finished>>,
}

impl BatchCommitter {
    /// Move `store` onto a committer thread for `serial`'s drain starting at `cursor`.
    pub fn spawn(store: Store, serial: &str, cursor: u32) -> Self {
        // Capacity 1: one batch queued behind the one being committed.
        let (tx, rx) = sync_channel::<Job>(1);
        let failed = Arc::new(AtomicBool::new(false));
        let thread_failed = failed.clone();
        let serial = serial.to_owned();
        let handle = std::thread::Builder::new()
            .name("oura-store-commit".into())
            .spawn(move || {
                let mut done = Finished {
                    store,
                    inserted: 0,
                    checkpoint: cursor,
                    error: None,
                };
                for job in rx {
                    let started = Instant::now();
                    match done.store.commit_batch(&serial, &job.events, job.cursor) {
                        Ok(inserted) => {
                            done.inserted += inserted;
                            done.checkpoint = job.cursor;
                            (job.on_commit)(Committed {
                                inserted,
                                cursor: job.cursor,
                                elapsed: started.elapsed(),
                            });
                        }
                        Err(error) => {
                            thread_failed.store(true, Ordering::SeqCst);
                            done.error = Some(error);
                            // Returning drops `rx`, so later submits fail fast.
                            break;
                        }
                    }
                }
                done
            })
            .expect("spawning the oura-store commit thread");
        Self {
            tx: Some(tx),
            failed,
            handle: Some(handle),
        }
    }

    /// Queue a complete batch and its cursor. `on_commit` runs on the committer
    /// thread once the batch is durable. Blocks while a batch is already waiting.
    /// Returns `false` once committing has failed; the drain should then stop.
    pub fn submit(
        &self,
        events: Vec<RingEvent>,
        cursor: u32,
        on_commit: impl FnOnce(Committed) + Send + 'static,
    ) -> bool {
        if self.failed.load(Ordering::SeqCst) {
            return false;
        }
        let Some(tx) = &self.tx else { return false };
        tx.send(Job {
            events,
            cursor,
            on_commit: Box::new(on_commit),
        })
        .is_ok()
    }

    /// Commit everything still queued, stop the thread and return the store.
    pub fn finish(mut self) -> Finished {
        self.tx.take(); // closes the channel once the queued batches are taken
        let handle = self.handle.take().expect("finish runs once");
        match handle.join() {
            Ok(done) => done,
            // commit_batch does not panic on bad data, and the store moved into a
            // thread that panicked cannot be recovered. Surface it instead of
            // silently losing the panic.
            Err(panic) => std::panic::resume_unwind(panic),
        }
    }
}

impl Drop for BatchCommitter {
    fn drop(&mut self) {
        // A caller that never reached `finish` (an early return or a cancelled
        // future) must still let queued batches commit and the thread end.
        self.tx.take();
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn event(ts: u32) -> RingEvent {
        RingEvent {
            tag: 0x43,
            name: "debug_event",
            timestamp: ts,
            body: vec![ts as u8],
            decoded: None,
        }
    }

    #[test]
    fn commits_in_order_and_returns_the_store() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_device("S1", None, None).unwrap();
        let committer = BatchCommitter::spawn(store, "S1", 0);
        let seen = Arc::new(Mutex::new(Vec::new()));
        for batch in 0..5u32 {
            let events = (0..10).map(|i| event(batch * 10 + i)).collect();
            let seen = seen.clone();
            assert!(committer.submit(events, (batch + 1) * 10, move |c| {
                seen.lock().unwrap().push((c.cursor, c.inserted));
            }));
        }
        let done = committer.finish();
        assert!(done.error.is_none());
        assert_eq!(done.inserted, 50);
        assert_eq!(done.checkpoint, 50);
        assert_eq!(done.store.cursor("S1").unwrap(), 50);
        assert_eq!(
            *seen.lock().unwrap(),
            vec![(10, 10), (20, 10), (30, 10), (40, 10), (50, 10)]
        );
    }

    #[test]
    fn stops_after_a_failed_commit_and_keeps_the_last_good_cursor() {
        let store = Store::open_in_memory().unwrap();
        store.upsert_device("S1", None, None).unwrap();
        store.set_cursor("S1", 7).unwrap();
        // Every insert now fails, so the first batch cannot commit.
        store
            .conn_for_tests()
            .execute_batch("DROP TABLE events")
            .unwrap();
        let committer = BatchCommitter::spawn(store, "S1", 7);
        // The thread may not have failed yet when the next batch is offered, so
        // the first one or two submits can be accepted; neither may commit, and
        // a later one must be refused.
        let _ = committer.submit(vec![event(1)], 10, |_| panic!("must not commit"));
        let mut refused = false;
        for _ in 0..1000 {
            if !committer.submit(vec![event(2)], 20, |_| panic!("must not commit")) {
                refused = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(refused, "submit keeps accepting batches after a failure");
        let done = committer.finish();
        assert!(done.error.is_some());
        assert_eq!(done.inserted, 0);
        assert_eq!(done.checkpoint, 7);
        assert_eq!(done.store.cursor("S1").unwrap(), 7);
    }
}
