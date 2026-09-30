//! Text preparation: case/diacritic folding, character classes and the
//! pre-computed "haystack" representation the matcher runs against.

/// Rough character classes used to find word boundaries.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Class {
    White,
    Delim,
    NonWord,
    Lower,
    Upper,
    Letter,
    Digit,
}

impl Class {
    #[inline]
    fn is_word(self) -> bool {
        matches!(self, Class::Lower | Class::Upper | Class::Letter | Class::Digit)
    }
}

pub const SCORE_MATCH: i32 = 16;
pub const BONUS_BOUNDARY: i32 = SCORE_MATCH / 2;
pub const BONUS_BOUNDARY_WHITE: i32 = BONUS_BOUNDARY + 2;
pub const BONUS_BOUNDARY_DELIM: i32 = BONUS_BOUNDARY + 1;
pub const BONUS_CAMEL: i32 = BONUS_BOUNDARY - 1;
pub const BONUS_NON_WORD: i32 = BONUS_BOUNDARY / 2;

/// Base letters for U+00C0..=U+017F (Latin-1 Supplement + Latin Extended-A).
/// `_` means "no ASCII base letter".
const LATIN_BASE: &[u8; 192] = b"\
aaaaaaaceeeeiiiidnooooo_ouuuuyts\
aaaaaaaceeeeiiiidnooooo_ouuuuyty\
aaaaaaccccccccdd\
ddeeeeeeeeeegggg\
gggghhhhiiiiiiii\
iiiijjkkklllllll\
lllnnnnnnnnnoooo\
oooorrrrrrssssss\
sstttttt\
uuuuuuuuuuuuwwyy\
yzzzzzzs";

#[inline]
fn is_combining_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

/// Lowercases and strips diacritics so that `é`, `É` and `e` all compare equal.
#[inline]
pub fn fold(c: char) -> char {
    if c.is_ascii() {
        return c.to_ascii_lowercase();
    }
    let cp = c as u32;
    if (0xC0..=0x17F).contains(&cp) {
        let b = LATIN_BASE[(cp - 0xC0) as usize];
        if b != b'_' {
            return b as char;
        }
    }
    c.to_lowercase().next().unwrap_or(c)
}

#[inline]
pub fn class_of(c: char) -> Class {
    if c.is_ascii() {
        return match c {
            'a'..='z' => Class::Lower,
            'A'..='Z' => Class::Upper,
            '0'..='9' => Class::Digit,
            ' ' | '\t' | '\n' | '\r' => Class::White,
            '/' | '\\' | ',' | ':' | ';' | '|' | '-' | '_' | '.' => Class::Delim,
            _ => Class::NonWord,
        };
    }
    if c.is_whitespace() {
        Class::White
    } else if c.is_lowercase() {
        Class::Lower
    } else if c.is_uppercase() {
        Class::Upper
    } else if c.is_alphabetic() {
        Class::Letter
    } else if c.is_numeric() {
        Class::Digit
    } else if matches!(c, '—' | '–' | '·' | '•' | '›' | '»' | '‹' | '«') {
        Class::Delim
    } else {
        Class::NonWord
    }
}

#[inline]
fn bonus_for(prev: Class, cur: Class) -> i32 {
    if cur.is_word() {
        return match prev {
            Class::White => BONUS_BOUNDARY_WHITE,
            Class::Delim => BONUS_BOUNDARY_DELIM,
            Class::NonWord => BONUS_BOUNDARY,
            Class::Lower if cur == Class::Upper => BONUS_CAMEL,
            p if cur == Class::Digit && p != Class::Digit => BONUS_CAMEL,
            _ => 0,
        };
    }
    match cur {
        Class::White => 0,
        _ => BONUS_NON_WORD,
    }
}

/// Maximum number of characters considered per string. Longer window titles
/// are truncated for matching (highlighting still maps to the original).
pub const MAX_CHARS: usize = 512;

