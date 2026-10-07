//! Helpers shared by this crate's unit tests.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// A directory under the system temp dir that no other test in this process
/// can be using.
///
/// Tests run in parallel, and naming a directory after the clock alone let
/// two of them land on the same nanosecond and read each other's files; worse,
/// the runtime registry keys on the data directory, so colliding tests shared
/// one `RuntimeInner`. The process id and a counter keep the name unique on
/// their own, the clock only keeps runs apart from each other's leftovers.
pub(crate) fn unique_temp_dir(prefix: &str) -> PathBuf {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("time went backwards")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "{prefix}-{}-{}-{nanos}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}
