use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
    Json,
};
use bson::{doc, Regex};
use chrono::{DateTime, Duration, Utc};
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use uuid::Uuid;

use sha2::{Digest, Sha256};

use crate::{
    auth::{
        create_jwt_versioned, is_token_version_valid, verify_jwt, AdminUser, ApiError, AuthUser,
    },
    models::{
        compute_timed_window, mask_secret_key, AccountRecoveryLogDoc, AuthSettingsDoc,
        AuthSettingsDto, FriendDto, FriendshipDoc, GoogleOAuthStateDoc, OtpSessionDoc, UserDoc,
        UserDto,
    },
    routes::chat_routes::build_conversation_dto,
    seed::{
        ensure_direct_conversation, ensure_quick_test_users, ensure_user_onboarding,
        QUICK_TEST_USERS, TEST_USER_IDS,
    },
    sms, AppState,
};

pub async fn health_handler(State(state): State<AppState>) -> Json<Value> {
    let mongo_ok = state.db.run_command(doc! { "ping": 1 }).await.is_ok();
    let minio_ok = state.minio.check_health().await;

    Json(json!({
        "status": "ok",
        "mongodb": mongo_ok,
        "minio": minio_ok,
    }))
}

#[derive(Debug, Clone)]
pub struct EffectiveAuthSettings {
    pub smsmkt_api_key: String,
    pub smsmkt_secret_key: String,
    pub smsmkt_project_key: String,
    pub smsmkt_sender_name: String,
    pub google_client_id: String,
    pub updated_at: String,
}

pub async fn get_effective_auth_settings(
    state: &AppState,
) -> Result<EffectiveAuthSettings, String> {
    let coll = state.db.collection::<AuthSettingsDoc>("auth_settings");
    let db_doc = coll
        .find_one(doc! { "_id": "default" })
        .await
        .map_err(|e| e.to_string())?;

    let pick = |db_val: &str, cfg_val: &str| -> String {
        if !db_val.trim().is_empty() {
            db_val.trim().to_string()
        } else {
            cfg_val.trim().to_string()
        }
    };

    if let Some(d) = db_doc {
        Ok(EffectiveAuthSettings {
            smsmkt_api_key: pick(&d.smsmkt_api_key, &state.config.smsmkt_api_key),
            smsmkt_secret_key: pick(&d.smsmkt_secret_key, &state.config.smsmkt_secret_key),
            smsmkt_project_key: pick(&d.smsmkt_project_key, &state.config.smsmkt_project_key),
            smsmkt_sender_name: pick(&d.smsmkt_sender_name, &state.config.smsmkt_sender_name),
            google_client_id: pick(&d.google_client_id, &state.config.google_client_id),
            updated_at: d.updated_at,
        })
    } else {
        Ok(EffectiveAuthSettings {
            smsmkt_api_key: state.config.smsmkt_api_key.trim().to_string(),
            smsmkt_secret_key: state.config.smsmkt_secret_key.trim().to_string(),
            smsmkt_project_key: state.config.smsmkt_project_key.trim().to_string(),
            smsmkt_sender_name: state.config.smsmkt_sender_name.trim().to_string(),
            google_client_id: state.config.google_client_id.trim().to_string(),
            updated_at: Utc::now().to_rfc3339(),
        })
    }
}

async fn should_grant_initial_admin(
    state: &AppState,
    phone: &str,
    email: &str,
) -> Result<bool, String> {
    let super_phone = state.config.super_admin_phone.trim();
    if !super_phone.is_empty() && !phone.is_empty() {
        if let Ok(norm_super) = sms::normalize_thai_phone(super_phone) {
            if norm_super == phone {
                return Ok(true);
            }
        } else if super_phone == phone {
            return Ok(true);
        }
    }

    let super_email = state.config.super_admin_email.trim().to_lowercase();
    if !super_email.is_empty() && !email.is_empty() && super_email == email.trim().to_lowercase() {
        return Ok(true);
    }

    let mut excluded_admin_ids = vec!["user_ai", "user_official"];
    excluded_admin_ids.extend_from_slice(&TEST_USER_IDS);
    let human_admin_count = state
        .db
        .collection::<bson::Document>("users")
        .count_documents(doc! {
            "role": "admin",
            "is_oa_bot": { "$ne": true },
            "_id": { "$nin": excluded_admin_ids }
        })
        .await
        .map_err(|e| e.to_string())?;

    Ok(human_admin_count == 0)
}

fn request_is_localhost(headers: &axum::http::HeaderMap) -> bool {
    for xfh in headers.get_all("x-forwarded-host") {
        let ok = xfh
            .to_str()
            .ok()
            .map(crate::config::is_loopback_host_header)
            .unwrap_or(false);
        if !ok {
            return false;
        }
    }
    for host in headers.get_all(axum::http::header::HOST) {
        let ok = host
            .to_str()
            .ok()
            .map(crate::config::is_loopback_host_header)
            .unwrap_or(false);
        if !ok {
            return false;
        }
    }
    true
}

pub async fn auth_config_handler(
    headers: axum::http::HeaderMap,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let eff = get_effective_auth_settings(&state)
        .await
        .map_err(ApiError::internal)?;
    let (has_api, _) = mask_secret_key(&eff.smsmkt_api_key);
    let (has_secret, _) = mask_secret_key(&eff.smsmkt_secret_key);
    let phone_otp_ready = has_api
        && has_secret
        && (!eff.smsmkt_project_key.trim().is_empty() || !eff.smsmkt_sender_name.trim().is_empty());
    let google_enabled = !eff.google_client_id.trim().is_empty();
    let admin_bootstrap_enabled = !state.config.admin_bootstrap_code.trim().is_empty();
    let livekit_enabled = !state.config.livekit_api_key.trim().is_empty()
        && !state.config.livekit_api_secret.trim().is_empty();
    let allow_test_users = state.config.enable_test_users && request_is_localhost(&headers);
    let test_users: Vec<Value> = if allow_test_users {
        QUICK_TEST_USERS
            .iter()
            .map(|u| {
                json!({
                    "slot": u.slot,
                    "id": u.id,
                    "display_name": u.display_name,
                    "bc_id": u.bc_id,
                    "phone": u.phone,
                    "role": u.role,
                    "badge": u.badge,
                })
            })
            .collect()
    } else {
        Vec::new()
    };

    Ok(Json(json!({
        "phone_otp_enabled": true,
        "phone_otp_ready": phone_otp_ready,
        "google_enabled": google_enabled,
        "google_client_id": eff.google_client_id,
        "admin_bootstrap_enabled": admin_bootstrap_enabled,
        "livekit_enabled": livekit_enabled,
        "demo_enabled": false,
        "test_users_enabled": allow_test_users,
        "test_users": test_users,
    })))
}

#[derive(Debug, Deserialize)]
pub struct TestLoginPayload {
    #[serde(default)]
    pub slot: Option<u8>,
    #[serde(default)]
    pub user_id: Option<String>,
}

pub async fn test_login_handler(
    headers: axum::http::HeaderMap,
    State(state): State<AppState>,
    Json(payload): Json<TestLoginPayload>,
) -> Result<Json<Value>, ApiError> {
    let allow_test_users = state.config.enable_test_users && request_is_localhost(&headers);
    if !allow_test_users {
        return Err(ApiError::forbidden(
            "ปิดใช้งานการเข้าสู่ระบบบัญชีทดสอบด่วนแล้ว",
        ));
    }

    let trimmed_uid = payload
        .user_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let spec = match (payload.slot, trimmed_uid) {
        (Some(slot), Some(uid)) => QUICK_TEST_USERS
            .iter()
            .find(|u| u.slot == slot && u.id == uid)
            .ok_or_else(|| ApiError::bad_request("ไม่พบบัญชีทดสอบที่ระบุ"))?,
        (Some(slot), None) => QUICK_TEST_USERS
            .iter()
            .find(|u| u.slot == slot)
            .ok_or_else(|| ApiError::bad_request("ไม่พบบัญชีทดสอบที่ระบุ"))?,
        (None, Some(uid)) => QUICK_TEST_USERS
            .iter()
            .find(|u| u.id == uid)
            .ok_or_else(|| ApiError::bad_request("ไม่พบบัญชีทดสอบที่ระบุ"))?,
        (None, None) => {
            return Err(ApiError::bad_request("ไม่พบบัญชีทดสอบที่ระบุ"));
        }
    };

    let users_coll = state.db.collection::<UserDoc>("users");
    let existing = users_coll
        .find_one(doc! { "_id": spec.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let user = match existing {
        Some(u) if u.role == spec.role => u,
        _ => {
            ensure_quick_test_users(&state)
                .await
                .map_err(ApiError::internal)?;
            users_coll
                .find_one(doc! { "_id": spec.id })
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?
                .ok_or_else(|| ApiError::internal("ไม่สามารถเตรียมข้อมูลบัญชีทดสอบได้"))?
        }
    };

    let _ = ensure_user_onboarding(&state, &user).await;

    let token = create_jwt_versioned(
        &user.id,
        &user.email,
        &user.role,
        user.token_version,
        &state.config.jwt_secret,
    )
    .map_err(ApiError::internal)?;

    Ok(Json(json!({
        "token": token,
        "user": UserDto::from(user),
        "is_new_user": false,
    })))
}

#[derive(Debug, Deserialize)]
pub struct BootstrapAdminPayload {
    pub code: String,
    pub display_name: Option<String>,
}

pub async fn bootstrap_admin_handler(
    State(state): State<AppState>,
    Json(payload): Json<BootstrapAdminPayload>,
) -> Result<Json<Value>, ApiError> {
    let expected = state.config.admin_bootstrap_code.trim();
    if expected.is_empty() {
        return Err(ApiError::forbidden("ปิดใช้งานการเปิดสิทธิ์แอดมินตั้งต้นแล้ว"));
    }
    let provided = payload.code.trim();
    if provided.is_empty() || provided != expected {
        return Err(ApiError::unauthorized("รหัสตั้งต้นแอดมินระบบไม่ถูกต้อง"));
    }

    let custom_name = payload
        .display_name
        .unwrap_or_default()
        .trim()
        .to_string();
    let users_coll = state.db.collection::<UserDoc>("users");
    let existing = users_coll
        .find_one(doc! { "_id": "user_owner_admin" })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let (user, is_new_user) = if let Some(mut u) = existing {
        u.role = "admin".to_string();
        if !custom_name.is_empty() {
            u.display_name = custom_name;
        }
        users_coll
            .update_one(
                doc! { "_id": &u.id },
                doc! {
                    "$set": {
                        "role": "admin",
                        "display_name": &u.display_name,
                    }
                },
            )
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;
        (u, false)
    } else {
        let display_name = if custom_name.is_empty() {
            "เจ้าของระบบ BC Ai Chat".to_string()
        } else {
            custom_name
        };
        let avatar_url = format!(
            "https://ui-avatars.com/api/?name={}&background=812920&color=fff&bold=true",
            urlencoding::encode(&display_name)
        );
        let new_user = UserDoc {
            id: "user_owner_admin".to_string(),
            email: String::new(),
            phone: String::new(),
            phone_verified: false,
            email_verified: false,
            display_name,
            bc_id: "@owner.bc".to_string(),
            avatar_url,
            status_message: "ผู้ดูแลระบบหลักและเจ้าของแพลตฟอร์ม BC Ai Chat".to_string(),
            qr_token: "BCQR_OWNER_ADMIN".to_string(),
            role: "admin".to_string(),
            department: "เจ้าของระบบ".to_string(),
            job_title: "ผู้ดูแลระบบหลัก".to_string(),
            google_id: None,
            is_oa_bot: false,
            oa_id: None,
            allow_add_by_phone: true,
            allow_add_by_id: true,
            allow_add_by_email: true,
            notify_preview: true,
            notify_on_mention: true,
            dnd_until: None,
            recovery_pin_hash: None,
            recovery_code_hashes: Vec::new(),
            recovery_failed_attempts: 0,
            recovery_locked_until: None,
            token_version: 0,
            last_recovered_at: None,
            created_at: Utc::now().to_rfc3339(),
        };
        users_coll
            .insert_one(&new_user)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;
        (new_user, true)
    };

    let _ = ensure_user_onboarding(&state, &user).await;

    let jwt_subject = if !user.email.is_empty() {
        &user.email
    } else if !user.phone.is_empty() {
        &user.phone
    } else {
        &user.bc_id
    };
    let token = create_jwt_versioned(
        &user.id,
        jwt_subject,
        &user.role,
        user.token_version,
        &state.config.jwt_secret,
    )
    .map_err(ApiError::internal)?;

    Ok(Json(json!({
        "token": token,
        "user": UserDto::from(user),
        "is_new_user": is_new_user,
    })))
}

// =============================================================================
// Mobile Phone OTP Auth (SMSMKT)
// =============================================================================

#[derive(Debug, Deserialize)]
pub struct OtpRequestPayload {
    pub phone: String,
    #[serde(default)]
    pub purpose: Option<String>, // "auth" | "link" | "recover"
}

pub async fn otp_request_handler(
    State(state): State<AppState>,
    Json(payload): Json<OtpRequestPayload>,
) -> Result<Json<Value>, ApiError> {
    let normalized = sms::normalize_thai_phone(&payload.phone).map_err(ApiError::bad_request)?;
    let purpose = match payload.purpose.as_deref().map(str::trim) {
        Some("link") => "link".to_string(),
        Some("recover") => "recover".to_string(),
        _ => "auth".to_string(),
    };

    let now = Utc::now();
    let now_str = now.to_rfc3339();
    let otp_coll = state.db.collection::<OtpSessionDoc>("otp_sessions");

    // 60-second cooldown per phone for unverified active OTP session
    let cutoff = (now - Duration::seconds(60)).to_rfc3339();
    if let Ok(Some(recent)) = otp_coll
        .find_one(doc! {
            "phone": &normalized,
            "verified": false,
            "created_at": { "$gt": &cutoff },
            "expires_at": { "$gt": &now_str },
        })
        .await
    {
        let _ = recent;
        return Err(ApiError {
            status: StatusCode::TOO_MANY_REQUESTS,
            message: "กรุณารอ 60 วินาทีก่อนขอรหัส OTP ใหม่อีกครั้ง".to_string(),
        });
    }

    let eff = get_effective_auth_settings(&state)
        .await
        .map_err(ApiError::internal)?;
    let raw_hex = Uuid::new_v4().simple().to_string();
    let ref_code = raw_hex[..6].to_uppercase();

    let send_res = sms::send_otp(
        &state.minio.http,
        &state.config.smsmkt_base_url,
        &eff.smsmkt_api_key,
        &eff.smsmkt_secret_key,
        &eff.smsmkt_project_key,
        &eff.smsmkt_sender_name,
        &normalized,
        &ref_code,
    )
    .await
    .map_err(ApiError::bad_request)?;

    let challenge_id = Uuid::new_v4().to_string();
    let expires_at = (now + Duration::minutes(5)).to_rfc3339();

    let session = OtpSessionDoc {
        id: challenge_id.clone(),
        phone: normalized.clone(),
        smsmkt_token: send_res.token,
        ref_code: send_res.ref_code.clone(),
        purpose,
        target_user_id: None,
        attempts: 0,
        verified: false,
        created_at: now_str,
        expires_at,
    };

    otp_coll
        .insert_one(&session)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(json!({
        "challenge_id": challenge_id,
        "ref_code": session.ref_code,
        "masked_phone": sms::mask_phone(&normalized),
        "expires_in_sec": 300,
    })))
}

#[derive(Debug, Deserialize)]
pub struct OtpVerifyPayload {
    pub challenge_id: String,
    pub otp_code: String,
    pub display_name: Option<String>,
    pub ref_code: Option<String>,
}

async fn verify_otp_challenge(
    state: &AppState,
    challenge_id: &str,
    otp_code: &str,
    ref_code_override: Option<&str>,
) -> Result<OtpSessionDoc, ApiError> {
    let cid = challenge_id.trim();
    let code = otp_code.trim();
    if cid.is_empty() || code.is_empty() {
        return Err(ApiError::bad_request("กรุณากรอกรหัส OTP ให้ครบถ้วน"));
    }

    let otp_coll = state.db.collection::<OtpSessionDoc>("otp_sessions");
    let session = otp_coll
        .find_one(doc! { "_id": cid })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::bad_request("ไม่พบคำขอ OTP หรือรหัสอ้างอิงไม่ถูกต้อง"))?;

    if session.verified {
        return Err(ApiError::bad_request("รหัส OTP นี้ถูกใช้งานแล้ว กรุณาขอรหัสใหม่"));
    }

    if let Ok(exp_dt) = DateTime::parse_from_rfc3339(&session.expires_at) {
        if exp_dt.with_timezone(&Utc) < Utc::now() {
            return Err(ApiError::bad_request("รหัส OTP หมดอายุแล้ว กรุณาขอรหัสใหม่"));
        }
    }

    if session.attempts >= 5 {
        return Err(ApiError {
            status: StatusCode::TOO_MANY_REQUESTS,
            message: "กรอก OTP ผิดเกินกำหนด กรุณาขอรหัส OTP ใหม่".to_string(),
        });
    }

    let _ = otp_coll
        .update_one(doc! { "_id": cid }, doc! { "$inc": { "attempts": 1 } })
        .await;

    let eff = get_effective_auth_settings(state)
        .await
        .map_err(ApiError::internal)?;
    let use_ref = ref_code_override
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&session.ref_code);

    let val_res = sms::validate_otp(
        &state.minio.http,
        &state.config.smsmkt_base_url,
        &eff.smsmkt_api_key,
        &eff.smsmkt_secret_key,
        &session.smsmkt_token,
        code,
        use_ref,
    )
    .await
    .map_err(ApiError::bad_request)?;

    if !val_res.valid {
        return Err(ApiError::bad_request(val_res.message));
    }

    let _ = otp_coll
        .update_one(doc! { "_id": cid }, doc! { "$set": { "verified": true } })
        .await;

    Ok(session)
}

