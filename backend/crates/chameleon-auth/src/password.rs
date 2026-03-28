//! Password hashing (argon2) and verification (argon2 + legacy bcrypt).

use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};

/// Hash a password with argon2id (current standard).
pub fn hash_password(password: &str) -> Result<String, argon2::password_hash::Error> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let hash = argon2.hash_password(password.as_bytes(), &salt)?;
    Ok(hash.to_string())
}

/// Verify password against stored hash.
/// Supports: argon2 ($argon2...), bcrypt ($2b$...), legacy SHA-256 (hex, 64 chars).
/// Returns (matches, needs_rehash) — caller should re-hash with argon2 if needs_rehash=true.
pub fn verify_password_with_rehash(password: &str, stored_hash: &str) -> (bool, bool) {
    let matches = verify_password(password, stored_hash);
    let needs_rehash = matches && !stored_hash.starts_with("$argon2");
    (matches, needs_rehash)
}

/// Verify password. Use `verify_password_with_rehash` to detect legacy hashes.
pub fn verify_password(password: &str, stored_hash: &str) -> bool {
    if stored_hash.starts_with("$argon2") {
        // Argon2 hash
        match PasswordHash::new(stored_hash) {
            Ok(parsed) => Argon2::default()
                .verify_password(password.as_bytes(), &parsed)
                .is_ok(),
            Err(_) => false,
        }
    } else if stored_hash.starts_with("$2") {
        // Bcrypt hash (legacy from Python)
        bcrypt::verify(password, stored_hash).unwrap_or(false)
    } else if stored_hash.len() == 64 && stored_hash.chars().all(|c| c.is_ascii_hexdigit()) {
        // Legacy SHA-256 hex (timing-safe comparison)
        use sha2::{Sha256, Digest};
        let computed = format!("{:x}", Sha256::digest(password.as_bytes()));
        constant_time_eq(computed.as_bytes(), stored_hash.as_bytes())
    } else {
        false
    }
}

/// Constant-time string comparison that does NOT leak length information.
/// Uses HMAC-based comparison: both sides are hashed first to equalize length.
pub fn constant_time_eq_str(a: &str, b: &str) -> bool {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    // Hash both strings with a fixed key to equalize length before comparison
    let key = b"chameleon-ct-eq-key";
    let mut mac_a = Hmac::<Sha256>::new_from_slice(key).expect("HMAC key");
    mac_a.update(a.as_bytes());
    let hash_a = mac_a.finalize().into_bytes();

    let mut mac_b = Hmac::<Sha256>::new_from_slice(key).expect("HMAC key");
    mac_b.update(b.as_bytes());
    let hash_b = mac_b.finalize().into_bytes();

    // Now compare fixed-length hashes — no length leak
    constant_time_eq(&hash_a, &hash_b)
}

/// Constant-time byte comparison (requires equal length inputs).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter()
        .zip(b.iter())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_argon2_roundtrip() {
        let hash = hash_password("test123").unwrap();
        assert!(hash.starts_with("$argon2"));
        assert!(verify_password("test123", &hash));
        assert!(!verify_password("wrong", &hash));
    }

    #[test]
    fn test_bcrypt_verify() {
        // Pre-computed bcrypt hash for "testpass"
        let hash = bcrypt::hash("testpass", 4).unwrap();
        assert!(verify_password("testpass", &hash));
        assert!(!verify_password("wrong", &hash));
    }

    #[test]
    fn test_sha256_legacy_verify() {
        use sha2::{Sha256, Digest};
        let legacy_hash = format!("{:x}", Sha256::digest(b"legacypass"));
        assert!(verify_password("legacypass", &legacy_hash));
        assert!(!verify_password("wrong", &legacy_hash));
    }

    #[test]
    fn test_invalid_hash() {
        assert!(!verify_password("any", "not_a_valid_hash"));
        assert!(!verify_password("any", ""));
    }
}
