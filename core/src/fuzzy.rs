//! Fuzzy matcher. A compact take on fzf's v2 algorithm: a Smith-Waterman
//! style dynamic program with affine gap penalties that rewards matches on
//! word boundaries, camelCase humps and consecutive runs, and reports the
//! positions of the best alignment for highlighting.

use crate::text::{BONUS_BOUNDARY, Haystack, SCORE_MATCH};

const GAP_START: i32 = -3;
const GAP_EXTENSION: i32 = -1;
const BONUS_CONSECUTIVE: i32 = -(GAP_START + GAP_EXTENSION);
const BONUS_FIRST_CHAR_MULTIPLIER: i32 = 2;
const NEG: i32 = i32::MIN / 4;
const NONE: u16 = u16::MAX;

/// Reusable matcher; keeps its scratch buffers between calls so matching a
/// whole window list per keystroke does not allocate.
#[derive(Default)]
pub struct Matcher {
    score: Vec<i32>,
    chunk_bonus: Vec<i16>,
    from: Vec<u16>,
}

impl Matcher {
    pub fn new() -> Self {
        Self::default()
    }

    /// Scores `needle` (already folded) against `hay`. On a match returns the
    /// score and, if `positions` is given, fills it with the matched char
    /// indices in ascending order.
    #[allow(clippy::needless_range_loop)]
    pub fn score(&mut self, needle: &[char], hay: &Haystack, positions: Option<&mut Vec<u32>>) -> Option<i32> {
        let m = needle.len();
        let n = hay.len();
        if m == 0 {
            return Some(0);
        }
        if m > n {
            return None;
        }

        // Cheap rejection plus the window [first, last] the DP must cover:
        // the leftmost greedy match start and the rightmost greedy match end.
        let first = first_match_start(needle, &hay.chars)?;
        let last = last_match_end(needle, &hay.chars)?;
        if last < first {
            return None;
        }

        let width = last - first + 1;
        let cells = m * width;
        if self.score.len() < cells {
            self.score.resize(cells, NEG);
            self.chunk_bonus.resize(cells, 0);
            self.from.resize(cells, NONE);
        }
        let chars = &hay.chars[first..=last];
        let bonus = &hay.bonus[first..=last];

        for i in 0..m {
            let qc = needle[i];
            let row = i * width;
            let prev_row = row.wrapping_sub(width);
            // Best score of any predecessor in row i-1 reachable through a gap
            // of length >= 1, already charged with its gap penalty.
            let mut gap_best = NEG;
            let mut gap_from = NONE;

            for j in 0..width {
                if i > 0 && j >= 2 {
                    let extended = if gap_best > NEG { gap_best + GAP_EXTENSION } else { NEG };
                    let candidate = self.score[prev_row + j - 2];
                    let opened = if candidate > NEG { candidate + GAP_START } else { NEG };
                    if opened >= extended && opened > NEG {
                        gap_best = opened;
                        gap_from = (j - 2) as u16;
                    } else {
                        gap_best = extended;
                    }
                }

                let cell = row + j;
                if chars[j] != qc {
                    self.score[cell] = NEG;
                    continue;
                }
                let b = bonus[j] as i32;

                if i == 0 {
                    self.score[cell] = SCORE_MATCH + b * BONUS_FIRST_CHAR_MULTIPLIER;
                    self.chunk_bonus[cell] = b as i16;
                    self.from[cell] = NONE;
                    continue;
                }

                let mut best = NEG;
                let mut best_from = NONE;
                let mut best_chunk = 0i32;

                if j > 0 {
                    let diag = self.score[prev_row + j - 1];
                    if diag > NEG {
                        let chunk_start = self.chunk_bonus[prev_row + j - 1] as i32;
                        // A strong boundary inside a run starts a new chunk.
                        let (bb, chunk) = if b >= BONUS_BOUNDARY && b > chunk_start {
                            (b, b)
                        } else {
                            (b.max(chunk_start).max(BONUS_CONSECUTIVE), chunk_start)
                        };
                        best = diag + SCORE_MATCH + bb;
                        best_from = (j - 1) as u16;
                        best_chunk = chunk;
                    }
                }
                if gap_best > NEG {
                    let s = gap_best + SCORE_MATCH + b;
                    if s > best {
                        best = s;
                        best_from = gap_from;
                        best_chunk = b;
                    }
                }
                self.score[cell] = best;
                self.chunk_bonus[cell] = best_chunk as i16;
                self.from[cell] = best_from;
            }
        }

        // Pick the best end position in the last row (earliest on ties).
        let last_row = (m - 1) * width;
        let mut best = NEG;
        let mut best_j = NONE;
        for j in 0..width {
            let s = self.score[last_row + j];
            if s > best {
                best = s;
                best_j = j as u16;
            }
        }
        if best <= NEG / 2 || best_j == NONE {
            return None;
        }

        if let Some(out) = positions {
            out.clear();
            out.resize(m, 0);
            let mut j = best_j;
            for i in (0..m).rev() {
                out[i] = (first + j as usize) as u32;
                j = self.from[i * width + j as usize];
                if j == NONE && i > 0 {
                    // Should be unreachable: every non-first row cell has a predecessor.
                    return None;
                }
            }
        }
        Some(best)
    }
}

