//! Mobile auth — Apple Sign In, device registration, token refresh, activation.
//! Returns proper HTTP status codes, validates input structure.

use std::sync::OnceLock;

use axum::{
    extract::State,
    http::HeaderMap,
    routing::post,
    Json, Router,
};
use chrono::{NaiveDateTime, Utc};
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use uuid::Uuid;

use chameleon_auth::jwt;
use chameleon_core::http_utils::extract_client_ip;
use chameleon_core::{ApiError, ApiResult, ChameleonCore};
use chameleon_db::models::User;
use chameleon_db::queries::users::{find_user_by_apple_id, find_user_by_device_id, find_user_by_id};

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/auth/apple", post(apple_login))
        .route("/auth/refresh", post(refresh))
        .route("/auth/register", post(register_device))
        .route("/auth/activate", post(activate))
}

// ── Request / Response types ──

#[derive(Deserialize)]
#[allow(dead_code)]
struct AppleLoginRequest {
    identity_token: String,
    user_identifier: Option<String>,
    device_id: Option<String>,
}

#[derive(Deserialize)]
struct RefreshRequest {
    refresh_token: String,
}

#[derive(Deserialize)]
struct RegisterRequest {
    device_id: String,
}

#[derive(Deserialize)]
#[allow(dead_code)]
struct ActivateRequest {
    code: String,
    device_id: Option<String>,
}

#[derive(Serialize)]
struct AuthResponse {
    access_token: String,
    refresh_token: String,
    username: String,
    expires_at: Option<NaiveDateTime>,
}

#[derive(Serialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
}

// ── Apple JWKS cache ──

/// Cached Apple JWKS keys with TTL.
struct AppleJwks {
    keys: Vec<AppleJwk>,
    fetched_at: std::time::Instant,
}

#[derive(Deserialize, Clone)]
struct AppleJwk {
    #[allow(dead_code)]
    kty: String,
    kid: String,
    #[allow(dead_code)]
    r#use: String,
    #[allow(dead_code)]
    alg: String,
    n: String,
    e: String,
}

static APPLE_JWKS: OnceLock<RwLock<Option<AppleJwks>>> = OnceLock::new();

/// JWKS cache TTL: 1 hour.
const JWKS_TTL: std::time::Duration = std::time::Duration::from_secs(3600);

/// Fetch (or return cached) Apple's JWKS public keys.
async fn get_apple_jwks() -> Result<Vec<AppleJwk>, ApiError> {
    let lock = APPLE_JWKS.get_or_init(|| RwLock::new(None));

    // Check cache
    {
        let cache = lock.read().await;
        if let Some(ref jwks) = *cache {
            if jwks.fetched_at.elapsed() < JWKS_TTL {
                return Ok(jwks.keys.clone());
            }
        }
    }

    // Fetch fresh keys from Apple
    let resp = reqwest::get("https://appleid.apple.com/auth/keys")
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to fetch Apple JWKS: {e}")))?;

    #[derive(Deserialize)]
    struct JwksResponse {
        keys: Vec<AppleJwk>,
    }

    let jwks: JwksResponse = resp
        .json()
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to parse Apple JWKS: {e}")))?;

    // Update cache
    {
        let mut cache = lock.write().await;
        *cache = Some(AppleJwks {
            keys: jwks.keys.clone(),
            fetched_at: std::time::Instant::now(),
        });
    }

    Ok(jwks.keys)
}

// ── Helpers ──

/// Verify an Apple identity_token JWT: fetches Apple's JWKS, validates the
/// signature (RS256), checks issuer/audience/expiry, and returns the `sub` claim.
async fn verify_apple_identity_token(token: &str, bundle_id: &str) -> Result<String, ApiError> {
    // Decode header to get the key ID
    let header = decode_header(token)
        .map_err(|_| ApiError::BadRequest("Invalid Apple token header".into()))?;

    let kid = header
        .kid
        .ok_or_else(|| ApiError::BadRequest("Apple token missing kid".into()))?;

    // Get Apple's public keys
    let keys = get_apple_jwks().await?;

    let jwk = keys
        .iter()
        .find(|k| k.kid == kid)
        .ok_or_else(|| ApiError::BadRequest("Apple token kid not found in JWKS".into()))?;

    // Create decoding key from RSA modulus + exponent
    let decoding_key = DecodingKey::from_rsa_components(&jwk.n, &jwk.e)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("Failed to create RSA key: {e}")))?;

    // Validate signature, issuer, audience, and expiry
    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_issuer(&["https://appleid.apple.com"]);
    validation.set_audience(&[bundle_id]);

    #[derive(Deserialize)]
    struct AppleClaims {
        sub: String,
    }

    let token_data = decode::<AppleClaims>(token, &decoding_key, &validation)
        .map_err(|e| ApiError::BadRequest(format!("Apple token verification failed: {e}")))?;

    Ok(token_data.claims.sub)
}

