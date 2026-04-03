//! Mobile subscription endpoints — all require MobileUser auth.

use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
};
use chameleon_auth::MobileUser;
use chameleon_core::{ApiError, ApiResult, ChameleonCore};
use chameleon_db::queries::users::{find_user_by_id, find_user_by_original_transaction_id};
use chrono::Utc;
use serde::Deserialize;

/// Map a product_id to (days, plan_name) based on keywords in the ID.
pub(crate) fn product_to_duration(product_id: &str) -> (i32, &'static str) {
    let lower = product_id.to_lowercase();
    if lower.contains("year") {
        (365, "yearly")
    } else if lower.contains("week") {
        (7, "weekly")
    } else if lower.contains("month") {
        (30, "monthly")
    } else {
        (30, "monthly")
    }
}

pub fn router() -> Router<ChameleonCore> {
    Router::new()
        .route("/subscription", get(get_status))
        .route("/subscription/verify", post(verify_purchase))
        .route("/subscription/restore", post(restore_purchase))
}

// ── GET /subscription ──

async fn get_status(
    State(core): State<ChameleonCore>,
    user: MobileUser,
) -> ApiResult<Json<serde_json::Value>> {
    let db_user = find_user_by_id(&core.db, user.user_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound("User not found".into()))?;

    let now = Utc::now().naive_utc();

    let (status, expires_at) = match db_user.subscription_expiry {
        None => ("none", None),
        Some(expiry) if expiry > now && db_user.original_transaction_id.is_some() => {
            ("active", Some(expiry))
        }
        Some(expiry) if expiry > now => ("trial", Some(expiry)),
        Some(expiry) => ("expired", Some(expiry)),
    };

    let plan = db_user.current_plan.unwrap_or_default();

    Ok(Json(serde_json::json!({
        "status": status,
        "expires_at": expires_at.map(|e| e.format("%Y-%m-%dT%H:%M:%S").to_string()),
        "plan": plan,
        "auto_renew": false
    })))
}

// ── POST /subscription/verify ──

#[derive(Deserialize)]
struct VerifyRequest {
    platform: String,
    transaction_id: Option<String>,
    original_transaction_id: Option<String>,
    product_id: Option<String>,
    #[allow(dead_code)]
    receipt_data: Option<String>,
}

async fn verify_purchase(
    State(core): State<ChameleonCore>,
    user: MobileUser,
    Json(req): Json<VerifyRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    if req.platform != "ios" {
        return Err(ApiError::BadRequest("Platform not yet supported".into()));
    }

    let transaction_id = req
        .transaction_id
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ApiError::BadRequest("transaction_id is required".into()))?;

    let product_id = req
        .product_id
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ApiError::BadRequest("product_id is required".into()))?;

    let original_txn = req
        .original_transaction_id
        .as_deref()
        .unwrap_or(transaction_id);

    // Determine subscription duration from product_id
    let (days, plan) = product_to_duration(product_id);

    // TODO: Implement proper Apple App Store Server API verification.
    // Currently using trust-but-verify: we accept the client's transaction and
    // should later validate via Apple Server-to-Server notifications (V2).
    tracing::info!(
        user_id = user.user_id,
        transaction_id = transaction_id,
        original_transaction_id = original_txn,
        product_id = product_id,
        days = days,
        "Processing iOS subscription purchase"
    );

    // Atomic check-and-update: use a single UPDATE with WHERE clause to prevent
    // race conditions on original_transaction_id ownership.
    // RETURNING avoids a separate SELECT round-trip.
    let row: Option<(chrono::NaiveDateTime,)> = sqlx::query_as(
        "UPDATE users SET \
            original_transaction_id = $1, \
            app_store_product_id = $2, \
            current_plan = $3, \
            subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + make_interval(days => $4) \
         WHERE id = $5 \
           AND NOT EXISTS (SELECT 1 FROM users WHERE original_transaction_id = $1 AND id != $5) \
         RETURNING subscription_expiry"
    )
    .bind(original_txn)
    .bind(product_id)
    .bind(plan)
    .bind(days)
    .bind(user.user_id)
    .fetch_optional(&core.db)
    .await?;

    // If no row returned, the transaction belongs to someone else (atomic check)
    let (new_expiry,) = row.ok_or_else(|| {
        ApiError::Conflict("This transaction belongs to a different account".into())
    })?;

    let expires_at = Some(new_expiry.format("%Y-%m-%dT%H:%M:%S").to_string());

    Ok(Json(serde_json::json!({
        "status": "active",
        "expires_at": expires_at,
        "plan": plan
    })))
}

// ── POST /subscription/restore ──

#[derive(Deserialize)]
struct RestoreRequest {
    original_transaction_id: String,
}

async fn restore_purchase(
    State(core): State<ChameleonCore>,
    user: MobileUser,
    Json(req): Json<RestoreRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    // Find any user with this original_transaction_id
    let found = find_user_by_original_transaction_id(&core.db, &req.original_transaction_id)
        .await
        .map_err(ApiError::Internal)?;

    let db_user = match found {
        None => {
            return Err(ApiError::NotFound(
                "No subscription found for this transaction".into(),
            ));
        }
        Some(u) if u.id != user.user_id => {
            // Transfer the subscription to the current user if the old account
            // is inactive or has no other auth provider (anonymous trial).
            // This supports the "new device" restore flow.
            if !u.is_active || u.auth_provider.as_deref() == Some("device") {
                let mut tx = core.db.begin().await?;

                sqlx::query(
                    "UPDATE users SET original_transaction_id = $1, \
                     app_store_product_id = $2, current_plan = $3, \
                     subscription_expiry = $4 \
                     WHERE id = $5",
                )
                .bind(&req.original_transaction_id)
                .bind(&u.app_store_product_id)
                .bind(&u.current_plan)
                .bind(u.subscription_expiry)
                .bind(user.user_id)
                .execute(&mut *tx)
                .await?;

                // Clear from old user
                sqlx::query(
                    "UPDATE users SET original_transaction_id = NULL WHERE id = $1",
                )
                .bind(u.id)
                .execute(&mut *tx)
                .await?;

                // Re-fetch current user with updated data
                let restored = sqlx::query_as::<_, chameleon_db::models::User>(
                    "SELECT * FROM users WHERE id = $1",
                )
                .bind(user.user_id)
                .fetch_optional(&mut *tx)
                .await?
                .ok_or_else(|| ApiError::NotFound("User not found".into()))?;

                tx.commit().await?;

                tracing::info!(
                    from_user = u.id,
                    to_user = user.user_id,
                    "Subscription transferred to new account"
                );

                restored
            } else {
                return Err(ApiError::Conflict(
                    "This transaction belongs to a different active account".into(),
                ));
            }
        }
        Some(u) => u,
    };

    let now = Utc::now().naive_utc();

    let (status, expires_at) = match db_user.subscription_expiry {
        None => ("none", None),
        Some(expiry) if expiry > now => ("active", Some(expiry)),
        Some(expiry) => ("expired", Some(expiry)),
    };

    let plan = db_user.current_plan.unwrap_or_default();

    Ok(Json(serde_json::json!({
        "status": status,
        "expires_at": expires_at.map(|e| e.format("%Y-%m-%dT%H:%M:%S").to_string()),
        "plan": plan,
        "auto_renew": false
    })))
}