/// A string prepared for matching: folded characters plus, for each of them,
/// the positional bonus and where it lives in the original UTF-16 string.
#[derive(Default, Clone, Debug)]
pub struct Haystack {
    pub chars: Vec<char>,
    pub bonus: Vec<i16>,
    /// UTF-16 offset of each folded char in the original string.
    pub u16_start: Vec<u32>,
    /// UTF-16 length of the original char, including trailing combining marks.
    pub u16_len: Vec<u16>,
}

impl Haystack {
    pub fn new(s: &str) -> Self {
        let cap = s.len().min(MAX_CHARS);
        let mut h = Haystack {
            chars: Vec::with_capacity(cap),
            bonus: Vec::with_capacity(cap),
            u16_start: Vec::with_capacity(cap),
            u16_len: Vec::with_capacity(cap),
        };
        let mut prev = Class::White;
        let mut offset: u32 = 0;
        for c in s.chars() {
            let len16 = c.len_utf16() as u32;
            if is_combining_mark(c) {
                // Decomposed (NFD) text, common in file names: fold the mark
                // into the preceding character so highlights cover both.
                if let Some(last) = h.u16_len.last_mut() {
                    *last += len16 as u16;
                }
                offset += len16;
                continue;
            }
            if h.chars.len() == MAX_CHARS {
                break;
            }
            let class = class_of(c);
            h.chars.push(fold(c));
            h.bonus.push(bonus_for(prev, class) as i16);
            h.u16_start.push(offset);
            h.u16_len.push(len16 as u16);
            prev = class;
            offset += len16;
        }
        h
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.chars.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }

    /// True if the folded string starts with `needle`.
    pub fn starts_with(&self, needle: &[char]) -> bool {
        self.chars.len() >= needle.len() && self.chars[..needle.len()] == *needle
    }
}

/// Folds a query and splits it into whitespace separated tokens.
pub fn tokenize(query: &str) -> Vec<Vec<char>> {
    let mut tokens = Vec::new();
    let mut cur = Vec::new();
    for c in query.chars() {
        if is_combining_mark(c) {
            continue;
        }
        if c.is_whitespace() {
            if !cur.is_empty() {
                tokens.push(std::mem::take(&mut cur));
            }
        } else if cur.len() < 64 {
            cur.push(fold(c));
        }
    }
    if !cur.is_empty() {
        tokens.push(cur);
    }
    tokens
}

/// The canonical form of a query used as a key for learned selections.
pub fn normalize_query(query: &str) -> String {
    tokenize(query)
        .iter()
        .map(|t| t.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds_diacritics_and_case() {
        let s: String = "ÅÄÖ éèê Łódź ß".chars().map(fold).collect();
        assert_eq!(s, "aao eee lodz s");
    }

    #[test]
    fn nfd_marks_merge_into_previous_char() {
        // "e" + COMBINING ACUTE ACCENT, then "x"
        let h = Haystack::new("e\u{301}x");
        assert_eq!(h.chars, vec!['e', 'x']);
        assert_eq!(h.u16_start, vec![0, 2]);
        assert_eq!(h.u16_len, vec![2, 1]);
    }

    #[test]
    fn utf16_offsets_account_for_astral_chars() {
        let h = Haystack::new("😀 ab");
        assert_eq!(h.u16_start, vec![0, 2, 3, 4]);
        assert_eq!(h.u16_len[0], 2);
    }

    #[test]
    fn boundaries() {
        let h = Haystack::new("fooBar baz-qux");
        assert_eq!(h.bonus[0] as i32, BONUS_BOUNDARY_WHITE);
        assert_eq!(h.bonus[3] as i32, BONUS_CAMEL);
        assert_eq!(h.bonus[7] as i32, BONUS_BOUNDARY_WHITE);
        assert_eq!(h.bonus[11] as i32, BONUS_BOUNDARY_DELIM);
        assert_eq!(h.bonus[1], 0);
    }

    #[test]
    fn tokenizes() {
        assert_eq!(normalize_query("  Chrome   GitHub "), "chrome github");
        assert!(tokenize("   ").is_empty());
    }
}
