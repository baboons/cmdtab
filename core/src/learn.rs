//! Learns which app you pick for which query ("sl" -> Slack) so frequently
//! chosen results float to the top next time. Counts decay exponentially so
//! habits can change, and the store is persisted as a small TSV file.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

const HEADER: &str = "# cmdtab-learn v1";
const HALF_LIFE_SECS: f64 = 21.0 * 24.0 * 3600.0;
const MAX_PREFIX_CHARS: usize = 12;
const MAX_ENTRIES: usize = 4096;
const MAX_BOOST: f64 = 28.0;
const SEP: char = '\u{1f}';

#[derive(Clone, Copy, Debug)]
struct Entry {
    count: f64,
    last: u64,
}

impl Entry {
    fn decayed(&self, now: u64) -> f64 {
        let age = now.saturating_sub(self.last) as f64;
        self.count * 0.5f64.powf(age / HALF_LIFE_SECS)
    }
}

pub struct LearnStore {
    map: HashMap<String, Entry>,
    writer: Option<Sender<String>>,
}

pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn key(prefix: &str, app: &str) -> String {
    let mut k = String::with_capacity(prefix.len() + app.len() + 1);
    k.push_str(prefix);
    k.push(SEP);
    k.push_str(app);
    k
}

fn truncate_chars(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((idx, _)) => &s[..idx],
        None => s,
    }
}

impl LearnStore {
    /// An in-memory store that is never persisted.
    pub fn ephemeral() -> Self {
        LearnStore { map: HashMap::new(), writer: None }
    }

    /// Loads the store from `path` (if it exists) and persists every change
    /// back to it from a background thread.
    pub fn open(path: &Path) -> Self {
        let mut store = LearnStore { map: load(path), writer: None };
        store.writer = Some(spawn_writer(path.to_path_buf()));
        store
    }

    /// Boost (0..=MAX_BOOST) for `app` given the normalized query.
    pub fn boost(&self, query: &str, app: &str, now: u64) -> i32 {
        if query.is_empty() || app.is_empty() || self.map.is_empty() {
            return 0;
        }
        let prefix = truncate_chars(query, MAX_PREFIX_CHARS);
        match self.map.get(&key(prefix, app)) {
            Some(e) => (10.0 * (1.0 + e.decayed(now)).ln()).min(MAX_BOOST) as i32,
            None => 0,
        }
    }

    /// Remembers that `app` was chosen after typing `query`. Every prefix of
    /// the query is reinforced so the boost kicks in from the first keystroke.
    pub fn record(&mut self, query: &str, app: &str, now: u64) {
        if query.is_empty() || app.is_empty() {
            return;
        }
        let q = truncate_chars(query, MAX_PREFIX_CHARS);
        let mut ends: Vec<usize> = q.char_indices().skip(1).map(|(i, _)| i).collect();
        ends.push(q.len());
        for end in ends {
            let prefix = &q[..end];
            if prefix.ends_with(' ') {
                continue;
            }
            let entry = self.map.entry(key(prefix, app)).or_insert(Entry { count: 0.0, last: now });
            entry.count = entry.decayed(now) + 1.0;
            entry.last = now;
        }
        self.evict(now);
        if let Some(tx) = &self.writer {
            let _ = tx.send(self.serialize());
        }
    }

    /// Forgets everything that was learned.
    pub fn clear(&mut self) {
        self.map.clear();
        if let Some(tx) = &self.writer {
            let _ = tx.send(self.serialize());
        }
    }

    fn evict(&mut self, now: u64) {
        if self.map.len() <= MAX_ENTRIES {
            return;
        }
        let mut scored: Vec<(f64, String)> = self.map.iter().map(|(k, e)| (e.decayed(now), k.clone())).collect();
        scored.sort_by(|a, b| a.0.total_cmp(&b.0));
        let remove = self.map.len() - MAX_ENTRIES * 3 / 4;
        for (_, k) in scored.into_iter().take(remove) {
            self.map.remove(&k);
        }
    }

    fn serialize(&self) -> String {
        let mut out = String::with_capacity(self.map.len() * 32 + HEADER.len() + 1);
        out.push_str(HEADER);
        out.push('\n');
        for (k, e) in &self.map {
            if let Some((prefix, app)) = k.split_once(SEP) {
                out.push_str(&format!("{:.4}\t{}\t{}\t{}\n", e.count, e.last, prefix, app));
            }
        }
        out
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.map.len()
    }
}

fn load(path: &Path) -> HashMap<String, Entry> {
    let mut map = HashMap::new();
    let Ok(data) = fs::read_to_string(path) else { return map };
    for line in data.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let mut parts = line.splitn(4, '\t');
        let (Some(count), Some(last), Some(prefix), Some(app)) = (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        let (Ok(count), Ok(last)) = (count.parse::<f64>(), last.parse::<u64>()) else { continue };
        if count.is_finite() && count > 0.0 {
            map.insert(key(prefix, app), Entry { count, last });
        }
    }
    map
}

/// One writer thread per store; bursts of updates collapse into one write.
fn spawn_writer(path: PathBuf) -> Sender<String> {
    let (tx, rx) = mpsc::channel::<String>();
    thread::Builder::new()
        .name("cmdtab-learn-writer".into())
        .spawn(move || {
            while let Ok(mut content) = rx.recv() {
                while let Ok(newer) = rx.try_recv() {
                    content = newer;
                }
                let _ = write_atomic(&path, content.as_bytes());
            }
        })
        .expect("spawn learn writer");
    tx
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_data()?;
    }
    fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reinforces_every_prefix() {
        let mut s = LearnStore::ephemeral();
        s.record("slack", "com.tinyspeck.slackmacgap", 1000);
        for q in ["s", "sl", "sla", "slac", "slack"] {
            assert!(s.boost(q, "com.tinyspeck.slackmacgap", 1000) > 0, "{q}");
        }
        assert_eq!(s.boost("x", "com.tinyspeck.slackmacgap", 1000), 0);
        assert_eq!(s.boost("s", "com.apple.Safari", 1000), 0);
    }

    #[test]
    fn boost_grows_then_saturates_and_decays() {
        let mut s = LearnStore::ephemeral();
        s.record("s", "a", 0);
        let one = s.boost("s", "a", 0);
        for _ in 0..50 {
            s.record("s", "a", 0);
        }
        let many = s.boost("s", "a", 0);
        assert!(many > one);
        assert!(many <= MAX_BOOST as i32);
        let later = s.boost("s", "a", (HALF_LIFE_SECS * 10.0) as u64);
        assert!(later < many);
    }

    #[test]
    fn skips_trailing_space_prefixes() {
        let mut s = LearnStore::ephemeral();
        s.record("ab cd", "x", 0);
        assert_eq!(s.len(), 4); // a, ab, ab c, ab cd
    }

    #[test]
    fn round_trips_through_disk() {
        let dir = std::env::temp_dir().join(format!("cmdtab-learn-test-{}", std::process::id()));
        let path = dir.join("learn.tsv");
        let _ = fs::remove_dir_all(&dir);
        let mut s = LearnStore::ephemeral();
        s.record("term", "com.apple.Terminal", 42);
        write_atomic(&path, s.serialize().as_bytes()).unwrap();
        let loaded = LearnStore { map: load(&path), writer: None };
        assert_eq!(loaded.boost("te", "com.apple.Terminal", 42), s.boost("te", "com.apple.Terminal", 42));
        let _ = fs::remove_dir_all(&dir);
    }
}
