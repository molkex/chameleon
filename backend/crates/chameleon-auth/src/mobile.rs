//! Mobile JWT auth extractor — verifies tokens signed with mobile_jwt_secret.

use axum::{extract::FromRequestParts, http::request::Parts};
use serde::Serialize;

use crate::jwt;
use crate::rbac::extract_client_ip;

/// Authenticated mobile user.
#[derive(Debug, Clone, Serialize)]
pub struct MobileUser {
    pub user_id: i32,
    pub username: String,
}

/// Mobile auth state (separate JWT secret from admin).
#[derive(Debug, Clone)]
pub struct MobileAuthState {
    pub jwt_secret: String,
}

/// Auth error for mobile endpoints.
#[derive(Debug)]
pub struct MobileAuthError;

impl axum::response::IntoResponse for MobileAuthError {
    fn into_response(self) -> axum::response::Response {
        use axum::http::StatusCode;
        use axum::Json;
        (StatusCode::UNAUTHORIZED, Json(serde_json::json!({"detail": "Not authenticated"}))).into_response()
    }
}

impl<S> FromRequestParts<S> for MobileUser
where
    S: Send + Sync,
    MobileAuthState: axum::extract::FromRef<S>,
{
    type Rejection = MobileAuthError;

    fn from_request_parts(
        parts: &mut Parts,
        state: &S,
    ) -> impl std::future::Future<Output = Result<Self, Self::Rejection>> + Send {
        async move {
            let auth_state = <MobileAuthState as axum::extract::FromRef<S>>::from_ref(state);

            // Try Bearer token header
            if let Some(auth_header) = parts.headers.get("authorization") {
                if let Ok(value) = auth_header.to_str() {
                    if let Some(token) = value.strip_prefix("Bearer ") {
                        let client_ip = extract_client_ip(parts);
                        if let Some(claims) = jwt::verify_token(&auth_state.jwt_secret, token, "access", client_ip.as_deref()) {
                            let user_id: i32 = match claims.sub.parse() {
                                Ok(id) => id,
                                Err(_) => return Err(MobileAuthError),
                            };
                            return Ok(MobileUser {
                                user_id,
                                username: claims.username,
                            });
                        }
                    }
                }
            }

            Err(MobileAuthError)
        }
    }
}