pub async fn otp_verify_handler(
    State(state): State<AppState>,
    Json(payload): Json<OtpVerifyPayload>,
) -> Result<Json<Value>, ApiError> {
    let session = verify_otp_challenge(
        &state,
        &payload.challenge_id,
        &payload.otp_code,
        payload.ref_code.as_deref(),
    )
    .await?;

    let users_coll = state.db.collection::<UserDoc>("users");
    let existing = users_coll
        .find_one(doc! { "phone": &session.phone, "is_oa_bot": { "$ne": true } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let custom_name = payload
        .display_name
        .unwrap_or_default()
        .trim()
        .to_string();

    let (user, is_new_user) = if let Some(mut u) = existing {
        let mut changed = !u.phone_verified;
        u.phone_verified = true;
        if u.display_name.trim().is_empty() && !custom_name.is_empty() {
            u.display_name = custom_name;
            changed = true;
        }
        if changed {
            let _ = users_coll
                .update_one(
                    doc! { "_id": &u.id },
                    doc! {
                        "$set": {
                            "phone_verified": true,
                            "display_name": &u.display_name,
                        }
                    },
                )
                .await;
        }
        (u, false)
    } else {
        let tail = &session.phone[session.phone.len().saturating_sub(4)..];
        let default_name = if custom_name.is_empty() {
            format!("ผู้ใช้ {}", tail)
        } else {
            custom_name
        };
        let bc_id = allocate_unique_bc_id(&state.db, &format!("bc.{}", tail)).await?;
        let qr_token = format!("BCQR_{}", Uuid::new_v4().simple());
        let avatar_url = format!(
            "https://ui-avatars.com/api/?name={}&background=812920&color=fff&bold=true",
            urlencoding::encode(&default_name)
        );
        let is_admin = should_grant_initial_admin(&state, &session.phone, "")
            .await
            .map_err(ApiError::internal)?;

        let new_user = UserDoc {
            id: Uuid::new_v4().to_string(),
            email: String::new(),
            phone: session.phone.clone(),
            phone_verified: true,
            email_verified: false,
            display_name: default_name,
            bc_id,
            avatar_url,
            status_message: "พร้อมคุยกับเพื่อน ครอบครัว และร้านค้าบน BC Ai Chat".to_string(),
            qr_token,
            role: if is_admin {
                "admin".to_string()
            } else {
                "user".to_string()
            },
            department: "เพื่อน".to_string(),
            job_title: "สมาชิก".to_string(),
            google_id: None,
            is_oa_bot: false,
            oa_id: None,
            allow_add_by_phone: true,
            allow_add_by_id: true,
            allow_add_by_email: true,
            notify_preview: true,
            notify_on_mention: true,
            dnd_until: None,
            recovery_pin_hash: None,
            recovery_code_hashes: Vec::new(),
            recovery_failed_attempts: 0,
            recovery_locked_until: None,
            token_version: 0,
            last_recovered_at: None,
            created_at: Utc::now().to_rfc3339(),
        };

        users_coll
            .insert_one(&new_user)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;

        (new_user, true)
    };

    let _ = ensure_user_onboarding(&state, &user).await;

    let jwt_subject = if user.email.is_empty() {
        &user.phone
    } else {
        &user.email
    };
    let token = create_jwt_versioned(
        &user.id,
        jwt_subject,
        &user.role,
        user.token_version,
        &state.config.jwt_secret,
    )
    .map_err(ApiError::internal)?;

    let dto = UserDto::from(user);
    Ok(Json(json!({
        "token": token,
        "user": dto,
        "is_new_user": is_new_user,
    })))
}

#[derive(Debug, Deserialize)]
pub struct LinkPhonePayload {
    pub challenge_id: String,
    pub otp_code: String,
    pub ref_code: Option<String>,
    #[serde(default)]
    pub recovery_pin: Option<String>,
}

pub async fn link_phone_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<LinkPhonePayload>,
) -> Result<Json<Value>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let mut me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    if let Some(ref raw_pin) = payload.recovery_pin {
        let trimmed_pin = raw_pin.trim();
        if !trimmed_pin.is_empty() {
            if let Some(ref stored_hash) = me.recovery_pin_hash {
                if !stored_hash.trim().is_empty() && !verify_secret_salted(trimmed_pin, stored_hash)
                {
                    return Err(ApiError::unauthorized("รหัส PIN กู้คืนบัญชีไม่ถูกต้อง"));
                }
            }
        }
    }

    let session = verify_otp_challenge(
        &state,
        &payload.challenge_id,
        &payload.otp_code,
        payload.ref_code.as_deref(),
    )
    .await?;

    if let Some(_other) = users_coll
        .find_one(doc! {
            "phone": &session.phone,
            "_id": { "$ne": &auth.user_id },
            "is_oa_bot": { "$ne": true },
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        return Err(ApiError::bad_request(
            "เบอร์มือถือนี้ถูกเชื่อมกับบัญชีผู้ใช้อื่นแล้ว",
        ));
    }

    let action = if me.phone_verified && !me.phone.trim().is_empty() && me.phone != session.phone {
        "change_phone"
    } else {
        "link_phone"
    };

    me.phone = session.phone;
    me.phone_verified = true;

    users_coll
        .update_one(
            doc! { "_id": &me.id },
            doc! {
                "$set": {
                    "phone": &me.phone,
                    "phone_verified": true,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    record_recovery_log(
        &state,
        &me.id,
        action,
        "phone_otp",
        sms::mask_phone(&me.phone),
    )
    .await;

    let dto = UserDto::from(me);
    Ok(Json(json!({ "user": dto })))
}

// =============================================================================
// Verified Google OAuth 2.0 Login & Gmail Account Linking
// =============================================================================

#[derive(Debug, Clone)]
struct VerifiedGoogleProfile {
    sub: String,
    email: String,
    name: String,
    picture: String,
}

fn is_truthy_verified(val: Option<&Value>) -> bool {
    match val {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s.eq_ignore_ascii_case("true"),
        _ => false,
    }
}

async fn verify_google_token(
    state: &AppState,
    id_token: Option<&str>,
    access_token: Option<&str>,
) -> Result<VerifiedGoogleProfile, ApiError> {
    let eff = get_effective_auth_settings(state)
        .await
        .map_err(ApiError::internal)?;
    let expected_aud = eff.google_client_id.trim();

    let id_tok = id_token.map(str::trim).unwrap_or("");
    let acc_tok = access_token.map(str::trim).unwrap_or("");

    if id_tok.starts_with("demo_") || acc_tok.starts_with("demo_") {
        return Err(ApiError::unauthorized(
            "ไม่อนุญาตให้เข้าสู่ระบบแบบทดสอบ กรุณายืนยันผ่านบัญชี Google จริง",
        ));
    }
    if id_tok.is_empty() && acc_tok.is_empty() {
        return Err(ApiError::unauthorized(
            "กรุณายืนยันตัวตนผ่าน Google OAuth (ไม่พบโทเคนจาก Google)",
        ));
    }

    let verify_base = state.config.google_oauth_verify_base.trim_end_matches('/');

    if !id_tok.is_empty() {
        let verify_url = format!("{}/tokeninfo?id_token={}", verify_base, urlencoding::encode(id_tok));
        let resp = state
            .minio
            .http
            .get(&verify_url)
            .timeout(std::time::Duration::from_secs(12))
            .send()
            .await
            .map_err(|e| ApiError::unauthorized(format!("ตรวจสอบโทเคน Google ไม่สำเร็จ: {}", e)))?;

        if !resp.status().is_success() {
            return Err(ApiError::unauthorized(
                "โทเคน Google ไม่ถูกต้องหรือหมดอายุ",
            ));
        }
        let info: Value = resp
            .json()
            .await
            .map_err(|_| ApiError::unauthorized("ไม่สามารถอ่านข้อมูลยืนยันจาก Google"))?;

        if !expected_aud.is_empty() {
            let aud = info.get("aud").and_then(|v| v.as_str()).unwrap_or("");
            let azp = info.get("azp").and_then(|v| v.as_str()).unwrap_or("");
            if aud != expected_aud && azp != expected_aud {
                return Err(ApiError::unauthorized(
                    "Google Client ID (aud) ของโทเคนไม่ตรงกับระบบนี้",
                ));
            }
        }

        if !is_truthy_verified(info.get("email_verified")) {
            return Err(ApiError::unauthorized(
                "บัญชี Gmail นี้ยังไม่ได้รับการยืนยัน email_verified จาก Google",
            ));
        }

        let email = info
            .get("email")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| ApiError::unauthorized("Google ไม่ได้ส่งข้อมูลอีเมลกลับมา"))?;
        let sub = info
            .get("sub")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| ApiError::unauthorized("Google ไม่ได้ส่งรหัสประจำตัว sub"))?
            .to_string();
        let name = info
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        let picture = info
            .get("picture")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();

        return Ok(VerifiedGoogleProfile {
            sub,
            email,
            name,
            picture,
        });
    }

    // Verify access_token via tokeninfo + userinfo
    let tokeninfo_url = format!(
        "{}/tokeninfo?access_token={}",
        verify_base,
        urlencoding::encode(acc_tok)
    );
    let ti_resp = state
        .minio
        .http
        .get(&tokeninfo_url)
        .timeout(std::time::Duration::from_secs(12))
        .send()
        .await
        .map_err(|e| ApiError::unauthorized(format!("ตรวจสอบ Access Token Google ไม่สำเร็จ: {}", e)))?;

    if !ti_resp.status().is_success() {
        return Err(ApiError::unauthorized("Google Access Token ไม่ถูกต้องหรือหมดอายุ"));
    }
    let ti: Value = ti_resp
        .json()
        .await
        .map_err(|_| ApiError::unauthorized("อ่านผล tokeninfo ไม่สำเร็จ"))?;

    if !expected_aud.is_empty() {
        let aud = ti.get("aud").and_then(|v| v.as_str()).unwrap_or("");
        let azp = ti.get("azp").and_then(|v| v.as_str()).unwrap_or("");
        if aud != expected_aud && azp != expected_aud {
            return Err(ApiError::unauthorized(
                "Google Client ID ของ Access Token ไม่ตรงกับระบบนี้",
            ));
        }
    }

    let userinfo_url = if verify_base.contains("oauth2.googleapis.com") {
        "https://www.googleapis.com/oauth2/v3/userinfo".to_string()
    } else {
        format!("{}/oauth2/v3/userinfo", verify_base)
    };
    let ui_resp = state
        .minio
        .http
        .get(&userinfo_url)
        .bearer_auth(acc_tok)
        .timeout(std::time::Duration::from_secs(12))
        .send()
        .await
        .map_err(|e| ApiError::unauthorized(format!("ดึงโปรไฟล์ Google Userinfo ไม่สำเร็จ: {}", e)))?;

    if !ui_resp.status().is_success() {
        return Err(ApiError::unauthorized("ไม่สามารถดึงโปรไฟล์ที่ยืนยันแล้วจาก Google"));
    }
    let ui: Value = ui_resp
        .json()
        .await
        .map_err(|_| ApiError::unauthorized("อ่านข้อมูล Google Userinfo ไม่สำเร็จ"))?;

    if !is_truthy_verified(ui.get("email_verified")) && !is_truthy_verified(ti.get("email_verified"))
    {
        return Err(ApiError::unauthorized(
            "บัญชี Gmail นี้ยังไม่ได้ยืนยันตัวตน (email_verified)",
        ));
    }

    let email = ui
        .get("email")
        .or_else(|| ti.get("email"))
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ApiError::unauthorized("ไม่พบอีเมลในข้อมูลยืนยันของ Google"))?;
    let sub = ui
        .get("sub")
        .or_else(|| ti.get("sub"))
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ApiError::unauthorized("ไม่พบรหัส sub จาก Google"))?
        .to_string();
    let name = ui
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    let picture = ui
        .get("picture")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    Ok(VerifiedGoogleProfile {
        sub,
        email,
        name,
        picture,
    })
}

