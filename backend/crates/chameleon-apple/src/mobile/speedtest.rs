//! Speed test endpoint — returns a blob for download speed measurement.

use axum::{http::header, response::IntoResponse, routing::get, Router};
use chameleon_core::ChameleonCore;

pub fn router() -> Router<ChameleonCore> {
    Router::new().route("/speedtest", get(speedtest_download))
}

/// GET /speedtest — returns 1 MB of zeros for speed measurement.
async fn speedtest_download() -> impl IntoResponse {
    let data = vec![0u8; 1_048_576];
    (
        [
            (header::CONTENT_TYPE, "application/octet-stream"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        data,
    )
}
