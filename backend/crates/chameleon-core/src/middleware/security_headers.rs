//! Security headers middleware — matches Python's security_headers middleware.

use axum::{extract::Request, middleware::Next, response::Response};

pub async fn security_headers(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();

    headers.insert("x-content-type-options", "nosniff".parse().expect("static header"));
    headers.insert("x-frame-options", "DENY".parse().expect("static header"));
    headers.insert("x-xss-protection", "1; mode=block".parse().expect("static header"));
    // HSTS only behind TLS — sending on plain HTTP causes browsers to hang
    if std::env::var("FORCE_HTTPS").unwrap_or_default() == "1" {
        headers.insert(
            "strict-transport-security",
            "max-age=31536000; includeSubDomains".parse().expect("static header"),
        );
    }
    headers.insert(
        "referrer-policy",
        "strict-origin-when-cross-origin".parse().expect("static header"),
    );
    headers.insert(
        "permissions-policy",
        "camera=(), microphone=(), geolocation=()".parse().expect("static header"),
    );
    headers.insert(
        "content-security-policy",
        "default-src 'self'; frame-ancestors 'none'".parse().expect("static header"),
    );

    response
}
