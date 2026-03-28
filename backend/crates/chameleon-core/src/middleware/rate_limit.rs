//! Auth endpoint rate limiting — Redis-based, per-IP, fail-closed.

use std::sync::Arc;
use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use fred::prelude::*;

const MAX_ATTEMPTS: i64 = 10;
const WINDOW_SECS: i64 = 60;

/// Rate limit middleware that takes AppState via State extractor.
pub async fn auth_rate_limit(
    State(state): State<crate::ChameleonCore>,
    request: Request,
    next: Next,
) -> Response {
    // Extract IP
    let ip = request.headers()
        .get("x-real-ip").and_then(|v| v.to_str().ok())
        .or_else(|| request.headers().get("x-forwarded-for").and_then(|v| v.to_str().ok()).and_then(|v| v.split(',').next()))
        .unwrap_or("unknown").trim().to_string();

    let key = format!("auth_rate:{ip}");

    // Check current count — fail closed on Redis error
    let count: i64 = match state.redis.get::<Option<i64>, _>(&key).await {
        Ok(Some(c)) => c,
        Ok(None) => 0,
        Err(e) => {
            tracing::error!(error = %e, "Rate limiter Redis error — failing closed");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({"detail": "Service temporarily unavailable"})),
            ).into_response();
        }
    };

    if count >= MAX_ATTEMPTS {
        tracing::warn!(ip = %ip, count, "Auth rate limit exceeded");
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({"detail": "Too many login attempts. Try again later."})),
        ).into_response();
    }

    // Increment atomically (INCR + EXPIRE)
    let _: Result<i64, _> = state.redis.incr(&key).await;
    if count == 0 {
        let _: Result<bool, _> = state.redis.expire(&key, WINDOW_SECS, None).await;
    }

    next.run(request).await
}
