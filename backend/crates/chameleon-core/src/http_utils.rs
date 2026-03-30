//! Shared HTTP utilities.

use axum::http::HeaderMap;

/// Extract client IP from request headers.
/// Priority: X-Real-IP (nginx) > X-Forwarded-For (first hop) > fallback "unknown".
pub fn extract_client_ip(headers: &HeaderMap) -> String {
    headers.get("x-real-ip").and_then(|v| v.to_str().ok())
        .or_else(|| headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()).and_then(|v| v.split(',').next()))
        .unwrap_or("unknown").trim().to_string()
}
