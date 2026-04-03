//! App Store Server Notification V2 webhook handler.
//!
//! Apple sends a JWS (JSON Web Signature) `signedPayload` to this endpoint.
//! We decode the JWS payload, parse the notification, and update the user's
//! subscription state accordingly.
//!
//! Reference: https://developer.apple.com/documentation/appstoreservernotifications

use axum::extract::State;
use axum::http::StatusCode;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chameleon_core::{ApiError, ChameleonCore};
use serde::Deserialize;

// ── JWS decoding ──

/// Decode the payload (second segment) of a JWS token without signature verification.
///
/// TODO: Production — validate the full certificate chain against Apple's root CA.
/// See: https://developer.apple.com/documentation/appstoreservernotifications/responsebodyv2decodedpayload
fn decode_jws_payload<T: serde::de::DeserializeOwned>(jws: &str) -> Result<T, ApiError> {
    let parts: Vec<&str> = jws.split('.').collect();
    if parts.len() != 3 {
        return Err(ApiError::BadRequest("Invalid JWS format".into()));
    }
    let payload = URL_SAFE_NO_PAD
        .decode(parts[1])
        .or_else(|_| {
            // Apple sometimes uses standard base64 with padding
            use base64::engine::general_purpose::STANDARD;
            STANDARD.decode(parts[1])
        })
        .map_err(|_| ApiError::BadRequest("Invalid JWS encoding".into()))?;
    serde_json::from_slice(&payload)
        .map_err(|e| ApiError::BadRequest(format!("Invalid JWS payload: {e}")))
}

// ── Apple notification types ──

/// The outer wrapper Apple sends — contains the signed payload.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SignedPayloadWrapper {
    signed_payload: String,
}

/// Decoded notification payload.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppStoreNotification {
    notification_type: String,
    subtype: Option<String>,
    data: AppStoreNotificationData,
}

/// The `data` field inside the notification.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppStoreNotificationData {
    signed_transaction_info: Option<String>,
    #[allow(dead_code)]
    signed_renewal_info: Option<String>,
}

/// Decoded transaction info from the inner JWS.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TransactionInfo {
    original_transaction_id: String,
    transaction_id: String,
    product_id: String,
    #[allow(dead_code)]
    expires_date: Option<i64>, // milliseconds since epoch
}

// ── Product → duration mapping (mirrors verify_purchase logic) ──

