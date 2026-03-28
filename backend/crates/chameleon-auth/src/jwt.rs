//! JWT token creation and verification.
//! Matches Python rbac.py: HS256, access (15min) + refresh (7d), IP binding.

use chrono::Utc;
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};

/// JWT access token TTL in seconds (15 minutes).
pub const ACCESS_TTL: i64 = 900;
/// JWT refresh token TTL in seconds (7 days).
pub const REFRESH_TTL: i64 = 7 * 86400;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Claims {
    /// User ID (as string, matching Python's `sub`)
    pub sub: String,
    pub username: String,
    pub role: String,
    /// Token type: "access" or "refresh"
    #[serde(rename = "type")]
    pub token_type: String,
    /// Optional IP binding
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ip: Option<String>,
    pub iat: i64,
    pub exp: i64,
}

/// Create a JWT access token.
pub fn create_access_token(
    secret: &str,
    user_id: i32,
    username: &str,
    role: &str,
    ip: Option<&str>,
) -> Result<String, jsonwebtoken::errors::Error> {
    let now = Utc::now().timestamp();
    let claims = Claims {
        sub: user_id.to_string(),
        username: username.to_string(),
        role: role.to_string(),
        token_type: "access".to_string(),
        ip: ip.map(String::from),
        iat: now,
        exp: now + ACCESS_TTL,
    };
    encode(&Header::default(), &claims, &EncodingKey::from_secret(secret.as_bytes()))
}

/// Create a JWT refresh token.
pub fn create_refresh_token(
    secret: &str,
    user_id: i32,
    username: &str,
    role: &str,
    ip: Option<&str>,
) -> Result<String, jsonwebtoken::errors::Error> {
    let now = Utc::now().timestamp();
    let claims = Claims {
        sub: user_id.to_string(),
        username: username.to_string(),
        role: role.to_string(),
        token_type: "refresh".to_string(),
        ip: ip.map(String::from),
        iat: now,
        exp: now + REFRESH_TTL,
    };
    encode(&Header::default(), &claims, &EncodingKey::from_secret(secret.as_bytes()))
}

/// Verify and decode a JWT token. Returns None if invalid/expired.
/// Checks token_type and optional IP binding.
pub fn verify_token(
    secret: &str,
    token: &str,
    expected_type: &str,
    client_ip: Option<&str>,
) -> Option<Claims> {
    let mut validation = Validation::default();
    validation.validate_exp = true;

    let data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )
    .ok()?;

    let claims = data.claims;

    // Check token type
    if claims.token_type != expected_type {
        return None;
    }

    // IP binding check (only if both token and client have IP)
    if let (Some(token_ip), Some(req_ip)) = (&claims.ip, client_ip) {
        if token_ip != req_ip {
            tracing::warn!(
                token_ip = %token_ip,
                client_ip = %req_ip,
                "JWT IP mismatch"
            );
            return None;
        }
    }

    Some(claims)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "test_secret_key_for_jwt";

    #[test]
    fn test_access_token_roundtrip() {
        let token = create_access_token(SECRET, 1, "admin", "admin", Some("1.2.3.4")).unwrap();
        let claims = verify_token(SECRET, &token, "access", Some("1.2.3.4")).unwrap();
        assert_eq!(claims.sub, "1");
        assert_eq!(claims.username, "admin");
        assert_eq!(claims.role, "admin");
    }

    #[test]
    fn test_wrong_type_rejected() {
        let token = create_access_token(SECRET, 1, "admin", "admin", None).unwrap();
        assert!(verify_token(SECRET, &token, "refresh", None).is_none());
    }

    #[test]
    fn test_ip_mismatch_rejected() {
        let token = create_access_token(SECRET, 1, "admin", "admin", Some("1.2.3.4")).unwrap();
        assert!(verify_token(SECRET, &token, "access", Some("5.6.7.8")).is_none());
    }

    #[test]
    fn test_wrong_secret_rejected() {
        let token = create_access_token(SECRET, 1, "admin", "admin", None).unwrap();
        assert!(verify_token("wrong_secret", &token, "access", None).is_none());
    }

    #[test]
    fn test_refresh_token() {
        let token = create_refresh_token(SECRET, 42, "user", "viewer", None).unwrap();
        let claims = verify_token(SECRET, &token, "refresh", None).unwrap();
        assert_eq!(claims.sub, "42");
        assert_eq!(claims.role, "viewer");
    }
}
