//! Speed test endpoint — returns a blob for download speed measurement.

use axum::{body::Bytes, http::header, response::IntoResponse, routing::get, Router};
use chameleon_core::ChameleonCore;

/// 1 MB of zeros — allocated once at compile time, reused for every request.
static SPEEDTEST_DATA: &[u8] = &[0u8; 1_048_576];

pub fn router() -> Router<ChameleonCore> {
    Router::new().route("/speedtest", get(speedtest_download))
}

/// GET /speedtest — returns 1 MB of zeros for speed measurement.
async fn speedtest_download() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "application/octet-stream"),
            (header::CACHE_CONTROL, "no-cache"),
        ],
        Bytes::from_static(SPEEDTEST_DATA),
    )
}
