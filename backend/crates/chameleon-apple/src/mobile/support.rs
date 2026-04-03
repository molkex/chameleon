//! Support messages endpoints — chat between user and admin.
//! All endpoints require MobileUser auth.
//!
//! POST /support/messages accepts both:
//!   - application/json: `{ "text": "..." }`
//!   - multipart/form-data: field `content` (text) + optional `images` (JPEG/PNG files)

use std::path::PathBuf;

use axum::{
    extract::{DefaultBodyLimit, FromRequest, Multipart, State},
    http::header::CONTENT_TYPE,
    routing::get,
    Json, Router,
};
use chameleon_auth::MobileUser;
use chameleon_core::{ApiError, ApiResult, ChameleonCore};
use chrono::NaiveDateTime;
use serde::Deserialize;
use sqlx::FromRow;
use uuid::Uuid;

/// Max files per message.
const MAX_FILES: usize = 5;
/// Max file size: 10 MB.
const MAX_FILE_SIZE: usize = 10 * 1024 * 1024;
/// Max body size for multipart: 55 MB (headroom for 5 * 10 MB + text fields).
const MAX_BODY_SIZE: usize = 55 * 1024 * 1024;

const ALLOWED_EXTENSIONS: &[&str] = &["jpg", "jpeg", "png"];
const ALLOWED_CONTENT_TYPES: &[&str] = &["image/jpeg", "image/png"];

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route(
            "/support/messages",
            get(list_messages)
                .post(send_message)
                .layer(DefaultBodyLimit::max(MAX_BODY_SIZE)),
        )
        .route(
            "/support/messages/upload",
            axum::routing::post(send_message_multipart)
                .layer(DefaultBodyLimit::max(MAX_BODY_SIZE)),
        )
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

/// POST /support/messages — send a message from the user (JSON body).
async fn send_message(
    State(core): State<ChameleonCore>,
    user: MobileUser,
    req: axum::http::Request<axum::body::Body>,
) -> ApiResult<Json<serde_json::Value>> {
    // Check content type to decide JSON vs multipart
    let content_type = req
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_lowercase();

    if content_type.contains("multipart/form-data") {
        // Parse as multipart
        let multipart = <Multipart as FromRequest<_>>::from_request(req, &core)
            .await
            .map_err(|e| ApiError::BadRequest(format!("Invalid multipart: {e}")))?;
        handle_multipart(core, user, multipart).await
    } else {
        // Parse as JSON
        let body = axum::body::to_bytes(req.into_body(), 1_048_576)
            .await
            .map_err(|e| ApiError::BadRequest(format!("Failed to read body: {e}")))?;
        let payload: SendMessageRequest = serde_json::from_slice(&body)
            .map_err(|e| ApiError::BadRequest(format!("Invalid JSON: {e}")))?;
        handle_json_message(core, user, payload).await
    }
}

/// POST /support/messages/upload — dedicated multipart endpoint.
async fn send_message_multipart(
    State(core): State<ChameleonCore>,
    user: MobileUser,
    multipart: Multipart,
) -> ApiResult<Json<serde_json::Value>> {
    handle_multipart(core, user, multipart).await
}

/// Handle a plain JSON message (no attachments).
async fn handle_json_message(
    core: ChameleonCore,
    user: MobileUser,
    body: SendMessageRequest,
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

    Ok(Json(message_json(&row)))
}

