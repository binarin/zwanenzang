//! ULIDs: 48 bits of milliseconds followed by 80 random bits, written as 26
//! characters of Crockford base32. The canonical text form is uppercase; it
//! is the only form accepted inside events, because one id is one byte
//! sequence.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Number of random bits below the timestamp.
pub const RANDOM_BITS: u32 = 80;
/// Largest value of the random part.
pub const RANDOM_MAX: u128 = (1u128 << RANDOM_BITS) - 1;
/// Largest value of the timestamp part.
pub const TIME_MAX: u64 = (1u64 << 48) - 1;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Ulid(pub u128);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("invalid ULID {0:?}")]
pub struct UlidError(pub String);

impl Ulid {
    pub fn from_parts(time_ms: u64, random: u128) -> Ulid {
        Ulid(((time_ms as u128) << RANDOM_BITS) | (random & RANDOM_MAX))
    }

    pub fn time_ms(self) -> u64 {
        (self.0 >> RANDOM_BITS) as u64
    }

    pub fn random(self) -> u128 {
        self.0 & RANDOM_MAX
    }

    /// Parses the canonical uppercase form only.
    pub fn parse_canonical(s: &str) -> Result<Ulid, UlidError> {
        let bytes = s.as_bytes();
        if bytes.len() != 26 {
            return Err(UlidError(s.to_string()));
        }
        // The first character carries only 3 bits.
        if bytes[0] > b'7' {
            return Err(UlidError(s.to_string()));
        }
        let mut v: u128 = 0;
        for &b in bytes {
            let d = decode_char(b).ok_or_else(|| UlidError(s.to_string()))?;
            v = (v << 5) | d as u128;
        }
        Ok(Ulid(v))
    }

    pub fn to_canonical(self) -> String {
        let mut out = [0u8; 26];
        let mut v = self.0;
        for slot in out.iter_mut().rev() {
            *slot = ALPHABET[(v & 31) as usize];
            v >>= 5;
        }
        String::from_utf8(out.to_vec()).expect("alphabet is ASCII")
    }
}

/// Decodes one canonical (uppercase) Crockford character.
fn decode_char(b: u8) -> Option<u8> {
    ALPHABET.iter().position(|&a| a == b).map(|p| p as u8)
}

/// True when `s` could be the start of a canonical ULID, ignoring case.
pub fn is_prefix_text(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 26
        && s.bytes()
            .all(|b| decode_char(b.to_ascii_uppercase()).is_some())
}

impl fmt::Display for Ulid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_canonical())
    }
}

impl FromStr for Ulid {
    type Err = UlidError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ulid::parse_canonical(s)
    }
}

impl Serialize for Ulid {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_canonical())
    }
}

impl<'de> Deserialize<'de> for Ulid {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Ulid::parse_canonical(&s).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_order() {
        let a = Ulid::from_parts(1_700_000_000_000, 5);
        let b = Ulid::from_parts(1_700_000_000_000, 6);
        let c = Ulid::from_parts(1_700_000_000_001, 0);
        for u in [a, b, c, Ulid(0), Ulid(u128::MAX)] {
            assert_eq!(Ulid::parse_canonical(&u.to_canonical()).unwrap(), u);
        }
        assert!(a < b && b < c);
        assert!(a.to_canonical() < b.to_canonical());
        assert!(b.to_canonical() < c.to_canonical());
        assert_eq!(Ulid(u128::MAX).to_canonical(), "7ZZZZZZZZZZZZZZZZZZZZZZZZZ");
        assert_eq!(c.time_ms(), 1_700_000_000_001);
        assert_eq!(b.random(), 6);
    }

    #[test]
    fn rejects_non_canonical() {
        assert!(Ulid::parse_canonical("01jc3v7k9qz8m4r2t6w0xnpb5a").is_err());
        assert!(Ulid::parse_canonical("01JC3V7K9QZ8M4R2T6W0XNPB5").is_err());
        assert!(Ulid::parse_canonical("81JC3V7K9QZ8M4R2T6W0XNPB5A").is_err());
        assert!(Ulid::parse_canonical("01JC3V7K9QZ8M4R2T6W0XNPBIA").is_err());
        assert!(Ulid::parse_canonical("01JC3V7K9QZ8M4R2T6W0XNPB5A").is_ok());
    }

    #[test]
    fn prefix_text() {
        assert!(is_prefix_text("01jc"));
        assert!(!is_prefix_text("01-c"));
        assert!(!is_prefix_text(""));
    }
}
