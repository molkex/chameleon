//! Support messages endpoints — chat between user and admin.
//! All endpoints require MobileUser auth.

use axum::{extract::State, routing::get, Json, Router};
use chameleon_auth::MobileUser;
use chameleon_core::{ApiError, ApiResult, ChameleonCore};
use chrono::NaiveDateTime;
use serde::Deserialize;
use sqlx::FromRow;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/support/messages", get(list_messages).post(send_message))
        .route("/support/unread", get(unread_count))
}

// ── Types ──

#[derive(Debug, FromRow)]
struct MessageRow {
    id: i32,
    direction: String,
    content: String,
    attachments: Option<serde_json::Value>,
    created_at: Option<NaiveDateTime>,
}

#[derive(Deserialize)]
struct SendMessageRequest {
    text: String,
}

// ── Handlers ──

/// GET /support/messages — list all messages for the current user.
/// Also marks admin messages as read.
async fn list_messages(
    State(core): State<ChameleonCore>,
    user: MobileUser,
) -> ApiResult<Json<serde_json::Value>> {
    // Mark admin messages as read
    sqlx::query(
        "UPDATE support_messages SET is_read = true \
         WHERE user_id = $1 AND direction = 'admin' AND is_read = false",
    )
    .bind(user.user_id)
    .execute(&core.db)
    .await?;

    // Fetch all messages ordered by time
    let rows = sqlx::query_as::<_, MessageRow>(
        "SELECT id, direction, content, attachments, created_at \
         FROM support_messages \
         WHERE user_id = $1 \
         ORDER BY created_at ASC",
    )
    .bind(user.user_id)
    .fetch_all(&core.db)
    .await?;

    let messages: Vec<serde_json::Value> = rows
        .into_iter()
        .map(|r| {
            serde_json::json!({
                "id": r.id,
                "sender": r.direction,
                "text": r.content,
                "attachment": r.attachments,
                "created_at": r.created_at,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "messages": messages })))
}

/// POST /support/messages — send a message from the user.
async fn send_message(
    State(core): State<ChameleonCore>,
    user: MobileUser,
    Json(body): Json<SendMessageRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let text = body.text.trim().to_string();

    if text.is_empty() || text.len() > 4096 {
        return Err(ApiError::BadRequest(
            "Message text must be between 1 and 4096 characters".to_string(),
        ));
    }

    let row = sqlx::query_as::<_, MessageRow>(
        "INSERT INTO support_messages (user_id, direction, content) \
         VALUES ($1, 'user', $2) \
         RETURNING id, direction, content, attachments, created_at",
    )
    .bind(user.user_id)
    .bind(&text)
    .fetch_one(&core.db)
    .await?;

    Ok(Json(serde_json::json!({
        "id": row.id,
        "sender": row.direction,
        "text": row.content,
        "attachment": row.attachments,
        "created_at": row.created_at,
    })))
}

/// GET /support/unread — count of unread admin messages.
async fn unread_count(
    State(core): State<ChameleonCore>,
    user: MobileUser,
) -> ApiResult<Json<serde_json::Value>> {
    let (count,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM support_messages \
         WHERE user_id = $1 AND direction = 'admin' AND is_read = false",
    )
    .bind(user.user_id)
    .fetch_one(&core.db)
    .await?;

    Ok(Json(serde_json::json!({ "unread": count })))
}
