//! Admin user CRUD endpoints.
//! GET /admins, POST /admins, DELETE /admins/{id}

use axum::{extract::{Path, State}, routing::{delete, get, post}, Json, Router};
use serde::Deserialize;

use chameleon_auth::{password, rbac::Role, RequireAdmin};
use chameleon_db::queries::admin as admin_q;
use chameleon_core::{ChameleonCore, error::{ApiError, ApiResult}};

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/admins", get(list_admins).post(create_admin))
        .route("/admins/{id}", delete(delete_admin))
}

async fn list_admins(
    State(state): State<ChameleonCore>,
    _admin: RequireAdmin,
) -> ApiResult<Json<Vec<serde_json::Value>>> {
    let admins = admin_q::list_admins(&state.db).await.map_err(|e| ApiError::Internal(e))?;
    let result: Vec<serde_json::Value> = admins.into_iter().map(|a| {
        serde_json::json!({
            "id": a.id, "username": a.username, "role": a.role,
            "is_active": a.is_active,
            "last_login": a.last_login.map(|t| t.format("%Y-%m-%dT%H:%M:%S").to_string()),
            "created_at": a.created_at.map(|t| t.format("%Y-%m-%dT%H:%M:%S").to_string()),
        })
    }).collect();
    Ok(Json(result))
}

#[derive(Deserialize)]
struct CreateAdminBody {
    username: String,
    password: String,
    role: Option<String>,
}

async fn create_admin(
    State(state): State<ChameleonCore>,
    admin: RequireAdmin,
    Json(body): Json<CreateAdminBody>,
) -> ApiResult<Json<serde_json::Value>> {
    let username = body.username.trim();
    if username.is_empty() || body.password.is_empty() {
        return Err(ApiError::BadRequest("username and password required".into()));
    }
    if username.len() > 64 {
        return Err(ApiError::BadRequest("username too long (max 64)".into()));
    }
    if body.password.len() < 8 {
        return Err(ApiError::BadRequest("password too short (min 8)".into()));
    }
    if body.password.len() > 128 {
        return Err(ApiError::BadRequest("password too long (max 128)".into()));
    }
    let role = body.role.as_deref().unwrap_or("viewer");
    if Role::from_str(role).is_none() {
        return Err(ApiError::BadRequest("invalid role".into()));
    }

    // Check uniqueness
    if admin_q::find_admin_by_username(&state.db, username).await.map_err(|e| ApiError::Internal(e))?.is_some() {
        return Err(ApiError::Conflict("username already exists".into()));
    }

    let pw_hash = password::hash_password(&body.password)
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("hash error: {e}")))?;

    let new_admin = admin_q::create_admin(&state.db, username, &pw_hash, role)
        .await.map_err(|e| ApiError::Internal(e))?;

    tracing::info!(creator = %admin.0.username, new_user = username, role, "Admin created");

    Ok(Json(serde_json::json!({
        "ok": true,
        "admin": {"id": new_admin.id, "username": new_admin.username, "role": new_admin.role},
    })))
}

async fn delete_admin(
    State(state): State<ChameleonCore>,
    admin: RequireAdmin,
    Path(admin_id): Path<i32>,
) -> ApiResult<Json<serde_json::Value>> {
    if admin.0.user_id == admin_id {
        return Err(ApiError::BadRequest("cannot delete yourself".into()));
    }

    let deleted = admin_q::delete_admin(&state.db, admin_id)
        .await.map_err(|e| ApiError::Internal(e))?;

    if !deleted {
        return Err(ApiError::NotFound("admin not found".into()));
    }

    tracing::info!(admin = %admin.0.username, deleted_id = admin_id, "Admin deleted");
    Ok(Json(serde_json::json!({"ok": true})))
}