/// Handle a multipart message (text + optional images).
async fn handle_multipart(
    core: ChameleonCore,
    user: MobileUser,
    mut multipart: Multipart,
) -> ApiResult<Json<serde_json::Value>> {
    let mut content: Option<String> = None;
    let mut saved_paths: Vec<String> = Vec::new();

    let upload_base = PathBuf::from(&core.config.upload_dir).join("support");

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::BadRequest(format!("Multipart read error: {e}")))?
    {
        let field_name = field.name().unwrap_or("").to_string();

        match field_name.as_str() {
            "content" => {
                let text = field
                    .text()
                    .await
                    .map_err(|e| ApiError::BadRequest(format!("Failed to read content: {e}")))?;
                content = Some(text);
            }
            "images" | "images[]" => {
                if saved_paths.len() >= MAX_FILES {
                    return Err(ApiError::BadRequest(format!(
                        "Maximum {MAX_FILES} files allowed"
                    )));
                }

                // Validate content type
                let ct = field
                    .content_type()
                    .unwrap_or("application/octet-stream")
                    .to_string();
                if !ALLOWED_CONTENT_TYPES.contains(&ct.as_str()) {
                    return Err(ApiError::BadRequest(format!(
                        "Unsupported file type: {ct}. Only JPEG and PNG are allowed"
                    )));
                }

                // Determine extension from filename or content type
                let ext = if let Some(filename) = field.file_name() {
                    validate_filename_extension(filename)?
                } else {
                    match ct.as_str() {
                        "image/jpeg" => "jpg".to_string(),
                        "image/png" => "png".to_string(),
                        _ => {
                            return Err(ApiError::BadRequest(
                                "Cannot determine file extension".to_string(),
                            ))
                        }
                    }
                };

                // Read file data with size limit
                let data = field
                    .bytes()
                    .await
                    .map_err(|e| ApiError::BadRequest(format!("Failed to read file: {e}")))?;

                if data.len() > MAX_FILE_SIZE {
                    return Err(ApiError::BadRequest(format!(
                        "File too large. Maximum size is {} MB",
                        MAX_FILE_SIZE / 1024 / 1024
                    )));
                }

                if data.is_empty() {
                    continue; // Skip empty files
                }

                // Save file
                let path =
                    save_upload_file(&upload_base, user.user_id, &ext, &data).await?;
                saved_paths.push(path);
            }
            _ => {
                // Ignore unknown fields
            }
        }
    }

    // Validate: must have content or images
    let text = content
        .map(|t| t.trim().to_string())
        .unwrap_or_default();

    if text.is_empty() && saved_paths.is_empty() {
        return Err(ApiError::BadRequest(
            "Message must contain text or images".to_string(),
        ));
    }

    if text.len() > 4096 {
        return Err(ApiError::BadRequest(
            "Message text must not exceed 4096 characters".to_string(),
        ));
    }

    // Build attachments JSON
    let attachments: Option<serde_json::Value> = if saved_paths.is_empty() {
        None
    } else {
        Some(serde_json::json!(saved_paths))
    };

    let display_text = if text.is_empty() {
        "[image]".to_string()
    } else {
        text
    };

    let row = sqlx::query_as::<_, MessageRow>(
        "INSERT INTO support_messages (user_id, direction, content, attachments) \
         VALUES ($1, 'user', $2, $3) \
         RETURNING id, direction, content, attachments, created_at",
    )
    .bind(user.user_id)
    .bind(&display_text)
    .bind(&attachments)
    .fetch_one(&core.db)
    .await?;

    Ok(Json(message_json(&row)))
}

/// Validate filename extension and return normalized extension.
fn validate_filename_extension(filename: &str) -> Result<String, ApiError> {
    // Sanitize: take only the extension from the last dot
    let ext = filename
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_lowercase();

    if !ALLOWED_EXTENSIONS.contains(&ext.as_str()) {
        return Err(ApiError::BadRequest(format!(
            "Unsupported file extension: .{ext}. Only .jpg, .jpeg, .png are allowed"
        )));
    }

    Ok(ext)
}

/// Save uploaded file to disk. Returns the relative path for DB storage.
async fn save_upload_file(
    upload_base: &PathBuf,
    user_id: i32,
    ext: &str,
    data: &[u8],
) -> ApiResult<String> {
    // Ensure upload directory exists
    tokio::fs::create_dir_all(upload_base)
        .await
        .map_err(|e| {
            tracing::error!("Failed to create upload dir {:?}: {e}", upload_base);
            ApiError::Internal(anyhow::anyhow!("Upload directory error"))
        })?;

    let timestamp = chrono::Utc::now().timestamp();
    let uuid = Uuid::new_v4();
    let filename = format!("{user_id}_{timestamp}_{uuid}.{ext}");
    let file_path = upload_base.join(&filename);

    tokio::fs::write(&file_path, data).await.map_err(|e| {
        tracing::error!("Failed to write upload file {:?}: {e}", file_path);
        ApiError::Internal(anyhow::anyhow!("Failed to save file"))
    })?;

    // Return relative path: support/{filename}
    Ok(format!("support/{filename}"))
}

/// Build the standard JSON response for a message.
fn message_json(row: &MessageRow) -> serde_json::Value {
    serde_json::json!({
        "id": row.id,
        "sender": row.direction,
        "text": row.content,
        "attachment": row.attachments,
        "created_at": row.created_at,
    })
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
