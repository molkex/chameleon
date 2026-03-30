//! VPN user management endpoints.
//! GET /users, POST /users/{username}/extend, DELETE /users/{username}

use axum::{extract::{Path, Query, State}, routing::{delete, get, post}, Json, Router};
use serde::{Deserialize, Serialize};

use chameleon_auth::{AuthAdmin, RequireOperator};
use chameleon_db::queries::users as user_q;
use chameleon_core::{ChameleonCore, error::{ApiError, ApiResult}};

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/users", get(list_users))
        .route("/users/{username}/extend", post(extend_user))
        .route("/users/{username}", delete(delete_user))
}

#[derive(Deserialize)]
struct ListParams {
    page: Option<i64>,
    page_size: Option<i64>,
    status: Option<String>,
    search: Option<String>,
}

#[derive(Serialize)]
struct UserListResponse {
    users: Vec<UserItem>,
    total: i64,
    page: i64,
    page_size: i64,
}

#[derive(Serialize)]
struct UserItem {
    id: i32,
    vpn_username: Option<String>,
    full_name: Option<String>,
    is_active: bool,
    subscription_expiry: Option<String>,
    days_left: Option<i64>,
    cumulative_traffic: f64,
    devices: i32,
    device_limit: Option<i32>,
    created_at: Option<String>,
}

async fn list_users(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
    Query(params): Query<ListParams>,
) -> ApiResult<Json<UserListResponse>> {
    let page = params.page.unwrap_or(1).max(1);
    let page_size = params.page_size.unwrap_or(25).clamp(1, 200);

    let result = user_q::list_users(
        &state.db, page, page_size,
        params.status.as_deref(),
        params.search.as_deref(),
    ).await.map_err(|e| ApiError::Internal(e))?;

    let now = chrono::Utc::now().naive_utc();
    let users: Vec<UserItem> = result.users.into_iter().map(|u| {
        let days_left = u.subscription_expiry.map(|exp| {
            let delta = exp - now;
            delta.num_days().max(0)
        });
        let expiry_fmt = u.subscription_expiry.map(|t| t.format("%d.%m.%Y %H:%M").to_string());
        let is_active = u.is_active && u.subscription_expiry.map_or(true, |exp| exp > now);

        UserItem {
            id: u.id,
            vpn_username: u.vpn_username,
            full_name: u.full_name,
            is_active,
            subscription_expiry: expiry_fmt,
            days_left,
            cumulative_traffic: (u.cumulative_traffic.unwrap_or(0) as f64) / 1024.0 / 1024.0 / 1024.0,
            devices: 0,
            device_limit: u.device_limit,
            created_at: u.created_at.map(|t| t.format("%d.%m.%Y %H:%M").to_string()),
        }
    }).collect();

    Ok(Json(UserListResponse { users, total: result.total, page, page_size }))
}

#[derive(Deserialize)]
struct ExtendBody {
    days: Option<i32>,
}

async fn extend_user(
    State(state): State<ChameleonCore>,
    _op: RequireOperator,
    Path(username): Path<String>,
    Json(body): Json<ExtendBody>,
) -> ApiResult<Json<serde_json::Value>> {
    let days = body.days.unwrap_or(30).clamp(1, 365);
    let affected = user_q::extend_subscription(&state.db, &username, days)
        .await.map_err(|e| ApiError::Internal(e))?;

    if affected == 0 {
        return Err(ApiError::NotFound("user not found".into()));
    }

    tracing::info!(username = %username, days, "User extended");
    Ok(Json(serde_json::json!({"ok": true, "username": username, "days": days})))
}

async fn delete_user(
    State(state): State<ChameleonCore>,
    _op: RequireOperator,
    Path(username): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let affected = user_q::delete_by_vpn_username(&state.db, &username)
        .await.map_err(|e| ApiError::Internal(e))?;

    if affected == 0 {
        return Err(ApiError::NotFound("user not found".into()));
    }

    tracing::info!(username = %username, "User deleted");
    Ok(Json(serde_json::json!({"ok": true, "username": username})))
}