/// Generate a random subscription token (24 random bytes, hex-encoded = 48 chars).
fn generate_subscription_token() -> String {
    use rand::Rng;
    let bytes: [u8; 24] = rand::thread_rng().r#gen();
    hex::encode(bytes)
}

/// Create access + refresh JWT tokens for a user.
fn create_tokens(
    secret: &str,
    user: &User,
    _client_ip: &str,
) -> ApiResult<(String, String)> {
    let username = user.vpn_username.as_deref().unwrap_or("unknown");
    // No IP binding for mobile — LTE networks and Cloudflare change IPs between requests
    let access = jwt::create_access_token(secret, user.id, username, "user", None)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("JWT create error: {e}")))?;

    let refresh = jwt::create_refresh_token(secret, user.id, username, "user", None)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("JWT create error: {e}")))?;

    Ok((access, refresh))
}

/// Insert a new user into the database.
async fn insert_new_user(
    core: &ChameleonCore,
    apple_id: Option<&str>,
    device_id: Option<&str>,
    auth_provider: &str,
    username_prefix: &str,
) -> ApiResult<User> {
    let vpn_username = format!("{}_{}", username_prefix, &Uuid::new_v4().to_string()[..8]);
    let vpn_uuid = Uuid::new_v4().to_string();
    let vpn_short_id = format!("{:08x}", rand::random::<u32>());
    let subscription_token = generate_subscription_token();
    let activation_code = generate_subscription_token(); // Separate secret for /auth/activate

    let trial_expiry = Utc::now().naive_utc()
        + chrono::Duration::days(core.config.trial_days as i64);

    let user = sqlx::query_as::<_, User>(
        "INSERT INTO users (apple_id, device_id, vpn_username, vpn_uuid, vpn_short_id, \
         subscription_expiry, is_active, auth_provider, subscription_token, activation_code, created_at) \
         VALUES ($1, $2, $3, $4, $5, $6, true, $7, $8, $9, NOW()) RETURNING *",
    )
    .bind(apple_id)
    .bind(device_id)
    .bind(&vpn_username)
    .bind(&vpn_uuid)
    .bind(&vpn_short_id)
    .bind(trial_expiry)
    .bind(auth_provider)
    .bind(&subscription_token)
    .bind(&activation_code)
    .fetch_one(&core.db)
    .await?;

    // Add user to Xray immediately (no restart needed)
    if let (Some(uuid), Some(uname)) = (&user.vpn_uuid, &user.vpn_username) {
        let short_id = user.vpn_short_id.as_deref().unwrap_or("");
        let added = core.engine.xray_api()
            .add_user_to_all_inbounds(uuid, uname, short_id).await;
        if added {
            tracing::info!(username = uname, "User added to Xray (live, no restart)");
        } else {
            tracing::warn!(username = uname, "Failed to add user to Xray live — will be added on next restart");
        }
    }

    Ok(user)
}

// ── Handlers ──

/// POST /auth/apple — Apple Sign-In
async fn apple_login(
    State(core): State<ChameleonCore>,
    headers: HeaderMap,
    Json(body): Json<AppleLoginRequest>,
) -> ApiResult<Json<AuthResponse>> {
    // Validate input
    if body.identity_token.is_empty() {
        return Err(ApiError::BadRequest("identity_token required".into()));
    }
    if body.identity_token.len() > 4096 {
        return Err(ApiError::BadRequest("identity_token too large".into()));
    }
    if let Some(ref did) = body.device_id {
        if did.len() > 256 {
            return Err(ApiError::BadRequest("device_id too large".into()));
        }
    }

    let client_ip = extract_client_ip(&headers);

    // Verify Apple JWT signature and claims, then extract the Apple ID (sub claim)
    let apple_sub = verify_apple_identity_token(
        &body.identity_token,
        &core.config.apple_bundle_id,
    )
    .await?;

    // Look up existing user
    let user = find_user_by_apple_id(&core.db, &apple_sub)
        .await
        .map_err(|e| ApiError::Internal(e))?;

    let user = match user {
        Some(u) => {
            if !u.is_active {
                return Err(ApiError::Forbidden("Account is deactivated".into()));
            }
            u
        }
        None => {
            // Create new user with trial
            let prefix = if apple_sub.len() >= 8 {
                format!("apple_{}", &apple_sub[..8])
            } else {
                format!("apple_{}", &apple_sub)
            };

            insert_new_user(
                &core,
                Some(&apple_sub),
                body.device_id.as_deref(),
                "apple",
                &prefix,
            )
            .await?
        }
    };

    let secret = &core.config.mobile_jwt_secret;
    let (access_token, refresh_token) = create_tokens(secret, &user, &client_ip)?;

    tracing::info!(
        user_id = user.id,
        apple_id = %apple_sub,
        "Apple Sign-In successful"
    );

    Ok(Json(AuthResponse {
        access_token,
        refresh_token,
        username: user.vpn_username.unwrap_or_default(),
        expires_at: user.subscription_expiry,
    }))
}

