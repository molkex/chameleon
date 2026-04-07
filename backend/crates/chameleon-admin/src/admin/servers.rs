//! VPN Servers CRUD endpoints.
//! GET    /servers     — list all servers
//! POST   /servers     — create server
//! PUT    /servers/:id — update server
//! DELETE /servers/:id — delete server

use axum::{
    extract::{Path, State},
    routing::get,
    Json, Router,
};
use serde::Deserialize;

use chameleon_auth::{AuthAdmin, RequireAdmin};
use chameleon_core::{ChameleonCore, error::{ApiResult, ApiError}};
use chameleon_db::queries::servers;

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/servers", get(list_servers).post(create_server))
        .route("/servers/{id}", axum::routing::put(update_server).delete(delete_server))
}

#[derive(Deserialize)]
struct ServerInput {
    key: String,
    name: String,
    #[serde(default)]
    flag: String,
    host: String,
    #[serde(default = "default_port")]
    port: i32,
    #[serde(default)]
    domain: String,
    #[serde(default)]
    sni: String,
    #[serde(default = "default_true")]
    is_active: bool,
    #[serde(default)]
    sort_order: i32,
}

fn default_port() -> i32 { 2096 }
fn default_true() -> bool { true }

async fn list_servers(
    State(state): State<ChameleonCore>,
    _admin: AuthAdmin,
) -> ApiResult<Json<serde_json::Value>> {
    let list = servers::list_all(&state.db).await
        .map_err(|e| ApiError::Internal(e.into()))?;
    Ok(Json(serde_json::json!(list)))
}

async fn create_server(
    State(state): State<ChameleonCore>,
    _admin: RequireAdmin,
    Json(input): Json<ServerInput>,
) -> ApiResult<Json<serde_json::Value>> {
    let server = servers::create(
        &state.db,
        &input.key,
        &input.name,
        &input.flag,
        &input.host,
        input.port,
        &input.domain,
        &input.sni,
        input.is_active,
        input.sort_order,
    ).await
    .map_err(|e| ApiError::Internal(e.into()))?;
    Ok(Json(serde_json::json!(server)))
}

async fn update_server(
    State(state): State<ChameleonCore>,
    _admin: RequireAdmin,
    Path(id): Path<i32>,
    Json(input): Json<ServerInput>,
) -> ApiResult<Json<serde_json::Value>> {
    let server = servers::update(
        &state.db,
        id,
        &input.key,
        &input.name,
        &input.flag,
        &input.host,
        input.port,
        &input.domain,
        &input.sni,
        input.is_active,
        input.sort_order,
    ).await
    .map_err(|e| ApiError::Internal(e.into()))?;

    match server {
        Some(s) => Ok(Json(serde_json::json!(s))),
        None => Err(ApiError::NotFound("Server not found".into())),
    }
}

async fn delete_server(
    State(state): State<ChameleonCore>,
    _admin: RequireAdmin,
    Path(id): Path<i32>,
) -> ApiResult<Json<serde_json::Value>> {
    let deleted = servers::delete(&state.db, id).await
        .map_err(|e| ApiError::Internal(e.into()))?;
    if deleted {
        Ok(Json(serde_json::json!({"ok": true})))
    } else {
        Err(ApiError::NotFound("Server not found".into()))
    }
}
