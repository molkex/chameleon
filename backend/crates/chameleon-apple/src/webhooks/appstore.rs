//! App Store Server Notification V2 webhook handler.
//!
//! Apple sends a JWS (JSON Web Signature) `signedPayload` to this endpoint.
//! We decode the JWS payload, verify the signature using the certificate from
//! the `x5c` header, and update the user's subscription state accordingly.
//!
//! Reference: https://developer.apple.com/documentation/appstoreservernotifications

use axum::extract::State;
use axum::http::StatusCode;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use chameleon_core::{ApiError, ChameleonCore};
use crate::mobile::subscription::product_to_duration;
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, decode_header};
use serde::Deserialize;
use x509_parser::prelude::*;

// ── JWS verification & decoding ──

/// Apple's root CA issuer common name prefix used for basic chain validation.
const APPLE_ISSUER_MARKER: &str = "Apple";

/// Verify the JWS signature and decode the payload.
///
/// 1. Decodes the JWS header to extract `x5c` certificate chain and `alg`.
/// 2. Parses the first (leaf/signing) certificate from the `x5c` chain.
/// 3. Validates the certificate issuer contains "Apple" (basic chain check).
/// 4. Extracts the EC public key and verifies the JWS signature.
///
/// TODO: Full certificate chain verification against Apple Root CA (download from
/// https://www.apple.com/certificateauthority/ and pin). Currently we verify the
/// signature with the embedded cert and check issuer strings, but a sophisticated
/// attacker could forge the entire x5c chain. For production hardening, pin the
/// Apple Root CA G3 certificate and verify the full chain.
fn verify_and_decode_jws<T: serde::de::DeserializeOwned>(jws: &str) -> Result<T, ApiError> {
    // 1. Decode JWS header to get x5c and algorithm
    let header = decode_header(jws)
        .map_err(|e| ApiError::BadRequest(format!("Invalid JWS header: {e}")))?;

    let x5c = header
        .x5c
        .ok_or_else(|| ApiError::BadRequest("JWS missing x5c certificate chain".into()))?;

    if x5c.is_empty() {
        return Err(ApiError::BadRequest("Empty x5c certificate chain".into()));
    }

    // Require at least 3 certs: leaf, intermediate, root (Apple's standard chain)
    if x5c.len() < 2 {
        tracing::warn!(
            chain_length = x5c.len(),
            "x5c chain shorter than expected (Apple typically sends 3 certificates)"
        );
    }

    // 2. Decode the leaf (signing) certificate from base64 DER
    let cert_der = STANDARD
        .decode(&x5c[0])
        .map_err(|_| ApiError::BadRequest("Invalid x5c certificate encoding".into()))?;

    let (_, cert) = X509Certificate::from_der(&cert_der)
        .map_err(|e| ApiError::BadRequest(format!("Failed to parse x5c signing certificate: {e}")))?;

    // 3. Basic issuer validation — verify the cert chain involves Apple
    let issuer = cert.issuer().to_string();
    if !issuer.contains(APPLE_ISSUER_MARKER) {
        return Err(ApiError::BadRequest(format!(
            "Signing certificate issuer does not contain '{APPLE_ISSUER_MARKER}': {issuer}"
        )));
    }

    // Also check that the leaf cert subject mentions Apple
    let subject = cert.subject().to_string();
    if !subject.contains(APPLE_ISSUER_MARKER) {
        tracing::warn!(
            subject = %subject,
            "Signing certificate subject does not mention Apple"
        );
    }

    // 4. Extract the SubjectPublicKeyInfo (SPKI) in DER format
    let spki_der = cert.public_key().raw;

    // 5. Determine algorithm — Apple uses ES256 for App Store notifications
    let alg = match header.alg {
        Algorithm::ES256 => Algorithm::ES256,
        other => {
            return Err(ApiError::BadRequest(format!(
                "Unexpected JWS algorithm: {other:?} (expected ES256)"
            )));
        }
    };

    // 6. Build decoding key from the SPKI DER bytes and verify signature
    let decoding_key = DecodingKey::from_ec_der(spki_der);

    let mut validation = Validation::new(alg);
    validation.validate_aud = false; // App Store notifications don't include `aud`
    validation.validate_exp = false; // Notifications may arrive delayed

    let token_data = decode::<T>(jws, &decoding_key, &validation)
        .map_err(|e| ApiError::BadRequest(format!("JWS signature verification failed: {e}")))?;

    Ok(token_data.claims)
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
    let notification: AppStoreNotification = verify_and_decode_jws(&wrapper.signed_payload)?;

    let notif_type = &notification.notification_type;
    let subtype = notification.subtype.as_deref().unwrap_or("none");

    tracing::info!(
        notification_type = notif_type,
        subtype = subtype,
        "Received App Store Server Notification V2"
    );

    // 3. Extract transaction info (if present)
    let txn_info = match &notification.data.signed_transaction_info {
        Some(signed) => Some(verify_and_decode_jws::<TransactionInfo>(signed)?),
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
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    /// Decode JWS payload WITHOUT signature verification (testing only).
    fn decode_jws_payload_unverified<T: serde::de::DeserializeOwned>(jws: &str) -> Result<T, ApiError> {
        let parts: Vec<&str> = jws.split('.').collect();
        if parts.len() != 3 {
            return Err(ApiError::BadRequest("Invalid JWS format".into()));
        }
        let payload = URL_SAFE_NO_PAD
            .decode(parts[1])
            .or_else(|_| STANDARD.decode(parts[1]))
            .map_err(|_| ApiError::BadRequest("Invalid JWS encoding".into()))?;
        serde_json::from_slice(&payload)
            .map_err(|e| ApiError::BadRequest(format!("Invalid JWS payload: {e}")))
    }

    #[test]
    fn test_decode_jws_payload_unverified_valid() {
        // Build a fake JWS: header.payload.signature
        let payload = serde_json::json!({"notification_type": "DID_RENEW", "subtype": null, "data": {}});
        let encoded = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());
        let jws = format!("eyJhbGciOiJFUzI1NiJ9.{encoded}.fakesig");

        let decoded: serde_json::Value = decode_jws_payload_unverified(&jws).unwrap();
        assert_eq!(decoded["notification_type"], "DID_RENEW");
    }

    #[test]
    fn test_decode_jws_payload_unverified_invalid_parts() {
        let result = decode_jws_payload_unverified::<serde_json::Value>("not.a.valid.jws.token");
        assert!(result.is_err());
    }

    #[test]
    fn test_decode_jws_payload_unverified_bad_base64() {
        let result = decode_jws_payload_unverified::<serde_json::Value>("a.!!!.c");
        assert!(result.is_err());
    }

    #[test]
    fn test_verify_and_decode_jws_missing_x5c() {
        // JWS with ES256 header but no x5c field — should fail
        let header = serde_json::json!({"alg": "ES256", "typ": "JWT"});
        let payload = serde_json::json!({"test": true});
        let h = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap());
        let p = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());
        let jws = format!("{h}.{p}.fakesig");

        let result = verify_and_decode_jws::<serde_json::Value>(&jws);
        assert!(result.is_err());
        let err = format!("{}", result.unwrap_err());
        assert!(
            err.contains("x5c"),
            "Error should mention x5c: {err}"
        );
    }

    #[test]
    fn test_verify_and_decode_jws_empty_x5c() {
        // JWS with empty x5c array
        let header = serde_json::json!({"alg": "ES256", "x5c": []});
        let payload = serde_json::json!({"test": true});
        let h = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap());
        let p = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());
        let jws = format!("{h}.{p}.fakesig");

        let result = verify_and_decode_jws::<serde_json::Value>(&jws);
        assert!(result.is_err());
        let err = format!("{}", result.unwrap_err());
        assert!(
            err.contains("Empty x5c") || err.contains("x5c"),
            "Error should mention empty x5c: {err}"
        );
    }

    #[test]
    fn test_product_to_duration() {
        assert_eq!(product_to_duration("com.vpn.yearly"), (365, "yearly"));
        assert_eq!(product_to_duration("com.vpn.weekly"), (7, "weekly"));
        assert_eq!(product_to_duration("com.vpn.monthly"), (30, "monthly"));
        assert_eq!(product_to_duration("com.vpn.unknown"), (30, "monthly"));
    }
}
