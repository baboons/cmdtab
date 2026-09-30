//! Ranks windows for a query: every query token must match either the app
//! name or the window title; scores are combined with recency (MRU) and what
//! the learning store remembers about past selections.

use crate::fuzzy::Matcher;
use crate::learn::LearnStore;
use crate::text::{Haystack, normalize_query, tokenize};

/// Extra points when a token matches the app name rather than the title:
/// people mostly type app names.
const APP_FIELD_BONUS: i32 = 6;
/// Extra points when the app name starts with the token.
const APP_PREFIX_BONUS: i32 = 10;

pub struct Item {
    pub id: u64,
    pub app: Haystack,
    pub title: Haystack,
    pub key: String,
    /// 0 = most recently used.
    pub mru: u32,
}

/// A UTF-16 range in the original string, ready for NSRange.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Range16 {
    pub start: u32,
    pub len: u32,
}

#[derive(Debug, Clone)]
pub struct Hit {
    pub index: usize,
    pub id: u64,
    pub score: i32,
    pub app_hl: Vec<Range16>,
    pub title_hl: Vec<Range16>,
}

#[derive(Default)]
pub struct Index {
    items: Vec<Item>,
    matcher: Matcher,
    hits: Vec<Hit>,
    app_tmp: Vec<u32>,
    title_tmp: Vec<u32>,
    app_pos: Vec<u32>,
    title_pos: Vec<u32>,
}

/// Recency bonus. The current window (rank 0) is treated like rank 3: if
/// you are searching you most likely want to go somewhere else, but it
/// should still beat windows you haven't touched in ages.
fn mru_boost(rank: u32) -> i32 {
    match rank {
        0 => 6,
        r => (24 / (r + 1)) as i32,
    }
}

impl Index {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_items(&mut self, items: Vec<Item>) {
        self.items = items;
        self.hits.clear();
    }

    pub fn items(&self) -> &[Item] {
        &self.items
    }

    pub fn hits(&self) -> &[Hit] {
        &self.hits
    }

    pub fn search(&mut self, query: &str, learn: &LearnStore, now: u64) -> &[Hit] {
        self.hits.clear();
        let tokens = tokenize(query);

        if tokens.is_empty() {
            for (index, it) in self.items.iter().enumerate() {
                self.hits.push(Hit { index, id: it.id, score: 0, app_hl: Vec::new(), title_hl: Vec::new() });
            }
            self.hits.sort_by_key(|h| self.items[h.index].mru);
            return &self.hits;
        }

        let normalized = normalize_query(query);
        'items: for (index, it) in self.items.iter().enumerate() {
            let mut total = 0;
            self.app_pos.clear();
            self.title_pos.clear();
            for tok in &tokens {
                let app = self.matcher.score(tok, &it.app, Some(&mut self.app_tmp)).map(|s| {
                    s + APP_FIELD_BONUS + if it.app.starts_with(tok) { APP_PREFIX_BONUS } else { 0 }
                });
                let title = self.matcher.score(tok, &it.title, Some(&mut self.title_tmp));
                match (app, title) {
                    (None, None) => continue 'items,
                    (Some(a), t) if t.is_none_or(|t| a >= t) => {
                        total += a;
                        self.app_pos.extend_from_slice(&self.app_tmp);
                    }
                    (_, Some(t)) => {
                        total += t;
                        self.title_pos.extend_from_slice(&self.title_tmp);
                    }
                    (Some(_), None) => unreachable!(),
                }
            }
            total += mru_boost(it.mru) + learn.boost(&normalized, &it.key, now);
            self.hits.push(Hit {
                index,
                id: it.id,
                score: total,
                app_hl: ranges(&it.app, &mut self.app_pos),
                title_hl: ranges(&it.title, &mut self.title_pos),
            });
        }

        let items = &self.items;
        self.hits.sort_by(|a, b| b.score.cmp(&a.score).then(items[a.index].mru.cmp(&items[b.index].mru)));
        &self.hits
    }
}

