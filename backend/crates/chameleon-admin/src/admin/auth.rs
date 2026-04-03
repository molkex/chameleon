//! Admin JWT auth endpoints.
//! POST /login, POST /refresh, POST /logout, GET /me

use axum::{
    extract::State,
    http::HeaderMap,
    routing::{get, post},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, SameSite};
use axum_extra::extract::CookieJar;
use serde::{Deserialize, Serialize};

use chameleon_auth::{jwt, password, AuthAdmin};
use chameleon_db::queries::admin as admin_q;

use chameleon_core::error::{ApiError, ApiResult};
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/login", post(login))
        .route("/refresh", post(refresh))
        .route("/logout", post(logout))
        .route("/me", get(me))
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct LoginResponse {
    ok: bool,
    expires_in: i64,
    user: UserInfo,
}

#[derive(Serialize)]
struct UserInfo {
    id: i32,
    username: String,
    role: String,
}

fn extract_ip(headers: &HeaderMap) -> String {
    chameleon_core::http_utils::extract_client_ip(headers)
}

async fn login(
    State(state): State<ChameleonCore>,
    headers: HeaderMap,
    jar: CookieJar,
    Json(body): Json<LoginRequest>,
) -> ApiResult<(CookieJar, Json<LoginResponse>)> {
    // Input validation: prevent DoS via oversized argon2 input
    if body.username.len() > 64 {
        return Err(ApiError::BadRequest("username too long".into()));
    }
    if body.password.len() > 128 {
        return Err(ApiError::BadRequest("password too long".into()));
    }

    let client_ip = extract_ip(&headers);
    let admin = match authenticate(&state, &body.username, &body.password).await {
        Ok(a) => a,
        Err(e) => {
            let _ = admin_q::write_audit_log(
                &state.db, None, "login_failed", &client_ip, None,
                Some(&format!("user={}", body.username)),
            ).await;
            tracing::warn!(user = %body.username, ip = %client_ip, "Failed admin login attempt");
            return Err(e);
        }
    };
    let (user_id, username, role) = admin;

    let secret = &state.config.admin_jwt_secret;
    let ip_ref = Some(client_ip.as_str());
    let access = jwt::create_access_token(secret, user_id, &username, &role, ip_ref)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("JWT error: {e}")))?;
    let refresh_tok = jwt::create_refresh_token(secret, user_id, &username, &role, ip_ref)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("JWT error: {e}")))?;

    let jar = jar
        .add(access_cookie(&access))
        .add(refresh_cookie(&refresh_tok));

    let _ = admin_q::update_last_login(&state.db, user_id).await;
    let _ = admin_q::write_audit_log(
        &state.db, Some(user_id), "jwt_login", &extract_ip(&headers), None,
        Some(&format!("user={username} role={role}")),
    ).await;

    tracing::info!(user = %username, role = %role, "Admin login");

    Ok((jar, Json(LoginResponse {
        ok: true,
        expires_in: jwt::ACCESS_TTL,
        user: UserInfo { id: user_id, username, role },
    })))
}

async fn refresh(
    State(state): State<ChameleonCore>,
    headers: HeaderMap,
    jar: CookieJar,
) -> ApiResult<(CookieJar, Json<LoginResponse>)> {
    use fred::prelude::*;
    use sha2::{Sha256, Digest};

    let refresh_token = jar.get("refresh_token")
        .map(|c| c.value().to_string())
        .ok_or(ApiError::Unauthorized)?;

    let secret = &state.config.admin_jwt_secret;
    let claims = jwt::verify_token(secret, &refresh_token, "refresh", None)
        .ok_or(ApiError::Unauthorized)?;

    // F-03: One-time-use refresh tokens via Redis blacklist
    let token_hash = format!("{:x}", Sha256::digest(refresh_token.as_bytes()));
    let blacklist_key = format!("refresh_used:{token_hash}");

    // Atomic one-time-use: SET NX (set-if-not-exists) + EX (expire).
    // Returns true if key was SET (first use), false if already existed (replay).
    // Single Redis command = no TOCTOU race condition.
    let was_set: bool = match state.redis.set::<bool, _, _>(
        &blacklist_key, "1",
        Some(Expiration::EX(jwt::REFRESH_TTL)),
        Some(SetOptions::NX),  // Only set if not exists
        false,
    ).await {
        Ok(set) => set,
        Err(e) => {
            tracing::error!(error = %e, "Redis unavailable for token blacklist — failing closed");
            return Err(ApiError::Internal(anyhow::anyhow!("Token verification unavailable")));
        }
    };

    if !was_set {
        tracing::warn!(user = %claims.username, "Refresh token replay detected — rejecting");
        return Err(ApiError::Unauthorized);
    }

    let user_id: i32 = claims.sub.parse()
        .map_err(|_| ApiError::Unauthorized)?;

    let client_ip = extract_ip(&headers);
    let ip_ref = Some(client_ip.as_str());
    let access = jwt::create_access_token(secret, user_id, &claims.username, &claims.role, ip_ref)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("JWT error: {e}")))?;
    let new_refresh = jwt::create_refresh_token(secret, user_id, &claims.username, &claims.role, ip_ref)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("JWT error: {e}")))?;

    let jar = jar
        .add(access_cookie(&access))
        .add(refresh_cookie(&new_refresh));

    Ok((jar, Json(LoginResponse {
        ok: true,
        expires_in: jwt::ACCESS_TTL,
        user: UserInfo {
            id: user_id,
            username: claims.username,
            role: claims.role,
        },
    })))
}

