//! Role-based access control — axum extractors for admin authentication.
//! Matches Python rbac.py: session + JWT cookie + Bearer header, role hierarchy.

use std::net::IpAddr;

use axum::{
    extract::FromRequestParts,
    http::request::Parts,
};
use serde::Serialize;

use crate::jwt;

/// Role hierarchy: viewer(1) < operator(2) < admin(3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub enum Role {
    Viewer = 1,
    Operator = 2,
    Admin = 3,
}

impl Role {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "admin" => Some(Role::Admin),
            "operator" => Some(Role::Operator),
            "viewer" => Some(Role::Viewer),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Role::Admin => "admin",
            Role::Operator => "operator",
            Role::Viewer => "viewer",
        }
    }
}

/// Authenticated admin user info extracted from request.
#[derive(Debug, Clone, Serialize)]
pub struct AuthAdmin {
    pub user_id: i32,
    pub username: String,
    pub role: Role,
}

/// Error type for auth extraction failures.
#[derive(Debug)]
pub enum AuthError {
    Unauthorized,
    Forbidden(String),
}

impl axum::response::IntoResponse for AuthError {
    fn into_response(self) -> axum::response::Response {
        use axum::http::StatusCode;
        use axum::Json;

        match self {
            AuthError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"detail": "Not authenticated"})),
            ).into_response(),
            AuthError::Forbidden(msg) => (
                StatusCode::FORBIDDEN,
                Json(serde_json::json!({"detail": msg})),
            ).into_response(),
        }
    }
}

/// Extract client IP from request.
/// Priority: X-Real-IP (set by nginx) > X-Forwarded-For > ConnectInfo peer address.
/// NOTE: X-Real-IP/X-Forwarded-For are only trustworthy behind a reverse proxy (nginx).
/// In production, nginx sets X-Real-IP from $remote_addr which cannot be spoofed.
pub fn extract_client_ip(parts: &Parts) -> Option<String> {
    // Trusted proxy headers (set by nginx)
    if let Some(ip) = parts.headers.get("x-real-ip").and_then(|v| v.to_str().ok()) {
        return Some(ip.to_string());
    }
    if let Some(xff) = parts.headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
        if let Some(first) = xff.split(',').next() {
            return Some(first.trim().to_string());
        }
    }
    // Fallback: peer socket address (ConnectInfo)
    parts.extensions.get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
        .map(|ci| ci.0.ip().to_string())
}

