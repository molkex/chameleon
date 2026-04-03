//! Mobile subscription endpoints — all require MobileUser auth.

use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
};
use chameleon_auth::MobileUser;
use chameleon_core::{ApiError, ApiResult, ChameleonCore};
use chameleon_db::queries::users::find_user_by_id;
use chrono::Utc;
use serde::Deserialize;

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
    let product_lower = product_id.to_lowercase();
    let (days, plan) = if product_lower.contains("year") {
        (365, "yearly")
    } else if product_lower.contains("week") {
        (7, "weekly")
    } else if product_lower.contains("month") {
        (30, "monthly")
    } else {
        (30, "monthly")
    };

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

    // Check if this transaction already belongs to a different user
    if !original_txn.is_empty() {
        let existing = sqlx::query_as::<_, chameleon_db::models::User>(
            "SELECT * FROM users WHERE original_transaction_id = $1 AND id != $2",
        )
        .bind(original_txn)
        .bind(user.user_id)
        .fetch_optional(&core.db)
        .await?;

        if existing.is_some() {
            return Err(ApiError::Conflict(
                "This transaction belongs to a different account".into(),
            ));
        }
    }

    // Update user subscription in DB
    sqlx::query(
        "UPDATE users SET \
            original_transaction_id = $1, \
            app_store_product_id = $2, \
            current_plan = $3, \
            subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + make_interval(days => $4) \
         WHERE id = $5"
    )
    .bind(original_txn)
    .bind(product_id)
    .bind(plan)
    .bind(days)
    .bind(user.user_id)
    .execute(&core.db)
    .await?;

    // Fetch updated user to return fresh expiry
    let updated = find_user_by_id(&core.db, user.user_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound("User not found".into()))?;

    let expires_at = updated
        .subscription_expiry
        .map(|e| e.format("%Y-%m-%dT%H:%M:%S").to_string());

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
    let found = sqlx::query_as::<_, chameleon_db::models::User>(
        "SELECT * FROM users WHERE original_transaction_id = $1",
    )
    .bind(&req.original_transaction_id)
    .fetch_optional(&core.db)
    .await?;

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
                .execute(&core.db)
                .await?;

                // Clear from old user
                sqlx::query(
                    "UPDATE users SET original_transaction_id = NULL WHERE id = $1",
                )
                .bind(u.id)
                .execute(&core.db)
                .await?;

                tracing::info!(
                    from_user = u.id,
                    to_user = user.user_id,
                    "Subscription transferred to new account"
                );

                // Re-fetch current user with updated data
                find_user_by_id(&core.db, user.user_id)
                    .await
                    .map_err(ApiError::Internal)?
                    .ok_or_else(|| ApiError::NotFound("User not found".into()))?
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
