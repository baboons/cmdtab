//! cargo run --release --example bench
use cmdtab_core::learn::LearnStore;
use cmdtab_core::rank::{Index, Item};
use cmdtab_core::text::Haystack;
use std::time::Instant;

fn main() {
    let apps = ["Safari", "Google Chrome", "Slack", "Mail", "Visual Studio Code", "Ghostty", "Finder", "Notes"];
    for n in [50usize, 200, 1000] {
        let mut idx = Index::new();
        idx.set_items(
            (0..n)
                .map(|i| Item {
                    id: i as u64,
                    app: Haystack::new(apps[i % apps.len()]),
                    title: Haystack::new(&format!("Document {i} — some project/folder/file_{i}.txt · Pull request #{i}")),
                    key: apps[i % apps.len()].to_string(),
                    mru: i as u32,
                })
                .collect(),
        );
        let learn = LearnStore::ephemeral();
        let queries = ["d", "do", "doc", "docu", "proj fil", "vsc", "pull 12", "zzz"];
        let rounds = 200;
        let start = Instant::now();
        for _ in 0..rounds {
            for q in queries {
                std::hint::black_box(idx.search(q, &learn, 0).len());
            }
        }
        let per = start.elapsed() / (rounds * queries.len()) as u32;
        println!("{n:>5} windows: {per:?} per keystroke");
    }
}
