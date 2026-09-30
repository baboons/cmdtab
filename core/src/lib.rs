//! cmdtab-core: the search engine behind CmdTab's type-to-find switcher.
//!
//! Exposed to Swift through a small C ABI (see `include/cmdtab_core.h`).
//! All functions taking a `CtEngine` must be called from one thread at a time.

// Safety contract for every `ct_*` function: pointers must be NULL or valid
// for the given lengths, and an engine must not be used concurrently.
#![allow(clippy::missing_safety_doc)]

pub mod fuzzy;
pub mod learn;
pub mod rank;
pub mod text;

use std::ffi::{CStr, c_char};
use std::path::Path;
use std::ptr;
use std::slice;

use learn::{LearnStore, now_secs};
use rank::{Index, Item, Range16};
use text::{Haystack, normalize_query};

pub struct CtEngine {
    index: Index,
    learn: LearnStore,
}

#[repr(C)]
pub struct CtItem {
    pub id: u64,
    pub app: *const u8,
    pub app_len: usize,
    pub title: *const u8,
    pub title_len: usize,
    pub key: *const u8,
    pub key_len: usize,
    pub mru: u32,
}

#[repr(C)]
pub struct CtResult {
    pub id: u64,
    pub score: i32,
    pub app_ranges: *const Range16,
    pub app_ranges_len: usize,
    pub title_ranges: *const Range16,
    pub title_ranges_len: usize,
}

unsafe fn str_from<'a>(ptr: *const u8, len: usize) -> std::borrow::Cow<'a, str> {
    if ptr.is_null() || len == 0 {
        return std::borrow::Cow::Borrowed("");
    }
    String::from_utf8_lossy(unsafe { slice::from_raw_parts(ptr, len) })
}

/// Creates an engine. `learn_path` (nullable, UTF-8, NUL-terminated) is where
/// learned selections are persisted; pass NULL to keep them in memory only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_engine_new(learn_path: *const c_char) -> *mut CtEngine {
    let learn = if learn_path.is_null() {
        LearnStore::ephemeral()
    } else {
        match unsafe { CStr::from_ptr(learn_path) }.to_str() {
            Ok(p) if !p.is_empty() => LearnStore::open(Path::new(p)),
            _ => LearnStore::ephemeral(),
        }
    };
    Box::into_raw(Box::new(CtEngine { index: Index::new(), learn }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_engine_free(engine: *mut CtEngine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// Replaces the candidate set. Strings are copied; the caller keeps ownership.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_engine_set_items(engine: *mut CtEngine, items: *const CtItem, count: usize) {
    let Some(engine) = (unsafe { engine.as_mut() }) else { return };
    let src = if items.is_null() || count == 0 { &[][..] } else { unsafe { slice::from_raw_parts(items, count) } };
    let prepared = src
        .iter()
        .map(|it| unsafe {
            Item {
                id: it.id,
                app: Haystack::new(&str_from(it.app, it.app_len)),
                title: Haystack::new(&str_from(it.title, it.title_len)),
                key: str_from(it.key, it.key_len).into_owned(),
                mru: it.mru,
            }
        })
        .collect();
    engine.index.set_items(prepared);
}

/// Runs a query and returns the number of results. Results are sorted best
/// first and stay valid until the next `ct_engine_search`/`ct_engine_set_items`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_engine_search(engine: *mut CtEngine, query: *const u8, query_len: usize) -> usize {
    let Some(engine) = (unsafe { engine.as_mut() }) else { return 0 };
    let q = unsafe { str_from(query, query_len) };
    engine.index.search(&q, &engine.learn, now_secs()).len()
}

/// Reads result `index` of the last search into `out`. Returns false when out of range.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_engine_result(engine: *const CtEngine, index: usize, out: *mut CtResult) -> bool {
    let (Some(engine), false) = (unsafe { engine.as_ref() }, out.is_null()) else { return false };
    let Some(hit) = engine.index.hits().get(index) else { return false };
    let as_ptr = |v: &Vec<Range16>| if v.is_empty() { ptr::null() } else { v.as_ptr() };
    unsafe {
        *out = CtResult {
            id: hit.id,
            score: hit.score,
            app_ranges: as_ptr(&hit.app_hl),
            app_ranges_len: hit.app_hl.len(),
            title_ranges: as_ptr(&hit.title_hl),
            title_ranges_len: hit.title_hl.len(),
        };
    }
    true
}

/// Records that the item with `key` was chosen for `query`, so it ranks
/// higher for that query (and its prefixes) in the future.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_engine_record(
    engine: *mut CtEngine,
    query: *const u8,
    query_len: usize,
    key: *const u8,
    key_len: usize,
) {
    let Some(engine) = (unsafe { engine.as_mut() }) else { return };
    let q = normalize_query(&unsafe { str_from(query, query_len) });
    let k = unsafe { str_from(key, key_len) };
    engine.learn.record(&q, &k, now_secs());
}

/// Forgets all learned selections (in memory and on disk).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_engine_clear_learning(engine: *mut CtEngine) {
    if let Some(engine) = unsafe { engine.as_mut() } {
        engine.learn.clear();
    }
}

/// Library version, NUL-terminated, static.
#[unsafe(no_mangle)]
pub extern "C" fn ct_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_round_trip() {
        unsafe {
            let e = ct_engine_new(ptr::null());
            let strings = [("Slack", "general"), ("Safari", "Slashdot")];
            let items: Vec<CtItem> = strings
                .iter()
                .enumerate()
                .map(|(i, (a, t))| CtItem {
                    id: i as u64 + 10,
                    app: a.as_ptr(),
                    app_len: a.len(),
                    title: t.as_ptr(),
                    title_len: t.len(),
                    key: a.as_ptr(),
                    key_len: a.len(),
                    mru: i as u32 + 1,
                })
                .collect();
            ct_engine_set_items(e, items.as_ptr(), items.len());
            let q = "sla";
            assert_eq!(ct_engine_search(e, q.as_ptr(), q.len()), 2);
            let mut r = std::mem::zeroed::<CtResult>();
            assert!(ct_engine_result(e, 0, &mut r));
            assert_eq!(r.id, 10);
            assert_eq!(r.app_ranges_len, 1);
            assert!(!ct_engine_result(e, 2, &mut r));
            ct_engine_record(e, q.as_ptr(), q.len(), "Safari".as_ptr(), 6);
            ct_engine_free(e);
        }
    }
}
