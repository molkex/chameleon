//! Telemetry endpoints — receive diagnostic data from iOS app.
//! Supports both authenticated and anonymous submissions.

use axum::{extract::State, routing::post, Json, Router};
use chameleon_auth::MobileUser;
use chameleon_core::{ApiResult, ChameleonCore};
use serde::Deserialize;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/telemetry", post(receive_telemetry))
        .route("/telemetry/anonymous", post(receive_telemetry_anonymous))
}

#[derive(Deserialize)]
struct TelemetryEvent {
    event_type: Option<String>,
    device_id: Option<String>,
    #[serde(flatten)]
    data: serde_json::Value,
}

/// POST /telemetry — authenticated telemetry from logged-in users.
async fn receive_telemetry(
    State(core): State<ChameleonCore>,
    user: MobileUser,
    Json(body): Json<TelemetryEvent>,
) -> ApiResult<Json<serde_json::Value>> {
    let event_type = body.event_type.as_deref().unwrap_or("telemetry");

    sqlx::query(
        "INSERT INTO analytics_events (user_id, event_type, event_data, timestamp) \
         VALUES ($1, $2, $3, NOW())",
    )
    .bind(user.user_id)
    .bind(event_type)
    .bind(&body.data)
    .execute(&core.db)
    .await?;

    Ok(Json(serde_json::json!({"status": "ok"})))
}

/// POST /telemetry/anonymous — telemetry before login (uses device_id).
async fn receive_telemetry_anonymous(
    State(core): State<ChameleonCore>,
    Json(body): Json<TelemetryEvent>,
) -> ApiResult<Json<serde_json::Value>> {
    let event_type = body.event_type.as_deref().unwrap_or("telemetry");

    // Store device_id inside event_data for anonymous events
    let mut data = body.data;
    if let Some(device_id) = &body.device_id {
        if let Some(obj) = data.as_object_mut() {
            obj.insert(
                "device_id".to_string(),
                serde_json::Value::String(device_id.clone()),
            );
        }
    }

    sqlx::query(
        "INSERT INTO analytics_events (user_id, event_type, event_data, timestamp) \
         VALUES (NULL, $1, $2, NOW())",
    )
    .bind(event_type)
    .bind(&data)
    .execute(&core.db)
    .await?;

    Ok(Json(serde_json::json!({"status": "ok"})))
}
