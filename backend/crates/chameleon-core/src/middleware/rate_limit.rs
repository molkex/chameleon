//! Redis-based per-IP rate limiting — fail-closed.

use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use fred::prelude::*;

/// Shared rate-limit check against Redis.
/// Returns `None` if the request is allowed, or `Some(Response)` if it should be rejected.
async fn check_rate_limit(
    redis: &fred::clients::Pool,
    key_prefix: &str,
    ip: &str,
    max_attempts: i64,
    window_secs: i64,
) -> Option<Response> {
    let key = format!("{key_prefix}:{ip}");

    let count: i64 = match redis.get::<Option<i64>, _>(&key).await {
        Ok(Some(c)) => c,
        Ok(None) => 0,
        Err(e) => {
            tracing::error!(error = %e, "Rate limiter Redis error — failing closed");
            return Some((
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({"detail": "Service temporarily unavailable"})),
            ).into_response());
        }
    };

    if count >= max_attempts {
        tracing::warn!(ip = %ip, count, prefix = %key_prefix, "Rate limit exceeded");
        return Some((
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({"detail": "Too many requests. Try again later."})),
        ).into_response());
    }

    // Increment atomically (INCR + EXPIRE)
    let _: Result<i64, _> = redis.incr(&key).await;
    if count == 0 {
        let _: Result<bool, _> = redis.expire(&key, window_secs, None).await;
    }

    None
}

/// Auth rate limit: 10 requests per 60 seconds per IP.
pub async fn auth_rate_limit(
    State(state): State<crate::ChameleonCore>,
    request: Request,
    next: Next,
) -> Response {
    let ip = crate::http_utils::extract_client_ip(request.headers());

    if let Some(reject) = check_rate_limit(&state.redis, "auth_rate", &ip, 30, 60).await {
        return reject;
    }

    next.run(request).await
}

/// Subscription endpoint rate limit: 30 requests per 60 seconds per IP.
pub async fn subscription_rate_limit(
    State(state): State<crate::ChameleonCore>,
    request: Request,
    next: Next,
) -> Response {
    let ip = crate::http_utils::extract_client_ip(request.headers());

    if let Some(reject) = check_rate_limit(&state.redis, "sub_rate", &ip, 30, 60).await {
        return reject;
    }

    next.run(request).await
}