fn first_match_start(needle: &[char], hay: &[char]) -> Option<usize> {
    let mut qi = 0;
    let mut start = None;
    for (idx, &c) in hay.iter().enumerate() {
        if c == needle[qi] {
            if qi == 0 {
                start = Some(idx);
            }
            qi += 1;
            if qi == needle.len() {
                return start;
            }
        }
    }
    None
}

fn last_match_end(needle: &[char], hay: &[char]) -> Option<usize> {
    let mut qi = needle.len();
    let mut end = None;
    for idx in (0..hay.len()).rev() {
        if hay[idx] == needle[qi - 1] {
            if qi == needle.len() {
                end = Some(idx);
            }
            qi -= 1;
            if qi == 0 {
                return end;
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::tokenize;

    fn score(q: &str, s: &str) -> Option<(i32, Vec<u32>)> {
        let mut m = Matcher::new();
        let mut pos = Vec::new();
        let needle = &tokenize(q)[0];
        m.score(needle, &Haystack::new(s), Some(&mut pos)).map(|sc| (sc, pos))
    }

    #[test]
    fn rejects_non_subsequence() {
        assert!(score("xyz", "Slack").is_none());
        assert!(score("slackk", "Slack").is_none());
    }

    #[test]
    fn prefers_word_starts() {
        let (_, pos) = score("vsc", "Visual Studio Code").unwrap();
        assert_eq!(pos, vec![0, 7, 14]);
        let (_, pos) = score("gh", "Weekly digest - GitHub").unwrap();
        assert_eq!(pos, vec![16, 19]);
    }

    #[test]
    fn prefers_consecutive_runs() {
        let slack = score("sl", "Slack").unwrap().0;
        let sublime = score("sl", "Sublime Text").unwrap().0;
        assert!(slack > sublime, "{slack} vs {sublime}");
    }

    #[test]
    fn exact_word_beats_scattered() {
        let a = score("term", "Terminal").unwrap().0;
        let b = score("term", "The Remote Machine").unwrap().0;
        assert!(a > b, "{a} vs {b}");
    }

    #[test]
    fn camel_case_humps() {
        let (_, pos) = score("gp", "getPath()").unwrap();
        assert_eq!(pos, vec![0, 3]);
    }

    #[test]
    fn matches_diacritics_insensitively() {
        let (_, pos) = score("malmo", "Resa till Malmö").unwrap();
        assert_eq!(pos, vec![10, 11, 12, 13, 14]);
    }

    #[test]
    fn positions_are_increasing_and_match() {
        let hay = "src/main/java/com/example/FooBarService.java";
        for q in ["fbs", "srv", "java", "mjc", "sjava"] {
            let (_, pos) = score(q, hay).unwrap();
            let h = Haystack::new(hay);
            let needle = &tokenize(q)[0];
            assert_eq!(pos.len(), needle.len());
            for w in pos.windows(2) {
                assert!(w[0] < w[1]);
            }
            for (k, &p) in pos.iter().enumerate() {
                assert_eq!(h.chars[p as usize], needle[k]);
            }
        }
    }
}
