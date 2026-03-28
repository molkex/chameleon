//! Authentication and authorization — JWT, password hashing, RBAC extractors.

pub mod jwt;
pub mod mobile;
pub mod password;
pub mod rbac;

pub use rbac::{AuthAdmin, AuthError, RequireAdmin, RequireOperator, Role};
pub use mobile::{MobileUser, MobileAuthState, MobileAuthError};

/// Shared auth configuration extracted from AppState.
/// Must be implemented as `FromRef<AppState>` in the API crate.
#[derive(Debug, Clone)]
pub struct AuthState {
    pub jwt_secret: String,
    pub ip_allowlist: Vec<String>,
}