#[derive(Debug, Deserialize)]
pub struct GoogleAuthRequest {
    pub id_token: Option<String>,
    pub access_token: Option<String>,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub recovery_pin: Option<String>,
}

async fn login_with_verified_google(
    state: &AppState,
    profile: VerifiedGoogleProfile,
    fallback_display_name: Option<&str>,
    fallback_avatar_url: Option<&str>,
) -> Result<(UserDoc, String, bool), ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");

    let existing = users_coll
        .find_one(doc! {
            "is_oa_bot": { "$ne": true },
            "_id": { "$nin": ["user_ai", "user_official"] },
            "$or": [
                { "google_id": &profile.sub },
                { "email": &profile.email },
            ]
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let (user, is_new_user) = if let Some(mut u) = existing {
        u.email = profile.email.clone();
        u.email_verified = true;
        u.google_id = Some(profile.sub.clone());
        if u.display_name.trim().is_empty() {
            u.display_name = if !profile.name.is_empty() {
                profile.name.clone()
            } else {
                fallback_display_name.unwrap_or("").trim().to_string()
            };
        }
        if u.avatar_url.trim().is_empty() && !profile.picture.is_empty() {
            u.avatar_url = profile.picture.clone();
        }
        let _ = users_coll
            .update_one(
                doc! { "_id": &u.id },
                doc! {
                    "$set": {
                        "email": &u.email,
                        "email_verified": true,
                        "google_id": &u.google_id,
                        "display_name": &u.display_name,
                        "avatar_url": &u.avatar_url,
                    }
                },
            )
            .await;
        (u, false)
    } else {
        let local_part: String = profile
            .email
            .split('@')
            .next()
            .unwrap_or("user")
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_')
            .collect();
        let default_name = if !profile.name.is_empty() {
            profile.name
        } else {
            let fnm = fallback_display_name.unwrap_or("").trim();
            if !fnm.is_empty() {
                fnm.to_string()
            } else if !local_part.is_empty() {
                local_part.clone()
            } else {
                "สมาชิก Gmail".to_string()
            }
        };
        let avatar_url = if !profile.picture.is_empty() {
            profile.picture
        } else if let Some(fav) = fallback_avatar_url.map(str::trim).filter(|s| !s.is_empty()) {
            fav.to_string()
        } else {
            format!(
                "https://ui-avatars.com/api/?name={}&background=812920&color=fff&bold=true",
                urlencoding::encode(&default_name)
            )
        };
        let raw_base = local_part
            .to_ascii_lowercase()
            .trim_matches(|c| c == '.' || c == '_' || c == '-')
            .replace("..", ".");
        let trimmed_base: String = raw_base.chars().take(18).collect();
        let clean_base = trimmed_base
            .trim_end_matches(|c| c == '.' || c == '_' || c == '-')
            .to_string();
        let safe_base = if clean_base.is_empty() {
            "gmail".to_string()
        } else {
            clean_base
        };
        let suffix = &Uuid::new_v4().simple().to_string()[..4];
        let bc_id = allocate_unique_bc_id(&state.db, &format!("{}_{}.bc", safe_base, suffix))
            .await?;
        let qr_token = format!("BCQR_{}", Uuid::new_v4().simple());
        let is_admin = should_grant_initial_admin(state, "", &profile.email)
            .await
            .map_err(ApiError::internal)?;

        let new_user = UserDoc {
            id: Uuid::new_v4().to_string(),
            email: profile.email,
            phone: String::new(),
            phone_verified: false,
            email_verified: true,
            display_name: default_name,
            bc_id,
            avatar_url,
            status_message: "พร้อมคุยกับเพื่อน ครอบครัว และร้านค้าบน BC Ai Chat".to_string(),
            qr_token,
            role: if is_admin {
                "admin".to_string()
            } else {
                "user".to_string()
            },
            department: "เพื่อน".to_string(),
            job_title: "สมาชิก".to_string(),
            google_id: Some(profile.sub),
            is_oa_bot: false,
            oa_id: None,
            allow_add_by_phone: true,
            allow_add_by_id: true,
            allow_add_by_email: true,
            notify_preview: true,
            notify_on_mention: true,
            dnd_until: None,
            recovery_pin_hash: None,
            recovery_code_hashes: Vec::new(),
            recovery_failed_attempts: 0,
            recovery_locked_until: None,
            token_version: 0,
            last_recovered_at: None,
            created_at: Utc::now().to_rfc3339(),
        };

        users_coll
            .insert_one(&new_user)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;
        (new_user, true)
    };

    let _ = ensure_user_onboarding(state, &user).await;

    let jwt_subject = if user.email.is_empty() {
        &user.phone
    } else {
        &user.email
    };
    let token = create_jwt_versioned(
        &user.id,
        jwt_subject,
        &user.role,
        user.token_version,
        &state.config.jwt_secret,
    )
    .map_err(ApiError::internal)?;

    Ok((user, token, is_new_user))
}

async fn link_verified_google_to_user(
    state: &AppState,
    user_id: &str,
    profile: VerifiedGoogleProfile,
) -> Result<UserDoc, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");

    if let Some(_conflict) = users_coll
        .find_one(doc! {
            "_id": { "$ne": user_id },
            "is_oa_bot": { "$ne": true },
            "$or": [
                { "google_id": &profile.sub },
                { "email": &profile.email, "email_verified": true },
            ]
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        return Err(ApiError::bad_request(
            "บัญชี Gmail นี้ถูกเชื่อมกับบัญชีผู้ใช้อื่นแล้ว",
        ));
    }

    let mut me = users_coll
        .find_one(doc! { "_id": user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    me.email = profile.email;
    me.email_verified = true;
    me.google_id = Some(profile.sub);
    if me.avatar_url.contains("ui-avatars.com") && !profile.picture.is_empty() {
        me.avatar_url = profile.picture;
    }

    users_coll
        .update_one(
            doc! { "_id": &me.id },
            doc! {
                "$set": {
                    "email": &me.email,
                    "email_verified": true,
                    "google_id": &me.google_id,
                    "avatar_url": &me.avatar_url,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(me)
}

pub async fn google_auth_handler(
    State(state): State<AppState>,
    Json(payload): Json<GoogleAuthRequest>,
) -> Result<Json<Value>, ApiError> {
    let profile = verify_google_token(
        &state,
        payload.id_token.as_deref(),
        payload.access_token.as_deref(),
    )
    .await?;

    let (user, token, is_new_user) = login_with_verified_google(
        &state,
        profile,
        payload.display_name.as_deref(),
        payload.avatar_url.as_deref(),
    )
    .await?;

    Ok(Json(json!({
        "token": token,
        "user": UserDto::from(user),
        "is_new_user": is_new_user,
    })))
}

pub async fn link_google_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<GoogleAuthRequest>,
) -> Result<Json<Value>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let me_before = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    if let Some(ref raw_pin) = payload.recovery_pin {
        let trimmed_pin = raw_pin.trim();
        if !trimmed_pin.is_empty() {
            if let Some(ref stored_hash) = me_before.recovery_pin_hash {
                if !stored_hash.trim().is_empty() && !verify_secret_salted(trimmed_pin, stored_hash)
                {
                    return Err(ApiError::unauthorized("รหัส PIN กู้คืนบัญชีไม่ถูกต้อง"));
                }
            }
        }
    }

    let profile = verify_google_token(
        &state,
        payload.id_token.as_deref(),
        payload.access_token.as_deref(),
    )
    .await?;

    let action = if me_before.email_verified
        && !me_before.email.trim().is_empty()
        && me_before.email != profile.email
    {
        "change_google"
    } else {
        "link_google"
    };

    let updated = link_verified_google_to_user(&state, &auth.user_id, profile).await?;
    record_recovery_log(
        &state,
        &updated.id,
        action,
        "google_oauth",
        mask_email(&updated.email),
    )
    .await;

    Ok(Json(json!({ "user": UserDto::from(updated) })))
}

pub async fn unlink_google_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let mut me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    if !me.phone_verified || me.phone.trim().is_empty() {
        return Err(ApiError::bad_request(
            "ไม่สามารถยกเลิกการเชื่อม Gmail ได้ เนื่องจากต้องมีช่องทางเข้าสู่ระบบที่ยืนยันแล้วอย่างน้อย 1 ช่องทาง",
        ));
    }

    let prev_masked = if me.email.trim().is_empty() {
        "Gmail".to_string()
    } else {
        mask_email(&me.email)
    };

    me.email.clear();
    me.email_verified = false;
    me.google_id = None;

    users_coll
        .update_one(
            doc! { "_id": &me.id },
            doc! {
                "$set": {
                    "email": "",
                    "email_verified": false,
                    "google_id": bson::Bson::Null,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    record_recovery_log(&state, &me.id, "unlink_google", "authenticated", prev_masked).await;

    Ok(Json(json!({ "user": UserDto::from(me) })))
}

#[derive(Debug, Deserialize)]
pub struct GoogleStartQuery {
    pub mode: Option<String>,
    pub token: Option<String>,
    pub state: Option<String>,
}

/// Resolve a strictly allowlisted callback origin for Google OAuth redirects so local
/// `localhost:3096` / `localhost:8096` (and normalized `127.0.0.1`) work seamlessly without
/// exposing the endpoint to Host-header injection.
pub fn resolve_google_callback_base(headers: &HeaderMap, configured_base: &str) -> String {
    let normalized_configured = configured_base
        .trim()
        .trim_end_matches('/')
        .replace("http://127.0.0.1:", "http://localhost:");
    let incoming_host = headers
        .get("x-forwarded-host")
        .or_else(|| headers.get("host"))
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.split(',').next())
        .map(|s| s.trim().to_ascii_lowercase())
        .unwrap_or_default();

    match incoming_host.as_str() {
        "localhost:3096" | "127.0.0.1:3096" => "http://localhost:3096".to_string(),
        "localhost:8096" | "127.0.0.1:8096" => "http://localhost:8096".to_string(),
        _ => normalized_configured,
    }
}

pub async fn google_oauth_start_handler(
    headers: HeaderMap,
    Query(query): Query<GoogleStartQuery>,
    State(state): State<AppState>,
) -> Response {
    let eff = match get_effective_auth_settings(&state).await {
        Ok(s) => s,
        Err(e) => {
            return Html(format!("<h2>เกิดข้อผิดพลาด</h2><p>{}</p>", e)).into_response();
        }
    };
    let client_id = eff.google_client_id.trim();
    if client_id.is_empty() {
        return Html(
            "<html><body style=\"font-family:sans-serif;background:#FBF9F8;color:#812920;padding:24px\"><h2>ยังไม่ได้ตั้งค่า Google Client ID</h2><p>กรุณาให้ผู้ดูแลระบบตั้งค่า GOOGLE_CLIENT_ID ในระบบก่อนใช้งานการยืนยัน Gmail</p></body></html>"
                .to_string(),
        )
        .into_response();
    }

    let mode = match query.mode.as_deref().map(str::trim) {
        Some("link") => "link",
        Some("recover") => "recover",
        _ => "login",
    };

    let mut link_user_id = None;
    if mode == "link" {
        let tok = query.token.as_deref().unwrap_or("").trim();
        match verify_jwt(tok, &state.config.jwt_secret) {
            Ok(claims) if is_token_version_valid(&state, &claims.sub, claims.tv) => {
                link_user_id = Some(claims.sub);
            }
            _ => {
                return Html("<h2>โทเคนหมดอายุ กรุณาเข้าสู่ระบบใหม่อีกครั้ง</h2>".to_string())
                    .into_response();
            }
        }
    }

    let state_id = query
        .state
        .as_deref()
        .map(str::trim)
        .filter(|s| {
            s.len() >= 12
                && s.len() <= 64
                && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        })
        .map(str::to_string)
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    let nonce = Uuid::new_v4().simple().to_string();
    let now = Utc::now();
    let oauth_doc = GoogleOAuthStateDoc {
        id: state_id.clone(),
        mode: mode.to_string(),
        link_user_id,
        nonce: nonce.clone(),
        status: "pending".to_string(),
        verified_google_sub: None,
        verified_google_email: None,
        result_token: None,
        result_user: None,
        error_message: None,
        created_at: now.to_rfc3339(),
        expires_at: (now + Duration::minutes(10)).to_rfc3339(),
    };

    let coll = state
        .db
        .collection::<GoogleOAuthStateDoc>("google_oauth_states");
    let _ = coll
        .replace_one(doc! { "_id": &state_id }, &oauth_doc)
        .upsert(true)
        .await;

    let callback_base = resolve_google_callback_base(&headers, &state.config.public_base_url);
    let redirect_uri = format!("{}/api/auth/google/callback", callback_base);

    let google_url = format!(
        "https://accounts.google.com/o/oauth2/v2/auth?client_id={}&redirect_uri={}&response_type=id_token%20token&scope=openid%20email%20profile&state={}&nonce={}&prompt=select_account",
        urlencoding::encode(client_id),
        urlencoding::encode(&redirect_uri),
        urlencoding::encode(&state_id),
        urlencoding::encode(&nonce)
    );

    Redirect::temporary(&google_url).into_response()
}

pub async fn google_oauth_callback_handler() -> Html<&'static str> {
    Html(
        r#"<!doctype html>
<html lang="th">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>ยืนยันบัญชี Gmail — BC Ai Chat</title>
<style>
  body { font-family: system-ui, -apple-system, sans-serif; background:#FBF9F8; color:#1B1C1C; display:flex; align-items:center; justify-content:center; min-height:100vh; margin:0; padding:16px; }
  .card { max-width:420px; width:100%; background:#FFFFFF; border:1px solid #DCC0BC; border-radius:16px; padding:20px; box-shadow:0 8px 24px rgba(129,41,32,.08); }
  h1 { margin:0 0 8px; font-size:18px; color:#812920; }
  p { margin:0; font-size:14px; line-height:1.5; color:#524E4A; }
</style>
</head>
<body>
  <div class="card">
    <h1 id="title">กำลังตรวจสอบบัญชี Google...</h1>
    <p id="msg">โปรดรอสักครู่ ระบบกำลังยืนยันตัวตนกับ Google OAuth 2.0</p>
  </div>
<script>
(async function() {
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''));
  const query = new URLSearchParams(window.location.search);
  const state = hash.get('state') || query.get('state') || '';
  const id_token = hash.get('id_token') || '';
  const access_token = hash.get('access_token') || '';
  const err = hash.get('error') || query.get('error') || '';
  const titleEl = document.getElementById('title');
  const msgEl = document.getElementById('msg');
  try {
    const res = await fetch('/api/auth/google/complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ state, id_token, access_token, error: err }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'ยืนยันไม่สำเร็จ');
    titleEl.textContent = 'ยืนยัน Gmail สำเร็จแล้ว';
    msgEl.textContent = 'คุณสามารถปิดหน้าต่างนี้และกลับไปที่แอป BC Ai Chat ได้ทันที';
    if (window.opener && !window.opener.closed) {
      window.opener.postMessage({ type: 'bc_google_oauth_done', state, data }, '*');
      setTimeout(() => window.close(), 600);
    }
  } catch (e) {
    titleEl.textContent = 'ยืนยันบัญชี Google ไม่สำเร็จ';
    msgEl.textContent = e.message || 'กรุณาลองใหม่อีกครั้ง';
  }
})();
</script>
</body>
</html>"#,
    )
}

#[derive(Debug, Deserialize)]
pub struct GoogleCompletePayload {
    pub state: String,
    pub id_token: Option<String>,
    pub access_token: Option<String>,
    pub error: Option<String>,
}

pub async fn google_oauth_complete_handler(
    State(state): State<AppState>,
    Json(payload): Json<GoogleCompletePayload>,
) -> Result<Json<Value>, ApiError> {
    let state_id = payload.state.trim();
    if state_id.is_empty() {
        return Err(ApiError::bad_request("ไม่พบรหัส state ของ Google OAuth"));
    }

    let coll = state
        .db
        .collection::<GoogleOAuthStateDoc>("google_oauth_states");
    let st_doc = coll
        .find_one(doc! { "_id": state_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบรายการเข้าสู่ระบบ Google ที่ระบุ"))?;

    if let Ok(exp_dt) = DateTime::parse_from_rfc3339(&st_doc.expires_at) {
        if exp_dt.with_timezone(&Utc) < Utc::now() {
            return Err(ApiError::bad_request("คำขอ Google OAuth หมดอายุแล้ว"));
        }
    }

    if let Some(ref err) = payload.error {
        if !err.trim().is_empty() {
            let msg = format!("Google ยกเลิกหรือปฏิเสธคำขอ: {}", err.trim());
            let _ = coll
                .update_one(
                    doc! { "_id": state_id },
                    doc! { "$set": { "status": "error", "error_message": &msg } },
                )
                .await;
            return Err(ApiError::unauthorized(msg));
        }
    }

    let profile = match verify_google_token(
        &state,
        payload.id_token.as_deref(),
        payload.access_token.as_deref(),
    )
    .await
    {
        Ok(p) => p,
        Err(e) => {
            let _ = coll
                .update_one(
                    doc! { "_id": state_id },
                    doc! { "$set": { "status": "error", "error_message": &e.message } },
                )
                .await;
            return Err(e);
        }
    };

    if st_doc.mode == "recover" {
        let _ = coll
            .update_one(
                doc! { "_id": state_id },
                doc! {
                    "$set": {
                        "status": "verified_for_recovery",
                        "verified_google_sub": &profile.sub,
                        "verified_google_email": &profile.email,
                    }
                },
            )
            .await;
        return Ok(Json(json!({
            "status": "verified_for_recovery",
            "oauth_state": state_id,
            "email": profile.email,
        })));
    }

    if st_doc.mode == "link" {
        let uid = st_doc
            .link_user_id
            .as_deref()
            .ok_or_else(|| ApiError::bad_request("ไม่พบรหัสผู้ใช้สำหรับเชื่อมบัญชี Gmail"))?;
        let updated = link_verified_google_to_user(&state, uid, profile).await?;
        record_recovery_log(
            &state,
            &updated.id,
            "link_google",
            "google_oauth_popup",
            mask_email(&updated.email),
        )
        .await;
        let dto = UserDto::from(updated);
        let dto_bson = bson::to_bson(&dto).unwrap_or(bson::Bson::Null);
        let _ = coll
            .update_one(
                doc! { "_id": state_id },
                doc! { "$set": { "status": "completed", "result_user": dto_bson } },
            )
            .await;
        return Ok(Json(json!({ "status": "completed", "user": dto })));
    }

    let (user, token, is_new_user) =
        login_with_verified_google(&state, profile, None, None).await?;
    let dto = UserDto::from(user);
    let dto_bson = bson::to_bson(&dto).unwrap_or(bson::Bson::Null);
    let _ = coll
        .update_one(
            doc! { "_id": state_id },
            doc! { "$set": { "status": "completed", "result_token": &token, "result_user": dto_bson } },
        )
        .await;

    Ok(Json(json!({
        "status": "completed",
        "token": token,
        "user": dto,
        "is_new_user": is_new_user,
    })))
}

#[derive(Debug, Deserialize)]
pub struct GooglePollQuery {
    pub state: String,
}

pub async fn google_oauth_poll_handler(
    Query(query): Query<GooglePollQuery>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let state_id = query.state.trim();
    if state_id.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุ state"));
    }

    let coll = state
        .db
        .collection::<GoogleOAuthStateDoc>("google_oauth_states");
    let st_doc = coll
        .find_one(doc! { "_id": state_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let Some(doc_item) = st_doc else {
        return Ok(Json(json!({ "status": "not_found" })));
    };

    Ok(Json(json!({
        "status": doc_item.status,
        "mode": doc_item.mode,
        "oauth_state": doc_item.id,
        "email": doc_item.verified_google_email,
        "token": doc_item.result_token,
        "user": doc_item.result_user,
        "error": doc_item.error_message,
    })))
}

// =============================================================================
// Account Recovery, Security PIN, Backup Codes & Audit Logs (#56)
// =============================================================================

const RECOVERY_CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

fn mask_email(email: &str) -> String {
    let trimmed = email.trim();
    let Some((local, domain)) = trimmed.split_once('@') else {
        return "***".to_string();
    };
    let prefix: String = local.chars().take(2).collect();
    if prefix.is_empty() {
        format!("***@{domain}")
    } else {
        format!("{prefix}***@{domain}")
    }
}

fn validate_six_digit_pin(raw: &str) -> Result<String, ApiError> {
    let p = raw.trim();
    if p.len() == 6 && p.chars().all(|c| c.is_ascii_digit()) {
        Ok(p.to_string())
    } else {
        Err(ApiError::bad_request(
            "รหัส PIN กู้คืนบัญชีต้องเป็นตัวเลข 6 หลัก",
        ))
    }
}

fn normalize_backup_code(raw: &str) -> String {
    let alnum: String = raw
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    if alnum.len() == 12 && alnum.starts_with("BCRC") {
        format!("BCRC-{}-{}", &alnum[4..8], &alnum[8..12])
    } else if alnum.len() == 8 {
        format!("BCRC-{}-{}", &alnum[0..4], &alnum[4..8])
    } else {
        raw.trim().to_ascii_uppercase()
    }
}

fn generate_backup_codes(count: usize) -> Vec<String> {
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let bytes = *Uuid::new_v4().as_bytes();
        let mut chars = String::with_capacity(8);
        for b in &bytes[..8] {
            let idx = (*b as usize) & 31;
            chars.push(RECOVERY_CHARSET[idx] as char);
        }
        out.push(format!("BCRC-{}-{}", &chars[0..4], &chars[4..8]));
    }
    out
}

fn hash_secret_salted(secret: &str) -> String {
    let salt = &Uuid::new_v4().simple().to_string()[..16];
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(b":");
    hasher.update(secret.as_bytes());
    let digest = hex::encode(hasher.finalize());
    format!("{salt}:{digest}")
}

fn verify_secret_salted(secret: &str, stored: &str) -> bool {
    let Some((salt, expected_hex)) = stored.trim().split_once(':') else {
        return false;
    };
    if salt.is_empty() || expected_hex.is_empty() {
        return false;
    }
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(b":");
    hasher.update(secret.as_bytes());
    let actual_hex = hex::encode(hasher.finalize());
    let a = actual_hex.as_bytes();
    let b = expected_hex.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    a.iter()
        .zip(b.iter())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

fn check_recovery_lockout(user: &UserDoc, now: DateTime<Utc>) -> Result<(), ApiError> {
    if let Some(ref until_str) = user.recovery_locked_until {
        if let Ok(dt) = DateTime::parse_from_rfc3339(until_str.trim()) {
            if dt.with_timezone(&Utc) > now {
                return Err(ApiError {
                    status: StatusCode::TOO_MANY_REQUESTS,
                    message: "กรอกรหัสกู้คืนผิดเกินกำหนด บัญชีถูกล็อกการกู้คืนชั่วคราว 15 นาที"
                        .to_string(),
                });
            }
        }
    }
    Ok(())
}

async fn record_failed_recovery_attempt(
    users_coll: &mongodb::Collection<UserDoc>,
    user: &mut UserDoc,
    now: DateTime<Utc>,
) -> ApiError {
    user.recovery_failed_attempts = user.recovery_failed_attempts.saturating_add(1);
    if user.recovery_failed_attempts >= 5 {
        let lock_until = (now + Duration::minutes(15)).to_rfc3339();
        user.recovery_locked_until = Some(lock_until.clone());
        let _ = users_coll
            .update_one(
                doc! { "_id": &user.id },
                doc! {
                    "$set": {
                        "recovery_failed_attempts": user.recovery_failed_attempts,
                        "recovery_locked_until": &lock_until,
                    }
                },
            )
            .await;
        return ApiError {
            status: StatusCode::TOO_MANY_REQUESTS,
            message: "กรอกรหัสกู้คืนผิดเกิน 5 ครั้ง บัญชีถูกล็อกการกู้คืนชั่วคราว 15 นาที"
                .to_string(),
        };
    }

    let _ = users_coll
        .update_one(
            doc! { "_id": &user.id },
            doc! {
                "$set": {
                    "recovery_failed_attempts": user.recovery_failed_attempts,
                }
            },
        )
        .await;
    ApiError::unauthorized("รหัส PIN หรือรหัสกู้คืนสำรองไม่ถูกต้อง")
}

async fn record_recovery_log(
    state: &AppState,
    user_id: &str,
    action: &str,
    method: &str,
    detail_masked: String,
) {
    let entry = AccountRecoveryLogDoc {
        id: format!("reclog_{}", Uuid::new_v4().simple()),
        user_id: user_id.to_string(),
        action: action.to_string(),
        method: method.to_string(),
        detail_masked,
        created_at: Utc::now().to_rfc3339(),
    };
    let _ = state
        .db
        .collection::<AccountRecoveryLogDoc>("account_recovery_logs")
        .insert_one(&entry)
        .await;
}

async fn lookup_user_for_recovery_identifier(
    users_coll: &mongodb::Collection<UserDoc>,
    raw_identifier: &str,
) -> Result<Option<UserDoc>, ApiError> {
    let q = raw_identifier.trim();
    if q.is_empty() {
        return Err(ApiError::bad_request(
            "กรุณาระบุเบอร์โทรศัพท์เดิม, BC ID หรืออีเมลของบัญชีที่ต้องการกู้คืน",
        ));
    }

    if let Ok(norm_phone) = sms::normalize_thai_phone(q) {
        if let Some(u) = users_coll
            .find_one(doc! {
                "phone": &norm_phone,
                "is_oa_bot": { "$ne": true },
                "_id": { "$nin": ["user_ai", "user_official"] },
            })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
        {
            return Ok(Some(u));
        }
    }

    if !q.starts_with('@') && q.contains('@') {
        let clean_email = q.to_lowercase();
        if let Some(u) = users_coll
            .find_one(doc! {
                "email": &clean_email,
                "is_oa_bot": { "$ne": true },
                "_id": { "$nin": ["user_ai", "user_official"] },
            })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
        {
            return Ok(Some(u));
        }
    }

    let clean_id = q.trim_start_matches('@');
    let rx = Regex {
        pattern: format!("^@?{}$", regex_escape(clean_id)),
        options: "i".to_string(),
    };
    users_coll
        .find_one(doc! {
            "bc_id": rx,
            "is_oa_bot": { "$ne": true },
            "_id": { "$nin": ["user_ai", "user_official"] },
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))
}

fn match_pin_or_backup_code(user: &UserDoc, raw_secret: &str) -> Result<Option<usize>, ()> {
    let trimmed = raw_secret.trim();
    if trimmed.is_empty() {
        return Err(());
    }
    if trimmed.len() == 6 && trimmed.chars().all(|c| c.is_ascii_digit()) {
        if let Some(ref pin_hash) = user.recovery_pin_hash {
            if verify_secret_salted(trimmed, pin_hash) {
                return Ok(None);
            }
        }
        return Err(());
    }
    let normalized_code = normalize_backup_code(trimmed);
    for (idx, code_hash) in user.recovery_code_hashes.iter().enumerate() {
        if verify_secret_salted(&normalized_code, code_hash) {
            return Ok(Some(idx));
        }
    }
    Err(())
}

async fn resolve_google_for_recovery(
    state: &AppState,
    id_token: Option<&str>,
    access_token: Option<&str>,
    oauth_state: Option<&str>,
) -> Result<(String, String, Option<String>), ApiError> {
    if let Some(st_raw) = oauth_state.map(str::trim).filter(|s| !s.is_empty()) {
        let coll = state
            .db
            .collection::<GoogleOAuthStateDoc>("google_oauth_states");
        let st_doc = coll
            .find_one(doc! { "_id": st_raw })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .ok_or_else(|| ApiError::bad_request("ไม่พบสถานะการยืนยัน Google สำหรับกู้คืนบัญชี"))?;

        if st_doc.mode != "recover" {
            return Err(ApiError::bad_request(
                "รายการยืนยัน Google นี้ไม่ได้อยู่ในโหมดกู้คืนบัญชี",
            ));
        }
        if st_doc.status == "consumed" {
            return Err(ApiError::bad_request(
                "รายการยืนยัน Google นี้ถูกใช้งานไปแล้ว กรุณายืนยันใหม่อีกครั้ง",
            ));
        }
        if st_doc.status != "verified_for_recovery" {
            return Err(ApiError::unauthorized(
                "การยืนยันบัญชี Google ยังไม่เสร็จสมบูรณ์",
            ));
        }
        if let Ok(exp_dt) = DateTime::parse_from_rfc3339(&st_doc.expires_at) {
            if exp_dt.with_timezone(&Utc) < Utc::now() {
                return Err(ApiError::bad_request(
                    "รายการยืนยัน Google สำหรับกู้คืนบัญชีหมดอายุแล้ว",
                ));
            }
        }
        let sub = st_doc
            .verified_google_sub
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| ApiError::unauthorized("ไม่พบรหัสยืนยัน sub จาก Google"))?;
        let email = st_doc
            .verified_google_email
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| ApiError::unauthorized("ไม่พบอีเมลที่ยืนยันแล้วจาก Google"))?;
        return Ok((sub, email, Some(st_doc.id)));
    }

    let profile = verify_google_token(state, id_token, access_token).await?;
    Ok((profile.sub, profile.email, None))
}

#[derive(Debug, Deserialize)]
pub struct SetupRecoveryPayload {
    pub recovery_pin: String,
    #[serde(default)]
    pub current_pin: Option<String>,
    #[serde(default)]
    pub regenerate_codes: Option<bool>,
}

pub async fn setup_recovery_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<SetupRecoveryPayload>,
) -> Result<Json<Value>, ApiError> {
    let pin = validate_six_digit_pin(&payload.recovery_pin)?;
    let users_coll = state.db.collection::<UserDoc>("users");
    let mut me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let now = Utc::now();
    check_recovery_lockout(&me, now)?;

    if let Some(ref existing_hash) = me.recovery_pin_hash.clone() {
        if !existing_hash.trim().is_empty() {
            let cur = payload.current_pin.as_deref().unwrap_or("").trim();
            if cur.is_empty() || !verify_secret_salted(cur, existing_hash) {
                return Err(record_failed_recovery_attempt(&users_coll, &mut me, now).await);
            }
        }
    }

    let should_regen =
        me.recovery_code_hashes.is_empty() || payload.regenerate_codes.unwrap_or(true);
    let backup_codes = if should_regen {
        let plain_codes = generate_backup_codes(6);
        me.recovery_code_hashes = plain_codes
            .iter()
            .map(|c| hash_secret_salted(&normalize_backup_code(c)))
            .collect();
        plain_codes
    } else {
        Vec::new()
    };

    let new_pin_hash = hash_secret_salted(&pin);
    me.recovery_pin_hash = Some(new_pin_hash.clone());
    me.recovery_failed_attempts = 0;
    me.recovery_locked_until = None;

    users_coll
        .update_one(
            doc! { "_id": &me.id },
            doc! {
                "$set": {
                    "recovery_pin_hash": &new_pin_hash,
                    "recovery_code_hashes": &me.recovery_code_hashes,
                    "recovery_failed_attempts": 0_u32,
                    "recovery_locked_until": bson::Bson::Null,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    record_recovery_log(
        &state,
        &me.id,
        "setup_recovery_pin",
        "authenticated",
        format!("รหัสสำรองคงเหลือ {} ชุด", me.recovery_code_hashes.len()),
    )
    .await;

    Ok(Json(json!({
        "user": UserDto::from(me),
        "backup_codes": backup_codes,
    })))
}

pub async fn list_recovery_logs_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let coll = state
        .db
        .collection::<AccountRecoveryLogDoc>("account_recovery_logs");
    let docs: Vec<AccountRecoveryLogDoc> = coll
        .find(doc! { "user_id": &auth.user_id })
        .sort(doc! { "created_at": -1 })
        .limit(20)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let logs: Vec<Value> = docs
        .into_iter()
        .map(|d| {
            json!({
                "id": d.id,
                "user_id": d.user_id,
                "action": d.action,
                "method": d.method,
                "detail_masked": d.detail_masked,
                "created_at": d.created_at,
            })
        })
        .collect();

    Ok(Json(json!({ "logs": logs })))
}

#[derive(Debug, Deserialize)]
pub struct RecoverChangePhonePayload {
    pub method: String, // "google" | "pin_or_code"
    #[serde(default)]
    pub google_id_token: Option<String>,
    #[serde(default)]
    pub google_access_token: Option<String>,
    #[serde(default)]
    pub google_oauth_state: Option<String>,
    #[serde(default)]
    pub identifier: Option<String>,
    #[serde(default)]
    pub recovery_secret: Option<String>,
    pub new_phone_challenge_id: String,
    pub new_phone_otp_code: String,
    #[serde(default)]
    pub new_phone_ref_code: Option<String>,
    #[serde(default)]
    pub revoke_other_sessions: Option<bool>,
}

pub async fn recover_change_phone_handler(
    State(state): State<AppState>,
    Json(payload): Json<RecoverChangePhonePayload>,
) -> Result<Json<Value>, ApiError> {
    let method = payload.method.trim().to_lowercase();
    let users_coll = state.db.collection::<UserDoc>("users");
    let now = Utc::now();

    let (mut user, matched_code_idx, oauth_state_to_consume, method_label) = match method.as_str() {
        "google" => {
            let (g_sub, g_email, st_id) = resolve_google_for_recovery(
                &state,
                payload.google_id_token.as_deref(),
                payload.google_access_token.as_deref(),
                payload.google_oauth_state.as_deref(),
            )
            .await?;

            let u = users_coll
                .find_one(doc! {
                    "is_oa_bot": { "$ne": true },
                    "_id": { "$nin": ["user_ai", "user_official"] },
                    "$or": [
                        { "google_id": &g_sub },
                        { "email": &g_email, "email_verified": true },
                    ]
                })
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?
                .ok_or_else(|| {
                    ApiError::not_found("ไม่พบบัญชีผู้ใช้ที่เชื่อมกับ Gmail นี้ในระบบ")
                })?;

            check_recovery_lockout(&u, now)?;
            (u, None, st_id, "google_oauth".to_string())
        }
        "pin_or_code" => {
            let ident = payload.identifier.as_deref().unwrap_or("");
            let mut u = lookup_user_for_recovery_identifier(&users_coll, ident)
                .await?
                .ok_or_else(|| ApiError::not_found("ไม่พบบัญชีผู้ใช้จากข้อมูลที่ระบุ"))?;

            check_recovery_lockout(&u, now)?;

            let secret = payload.recovery_secret.as_deref().unwrap_or("");
            match match_pin_or_backup_code(&u, secret) {
                Ok(code_idx) => {
                    let lbl = if code_idx.is_some() {
                        "backup_code".to_string()
                    } else {
                        "recovery_pin".to_string()
                    };
                    (u, code_idx, None, lbl)
                }
                Err(()) => {
                    return Err(record_failed_recovery_attempt(&users_coll, &mut u, now).await);
                }
            }
        }
        _ => {
            return Err(ApiError::bad_request(
                "วิธีกู้คืนบัญชี (method) ต้องเป็น google หรือ pin_or_code",
            ));
        }
    };

    let otp_session = verify_otp_challenge(
        &state,
        &payload.new_phone_challenge_id,
        &payload.new_phone_otp_code,
        payload.new_phone_ref_code.as_deref(),
    )
    .await?;

    if let Some(_conflict) = users_coll
        .find_one(doc! {
            "phone": &otp_session.phone,
            "_id": { "$ne": &user.id },
            "is_oa_bot": { "$ne": true },
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        return Err(ApiError::bad_request(
            "เบอร์มือถือใหม่นี้ถูกเชื่อมกับบัญชีผู้ใช้อื่นแล้ว",
        ));
    }

    let old_phone_masked = if user.phone.trim().is_empty() {
        "ไม่มีเบอร์เดิม".to_string()
    } else {
        sms::mask_phone(&user.phone)
    };

    if let Some(idx) = matched_code_idx {
        if idx < user.recovery_code_hashes.len() {
            user.recovery_code_hashes.remove(idx);
        }
    }

    user.phone = otp_session.phone;
    user.phone_verified = true;
    user.recovery_failed_attempts = 0;
    user.recovery_locked_until = None;
    let recovered_at = Utc::now().to_rfc3339();
    user.last_recovered_at = Some(recovered_at.clone());

    if payload.revoke_other_sessions.unwrap_or(true) {
        user.token_version = user.token_version.saturating_add(1);
        state.set_token_version(&user.id, user.token_version);
    }

    users_coll
        .update_one(
            doc! { "_id": &user.id },
            doc! {
                "$set": {
                    "phone": &user.phone,
                    "phone_verified": true,
                    "recovery_code_hashes": &user.recovery_code_hashes,
                    "recovery_failed_attempts": 0_u32,
                    "recovery_locked_until": bson::Bson::Null,
                    "token_version": user.token_version,
                    "last_recovered_at": &recovered_at,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    if let Some(st_id) = oauth_state_to_consume {
        let _ = state
            .db
            .collection::<GoogleOAuthStateDoc>("google_oauth_states")
            .update_one(
                doc! { "_id": st_id },
                doc! { "$set": { "status": "consumed" } },
            )
            .await;
    }

    record_recovery_log(
        &state,
        &user.id,
        "recover_change_phone",
        &method_label,
        format!("{} -> {}", old_phone_masked, sms::mask_phone(&user.phone)),
    )
    .await;

    let jwt_subject = if user.email.is_empty() {
        &user.phone
    } else {
        &user.email
    };
    let token = create_jwt_versioned(
        &user.id,
        jwt_subject,
        &user.role,
        user.token_version,
        &state.config.jwt_secret,
    )
    .map_err(ApiError::internal)?;

    Ok(Json(json!({
        "token": token,
        "user": UserDto::from(user),
        "recovered": true,
    })))
}

#[derive(Debug, Deserialize)]
pub struct RecoverChangeGooglePayload {
    pub method: String, // "phone_otp" | "pin_or_code"
    #[serde(default)]
    pub phone_challenge_id: Option<String>,
    #[serde(default)]
    pub phone_otp_code: Option<String>,
    #[serde(default)]
    pub phone_ref_code: Option<String>,
    #[serde(default)]
    pub identifier: Option<String>,
    #[serde(default)]
    pub recovery_secret: Option<String>,
    #[serde(default)]
    pub new_google_id_token: Option<String>,
    #[serde(default)]
    pub new_google_access_token: Option<String>,
    #[serde(default)]
    pub new_google_oauth_state: Option<String>,
    #[serde(default)]
    pub revoke_other_sessions: Option<bool>,
}

pub async fn recover_change_google_handler(
    State(state): State<AppState>,
    Json(payload): Json<RecoverChangeGooglePayload>,
) -> Result<Json<Value>, ApiError> {
    let method = payload.method.trim().to_lowercase();
    let users_coll = state.db.collection::<UserDoc>("users");
    let now = Utc::now();

    let (mut user, matched_code_idx, new_sub, new_email, oauth_state_to_consume, method_label) =
        match method.as_str() {
            "pin_or_code" => {
                let ident = payload.identifier.as_deref().unwrap_or("");
                let mut u = lookup_user_for_recovery_identifier(&users_coll, ident)
                    .await?
                    .ok_or_else(|| ApiError::not_found("ไม่พบบัญชีผู้ใช้จากข้อมูลที่ระบุ"))?;

                check_recovery_lockout(&u, now)?;

                let secret = payload.recovery_secret.as_deref().unwrap_or("");
                let code_idx = match match_pin_or_backup_code(&u, secret) {
                    Ok(idx) => idx,
                    Err(()) => {
                        return Err(record_failed_recovery_attempt(&users_coll, &mut u, now).await);
                    }
                };
                let (sub, email, st_id) = resolve_google_for_recovery(
                    &state,
                    payload.new_google_id_token.as_deref(),
                    payload.new_google_access_token.as_deref(),
                    payload.new_google_oauth_state.as_deref(),
                )
                .await?;
                let lbl = if code_idx.is_some() {
                    "backup_code".to_string()
                } else {
                    "recovery_pin".to_string()
                };
                (u, code_idx, sub, email, st_id, lbl)
            }
            "phone_otp" => {
                let (sub, email, st_id) = resolve_google_for_recovery(
                    &state,
                    payload.new_google_id_token.as_deref(),
                    payload.new_google_access_token.as_deref(),
                    payload.new_google_oauth_state.as_deref(),
                )
                .await?;
                let cid = payload.phone_challenge_id.as_deref().unwrap_or("");
                let code = payload.phone_otp_code.as_deref().unwrap_or("");
                let otp_session = verify_otp_challenge(
                    &state,
                    cid,
                    code,
                    payload.phone_ref_code.as_deref(),
                )
                .await?;

                let u = users_coll
                    .find_one(doc! {
                        "phone": &otp_session.phone,
                        "is_oa_bot": { "$ne": true },
                        "_id": { "$nin": ["user_ai", "user_official"] },
                    })
                    .await
                    .map_err(|e| ApiError::internal(e.to_string()))?
                    .ok_or_else(|| {
                        ApiError::not_found("ไม่พบบัญชีผู้ใช้ที่เชื่อมกับเบอร์โทรศัพท์นี้")
                    })?;

                check_recovery_lockout(&u, now)?;
                (u, None, sub, email, st_id, "phone_otp".to_string())
            }
            _ => {
                return Err(ApiError::bad_request(
                    "วิธีกู้คืนบัญชี (method) ต้องเป็น phone_otp หรือ pin_or_code",
                ));
            }
        };

    if let Some(_conflict) = users_coll
        .find_one(doc! {
            "_id": { "$ne": &user.id },
            "is_oa_bot": { "$ne": true },
            "$or": [
                { "google_id": &new_sub },
                { "email": &new_email, "email_verified": true },
            ]
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        return Err(ApiError::bad_request(
            "บัญชี Gmail ใหม่นี้ถูกเชื่อมกับบัญชีผู้ใช้อื่นแล้ว",
        ));
    }

    let old_email_masked = if user.email.trim().is_empty() {
        "ไม่มีอีเมลเดิม".to_string()
    } else {
        mask_email(&user.email)
    };

    if let Some(idx) = matched_code_idx {
        if idx < user.recovery_code_hashes.len() {
            user.recovery_code_hashes.remove(idx);
        }
    }

    user.email = new_email;
    user.email_verified = true;
    user.google_id = Some(new_sub);
    user.recovery_failed_attempts = 0;
    user.recovery_locked_until = None;
    let recovered_at = Utc::now().to_rfc3339();
    user.last_recovered_at = Some(recovered_at.clone());

    if payload.revoke_other_sessions.unwrap_or(true) {
        user.token_version = user.token_version.saturating_add(1);
        state.set_token_version(&user.id, user.token_version);
    }

    users_coll
        .update_one(
            doc! { "_id": &user.id },
            doc! {
                "$set": {
                    "email": &user.email,
                    "email_verified": true,
                    "google_id": &user.google_id,
                    "recovery_code_hashes": &user.recovery_code_hashes,
                    "recovery_failed_attempts": 0_u32,
                    "recovery_locked_until": bson::Bson::Null,
                    "token_version": user.token_version,
                    "last_recovered_at": &recovered_at,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    if let Some(st_id) = oauth_state_to_consume {
        let _ = state
            .db
            .collection::<GoogleOAuthStateDoc>("google_oauth_states")
            .update_one(
                doc! { "_id": st_id },
                doc! { "$set": { "status": "consumed" } },
            )
            .await;
    }

    record_recovery_log(
        &state,
        &user.id,
        "recover_change_google",
        &method_label,
        format!("{} -> {}", old_email_masked, mask_email(&user.email)),
    )
    .await;

    let token = create_jwt_versioned(
        &user.id,
        &user.email,
        &user.role,
        user.token_version,
        &state.config.jwt_secret,
    )
    .map_err(ApiError::internal)?;

    Ok(Json(json!({
        "token": token,
        "user": UserDto::from(user),
        "recovered": true,
    })))
}

// =============================================================================
// Admin Auth Settings (SMSMKT + Google Client ID + Credit Check)
// =============================================================================

async fn build_auth_settings_dto(state: &AppState) -> Result<AuthSettingsDto, String> {
    let eff = get_effective_auth_settings(state).await?;
    let (has_api, masked_api) = mask_secret_key(&eff.smsmkt_api_key);
    let (has_sec, masked_sec) = mask_secret_key(&eff.smsmkt_secret_key);
    let (credit_info, credit_error) = if has_api && has_sec {
        match sms::check_credit(
            &state.minio.http,
            &state.config.smsmkt_base_url,
            &eff.smsmkt_api_key,
            &eff.smsmkt_secret_key,
        )
        .await
        {
            Ok(v) => (Some(v), None),
            Err(e) => (None, Some(e)),
        }
    } else {
        (None, Some("ยังไม่ได้ตั้งค่า SMSMKT API/Secret Key".to_string()))
    };

    Ok(AuthSettingsDto {
        smsmkt_has_keys: has_api && has_sec,
        smsmkt_masked_api_key: masked_api,
        smsmkt_masked_secret_key: masked_sec,
        smsmkt_project_key: eff.smsmkt_project_key.clone(),
        smsmkt_sender_name: eff.smsmkt_sender_name.clone(),
        phone_otp_ready: has_api
            && has_sec
            && (!eff.smsmkt_project_key.trim().is_empty()
                || !eff.smsmkt_sender_name.trim().is_empty()),
        google_client_id: eff.google_client_id.clone(),
        google_enabled: !eff.google_client_id.trim().is_empty(),
        credit_info,
        credit_error,
        updated_at: eff.updated_at,
    })
}

pub async fn admin_get_auth_settings_handler(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<AuthSettingsDto>, ApiError> {
    let dto = build_auth_settings_dto(&state)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct UpdateAuthSettingsRequest {
    pub smsmkt_api_key: Option<String>,
    pub smsmkt_secret_key: Option<String>,
    pub smsmkt_project_key: Option<String>,
    pub smsmkt_sender_name: Option<String>,
    pub google_client_id: Option<String>,
}

pub async fn admin_update_auth_settings_handler(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(payload): Json<UpdateAuthSettingsRequest>,
) -> Result<Json<AuthSettingsDto>, ApiError> {
    let coll = state.db.collection::<AuthSettingsDoc>("auth_settings");
    let current = coll
        .find_one(doc! { "_id": "default" })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let mut doc_item = current.unwrap_or_else(|| AuthSettingsDoc {
        id: "default".to_string(),
        smsmkt_api_key: String::new(),
        smsmkt_secret_key: String::new(),
        smsmkt_project_key: String::new(),
        smsmkt_sender_name: String::new(),
        google_client_id: String::new(),
        updated_at: Utc::now().to_rfc3339(),
    });

    if let Some(ref k) = payload.smsmkt_api_key {
        let t = k.trim();
        if !t.is_empty() && !t.starts_with("****") {
            doc_item.smsmkt_api_key = t.to_string();
        }
    }
    if let Some(ref k) = payload.smsmkt_secret_key {
        let t = k.trim();
        if !t.is_empty() && !t.starts_with("****") {
            doc_item.smsmkt_secret_key = t.to_string();
        }
    }
    if let Some(ref pk) = payload.smsmkt_project_key {
        doc_item.smsmkt_project_key = pk.trim().to_string();
    }
    if let Some(ref sn) = payload.smsmkt_sender_name {
        doc_item.smsmkt_sender_name = sn.trim().to_string();
    }
    if let Some(ref gc) = payload.google_client_id {
        doc_item.google_client_id = gc.trim().to_string();
    }
    doc_item.updated_at = Utc::now().to_rfc3339();

    coll.replace_one(doc! { "_id": "default" }, &doc_item)
        .upsert(true)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = build_auth_settings_dto(&state)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(dto))
}

// =============================================================================
// Profile, Friends & Search
// =============================================================================

pub async fn me_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let user = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let dto = UserDto::from(user);
    let mut val = serde_json::to_value(&dto).unwrap_or_else(|_| json!({}));
    if let Some(obj) = val.as_object_mut() {
        obj.insert(
            "user".to_string(),
            serde_json::to_value(&dto).unwrap_or_default(),
        );
    }
    Ok(Json(val))
}

/// Normalize and validate a custom BC ID (e.g. `jead` or `@Jead` -> `@jead`).
pub fn normalize_and_validate_bc_id(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("กรุณากรอก BC ID ที่ต้องการ".to_string());
    }
    let stripped = trimmed.strip_prefix('@').unwrap_or(trimmed).trim();
    if stripped.is_empty() {
        return Err("กรุณากรอกชื่อ BC ID หลังเครื่องหมาย @".to_string());
    }
    if !stripped.is_ascii() {
        return Err("BC ID ใช้ได้เฉพาะภาษาอังกฤษ a-z, ตัวเลข 0-9 และ . _ - เท่านั้น".to_string());
    }
    let handle = stripped.to_ascii_lowercase();
    if handle.len() < 3 || handle.len() > 30 {
        return Err("BC ID ต้องมีความยาว 3–30 ตัวอักษร (ไม่นับ @)".to_string());
    }
    if !handle
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '_' || c == '-')
    {
        return Err("BC ID ใช้ได้เฉพาะ a-z, 0-9, จุด (.), _ และ - เท่านั้น".to_string());
    }
    let bytes = handle.as_bytes();
    let is_alnum = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    if !is_alnum(bytes[0]) || !is_alnum(bytes[bytes.len() - 1]) {
        return Err("BC ID ต้องขึ้นต้นและลงท้ายด้วยตัวอักษรภาษาอังกฤษหรือตัวเลข".to_string());
    }
    if handle.contains("..") {
        return Err("BC ID ห้ามมีจุด (.) ติดกัน 2 ตัว".to_string());
    }
    if matches!(
        handle.as_str(),
        "ai" | "bc.ai" | "bc.official" | "system" | "all" | "everyone"
    ) {
        return Err("BC ID นี้ถูกสงวนไว้สำหรับระบบ กรุณาใช้ชื่ออื่น".to_string());
    }
    Ok(format!("@{}", handle))
}

/// Check case-insensitively whether a normalized `@bc_id` is already taken by another user or OA shop.
pub async fn is_bc_id_taken(
    db: &mongodb::Database,
    normalized_bc_id: &str,
    exclude_user_id: Option<&str>,
) -> Result<bool, ApiError> {
    let handle = normalized_bc_id.trim().trim_start_matches('@');
    let rx = Regex {
        pattern: format!("^@?{}$", regex_escape(handle)),
        options: "i".to_string(),
    };
    let mut user_filter = doc! { "bc_id": rx.clone() };
    if let Some(uid) = exclude_user_id {
        user_filter.insert("_id", doc! { "$ne": uid });
    }
    let user_hit = db
        .collection::<bson::Document>("users")
        .find_one(user_filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    if user_hit.is_some() {
        return Ok(true);
    }

    let oa_hit = db
        .collection::<bson::Document>("oa_accounts")
        .find_one(doc! { "handle": rx })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(oa_hit.is_some())
}

async fn allocate_unique_bc_id(db: &mongodb::Database, base_prefix: &str) -> Result<String, ApiError> {
    let clean_prefix: String = base_prefix
        .to_ascii_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '.' || *c == '_')
        .collect::<String>()
        .trim_matches(|c| c == '.' || c == '_')
        .chars()
        .take(18)
        .collect();
    let prefix = if clean_prefix.is_empty() {
        "bc".to_string()
    } else {
        clean_prefix
    };

    for _ in 0..8 {
        let suffix = &Uuid::new_v4().simple().to_string()[..4];
        let raw = format!("@{}_{}.bc", prefix, suffix);
        let candidate = normalize_and_validate_bc_id(&raw).unwrap_or_else(|_| format!("@bc_{}", suffix));
        if !is_bc_id_taken(db, &candidate, None).await? {
            return Ok(candidate);
        }
    }
    let full = &Uuid::new_v4().simple().to_string()[..10];
    Ok(format!("@bc_{}", full))
}

#[derive(Debug, Deserialize)]
pub struct CheckBcIdQuery {
    pub bc_id: Option<String>,
}

pub async fn check_bc_id_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<CheckBcIdQuery>,
) -> Result<Json<Value>, ApiError> {
    let raw = query.bc_id.unwrap_or_default();
    let normalized = match normalize_and_validate_bc_id(&raw) {
        Ok(v) => v,
        Err(msg) => {
            return Ok(Json(json!({
                "valid": false,
                "available": false,
                "is_current": false,
                "normalized_bc_id": "",
                "message": msg,
            })));
        }
    };

    let me = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    if let Some(ref u) = me {
        let current_norm = format!(
            "@{}",
            u.bc_id.trim().trim_start_matches('@').to_ascii_lowercase()
        );
        if current_norm == normalized {
            return Ok(Json(json!({
                "valid": true,
                "available": true,
                "is_current": true,
                "normalized_bc_id": normalized,
                "message": "นี่คือ BC ID ปัจจุบันของคุณ",
            })));
        }
    }

    let taken = is_bc_id_taken(&state.db, &normalized, Some(&auth.user_id)).await?;
    Ok(Json(json!({
        "valid": true,
        "available": !taken,
        "is_current": false,
        "normalized_bc_id": normalized,
        "message": if taken {
            "BC ID นี้มีผู้ใช้งานแล้ว กรุณาใช้ชื่ออื่น".to_string()
        } else {
            format!("สามารถใช้ {} ได้", normalized)
        },
    })))
}

#[derive(Debug, Deserialize)]
pub struct UpdateProfileRequest {
    pub display_name: Option<String>,
    pub bc_id: Option<String>,
    pub status_message: Option<String>,
    pub avatar_url: Option<String>,
    pub role: Option<String>,
    pub department: Option<String>,
    pub job_title: Option<String>,
    pub allow_add_by_phone: Option<bool>,
    pub allow_add_by_id: Option<bool>,
    pub allow_add_by_email: Option<bool>,
    pub notify_preview: Option<bool>,
    pub notify_on_mention: Option<bool>,
    pub dnd_mode: Option<String>,
    pub dnd_until: Option<String>,
}

pub async fn update_profile_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<UpdateProfileRequest>,
) -> Result<Json<Value>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let mut user = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    if let Some(name) = payload.display_name {
        if !name.trim().is_empty() {
            user.display_name = name.trim().to_string();
        }
    }
    if let Some(raw_bc_id) = payload.bc_id {
        if !raw_bc_id.trim().is_empty() {
            let current_norm = format!(
                "@{}",
                user.bc_id.trim().trim_start_matches('@').to_ascii_lowercase()
            );
            let normalized =
                normalize_and_validate_bc_id(&raw_bc_id).map_err(ApiError::bad_request)?;
            if normalized != current_norm {
                if user.id == "user_ai" || user.id == "user_official" || user.is_oa_bot {
                    return Err(ApiError::forbidden(
                        "ไม่สามารถเปลี่ยน BC ID ของบัญชีระบบได้",
                    ));
                }
                if is_bc_id_taken(&state.db, &normalized, Some(&user.id)).await? {
                    return Err(ApiError::conflict(
                        "BC ID นี้มีผู้ใช้งานแล้ว กรุณาใช้ชื่ออื่น",
                    ));
                }
            }
            user.bc_id = normalized;
        }
    }
    if let Some(status) = payload.status_message {
        user.status_message = status.trim().to_string();
    }
    if let Some(avatar) = payload.avatar_url {
        if !avatar.trim().is_empty() {
            user.avatar_url = avatar.trim().to_string();
        }
    }
    if let Some(role) = payload.role {
        if (role == "admin" || role == "user") && auth.role == "admin" {
            user.role = role;
        }
    }
    if let Some(dept) = payload.department {
        if !dept.trim().is_empty() {
            user.department = dept.trim().to_string();
        }
    }
    if let Some(title) = payload.job_title {
        if !title.trim().is_empty() {
            user.job_title = title.trim().to_string();
        }
    }
    if let Some(v) = payload.allow_add_by_phone {
        user.allow_add_by_phone = v;
    }
    if let Some(v) = payload.allow_add_by_id {
        user.allow_add_by_id = v;
    }
    if let Some(v) = payload.allow_add_by_email {
        user.allow_add_by_email = v;
    }
    if let Some(v) = payload.notify_preview {
        user.notify_preview = v;
    }
    if let Some(v) = payload.notify_on_mention {
        user.notify_on_mention = v;
    }

    let now = Utc::now();
    if let Some(ref mode) = payload.dnd_mode {
        let trimmed = mode.trim();
        if !trimmed.is_empty() {
            match compute_timed_window(trimmed, now) {
                Some((false, _)) => user.dnd_until = None,
                Some((true, Some(until))) => user.dnd_until = Some(until),
                Some((true, None)) => {
                    user.dnd_until = Some((now + Duration::days(3650)).to_rfc3339());
                }
                None => {
                    return Err(ApiError::bad_request(
                        "โหมดห้ามรบกวน (dnd_mode) ต้องเป็น off, 1h, 8h หรือ until_8am",
                    ));
                }
            }
        }
    } else if let Some(raw_until) = payload.dnd_until {
        let trimmed = raw_until.trim();
        if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("off") {
            user.dnd_until = None;
        } else if DateTime::parse_from_rfc3339(trimmed).is_ok() {
            user.dnd_until = Some(trimmed.to_string());
        } else {
            return Err(ApiError::bad_request("รูปแบบเวลา dnd_until ไม่ถูกต้อง"));
        }
    }

    users_coll
        .update_one(
            doc! { "_id": &user.id },
            doc! {
                "$set": {
                    "display_name": &user.display_name,
                    "bc_id": &user.bc_id,
                    "status_message": &user.status_message,
                    "avatar_url": &user.avatar_url,
                    "role": &user.role,
                    "department": &user.department,
                    "job_title": &user.job_title,
                    "allow_add_by_phone": user.allow_add_by_phone,
                    "allow_add_by_id": user.allow_add_by_id,
                    "allow_add_by_email": user.allow_add_by_email,
                    "notify_preview": user.notify_preview,
                    "notify_on_mention": user.notify_on_mention,
                    "dnd_until": &user.dnd_until,
                }
            },
        )
        .await
        .map_err(|e| {
            let msg = e.to_string();
            if msg.contains("E11000") || msg.contains("duplicate key") {
                ApiError::conflict("BC ID นี้มีผู้ใช้งานแล้ว กรุณาใช้ชื่ออื่น")
            } else {
                ApiError::internal(msg)
            }
        })?;

    let dto = UserDto::from(user);
    let mut val = serde_json::to_value(&dto).unwrap_or_else(|_| json!({}));
    if let Some(obj) = val.as_object_mut() {
        obj.insert(
            "user".to_string(),
            serde_json::to_value(&dto).unwrap_or_default(),
        );
    }
    Ok(Json(val))
}

pub async fn reset_qr_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let mut user = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let new_qr = format!("BCQR_{}", Uuid::new_v4().simple());
    user.qr_token = new_qr.clone();

    users_coll
        .update_one(
            doc! { "_id": &user.id },
            doc! { "$set": { "qr_token": &new_qr } },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = UserDto::from(user);
    Ok(Json(json!({
        "qr_token": new_qr,
        "user": dto,
    })))
}

fn to_friend_dto(u: UserDoc, f: &FriendshipDoc) -> FriendDto {
    FriendDto {
        id: u.id,
        email: u.email,
        phone: u.phone,
        phone_verified: u.phone_verified,
        email_verified: u.email_verified,
        display_name: u.display_name,
        bc_id: u.bc_id,
        avatar_url: u.avatar_url,
        status_message: u.status_message,
        qr_token: u.qr_token,
        role: u.role,
        department: if u.department.is_empty() {
            "เพื่อน".to_string()
        } else {
            u.department
        },
        job_title: if u.job_title.is_empty() {
            "เพื่อน".to_string()
        } else {
            u.job_title
        },
        is_favorite: f.is_favorite,
        is_blocked: f.is_blocked,
        is_hidden: f.is_hidden,
    }
}

pub async fn list_friends_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<FriendDto>>, ApiError> {
    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");
    let users_coll = state.db.collection::<UserDoc>("users");

    let cursor = friends_coll
        .find(doc! { "user_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let friendships: Vec<FriendshipDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let friend_ids: Vec<String> = friendships.iter().map(|f| f.friend_id.clone()).collect();
    let user_cursor = users_coll
        .find(doc! { "_id": { "$in": &friend_ids } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let user_docs: Vec<UserDoc> = user_cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let user_map: HashMap<String, UserDoc> =
        user_docs.into_iter().map(|u| (u.id.clone(), u)).collect();

    let mut result = Vec::with_capacity(friendships.len());
    for f in &friendships {
        if let Some(u) = user_map.get(&f.friend_id).cloned() {
            if !u.is_oa_bot {
                result.push(to_friend_dto(u, f));
            }
        }
    }

    result.sort_by(|a, b| {
        a.is_blocked
            .cmp(&b.is_blocked)
            .then_with(|| a.is_hidden.cmp(&b.is_hidden))
            .then_with(|| b.is_favorite.cmp(&a.is_favorite))
            .then_with(|| a.display_name.cmp(&b.display_name))
    });

    Ok(Json(result))
}

#[derive(Debug, Deserialize)]
pub struct UpdateFriendRequest {
    pub is_favorite: Option<bool>,
    pub is_blocked: Option<bool>,
    pub is_hidden: Option<bool>,
}

pub async fn update_friend_handler(
    auth: AuthUser,
    Path(friend_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateFriendRequest>,
) -> Result<Json<FriendDto>, ApiError> {
    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");
    let users_coll = state.db.collection::<UserDoc>("users");

    let friend_user = users_coll
        .find_one(doc! { "_id": &friend_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลเพื่อนที่ระบุ"))?;

    let mut friendship = match friends_coll
        .find_one(doc! { "user_id": &auth.user_id, "friend_id": &friend_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        Some(f) => f,
        None => {
            let f = FriendshipDoc {
                id: Uuid::new_v4().to_string(),
                user_id: auth.user_id.clone(),
                friend_id: friend_id.clone(),
                is_favorite: false,
                is_blocked: false,
                is_hidden: false,
                created_at: Utc::now().to_rfc3339(),
            };
            friends_coll
                .insert_one(&f)
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?;
            f
        }
    };

    if let Some(fav) = payload.is_favorite {
        friendship.is_favorite = fav;
    }
    if let Some(blk) = payload.is_blocked {
        friendship.is_blocked = blk;
    }
    if let Some(hid) = payload.is_hidden {
        friendship.is_hidden = hid;
    }

    friends_coll
        .replace_one(doc! { "_id": &friendship.id }, &friendship)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(to_friend_dto(friend_user, &friendship)))
}

pub async fn remove_friend_handler(
    auth: AuthUser,
    Path(friend_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let fid = friend_id.trim();
    if fid.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุรหัสเพื่อนที่ต้องการลบ"));
    }
    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");
    friends_coll
        .delete_many(doc! { "user_id": &auth.user_id, "friend_id": fid })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(json!({
        "ok": true,
        "friend_id": fid,
    })))
}

/// Extracts a `BCQR_<token>` from a raw token string or deep-link/URL if present.
fn extract_qr_token_from_input(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let decoded = urlencoding::decode(trimmed)
        .map(|c| c.into_owned())
        .unwrap_or_else(|_| trimmed.to_string());
    let upper = decoded.to_uppercase();
    if let Some(idx) = upper.find("BCQR_") {
        let rest = &decoded[idx + 5..];
        let suffix: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
            .collect();
        if !suffix.is_empty() {
            return Some(format!("BCQR_{suffix}"));
        }
    }
    None
}

/// Extracts a clean digit-only phone search string (mapping Thai numerals `'๐'..='๙'` -> `'0'..='9'`,
/// stripping formatting characters `'-'`, `' '`, `'('`, `')'`, `'.'`, and converting leading `"66..."`
/// when total digits >= 4 to `"0..."`). Returns `None` if empty, contains no digits, or contains
/// alphabetic / non-phone characters.
fn extract_phone_digits_query(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut digits = String::with_capacity(trimmed.len());
    for raw_ch in trimmed.chars() {
        let ch = sms::thai_digit_to_ascii(raw_ch);
        if ch.is_ascii_digit() {
            digits.push(ch);
        } else if ch.is_whitespace()
            || matches!(
                ch,
                '+' | '-' | '(' | ')' | '.'
                    | '\u{200B}'..='\u{200F}'
                    | '\u{202A}'..='\u{202E}'
                    | '\u{FEFF}'
            )
        {
            continue;
        } else {
            return None;
        }
    }
    if digits.is_empty() {
        return None;
    }
    if digits.len() >= 4 && !digits.chars().all(|c| c == '6') {
        if let Some(rest) = digits.strip_prefix("66") {
            if rest.starts_with('0') {
                return Some(rest.to_string());
            }
            return Some(format!("0{rest}"));
        }
    }
    Some(digits)
}

#[derive(Debug, Deserialize)]
pub struct SearchUserQuery {
    pub q: Option<String>,
    pub by: Option<String>,
}

pub async fn search_users_handler(
    _auth: AuthUser,
    Query(query): Query<SearchUserQuery>,
    State(state): State<AppState>,
) -> Result<Json<Vec<UserDto>>, ApiError> {
    let q = query.q.unwrap_or_default().trim().to_string();
    let by_mode = query
        .by
        .as_deref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty());
    let users_coll = state.db.collection::<UserDoc>("users");

    if q.is_empty() {
        if by_mode.is_some() {
            return Ok(Json(Vec::new()));
        }
        let docs: Vec<UserDoc> = users_coll
            .find(doc! { "is_oa_bot": { "$ne": true } })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .try_collect()
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;
        return Ok(Json(docs.into_iter().map(UserDto::from).collect()));
    }

    let extracted_qr = extract_qr_token_from_input(&q);
    let norm_phone = sms::normalize_thai_phone(&q).ok();
    let digits_query = extract_phone_digits_query(&q);
    let escaped = regex_escape(&q);
    let rx = Regex {
        pattern: escaped,
        options: "i".to_string(),
    };

    let filter = match by_mode.as_deref() {
        Some("qr") => {
            let tok = extracted_qr.clone().unwrap_or_else(|| q.clone());
            doc! {
                "is_oa_bot": { "$ne": true },
                "qr_token": Regex {
                    pattern: format!("^{}$", regex_escape(&tok)),
                    options: "i".to_string(),
                }
            }
        }
        Some("phone") => {
            let mut or_clauses = vec![doc! { "phone": rx }];
            if let Some(ref np) = norm_phone {
                or_clauses.push(doc! { "phone": np });
            }
            if let Some(ref dq) = digits_query {
                if dq.len() >= 3 {
                    or_clauses.push(doc! {
                        "phone": Regex {
                            pattern: regex_escape(dq),
                            options: "i".to_string(),
                        }
                    });
                }
            }
            doc! {
                "phone": { "$ne": "" },
                "is_oa_bot": { "$ne": true },
                "allow_add_by_phone": { "$ne": false },
                "$or": or_clauses,
            }
        }
        Some("email") => doc! {
            "is_oa_bot": { "$ne": true },
            "allow_add_by_email": { "$ne": false },
            "email": rx,
        },
        Some("id" | "bc_id") => {
            let clean_id = q.trim_start_matches('@');
            doc! {
                "is_oa_bot": { "$ne": true },
                "allow_add_by_id": { "$ne": false },
                "bc_id": Regex {
                    pattern: regex_escape(clean_id),
                    options: "i".to_string(),
                },
            }
        }
        _ => {
            let mut or_clauses = vec![
                doc! { "bc_id": rx.clone() },
                doc! { "email": rx.clone() },
                doc! { "phone": rx.clone() },
                doc! { "display_name": rx.clone() },
                doc! { "department": rx },
            ];
            if let Some(ref tok) = extracted_qr {
                or_clauses.push(doc! {
                    "qr_token": Regex {
                        pattern: format!("^{}$", regex_escape(tok)),
                        options: "i".to_string(),
                    }
                });
            }
            if let Some(ref np) = norm_phone {
                or_clauses.push(doc! { "phone": np });
            }
            if let Some(ref dq) = digits_query {
                if dq.len() >= 3 {
                    or_clauses.push(doc! {
                        "phone": Regex {
                            pattern: regex_escape(dq),
                            options: "i".to_string(),
                        }
                    });
                }
            }
            doc! {
                "is_oa_bot": { "$ne": true },
                "$or": or_clauses,
            }
        }
    };

    let docs: Vec<UserDoc> = users_coll
        .find(filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let q_lower = q.to_lowercase();
    let looks_like_phone = norm_phone.is_some()
        || digits_query
            .as_ref()
            .is_some_and(|dq| dq.len() >= 7 || (q.starts_with('+') && dq.len() >= 3));
    let looks_like_email = !q.starts_with('@') && q.contains('@');
    let looks_like_handle = q.starts_with('@');

    let filtered: Vec<UserDto> = docs
        .into_iter()
        .filter(|u| match by_mode.as_deref() {
            Some("qr") => true,
            Some("phone") => u.allow_add_by_phone && !u.phone.is_empty(),
            Some("email") => u.allow_add_by_email,
            Some("id" | "bc_id") => u.allow_add_by_id,
            _ => {
                if let Some(ref tok) = extracted_qr {
                    if u.qr_token.eq_ignore_ascii_case(tok) {
                        return true;
                    }
                }
                if looks_like_phone {
                    return u.allow_add_by_phone
                        && !u.phone.is_empty()
                        && (u.phone.to_lowercase().contains(&q_lower)
                            || norm_phone.as_deref().is_some_and(|np| u.phone == np)
                            || digits_query
                                .as_deref()
                                .is_some_and(|dq| dq.len() >= 3 && u.phone.contains(dq)));
                }
                if looks_like_email {
                    return u.allow_add_by_email
                        && !u.email.is_empty()
                        && u.email.to_lowercase().contains(&q_lower);
                }
                if looks_like_handle {
                    let clean_q = q_lower.trim_start_matches('@');
                    return u.allow_add_by_id
                        && u.bc_id
                            .trim_start_matches('@')
                            .to_lowercase()
                            .contains(clean_q);
                }
                let matched_phone = u.allow_add_by_phone
                    && !u.phone.is_empty()
                    && (u.phone.to_lowercase().contains(&q_lower)
                        || norm_phone.as_deref().is_some_and(|np| u.phone == np)
                        || digits_query
                            .as_deref()
                            .is_some_and(|dq| dq.len() >= 3 && u.phone.contains(dq)));
                let matched_email = u.allow_add_by_email
                    && !u.email.is_empty()
                    && u.email.to_lowercase().contains(&q_lower);
                let matched_id = u.allow_add_by_id && u.bc_id.to_lowercase().contains(&q_lower);
                let matched_name = (u.allow_add_by_id || u.allow_add_by_phone || u.allow_add_by_email)
                    && (u.display_name.to_lowercase().contains(&q_lower)
                        || u.department.to_lowercase().contains(&q_lower));
                matched_phone || matched_email || matched_id || matched_name
            }
        })
        .map(UserDto::from)
        .collect();

    Ok(Json(filtered))
}

fn regex_escape(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if "\\.^$|?*+()[]{}".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

#[derive(Debug, Deserialize)]
pub struct AddFriendRequest {
    pub query: Option<String>,
    pub by: Option<String>,
    pub target_id: Option<String>,
    pub bc_id: Option<String>,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub qr_token: Option<String>,
}

async fn lookup_friend_by_qr(
    users_coll: &mongodb::Collection<UserDoc>,
    raw_qr: &str,
) -> Result<Option<UserDoc>, ApiError> {
    let tok = extract_qr_token_from_input(raw_qr).unwrap_or_else(|| raw_qr.trim().to_string());
    if tok.is_empty() {
        return Ok(None);
    }
    users_coll
        .find_one(doc! {
            "qr_token": Regex {
                pattern: format!("^{}$", regex_escape(&tok)),
                options: "i".to_string(),
            },
            "is_oa_bot": { "$ne": true },
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))
}

async fn lookup_friend_by_phone(
    users_coll: &mongodb::Collection<UserDoc>,
    raw_phone: &str,
) -> Result<Option<UserDoc>, ApiError> {
    let Ok(norm) = sms::normalize_thai_phone(raw_phone) else {
        return Ok(None);
    };
    let found = users_coll
        .find_one(doc! { "phone": norm, "is_oa_bot": { "$ne": true } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    if let Some(ref u) = found {
        if !u.allow_add_by_phone {
            return Err(ApiError::forbidden(
                "ผู้ใช้นี้ปิดการเพิ่มเพื่อนด้วยเบอร์โทรศัพท์",
            ));
        }
    }
    Ok(found)
}

async fn lookup_friend_by_bc_id(
    users_coll: &mongodb::Collection<UserDoc>,
    raw_id: &str,
) -> Result<Option<UserDoc>, ApiError> {
    let trimmed = raw_id.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    let clean = trimmed.trim_start_matches('@');
    let rx = Regex {
        pattern: format!("^@?{}$", regex_escape(clean)),
        options: "i".to_string(),
    };
    let found = users_coll
        .find_one(doc! {
            "bc_id": rx,
            "is_oa_bot": { "$ne": true },
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    if let Some(ref u) = found {
        if !u.allow_add_by_id {
            return Err(ApiError::forbidden("ผู้ใช้นี้ปิดการเพิ่มเพื่อนด้วย BC ID"));
        }
    }
    Ok(found)
}

async fn lookup_friend_by_email(
    users_coll: &mongodb::Collection<UserDoc>,
    raw_email: &str,
) -> Result<Option<UserDoc>, ApiError> {
    let clean = raw_email.trim().to_lowercase();
    if clean.is_empty() {
        return Ok(None);
    }
    let found = users_coll
        .find_one(doc! {
            "email": clean,
            "is_oa_bot": { "$ne": true },
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    if let Some(ref u) = found {
        if !u.allow_add_by_email {
            return Err(ApiError::forbidden("ผู้ใช้นี้ปิดการเพิ่มเพื่อนด้วยอีเมล"));
        }
    }
    Ok(found)
}

/// Safe bilateral friendship upsert when `me_id` adds `partner_id`:
/// - `me_id -> partner_id`: clears `is_hidden` AND `is_blocked` (because `me_id` explicitly added `partner_id`).
/// - `partner_id -> me_id`: NEVER clears `partner_id`'s `is_blocked`! Unhides only when not blocked.
async fn upsert_friendship_on_add(
    state: &AppState,
    me_id: &str,
    partner_id: &str,
) -> Result<FriendshipDoc, String> {
    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");
    let now = Utc::now().to_rfc3339();

    let my_doc = match friends_coll
        .find_one(doc! { "user_id": me_id, "friend_id": partner_id })
        .await
        .map_err(|e| e.to_string())?
    {
        Some(mut existing) => {
            if existing.is_blocked || existing.is_hidden {
                existing.is_blocked = false;
                existing.is_hidden = false;
                friends_coll
                    .replace_one(doc! { "_id": &existing.id }, &existing)
                    .await
                    .map_err(|e| e.to_string())?;
            }
            existing
        }
        None => {
            let created = FriendshipDoc {
                id: Uuid::new_v4().to_string(),
                user_id: me_id.to_string(),
                friend_id: partner_id.to_string(),
                is_favorite: false,
                is_blocked: false,
                is_hidden: false,
                created_at: now.clone(),
            };
            friends_coll
                .insert_one(&created)
                .await
                .map_err(|e| e.to_string())?;
            created
        }
    };

    match friends_coll
        .find_one(doc! { "user_id": partner_id, "friend_id": me_id })
        .await
        .map_err(|e| e.to_string())?
    {
        Some(mut rev) => {
            if !rev.is_blocked && rev.is_hidden {
                rev.is_hidden = false;
                friends_coll
                    .replace_one(doc! { "_id": &rev.id }, &rev)
                    .await
                    .map_err(|e| e.to_string())?;
            }
        }
        None => {
            let rev = FriendshipDoc {
                id: Uuid::new_v4().to_string(),
                user_id: partner_id.to_string(),
                friend_id: me_id.to_string(),
                is_favorite: false,
                is_blocked: false,
                is_hidden: false,
                created_at: now,
            };
            friends_coll
                .insert_one(&rev)
                .await
                .map_err(|e| e.to_string())?;
        }
    }

    Ok(my_doc)
}

pub async fn add_friend_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<AddFriendRequest>,
) -> Result<Json<Value>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบผู้ใช้ปัจจุบัน"))?;

    let mut target: Option<UserDoc> = None;

    if let Some(ref qr) = payload.qr_token {
        if !qr.trim().is_empty() {
            target = lookup_friend_by_qr(&users_coll, qr).await?;
        }
    }
    if target.is_none() {
        if let Some(ref ph) = payload.phone {
            if !ph.trim().is_empty() {
                target = lookup_friend_by_phone(&users_coll, ph).await?;
            }
        }
    }
    if target.is_none() {
        if let Some(ref bid) = payload.bc_id {
            if !bid.trim().is_empty() {
                target = lookup_friend_by_bc_id(&users_coll, bid).await?;
            }
        }
    }
    if target.is_none() {
        if let Some(ref em) = payload.email {
            if !em.trim().is_empty() {
                target = lookup_friend_by_email(&users_coll, em).await?;
            }
        }
    }
    if target.is_none() {
        if let Some(ref raw_q) = payload.query {
            let q = raw_q.trim();
            if !q.is_empty() {
                let by_hint = payload
                    .by
                    .as_deref()
                    .map(|s| s.trim().to_lowercase())
                    .filter(|s| !s.is_empty());
                match by_hint.as_deref() {
                    Some("qr") => {
                        target = lookup_friend_by_qr(&users_coll, q).await?;
                    }
                    Some("phone") => {
                        target = lookup_friend_by_phone(&users_coll, q).await?;
                    }
                    Some("id" | "bc_id") => {
                        target = lookup_friend_by_bc_id(&users_coll, q).await?;
                    }
                    Some("email") => {
                        target = lookup_friend_by_email(&users_coll, q).await?;
                    }
                    _ => {
                        // Auto-detect order: BCQR_.../URL -> Thai phone -> @bc_id -> email
                        if extract_qr_token_from_input(q).is_some() {
                            target = lookup_friend_by_qr(&users_coll, q).await?;
                        } else if sms::normalize_thai_phone(q).is_ok() {
                            target = lookup_friend_by_phone(&users_coll, q).await?;
                        } else if q.starts_with('@') || !q.contains('@') {
                            target = lookup_friend_by_bc_id(&users_coll, q).await?;
                        } else {
                            target = lookup_friend_by_email(&users_coll, q).await?;
                            if target.is_none() {
                                target = lookup_friend_by_bc_id(&users_coll, q).await?;
                            }
                        }
                    }
                }
            }
        }
    }
    if target.is_none() {
        if let Some(ref tid) = payload.target_id {
            if !tid.trim().is_empty() {
                let found = users_coll
                    .find_one(doc! { "_id": tid.trim(), "is_oa_bot": { "$ne": true } })
                    .await
                    .map_err(|e| ApiError::internal(e.to_string()))?;
                if let Some(ref u) = found {
                    if !u.allow_add_by_phone && !u.allow_add_by_id && !u.allow_add_by_email {
                        return Err(ApiError::forbidden(
                            "ผู้ใช้นี้ปิดการเพิ่มเพื่อนผ่านการค้นหา กรุณาเพิ่มผ่าน QR Code",
                        ));
                    }
                }
                target = found;
            }
        }
    }

    let partner = target.ok_or_else(|| {
        ApiError::not_found("ไม่พบผู้ใช้จากเบอร์โทร / BC ID / อีเมล / QR Code ที่ระบุ")
    })?;

    if partner.id == me.id {
        return Err(ApiError::bad_request("ไม่สามารถเพิ่มตัวเองเป็นเพื่อนได้"));
    }

    let friendship = upsert_friendship_on_add(&state, &me.id, &partner.id)
        .await
        .map_err(ApiError::internal)?;

    let conv = ensure_direct_conversation(
        &state,
        &me,
        &partner,
        "direct",
        "personal",
        false,
        "เราเป็นเพื่อนกันบน BC Ai Chat แล้ว ทักทายกันได้เลย!",
    )
    .await
    .map_err(ApiError::internal)?;

    let conv_dto = build_conversation_dto(&state, conv, &me.id)
        .await
        .map_err(ApiError::internal)?;

    let friend_dto = to_friend_dto(partner, &friendship);

    Ok(Json(json!({
        "friend": friend_dto,
        "conversation_id": conv_dto.id,
        "conversation": conv_dto,
    })))
}

#[cfg(test)]
mod google_oauth_tests {
    use super::resolve_google_callback_base;
    use axum::http::HeaderMap;

    #[test]
    fn normalizes_loopback_and_rejects_spoofed_hosts() {
        let empty = HeaderMap::new();
        assert_eq!(
            resolve_google_callback_base(&empty, "http://127.0.0.1:8096/"),
            "http://localhost:8096"
        );

        let mut fwd = HeaderMap::new();
        fwd.insert("x-forwarded-host", "localhost:3096".parse().unwrap());
        assert_eq!(
            resolve_google_callback_base(&fwd, "http://127.0.0.1:8096"),
            "http://localhost:3096"
        );

        let mut spoofed = HeaderMap::new();
        spoofed.insert("host", "evil.example.com".parse().unwrap());
        assert_eq!(
            resolve_google_callback_base(&spoofed, "https://www.bcaichat.com"),
            "https://www.bcaichat.com"
        );
    }

    #[test]
    fn normalize_and_validate_bc_id_rules() {
        use super::normalize_and_validate_bc_id;

        assert_eq!(normalize_and_validate_bc_id("jead").unwrap(), "@jead");
        assert_eq!(normalize_and_validate_bc_id("  @JEAD  ").unwrap(), "@jead");
        assert_eq!(
            normalize_and_validate_bc_id("@jaturapornchai_2823.bc").unwrap(),
            "@jaturapornchai_2823.bc"
        );
        assert!(normalize_and_validate_bc_id("@ab").is_err());
        assert!(normalize_and_validate_bc_id("@ai").is_err());
        assert!(normalize_and_validate_bc_id("@bc.ai").is_err());
        assert!(normalize_and_validate_bc_id("@bad space").is_err());
        assert!(normalize_and_validate_bc_id("@จืด").is_err());
        assert!(normalize_and_validate_bc_id("@foo..bar").is_err());
        assert!(normalize_and_validate_bc_id("@.jead").is_err());
    }

    #[test]
    fn extract_phone_digits_query_handles_thai_and_formatted_inputs() {
        use super::extract_phone_digits_query;

        assert_eq!(
            extract_phone_digits_query("0899223131").as_deref(),
            Some("0899223131")
        );
        assert_eq!(
            extract_phone_digits_query("089-922-3131").as_deref(),
            Some("0899223131")
        );
        assert_eq!(
            extract_phone_digits_query("+66 89-922-3131").as_deref(),
            Some("0899223131")
        );
        assert_eq!(
            extract_phone_digits_query("089-922").as_deref(),
            Some("089922")
        );
        assert_eq!(
            extract_phone_digits_query("๐๘๙๙๒๒๓๑๓๑").as_deref(),
            Some("0899223131")
        );
        assert_eq!(extract_phone_digits_query("66").as_deref(), Some("66"));
        assert_eq!(extract_phone_digits_query("6666").as_deref(), Some("6666"));
        assert_eq!(extract_phone_digits_query(""), None);
        assert_eq!(extract_phone_digits_query("   "), None);
        assert_eq!(extract_phone_digits_query("---"), None);
        assert_eq!(extract_phone_digits_query("abc089"), None);
        assert_eq!(extract_phone_digits_query("@jead"), None);
    }
}
