//! Format rules for the small strings that appear in events and
//! configuration.

/// Tags are org-compatible: one or more of `A-Z a-z 0-9 _ @ # %`, at most 64
/// characters.
pub fn valid_tag(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'@' | b'#' | b'%'))
}

/// Titles are non-empty after trimming, a single line, at most 512 bytes.
pub fn valid_title(s: &str) -> bool {
    !s.trim().is_empty() && s.len() <= 512 && !s.contains(['\n', '\r'])
}

/// Vocabulary entries (statuses, kinds), document names and repository
/// aliases: one or more of `A-Z a-z 0-9 _ -`, at most 64 characters.
pub fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}

/// Actor display names: non-empty after trimming, a single line, at most 128
/// bytes.
pub fn valid_actor_name(s: &str) -> bool {
    !s.trim().is_empty() && s.len() <= 128 && !s.contains(['\n', '\r'])
}

/// Number prefixes: an uppercase ASCII letter followed by up to nine
/// uppercase letters or digits.
pub fn valid_prefix(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 10
        && b[0].is_ascii_uppercase()
        && b.iter()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

/// Blob names are lowercase hex SHA-256 digests.
pub fn valid_blob_name(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags() {
        assert!(valid_tag("needs_review"));
        assert!(valid_tag("@home#1%"));
        assert!(!valid_tag("has-dash"));
        assert!(!valid_tag("with space"));
        assert!(!valid_tag(""));
        assert!(!valid_tag(&"a".repeat(65)));
    }

    #[test]
    fn titles() {
        assert!(valid_title("Fix it"));
        assert!(!valid_title("   "));
        assert!(!valid_title("two\nlines"));
        assert!(!valid_title(&"x".repeat(513)));
    }

    #[test]
    fn prefixes() {
        assert!(valid_prefix("ZZ"));
        assert!(valid_prefix("AIWF2"));
        assert!(!valid_prefix("zz"));
        assert!(!valid_prefix("2Z"));
        assert!(!valid_prefix(""));
    }
}