/// Extract cookie value from request headers.
fn get_cookie(parts: &Parts, name: &str) -> Option<String> {
    parts.headers
        .get_all("cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|s| s.split(';'))
        .find_map(|cookie| {
            let cookie = cookie.trim();
            if cookie.starts_with(name) && cookie.as_bytes().get(name.len()) == Some(&b'=') {
                Some(cookie[name.len() + 1..].to_string())
            } else {
                None
            }
        })
}

/// Check IP against admin allowlist (if configured).
fn check_ip_allowlist(client_ip: Option<&str>, allowlist: &[String]) -> Result<(), AuthError> {
    if allowlist.is_empty() {
        return Ok(());
    }
    // If allowlist is configured but we can't determine client IP, deny access
    let ip_str = match client_ip {
        Some(ip) => ip,
        None => {
            tracing::warn!("IP allowlist configured but client IP unknown — denying access");
            return Err(AuthError::Forbidden("Cannot determine client IP".into()));
        }
    };
    let ip: IpAddr = match ip_str.parse() {
        Ok(ip) => ip,
        Err(_) => {
            tracing::warn!(ip = %ip_str, "Unparseable client IP — denying access");
            return Err(AuthError::Forbidden("Invalid IP format".into()));
        }
    };

    for allowed in allowlist {
        // Try as network (CIDR)
        if let Ok(network) = allowed.parse::<ipnet::IpNet>() {
            if network.contains(&ip) {
                return Ok(());
            }
        }
        // Try as exact IP
        if allowed == ip_str {
            return Ok(());
        }
    }

    tracing::warn!(ip = %ip_str, "Admin access denied: IP not in allowlist");
    Err(AuthError::Forbidden("IP not allowed".into()))
}

/// Core auth logic: try JWT cookie → Bearer header → return AuthAdmin or error.
pub fn authenticate_request(
    parts: &Parts,
    jwt_secret: &str,
    ip_allowlist: &[String],
) -> Result<AuthAdmin, AuthError> {
    let client_ip = extract_client_ip(parts);

    // Check IP allowlist
    check_ip_allowlist(client_ip.as_deref(), ip_allowlist)?;

    // 1. JWT cookie ("access_token")
    if let Some(token) = get_cookie(parts, "access_token") {
        if let Some(claims) = jwt::verify_token(jwt_secret, &token, "access", client_ip.as_deref()) {
            return Ok(AuthAdmin {
                user_id: claims.sub.parse().map_err(|_| AuthError::Unauthorized)?,
                username: claims.username,
                role: match Role::from_str(&claims.role) { Some(r) => r, None => return Err(AuthError::Unauthorized) },
            });
        }
    }

    // 2. Bearer token header
    if let Some(auth_header) = parts.headers.get("authorization") {
        if let Ok(value) = auth_header.to_str() {
            if let Some(token) = value.strip_prefix("Bearer ") {
                if let Some(claims) = jwt::verify_token(jwt_secret, token, "access", client_ip.as_deref()) {
                    return Ok(AuthAdmin {
                        user_id: claims.sub.parse().map_err(|_| AuthError::Unauthorized)?,
                        username: claims.username,
                        role: match Role::from_str(&claims.role) { Some(r) => r, None => return Err(AuthError::Unauthorized) },
                    });
                }
            }
        }
    }

    Err(AuthError::Unauthorized)
}

// ── Axum Extractors ──

/// Require any authenticated admin (viewer+).
impl<S> FromRequestParts<S> for AuthAdmin
where
    S: Send + Sync,
    crate::AuthState: axum::extract::FromRef<S>,
{
    type Rejection = AuthError;

    fn from_request_parts(
        parts: &mut Parts,
        state: &S,
    ) -> impl std::future::Future<Output = Result<Self, Self::Rejection>> + Send {
        async move {
            let auth_state = <crate::AuthState as axum::extract::FromRef<S>>::from_ref(state);
            authenticate_request(parts, &auth_state.jwt_secret, &auth_state.ip_allowlist)
        }
    }
}

/// Require operator+ role.
pub struct RequireOperator(pub AuthAdmin);

impl<S> FromRequestParts<S> for RequireOperator
where
    S: Send + Sync,
    crate::AuthState: axum::extract::FromRef<S>,
{
    type Rejection = AuthError;

    fn from_request_parts(
        parts: &mut Parts,
        state: &S,
    ) -> impl std::future::Future<Output = Result<Self, Self::Rejection>> + Send {
        async move {
            let auth_state = <crate::AuthState as axum::extract::FromRef<S>>::from_ref(state);
            let admin = authenticate_request(parts, &auth_state.jwt_secret, &auth_state.ip_allowlist)?;
            if admin.role < Role::Operator {
                return Err(AuthError::Forbidden("Operator role required".into()));
            }
            Ok(RequireOperator(admin))
        }
    }
}

/// Require admin role.
pub struct RequireAdmin(pub AuthAdmin);

impl<S> FromRequestParts<S> for RequireAdmin
where
    S: Send + Sync,
    crate::AuthState: axum::extract::FromRef<S>,
{
    type Rejection = AuthError;

    fn from_request_parts(
        parts: &mut Parts,
        state: &S,
    ) -> impl std::future::Future<Output = Result<Self, Self::Rejection>> + Send {
        async move {
            let auth_state = <crate::AuthState as axum::extract::FromRef<S>>::from_ref(state);
            let admin = authenticate_request(parts, &auth_state.jwt_secret, &auth_state.ip_allowlist)?;
            if admin.role != Role::Admin {
                return Err(AuthError::Forbidden("Admin role required".into()));
            }
            Ok(RequireAdmin(admin))
        }
    }
}