async fn logout(jar: CookieJar) -> (CookieJar, Json<serde_json::Value>) {
    let jar = jar
        .remove(Cookie::build("access_token").path("/"))
        .remove(Cookie::build("refresh_token").path("/api/v1/admin/auth"));
    (jar, Json(serde_json::json!({"ok": true})))
}

async fn me(admin: AuthAdmin) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "id": admin.user_id,
        "username": admin.username,
        "role": admin.role.as_str(),
    }))
}

// ── Helpers ──

async fn authenticate(
    state: &ChameleonCore,
    username: &str,
    pwd: &str,
) -> ApiResult<(i32, String, String)> {
    // Try DB first
    if let Ok(Some(admin_user)) = admin_q::find_admin_by_username(&state.db, username).await {
        if !admin_user.is_active {
            return Err(ApiError::Unauthorized);
        }
        let (matches, needs_rehash) = password::verify_password_with_rehash(pwd, &admin_user.password_hash);
        if matches {
            // F-06: Auto-rehash legacy bcrypt/SHA-256 → argon2
            if needs_rehash {
                if let Ok(new_hash) = password::hash_password(pwd) {
                    let _ = sqlx::query("UPDATE admin_users SET password_hash = $1 WHERE id = $2")
                        .bind(&new_hash).bind(admin_user.id)
                        .execute(&state.db).await;
                    tracing::info!(user = %admin_user.username, "Password auto-rehashed to argon2");
                }
            }
            return Ok((admin_user.id, admin_user.username, admin_user.role));
        }
        return Err(ApiError::Unauthorized);
    }

    // If DB has admins, don't fall back
    if admin_q::count_admins(&state.db).await.unwrap_or(0) > 0 {
        return Err(ApiError::Unauthorized);
    }

    // Env fallback (first-run bootstrap only, constant-time comparison)
    let user_match = chameleon_auth::password::constant_time_eq_str(username, &state.config.admin_username);
    let pass_match = chameleon_auth::password::constant_time_eq_str(pwd, &state.config.admin_password);
    if user_match && pass_match {
        tracing::warn!("Admin login via env fallback — create a DB admin user to disable this");
        return Ok((0, username.to_string(), "admin".to_string()));
    }

    Err(ApiError::Unauthorized)
}

fn is_https() -> bool {
    // Secure by default — cookies get Secure flag unless explicitly disabled.
    // Set FORCE_HTTPS=0 only for local development without TLS.
    match std::env::var("FORCE_HTTPS").ok().as_deref() {
        Some("0") => false,
        Some("1") => true,
        Some(other) => {
            tracing::warn!(value = %other, "FORCE_HTTPS has unexpected value, defaulting to secure=true");
            true
        }
        None => {
            tracing::warn!("FORCE_HTTPS env var not set, defaulting to secure=true; set FORCE_HTTPS=0 for local dev");
            true
        }
    }
}

fn access_cookie(token: &str) -> Cookie<'static> {
    Cookie::build(("access_token", token.to_string()))
        .path("/")
        .http_only(true)
        .secure(is_https())
        .same_site(SameSite::Lax)
        .max_age(time::Duration::seconds(jwt::ACCESS_TTL))
        .build()
}

fn refresh_cookie(token: &str) -> Cookie<'static> {
    Cookie::build(("refresh_token", token.to_string()))
        .path("/api/v1/admin/auth")
        .http_only(true)
        .secure(is_https())
        .same_site(SameSite::Lax)
        .max_age(time::Duration::seconds(jwt::REFRESH_TTL))
        .build()
}