fn product_to_duration(product_id: &str) -> (i32, &'static str) {
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

// ── Handler ──

/// POST /webhooks/appstore
///
/// Apple always expects 200 OK — on non-200, Apple retries with exponential backoff.
/// We must never return an error HTTP status, even if processing fails internally.
pub async fn handle_notification(
    State(core): State<ChameleonCore>,
    body: String,
) -> StatusCode {
    if let Err(e) = process_notification(&core, &body).await {
        tracing::error!(error = %e, "Failed to process App Store notification");
    }
    // Always return 200 so Apple does not retry
    StatusCode::OK
}

async fn process_notification(core: &ChameleonCore, body: &str) -> Result<(), ApiError> {
    // 1. Parse the outer wrapper
    let wrapper: SignedPayloadWrapper = serde_json::from_str(body)
        .map_err(|e| ApiError::BadRequest(format!("Invalid notification wrapper: {e}")))?;

    // 2. Decode the signed payload (JWS → notification)
    let notification: AppStoreNotification = decode_jws_payload(&wrapper.signed_payload)?;

    let notif_type = &notification.notification_type;
    let subtype = notification.subtype.as_deref().unwrap_or("none");

    tracing::info!(
        notification_type = notif_type,
        subtype = subtype,
        "Received App Store Server Notification V2"
    );

    // 3. Extract transaction info (if present)
    let txn_info = match &notification.data.signed_transaction_info {
        Some(signed) => Some(decode_jws_payload::<TransactionInfo>(signed)?),
        None => None,
    };

    let txn = match &txn_info {
        Some(t) => t,
        None => {
            tracing::warn!(
                notification_type = notif_type,
                "No signed_transaction_info in notification — skipping"
            );
            return Ok(());
        }
    };

    tracing::info!(
        notification_type = notif_type,
        subtype = subtype,
        original_transaction_id = %txn.original_transaction_id,
        transaction_id = %txn.transaction_id,
        product_id = %txn.product_id,
        expires_date = ?txn.expires_date,
        "App Store notification transaction details"
    );

    // 4. Dispatch based on notification type
    match notif_type.as_str() {
        // ── Renewal / new subscription ──
        "DID_RENEW" | "SUBSCRIBED" => {
            handle_extend(core, txn).await?;
        }
        "DID_CHANGE_RENEWAL_STATUS" if subtype == "AUTO_RENEW_ENABLED" => {
            handle_extend(core, txn).await?;
        }

        // ── Expiry (informational — don't revoke, subscription_expiry handles it) ──
        "EXPIRED" | "GRACE_PERIOD_EXPIRED" => {
            tracing::info!(
                original_transaction_id = %txn.original_transaction_id,
                notification_type = notif_type,
                "Subscription expired — no action needed (expiry enforced by subscription_expiry)"
            );
        }

        // ── Refund — immediate revocation ──
        "REFUND" => {
            handle_refund(core, txn).await?;
        }

        // ── Everything else — log only ──
        _ => {
            tracing::info!(
                notification_type = notif_type,
                subtype = subtype,
                original_transaction_id = %txn.original_transaction_id,
                "Unhandled App Store notification type — logged for audit"
            );
        }
    }

    Ok(())
}

/// Extend user subscription (DID_RENEW, SUBSCRIBED, AUTO_RENEW_ENABLED).
async fn handle_extend(core: &ChameleonCore, txn: &TransactionInfo) -> Result<(), ApiError> {
    let (days, plan) = product_to_duration(&txn.product_id);

    let result = sqlx::query(
        "UPDATE users SET \
            app_store_product_id = $1, \
            current_plan = $2, \
            subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + make_interval(days => $3) \
         WHERE original_transaction_id = $4",
    )
    .bind(&txn.product_id)
    .bind(plan)
    .bind(days)
    .bind(&txn.original_transaction_id)
    .execute(&core.db)
    .await?;

    if result.rows_affected() == 0 {
        tracing::warn!(
            original_transaction_id = %txn.original_transaction_id,
            "No user found for original_transaction_id — renewal could not be applied"
        );
    } else {
        tracing::info!(
            original_transaction_id = %txn.original_transaction_id,
            product_id = %txn.product_id,
            days = days,
            plan = plan,
            "Subscription extended via App Store webhook"
        );
    }

    Ok(())
}

/// Revoke subscription immediately (REFUND).
async fn handle_refund(core: &ChameleonCore, txn: &TransactionInfo) -> Result<(), ApiError> {
    let result = sqlx::query(
        "UPDATE users SET subscription_expiry = NOW() WHERE original_transaction_id = $1",
    )
    .bind(&txn.original_transaction_id)
    .execute(&core.db)
    .await?;

    if result.rows_affected() == 0 {
        tracing::warn!(
            original_transaction_id = %txn.original_transaction_id,
            "No user found for original_transaction_id — refund revocation skipped"
        );
    } else {
        tracing::warn!(
            original_transaction_id = %txn.original_transaction_id,
            transaction_id = %txn.transaction_id,
            "Subscription REVOKED due to refund"
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_jws_payload_valid() {
        // Build a fake JWS: header.payload.signature
        let payload = serde_json::json!({"notification_type": "DID_RENEW", "subtype": null, "data": {}});
        let encoded = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());
        let jws = format!("eyJhbGciOiJFUzI1NiJ9.{encoded}.fakesig");

        let decoded: serde_json::Value = decode_jws_payload(&jws).unwrap();
        assert_eq!(decoded["notification_type"], "DID_RENEW");
    }

    #[test]
    fn test_decode_jws_payload_invalid_parts() {
        let result = decode_jws_payload::<serde_json::Value>("not.a.valid.jws.token");
        assert!(result.is_err());
    }

    #[test]
    fn test_decode_jws_payload_bad_base64() {
        let result = decode_jws_payload::<serde_json::Value>("a.!!!.c");
        assert!(result.is_err());
    }

    #[test]
    fn test_product_to_duration() {
        assert_eq!(product_to_duration("com.vpn.yearly"), (365, "yearly"));
        assert_eq!(product_to_duration("com.vpn.weekly"), (7, "weekly"));
        assert_eq!(product_to_duration("com.vpn.monthly"), (30, "monthly"));
        assert_eq!(product_to_duration("com.vpn.unknown"), (30, "monthly"));
    }
}