/// POST /auth/refresh — Token Refresh
async fn refresh(
    State(core): State<ChameleonCore>,
    headers: HeaderMap,
    Json(body): Json<RefreshRequest>,
) -> ApiResult<Json<TokenResponse>> {
    if body.refresh_token.is_empty() {
        return Err(ApiError::BadRequest("refresh_token required".into()));
    }

    let client_ip = extract_client_ip(&headers);
    let secret = &core.config.mobile_jwt_secret;

    // Verify the refresh token
    let claims = jwt::verify_token(secret, &body.refresh_token, "refresh", Some(&client_ip))
        .ok_or(ApiError::Unauthorized)?;

    let user_id: i32 = claims
        .sub
        .parse()
        .map_err(|_| ApiError::Unauthorized)?;

    // Look up user
    let user = find_user_by_id(&core.db, user_id)
        .await
        .map_err(|e| ApiError::Internal(e))?
        .ok_or(ApiError::Unauthorized)?;

    if !user.is_active {
        return Err(ApiError::Unauthorized);
    }

    let (access_token, refresh_token) = create_tokens(secret, &user, &client_ip)?;

    tracing::info!(user_id = user.id, "Mobile token refreshed");

    Ok(Json(TokenResponse {
        access_token,
        refresh_token,
    }))
}

/// POST /auth/register — Device Registration (trial)
async fn register_device(
    State(core): State<ChameleonCore>,
    headers: HeaderMap,
    Json(body): Json<RegisterRequest>,
) -> ApiResult<Json<AuthResponse>> {
    if body.device_id.is_empty() {
        return Err(ApiError::BadRequest("device_id required".into()));
    }
    if body.device_id.len() > 256 {
        return Err(ApiError::BadRequest("device_id too large".into()));
    }

    let client_ip = extract_client_ip(&headers);
    let secret = &core.config.mobile_jwt_secret;

    // Check if device already registered
    let existing = find_user_by_device_id(&core.db, &body.device_id)
        .await
        .map_err(ApiError::Internal)?;

    let user = match existing {
        Some(u) => {
            if !u.is_active {
                return Err(ApiError::Forbidden("Account is deactivated".into()));
            }
            u
        }
        None => {
            insert_new_user(&core, None, Some(&body.device_id), "device", "device")
                .await?
        }
    };

    let (access_token, refresh_token) = create_tokens(secret, &user, &client_ip)?;

    tracing::info!(
        user_id = user.id,
        device_id = %body.device_id,
        "Device registration successful"
    );

    Ok(Json(AuthResponse {
        access_token,
        refresh_token,
        username: user.vpn_username.unwrap_or_default(),
        expires_at: user.subscription_expiry,
    }))
}

/// POST /auth/activate — Activate with subscription code
async fn activate(
    State(core): State<ChameleonCore>,
    headers: HeaderMap,
    Json(body): Json<ActivateRequest>,
) -> ApiResult<Json<AuthResponse>> {
    if body.code.is_empty() {
        return Err(ApiError::BadRequest("code required".into()));
    }
    if body.code.len() > 64 {
        return Err(ApiError::BadRequest("code too large".into()));
    }

    let client_ip = extract_client_ip(&headers);
    let secret = &core.config.mobile_jwt_secret;

    // Look up user by activation_code (NOT subscription_token — that's public in sub links)
    let user: Option<User> =
        sqlx::query_as("SELECT * FROM users WHERE activation_code = $1")
            .bind(&body.code)
            .fetch_optional(&core.db)
            .await?;

    let user = user.ok_or_else(|| ApiError::NotFound("Invalid code".into()))?;

    if !user.is_active {
        return Err(ApiError::Forbidden("Account is deactivated".into()));
    }

    // Link device_id to the account if provided
    if let Some(ref did) = body.device_id {
        if !did.is_empty() {
            sqlx::query("UPDATE users SET device_id = $1 WHERE id = $2")
                .bind(did.as_str())
                .bind(user.id)
                .execute(&core.db)
                .await?;
        }
    }

    let (access_token, refresh_token) = create_tokens(secret, &user, &client_ip)?;

    tracing::info!(
        user_id = user.id,
        "Activation with code successful"
    );

    Ok(Json(AuthResponse {
        access_token,
        refresh_token,
        username: user.vpn_username.unwrap_or_default(),
        expires_at: user.subscription_expiry,
    }))
}
