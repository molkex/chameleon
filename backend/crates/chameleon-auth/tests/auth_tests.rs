use chameleon_auth::password;
use chameleon_auth::jwt;

#[test]
fn test_password_migration_sha256_to_argon2() {
    use sha2::{Sha256, Digest};
    let legacy_hash = format!("{:x}", Sha256::digest(b"oldpassword"));
    let (matches, needs_rehash) = password::verify_password_with_rehash("oldpassword", &legacy_hash);
    assert!(matches);
    assert!(needs_rehash);

    let new_hash = password::hash_password("oldpassword").unwrap();
    assert!(new_hash.starts_with("$argon2"));
    let (m2, r2) = password::verify_password_with_rehash("oldpassword", &new_hash);
    assert!(m2);
    assert!(!r2);
}

#[test]
fn test_password_migration_bcrypt_to_argon2() {
    let hash = bcrypt::hash("bcryptpass", 4).unwrap();
    let (matches, needs_rehash) = password::verify_password_with_rehash("bcryptpass", &hash);
    assert!(matches);
    assert!(needs_rehash);
}

#[test]
fn test_jwt_full_lifecycle() {
    let secret = "test_lifecycle_secret_key_123456";
    let access = jwt::create_access_token(secret, 42, "admin_user", "admin", Some("10.0.0.1")).unwrap();
    let claims = jwt::verify_token(secret, &access, "access", Some("10.0.0.1")).unwrap();
    assert_eq!(claims.sub, "42");
    assert_eq!(claims.role, "admin");

    let refresh = jwt::create_refresh_token(secret, 42, "admin_user", "admin", None).unwrap();
    assert!(jwt::verify_token(secret, &refresh, "refresh", None).is_some());
    assert!(jwt::verify_token(secret, &refresh, "access", None).is_none());
}

#[test]
fn test_constant_time_eq_hmac_based() {
    assert!(password::constant_time_eq_str("hello", "hello"));
    assert!(!password::constant_time_eq_str("hello", "world"));
    assert!(!password::constant_time_eq_str("short", "much_longer_string"));
    assert!(password::constant_time_eq_str("", ""));
}