/// Converts matched char indices into merged UTF-16 ranges.
fn ranges(h: &Haystack, pos: &mut Vec<u32>) -> Vec<Range16> {
    if pos.is_empty() {
        return Vec::new();
    }
    pos.sort_unstable();
    pos.dedup();
    let mut out: Vec<Range16> = Vec::with_capacity(pos.len());
    for &p in pos.iter() {
        let p = p as usize;
        let start = h.u16_start[p];
        let len = h.u16_len[p] as u32;
        match out.last_mut() {
            Some(r) if r.start + r.len == start => r.len += len,
            _ => out.push(Range16 { start, len }),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: u64, app: &str, title: &str, mru: u32) -> Item {
        Item { id, app: Haystack::new(app), title: Haystack::new(title), key: app.to_lowercase(), mru }
    }

    fn fixture() -> Index {
        let mut idx = Index::new();
        idx.set_items(vec![
            item(1, "Ghostty", "~/Projects/cmdtab", 0),
            item(2, "Safari", "Pull request #42 · cmdtab - GitHub", 1),
            item(3, "Slack", "general - Baboons", 2),
            item(4, "Sublime Text", "notes.md", 3),
            item(5, "Safari", "Hacker News", 4),
            item(6, "Visual Studio Code", "lib.rs — cmdtab", 5),
        ]);
        idx
    }

    fn ids(hits: &[Hit]) -> Vec<u64> {
        hits.iter().map(|h| h.id).collect()
    }

    #[test]
    fn empty_query_is_mru_order() {
        let mut idx = fixture();
        let learn = LearnStore::ephemeral();
        assert_eq!(ids(idx.search("", &learn, 0)), vec![1, 2, 3, 4, 5, 6]);
    }

    #[test]
    fn app_names_win() {
        let mut idx = fixture();
        let learn = LearnStore::ephemeral();
        assert_eq!(idx.search("sl", &learn, 0)[0].id, 3);
        assert_eq!(idx.search("vsc", &learn, 0)[0].id, 6);
        assert_eq!(idx.search("code", &learn, 0)[0].id, 6);
    }

    #[test]
    fn tokens_span_app_and_title() {
        let mut idx = fixture();
        let learn = LearnStore::ephemeral();
        let hits = idx.search("saf hack", &learn, 0);
        assert_eq!(hits[0].id, 5);
        assert_eq!(hits[0].app_hl, vec![Range16 { start: 0, len: 3 }]);
        assert_eq!(hits[0].title_hl, vec![Range16 { start: 0, len: 4 }]);
        // every token must match somewhere
        assert!(idx.search("saf zzz", &learn, 0).is_empty());
    }

    #[test]
    fn title_search_finds_windows() {
        let mut idx = fixture();
        let learn = LearnStore::ephemeral();
        let hits = idx.search("pull req", &learn, 0);
        assert_eq!(hits[0].id, 2);
        assert_eq!(hits[0].title_hl, vec![Range16 { start: 0, len: 4 }, Range16 { start: 5, len: 3 }]);
    }

    #[test]
    fn learning_reorders_close_matches() {
        let mut idx = fixture();
        let mut learn = LearnStore::ephemeral();
        // "s" alone: Safari (mru 1) beats Sublime Text (mru 3)
        let before = ids(idx.search("s", &learn, 0));
        assert!(before.iter().position(|&i| i == 2) < before.iter().position(|&i| i == 4));
        for _ in 0..3 {
            learn.record("s", "sublime text", 0);
        }
        assert_eq!(idx.search("s", &learn, 0)[0].id, 4);
    }

    #[test]
    fn current_window_is_not_preferred_on_ties() {
        let mut idx = Index::new();
        idx.set_items(vec![item(1, "Safari", "A", 0), item(2, "Safari", "B", 1)]);
        let learn = LearnStore::ephemeral();
        assert_eq!(idx.search("safari", &learn, 0)[0].id, 2);
    }

    #[test]
    fn current_window_still_beats_stale_ones() {
        let mut idx = Index::new();
        idx.set_items(vec![item(1, "Safari", "A", 0), item(2, "Slack", "B", 1), item(3, "System Settings", "C", 7)]);
        let learn = LearnStore::ephemeral();
        assert_eq!(ids(idx.search("s", &learn, 0)), vec![2, 1, 3]);
    }

    #[test]
    fn is_fast() {
        let mut idx = Index::new();
        let apps = ["Safari", "Google Chrome", "Slack", "Mail", "Visual Studio Code", "Ghostty", "Finder", "Notes"];
        let items = (0..400)
            .map(|i| item(i, apps[i as usize % apps.len()], &format!("Document number {i} — some project/folder/file_{i}.txt"), i as u32))
            .collect();
        idx.set_items(items);
        let learn = LearnStore::ephemeral();
        let start = std::time::Instant::now();
        let queries = ["d", "do", "doc", "docu", "docum", "proj fil", "sc", "vsc 12"];
        for q in queries {
            idx.search(q, &learn, 0);
        }
        let per_query = start.elapsed() / queries.len() as u32;
        // Generous bound for debug builds; release is ~20x faster.
        assert!(per_query.as_millis() < 50, "{per_query:?} per query");
    }
}
