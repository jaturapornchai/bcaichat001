//! Full integration test suite for BC Ai Chat Backend:
//! - In-process Axum mock server for SMSMKT (`SMSMKT_BASE_URL`) & Google OAuth (`GOOGLE_OAUTH_VERIFY_BASE`) -> ZERO real SMS credits spent!
//! - Isolated MongoDB test database dropped cleanly at the end of the run.
//! - Covers Phone OTP + 60s cooldown (429), Verified Google OAuth + fake/unverified rejection,
//!   Owner Bootstrap Admin, Friends/Groups/MinIO Vault/Confidential Purge/AI/Polls/Events/Albums/Notes/Themes,
//!   Multi-Shop BCAiChatOA + Multi-Role Shop Team (`owner`/`admin`/`agent`/`marketer`),
//!   and LiveKit SFU Voice/Video Calls (`start`/`active`/`accept`/`token`/`decline`/`hangup`/timeout + `call_log` + WS filtering).

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, Request, StatusCode},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use bcaichat_backend::{
    config::{resolve_enable_test_users, AppConfig},
    create_router,
    routes::call_routes::{mint_livekit_token, LiveKitClaims},
    seed::{seed_initial_data, TEST_USER_IDS},
    ws::can_receive,
    AppState,
};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde_json::{json, Value};
use tower::ServiceExt;

const MOCK_GOOGLE_CLIENT_ID: &str = "mock-google-client.apps.googleusercontent.com";
const TEST_BOOTSTRAP_CODE: &str = "BC_TEST_OWNER_BOOT_2026";
const TEST_LK_KEY: &str = "bcaichat_lk_dev_key";
const TEST_LK_SECRET: &str = "bcaichat_lk_dev_secret_key_2026_local_only";

#[derive(Clone, Default)]
struct MockAuthState {
    otp_sends: Arc<Mutex<Vec<Value>>>,
}

async fn mock_smsmkt_credit(headers: HeaderMap) -> (StatusCode, Json<Value>) {
    let api_key = headers
        .get("api_key")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let sec_key = headers
        .get("secret_key")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if api_key.is_empty() || sec_key.is_empty() {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "code": "401", "detail": "Unauthorized" })),
        );
    }
    (
        StatusCode::OK,
        Json(json!({
            "code": "000",
            "detail": "OK.",
            "result": { "credit": 9850 }
        })),
    )
}

async fn mock_smsmkt_otp_send(
    State(st): State<MockAuthState>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    assert!(headers.get("api_key").is_some());
    assert!(headers.get("secret_key").is_some());
    let mut log = st.otp_sends.lock().unwrap();
    let idx = log.len() + 1;
    log.push(body.clone());
    let ref_code = body["ref_code"].as_str().unwrap_or("REF001");
    (
        StatusCode::OK,
        Json(json!({
            "code": "000",
            "detail": "OK.",
            "result": {
                "token": format!("mock_smsmkt_tok_{idx}"),
                "ref_code": ref_code,
            }
        })),
    )
}

async fn mock_smsmkt_otp_validate(Json(body): Json<Value>) -> (StatusCode, Json<Value>) {
    let code = body["otp_code"].as_str().unwrap_or("");
    if code == "654321" {
        (
            StatusCode::OK,
            Json(json!({
                "code": "000",
                "detail": "OK.",
                "result": { "status": true, "message": "ยืนยันรหัสสำเร็จ" }
            })),
        )
    } else {
        (
            StatusCode::OK,
            Json(json!({
                "code": "000",
                "detail": "รหัส OTP ไม่ถูกต้อง",
                "result": { "status": false, "message": "รหัส OTP ไม่ถูกต้อง" }
            })),
        )
    }
}

async fn mock_google_tokeninfo(
    Query(q): Query<HashMap<String, String>>,
) -> (StatusCode, Json<Value>) {
    if let Some(id_tok) = q.get("id_token") {
        if id_tok == "unverified_id" {
            return (
                StatusCode::OK,
                Json(json!({
                    "aud": MOCK_GOOGLE_CLIENT_ID,
                    "sub": "gsub_unverified",
                    "email": "unverified@example.com",
                    "email_verified": "false",
                    "name": "Unverified User",
                })),
            );
        }
        if id_tok == "wrong_aud_id" {
            return (
                StatusCode::OK,
                Json(json!({
                    "aud": "other-client.apps.googleusercontent.com",
                    "sub": "gsub_wrong_aud",
                    "email": "wrongaud@example.com",
                    "email_verified": "true",
                    "name": "Wrong Aud",
                })),
            );
        }
        if let Some(slug) = id_tok.strip_prefix("valid_id_") {
            return (
                StatusCode::OK,
                Json(json!({
                    "aud": MOCK_GOOGLE_CLIENT_ID,
                    "sub": format!("gsub_{slug}"),
                    "email": format!("{slug}@example.com"),
                    "email_verified": "true",
                    "name": format!("คุณ {slug}"),
                    "picture": format!("https://ui-avatars.com/api/?name={slug}"),
                })),
            );
        }
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "invalid_token" })),
        );
    }

    if let Some(acc_tok) = q.get("access_token") {
        if let Some(slug) = acc_tok.strip_prefix("valid_acc_") {
            return (
                StatusCode::OK,
                Json(json!({
                    "aud": MOCK_GOOGLE_CLIENT_ID,
                    "sub": format!("gsub_{slug}"),
                    "email": format!("{slug}@example.com"),
                    "email_verified": "true",
                })),
            );
        }
    }

    (
        StatusCode::BAD_REQUEST,
        Json(json!({ "error": "invalid_token" })),
    )
}

async fn mock_google_userinfo(headers: HeaderMap) -> (StatusCode, Json<Value>) {
    let auth = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if let Some(slug) = auth.strip_prefix("Bearer valid_acc_") {
        return (
            StatusCode::OK,
            Json(json!({
                "sub": format!("gsub_{slug}"),
                "email": format!("{slug}@example.com"),
                "email_verified": true,
                "name": format!("คุณ {slug}"),
                "picture": format!("https://ui-avatars.com/api/?name={slug}"),
            })),
        );
    }
    (
        StatusCode::UNAUTHORIZED,
        Json(json!({ "error": "invalid_token" })),
    )
}

#[tokio::test]
async fn test_full_bcaichat_auth_oa_calls_minio_and_mongo_flow() {
    // Spin up in-process Mock SMSMKT + Google OAuth server (0 external network calls, 0 SMS credits!)
    let mock_auth = MockAuthState::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mock_base = format!("http://{}", listener.local_addr().unwrap());
    let mock_router = Router::new()
        .route("/api/get-credit", get(mock_smsmkt_credit))
        .route("/api/otp-send", post(mock_smsmkt_otp_send))
        .route("/api/otp-validate", post(mock_smsmkt_otp_validate))
        .route("/tokeninfo", get(mock_google_tokeninfo))
        .route("/oauth2/v3/userinfo", get(mock_google_userinfo))
        .with_state(mock_auth.clone());
    tokio::spawn(async move { axum::serve(listener, mock_router).await.unwrap() });

    let run_short = &uuid::Uuid::new_v4().simple().to_string()[..8];
    let mut config = AppConfig::from_env();
    config.mongodb_db = format!("bcaichat_api_it_{run_short}");
    config.smsmkt_base_url = mock_base.clone();
    config.smsmkt_api_key = "mock_smsmkt_key_local".to_string();
    config.smsmkt_secret_key = "mock_smsmkt_secret_local".to_string();
    config.smsmkt_project_key = "mock_otp_proj_local".to_string();
    config.google_oauth_verify_base = mock_base.clone();
    config.google_client_id = MOCK_GOOGLE_CLIENT_ID.to_string();
    config.admin_bootstrap_code = TEST_BOOTSTRAP_CODE.to_string();
    config.livekit_url = "ws://127.0.0.1:7880".to_string();
    config.livekit_api_key = TEST_LK_KEY.to_string();
    config.livekit_api_secret = TEST_LK_SECRET.to_string();
    config.deepseek_api_key.clear();
    config.enable_test_users = true;

    let state = AppState::init(config.clone()).await.expect("init AppState");
    seed_initial_data(&state).await.expect("seed initial data");

    let mut ws_rx = state.ws_hub.tx.subscribe();
    let app = create_router(state.clone());

    // =========================================================================
    // 1. Health, Auth Config & Zero-Demo + Quick Test Users Seed Verification
    // =========================================================================
    let (status, health) = call(&app, "GET", "/api/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(health["status"], "ok");
    assert_eq!(health["mongodb"], true);
    assert_eq!(health["minio"], true);

    let (status, auth_cfg) = call(&app, "GET", "/api/auth/config", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(auth_cfg["phone_otp_enabled"], true);
    assert_eq!(auth_cfg["phone_otp_ready"], true);
    assert_eq!(auth_cfg["google_enabled"], true);
    assert_eq!(auth_cfg["google_client_id"], MOCK_GOOGLE_CLIENT_ID);
    assert_eq!(auth_cfg["admin_bootstrap_enabled"], true);
    assert_eq!(auth_cfg["livekit_enabled"], true);
    assert_eq!(auth_cfg["demo_enabled"], false);
    assert_eq!(auth_cfg["test_users_enabled"], true);

    let test_users_cfg = auth_cfg["test_users"].as_array().expect("test_users array");
    assert_eq!(test_users_cfg.len(), 5);
    for (idx, item) in test_users_cfg.iter().enumerate() {
        let expected_slot = (idx + 1) as u64;
        assert_eq!(item["slot"], expected_slot);
        let uid = item["id"].as_str().unwrap_or("");
        assert_eq!(uid, TEST_USER_IDS[idx]);
        assert!(uuid::Uuid::parse_str(uid).is_ok(), "must be dashed UUID: {uid}");
        assert_eq!(
            item["role"], "user",
            "all 5 quick test users must have role == user"
        );
        let serialized = item.to_string();
        assert!(!serialized.to_lowercase().contains("demo"));
        assert!(!serialized.contains("ฝ่าย"));
        assert!(!serialized.contains("คลังสินค้า"));
        assert!(!serialized.contains("พนักงาน"));
    }

    // Reject non-test user_id / out-of-range slot / mismatched pair on POST /api/auth/test-login
    for bad_payload in [
        json!({}),
        json!({ "slot": 0 }),
        json!({ "slot": 6 }),
        json!({ "user_id": "user_owner_admin" }),
        json!({ "slot": 1, "user_id": TEST_USER_IDS[1] }),
    ] {
        let (status, _) = call(&app, "POST", "/api/auth/test-login", None, Some(bad_payload)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    // Login all 5 Quick Test Users (slot 1..=5 + user_id lookup) & verify seeded data + 0 default pins/favorites
    let mut test_tokens = Vec::with_capacity(5);
    for slot in 1u8..=5 {
        let (status, tl_res) = call(
            &app,
            "POST",
            "/api/auth/test-login",
            None,
            Some(json!({ "slot": slot })),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "slot {slot}: {tl_res}");
        assert_eq!(tl_res["is_new_user"], false);
        assert_eq!(tl_res["user"]["id"], TEST_USER_IDS[(slot - 1) as usize]);
        assert_eq!(tl_res["user"]["role"], "user");
        let tok = tl_res["token"].as_str().unwrap().to_string();
        assert!(!tok.is_empty());

        let (status, me) = call(&app, "GET", "/api/auth/me", Some(&tok), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(me["id"], TEST_USER_IDS[(slot - 1) as usize]);
        assert_eq!(me["role"], "user");

        let (status, convs) = call(&app, "GET", "/api/conversations", Some(&tok), None).await;
        assert_eq!(status, StatusCode::OK);
        for c in convs.as_array().unwrap() {
            assert_eq!(
                c["is_pinned"], false,
                "slot {slot} conv {} must default to is_pinned == false",
                c["id"]
            );
        }

        let (status, friends) = call(&app, "GET", "/api/friends", Some(&tok), None).await;
        assert_eq!(status, StatusCode::OK);
        for f in friends.as_array().unwrap() {
            assert_eq!(
                f["is_favorite"], false,
                "slot {slot} friend {} must default to is_favorite == false",
                f["id"]
            );
        }

        test_tokens.push(tok);
    }

    // Also support login by user_id directly
    let (status, tl_by_uid) = call(
        &app,
        "POST",
        "/api/auth/test-login",
        None,
        Some(json!({ "user_id": TEST_USER_IDS[0] })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(tl_by_uid["user"]["bc_id"], "@tonnam");

    // Slot 1 is NOT system admin (403 on /api/admin/*), owns ชาบ้านเชียง shop, has DM + group, and can discover unfriended Slot 5 (คิน)
    let (status, _) = call(
        &app,
        "GET",
        "/api/admin/auth-settings",
        Some(&test_tokens[0]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, slot1_convs) =
        call(&app, "GET", "/api/conversations", Some(&test_tokens[0]), None).await;
    assert_eq!(status, StatusCode::OK);
    let slot1_convs_arr = slot1_convs.as_array().unwrap();
    assert!(slot1_convs_arr.iter().any(|c| c["id"] == "conv_dm_test_1_2"));
    assert!(slot1_convs_arr
        .iter()
        .any(|c| c["id"] == "conv_group_test_friends" && c["name"] == "แก๊งเพื่อนวันหยุด"));

    let (status, slot1_oas) = call(&app, "GET", "/api/oa/mine", Some(&test_tokens[0]), None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(slot1_oas.as_array().unwrap().iter().any(|oa| {
        oa["id"] == "oa_test_chabanchiang"
            && oa["display_name"] == "ชาบ้านเชียง"
            && oa["my_role"] == "owner"
    }));

    let (status, slot2_oas) = call(&app, "GET", "/api/oa/mine", Some(&test_tokens[1]), None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(slot2_oas
        .as_array()
        .unwrap()
        .iter()
        .any(|oa| oa["id"] == "oa_test_chabanchiang" && oa["my_role"] == "agent"));

    let (status, slot4_convs) =
        call(&app, "GET", "/api/conversations", Some(&test_tokens[3]), None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(slot4_convs
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["id"] == "conv_oa_test_chabanchiang" && c["oa_id"] == "oa_test_chabanchiang"));

    let (status, chabc_coupons) = call(
        &app,
        "GET",
        "/api/oa/oa_test_chabanchiang/coupons",
        Some(&test_tokens[3]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(chabc_coupons
        .as_array()
        .unwrap()
        .iter()
        .any(|cp| cp["code"] == "CHABC20"));

    let (_, slot1_friends) = call(&app, "GET", "/api/friends", Some(&test_tokens[0]), None).await;
    assert!(
        !slot1_friends
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["id"] == TEST_USER_IDS[4]),
        "Slot 5 (คิน) must start unfriended so search/add-friend can be tested anytime"
    );
    let (status, search_kin) = call(
        &app,
        "GET",
        "/api/users/search?q=0810000005",
        Some(&test_tokens[0]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(search_kin
        .as_array()
        .unwrap()
        .iter()
        .any(|u| u["id"] == TEST_USER_IDS[4] && u["bc_id"] == "@kin"));

    // =========================================================================
    // 2. Owner Bootstrap Admin Flow
    // =========================================================================
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/bootstrap-admin",
        None,
        Some(json!({ "code": "WRONG_CODE" })),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, boot_res) = call(
        &app,
        "POST",
        "/api/auth/bootstrap-admin",
        None,
        Some(json!({ "code": TEST_BOOTSTRAP_CODE, "display_name": "เจ้าของระบบ BC" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{boot_res}");
    assert_eq!(boot_res["is_new_user"], true);
    assert_eq!(boot_res["user"]["id"], "user_owner_admin");
    assert_eq!(boot_res["user"]["role"], "admin");
    assert_eq!(boot_res["user"]["bc_id"], "@owner.bc");
    let admin_token = boot_res["token"].as_str().unwrap().to_string();

    let (status, boot_again) = call(
        &app,
        "POST",
        "/api/auth/bootstrap-admin",
        None,
        Some(json!({ "code": TEST_BOOTSTRAP_CODE })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(boot_again["is_new_user"], false);

    // Verify seeded users contain ONLY system bots + newly bootstrapped owner (0 demo accounts)
    let (status, all_users) = call(&app, "GET", "/api/admin/users", Some(&admin_token), None).await;
    assert_eq!(status, StatusCode::OK);
    let users_arr = all_users.as_array().unwrap();
    assert!(users_arr.iter().any(|u| u["id"] == "user_ai"));
    let official_u = users_arr
        .iter()
        .find(|u| u["id"] == "user_official")
        .expect("user_official must exist");
    let official_status = official_u["status_message"].as_str().unwrap_or("");
    assert!(
        official_status.contains("ร้านค้า") && !official_status.contains("OA"),
        "user_official status_message must use ร้านค้า without OA: {official_status}"
    );
    assert!(!users_arr.iter().any(|u| u["id"] == "user_demo1"));
    assert!(!users_arr.iter().any(|u| u["id"] == "user_jead"));

    // =========================================================================
    // 3. Mobile Phone OTP Auth + 60s Cooldown (429) via Mock SMSMKT
    // =========================================================================
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "021234567" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, otp_req) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "+66 81-234-5678" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{otp_req}");
    assert_eq!(otp_req["masked_phone"], "081-xxx-5678");
    let cid1 = otp_req["challenge_id"].as_str().unwrap().to_string();
    let ref1 = otp_req["ref_code"].as_str().unwrap().to_string();
    assert_eq!(mock_auth.otp_sends.lock().unwrap().len(), 1);

    // Cooldown: immediate repeat request within 60s must return 429 Too Many Requests without hitting SMSMKT
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "0812345678" })),
    )
    .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        mock_auth.otp_sends.lock().unwrap().len(),
        1,
        "cooldown must block before calling SMSMKT"
    );

    // Wrong OTP code -> 400
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/otp/verify",
        None,
        Some(json!({ "challenge_id": cid1, "otp_code": "000000" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Correct OTP code -> 200 OK
    let (status, otp_ver) = call(
        &app,
        "POST",
        "/api/auth/otp/verify",
        None,
        Some(json!({
            "challenge_id": cid1,
            "otp_code": "654321",
            "ref_code": ref1,
            "display_name": "ก้อง สายเที่ยว"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{otp_ver}");
    assert_eq!(otp_ver["is_new_user"], true);
    assert_eq!(otp_ver["user"]["phone"], "0812345678");
    assert_eq!(otp_ver["user"]["phone_verified"], true);
    assert_eq!(otp_ver["user"]["role"], "user");
    let kong_id = otp_ver["user"]["id"].as_str().unwrap().to_string();
    assert!(
        uuid::Uuid::parse_str(&kong_id).is_ok() && !kong_id.starts_with("user_"),
        "OTP user id must be dashed UUID: {kong_id}"
    );
    let kong_token = otp_ver["token"].as_str().unwrap().to_string();

    // Starter onboarding defaults: 0 default pins on Keep/user_ai/user_official/personal_note & 0 default favorites
    let (status, starter_convs) =
        call(&app, "GET", "/api/conversations", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::OK, "{starter_convs}");
    let starter_convs_arr = starter_convs.as_array().unwrap();
    let starter_keep = starter_convs_arr
        .iter()
        .find(|c| c["id"] == format!("conv_keep_{kong_id}"))
        .expect("starter Keep conversation must exist");
    assert_eq!(starter_keep["is_pinned"], false);
    for bot_id in ["user_ai", "user_official"] {
        let bot_conv = starter_convs_arr
            .iter()
            .find(|c| {
                c["members"]
                    .as_array()
                    .is_some_and(|m| m.iter().any(|u| u["id"] == bot_id))
            })
            .unwrap_or_else(|| panic!("starter conversation with {bot_id} must exist"));
        assert_eq!(
            bot_conv["is_pinned"], false,
            "starter conversation with {bot_id} must default to is_pinned == false"
        );
    }

    let (status, starter_friends) =
        call(&app, "GET", "/api/friends", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::OK, "{starter_friends}");
    let starter_friends_arr = starter_friends.as_array().unwrap();
    for bot_id in ["user_ai", "user_official"] {
        let bf = starter_friends_arr
            .iter()
            .find(|f| f["id"] == bot_id)
            .unwrap_or_else(|| panic!("starter friend {bot_id} must exist"));
        assert_eq!(
            bf["is_favorite"], false,
            "starter friend {bot_id} must default to is_favorite == false"
        );
    }

    let (status, starter_notes) =
        call(&app, "GET", "/api/notes", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::OK, "{starter_notes}");
    let starter_personal_note = starter_notes
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == format!("note_personal_seed_{kong_id}"))
        .expect("starter personal note must exist");
    assert_eq!(starter_personal_note["is_pinned"], false);

    // Replay verified challenge -> 400
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/otp/verify",
        None,
        Some(json!({ "challenge_id": cid1, "otp_code": "654321" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // =========================================================================
    // 4. Verified Google OAuth + Fake/Unverified Rejection + Account Linking
    // =========================================================================
    for bad_payload in [
        json!({ "id_token": "demo_jead" }),
        json!({ "email": "fake@bcaichat.local" }),
        json!({ "id_token": "unverified_id" }),
        json!({ "id_token": "wrong_aud_id" }),
        json!({ "id_token": "forged_jwt_token" }),
    ] {
        let (st, _) = call(&app, "POST", "/api/auth/google", None, Some(bad_payload.clone())).await;
        assert_eq!(
            st,
            StatusCode::UNAUTHORIZED,
            "must block unverified payload: {bad_payload}"
        );
    }

    // Verified id_token login (Prae)
    let (status, prae_auth) = call(
        &app,
        "POST",
        "/api/auth/google",
        None,
        Some(json!({ "id_token": "valid_id_prae", "display_name": "แพร คาเฟ่" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{prae_auth}");
    assert_eq!(prae_auth["user"]["email"], "prae@example.com");
    assert_eq!(prae_auth["user"]["email_verified"], true);
    let prae_id = prae_auth["user"]["id"].as_str().unwrap().to_string();
    let prae_token = prae_auth["token"].as_str().unwrap().to_string();

    // Verified OAuth redirect/popup state -> complete (with access_token) -> poll
    let oauth_state = "state_test_google_popup_12345";
    let start_res = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/auth/google/start?state={oauth_state}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(start_res.status(), StatusCode::TEMPORARY_REDIRECT);

    let (status, poll_pending) = call(
        &app,
        "GET",
        &format!("/api/auth/google/poll?state={oauth_state}"),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(poll_pending["status"], "pending");

    let (status, comp_res) = call(
        &app,
        "POST",
        "/api/auth/google/complete",
        None,
        Some(json!({ "state": oauth_state, "access_token": "valid_acc_boss" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{comp_res}");
    assert_eq!(comp_res["status"], "completed");

    let (status, poll_done) = call(
        &app,
        "GET",
        &format!("/api/auth/google/poll?state={oauth_state}"),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(poll_done["status"], "completed");
    let boss_id = poll_done["user"]["id"].as_str().unwrap().to_string();
    assert!(
        uuid::Uuid::parse_str(&boss_id).is_ok() && !boss_id.starts_with("user_"),
        "Google user id must be dashed UUID: {boss_id}"
    );
    let boss_token = poll_done["token"].as_str().unwrap().to_string();

    // Link Gmail to Kong (phone user) & Link Phone to Prae (Google user)
    let (status, linked_gmail) = call(
        &app,
        "POST",
        "/api/auth/link/google",
        Some(&kong_token),
        Some(json!({ "id_token": "valid_id_kong" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(linked_gmail["user"]["email"], "kong@example.com");
    assert_eq!(linked_gmail["user"]["email_verified"], true);

    let (status, prae_otp) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        Some(&prae_token),
        Some(json!({ "phone": "0891112222", "purpose": "link" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, linked_phone) = call(
        &app,
        "POST",
        "/api/auth/link/phone",
        Some(&prae_token),
        Some(json!({
            "challenge_id": prae_otp["challenge_id"],
            "otp_code": "654321"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(linked_phone["user"]["phone"], "0891112222");
    assert_eq!(linked_phone["user"]["phone_verified"], true);

    // Admin Auth Settings check (masking + mocked credit)
    let (status, _) = call(&app, "GET", "/api/admin/auth-settings", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, as_dto) =
        call(&app, "GET", "/api/admin/auth-settings", Some(&admin_token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(as_dto["smsmkt_has_keys"], true);
    assert!(as_dto["smsmkt_masked_api_key"]
        .as_str()
        .unwrap()
        .starts_with("****"));
    assert_eq!(as_dto["credit_info"]["credit"], 9850);

    // =========================================================================
    // 4b. Custom BC ID Check, Change & Strict Case-Insensitive Uniqueness
    // =========================================================================
    let (status, chk_free) = call(
        &app,
        "GET",
        "/api/auth/bc-id/check?bc_id=jead",
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(chk_free["valid"], true);
    assert_eq!(chk_free["available"], true);
    assert_eq!(chk_free["normalized_bc_id"], "@jead");

    let (status, kong_updated) = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&kong_token),
        Some(json!({ "bc_id": "Jead" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{kong_updated}");
    assert_eq!(kong_updated["bc_id"], "@jead");

    let (status, chk_taken) = call(
        &app,
        "GET",
        "/api/auth/bc-id/check?bc_id=@JEAD",
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(chk_taken["valid"], true);
    assert_eq!(chk_taken["available"], false);

    let (status, dup_err) = call(
        &app,
        "PUT",
        "/api/auth/profile",
        Some(&prae_token),
        Some(json!({ "bc_id": "@JEAD" })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{dup_err}");

    let (status, oa_dup_err) = call(
        &app,
        "POST",
        "/api/oa",
        Some(&prae_token),
        Some(json!({ "display_name": "ร้านซ้ำ", "handle": "jead" })),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{oa_dup_err}");

    // Same owner re-saving their own @jead succeeds
    let (status, kong_resave) = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&kong_token),
        Some(json!({ "bc_id": "@jead", "display_name": "ก้อง สายเที่ยว" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{kong_resave}");
    assert_eq!(kong_resave["bc_id"], "@jead");

    // Invalid BC IDs (too short / reserved / spaces) return 400
    for bad in ["ab", "@ai", "@bc.ai", "bad space"] {
        let (st, bad_res) = call(
            &app,
            "PUT",
            "/api/auth/profile",
            Some(&prae_token),
            Some(json!({ "bc_id": bad })),
        )
        .await;
        assert_eq!(st, StatusCode::BAD_REQUEST, "expected 400 for {bad}: {bad_res}");
    }

    // =========================================================================
    // 5. Friends, Groups, MinIO Vault, Confidential Purge, AI, Polls, Events, Albums, Notes & Themes
    // =========================================================================
    // Phone search variants: exact, dashes, +66, partial with dash, Thai digits, empty & Google-only user exclusion
    for raw_q in [
        "0812345678",
        "081-234-5678",
        "+66 81-234-5678",
        "081-234",
        "๐๘๑๒๓๔๕๖๗๘",
    ] {
        let encoded_q = urlencoding::encode(raw_q);
        let (st, res_by_phone) = call(
            &app,
            "GET",
            &format!("/api/users/search?by=phone&q={encoded_q}"),
            Some(&prae_token),
            None,
        )
        .await;
        assert_eq!(st, StatusCode::OK, "by=phone q={raw_q}: {res_by_phone}");
        let arr = res_by_phone.as_array().unwrap();
        assert!(
            arr.iter().any(|u| u["id"] == kong_id),
            "expected kong_id for by=phone q={raw_q}, got: {res_by_phone}"
        );
        assert!(
            !arr.iter().any(|u| u["id"] == boss_id),
            "Google-only user without phone must never match by=phone q={raw_q}"
        );

        let (st_any, res_any) = call(
            &app,
            "GET",
            &format!("/api/users/search?q={encoded_q}"),
            Some(&prae_token),
            None,
        )
        .await;
        assert_eq!(st_any, StatusCode::OK, "fallback q={raw_q}: {res_any}");
        assert!(
            res_any.as_array().unwrap().iter().any(|u| u["id"] == kong_id),
            "expected kong_id for fallback q={raw_q}, got: {res_any}"
        );
    }

    // Empty phone queries must return [] (never matching Google-only users with phone == "")
    for empty_uri in ["/api/users/search?by=phone", "/api/users/search?by=phone&q="] {
        let (st, empty_res) = call(&app, "GET", empty_uri, Some(&prae_token), None).await;
        assert_eq!(st, StatusCode::OK);
        assert!(
            empty_res.as_array().unwrap().is_empty(),
            "empty by=phone query {empty_uri} must return []: {empty_res}"
        );
    }

    // When allow_add_by_phone is false, Kong is excluded across exact/partial/Thai-digit phone searches
    let (st, _) = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&kong_token),
        Some(json!({ "allow_add_by_phone": false })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    for raw_q in ["0812345678", "081-234", "๐๘๑๒๓๔๕๖๗๘"] {
        let encoded_q = urlencoding::encode(raw_q);
        let (st, hidden_res) = call(
            &app,
            "GET",
            &format!("/api/users/search?by=phone&q={encoded_q}"),
            Some(&prae_token),
            None,
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert!(
            !hidden_res.as_array().unwrap().iter().any(|u| u["id"] == kong_id),
            "allow_add_by_phone=false must exclude kong for q={raw_q}: {hidden_res}"
        );
    }
    let (st, _) = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&kong_token),
        Some(json!({ "allow_add_by_phone": true })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (status, found_prae) = call(
        &app,
        "GET",
        "/api/users/search?q=089-111-2222",
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(found_prae.as_array().unwrap()[0]["id"], prae_id);

    let (status, added_friend) = call(
        &app,
        "POST",
        "/api/friends/add",
        Some(&kong_token),
        Some(json!({ "phone": "089-111-2222" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{added_friend}");
    let direct_conv_id = added_friend["conversation_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(added_friend["conversation"]["members"]
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["id"] == prae_id && m["phone"] == "0891112222"));

    let (status, upd_f) = call(
        &app,
        "PUT",
        &format!("/api/friends/{prae_id}"),
        Some(&kong_token),
        Some(json!({ "is_favorite": true })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(upd_f["is_favorite"], true);

    // Personal Mini-Apps & seeded MinIO objects
    let (status, mini_apps) = call(&app, "GET", "/api/mini-apps", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(mini_apps.as_array().unwrap().len() >= 5);
    for slug in ["ai", "split", "trip", "wishlist", "hangout"] {
        let res = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/miniapp/{slug}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }

    // Create family/friend group room
    let (status, group) = call(
        &app,
        "POST",
        "/api/conversations/group",
        Some(&kong_token),
        Some(json!({
            "name": "กลุ่มเพื่อนเที่ยววันหยุด",
            "member_ids": [&prae_id, "user_ai"],
            "folder": "family"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let gid = group["id"].as_str().unwrap().to_string();
    let invite_tok = group["invite_token"].as_str().unwrap().to_string();

    // Folder alias: both family & work return family rooms
    for fq in ["family", "work"] {
        let (st, list) = call(
            &app,
            "GET",
            &format!("/api/conversations?folder={fq}"),
            Some(&kong_token),
            None,
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert!(list.as_array().unwrap().iter().any(|c| c["id"] == gid));
    }

    // Join via invite_token & leave
    let (status, joined) = call(
        &app,
        "POST",
        "/api/conversations/join",
        Some(&boss_token),
        Some(json!({ "invite_token": invite_tok })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(joined["id"], gid);

    // Outsider protection (admin_token is not in gid!)
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/conversations/{gid}/messages"),
        Some(&admin_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Upload file to MinIO + link message + Vault check + Confidential instant purge
    let sample_bytes = b"BC Ai Chat Vault Test Content";
    let (status, uploaded) = call(
        &app,
        "POST",
        "/api/upload",
        Some(&kong_token),
        Some(json!({
            "file_name": "trip_plan.txt",
            "mime_type": "text/plain",
            "data_base64": BASE64.encode(sample_bytes),
            "conversation_id": gid
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let file_key = uploaded["key"].as_str().unwrap().to_string();
    let file_url = uploaded["url"].as_str().unwrap().to_string();

    let (status, file_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{gid}/messages"),
        Some(&kong_token),
        Some(json!({
            "type": "file",
            "content": "ไฟล์ทริปเที่ยว",
            "attachment": {
                "key": file_key,
                "url": file_url,
                "file_name": "trip_plan.txt",
                "mime_type": "text/plain",
                "file_size": sample_bytes.len()
            }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{gid}/messages"),
        Some(&kong_token),
        Some(json!({
            "type": "text",
            "content": "ดูแผนที่คาเฟ่ https://bcaichat.local/map-cafe"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, vault) = call(
        &app,
        "GET",
        &format!("/api/conversations/{gid}/vault"),
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(!vault["files"].as_array().unwrap().is_empty());
    assert!(!vault["links"].as_array().unwrap().is_empty());

    // Purge uploaded file message -> file removed from MinIO (404)
    let fmid = file_msg["id"].as_str().unwrap();
    let (status, purged) = call(
        &app,
        "DELETE",
        &format!("/api/messages/{fmid}/purge"),
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(purged["file_purged"], true);
    let (status, _) = call(&app, "GET", &format!("/api/files/{file_key}"), None, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // AI Summarize, Assist & @ai group reply
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{gid}/messages"),
        Some(&kong_token),
        Some(json!({ "type": "text", "content": "@ai ช่วยสรุปแผนเที่ยวให้หน่อย" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, msgs_ai) = call(
        &app,
        "GET",
        &format!("/api/conversations/{gid}/messages"),
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(msgs_ai.as_array().unwrap().last().unwrap()["sender_id"], "user_ai");

    let (status, sum_res) = call(
        &app,
        "POST",
        "/api/ai/summarize",
        Some(&kong_token),
        Some(json!({ "conversation_id": gid })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(!sum_res["summary"].as_str().unwrap().is_empty());

    // Polls, Events, Albums & Notes quick check
    let (status, poll_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{gid}/polls"),
        Some(&kong_token),
        Some(json!({
            "question": "กินอะไรดีเย็นนี้?",
            "options": ["ชาบู", "ปิ้งย่าง"]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let opt0 = poll_msg["poll"]["options"][0]["id"].as_str().unwrap();
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/messages/{}/vote", poll_msg["id"].as_str().unwrap()),
        Some(&prae_token),
        Some(json!({ "option_ids": [opt0] })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, ev_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{gid}/events"),
        Some(&kong_token),
        Some(json!({
            "title": "ทริปเขาใหญ่",
            "starts_at": "2026-12-05T08:00:00Z",
            "location": "เขาใหญ่"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/messages/{}/rsvp", ev_msg["id"].as_str().unwrap()),
        Some(&prae_token),
        Some(json!({ "status": "going" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, note) = call(
        &app,
        "POST",
        "/api/notes",
        Some(&kong_token),
        Some(json!({
            "conversation_id": gid,
            "title": "ของเตรียมไปแคมป์",
            "content": "เต็นท์และไฟฉาย",
            "is_pinned": true
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/notes/{}/like", note["id"].as_str().unwrap()),
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // 7 Ban Chiang Themes + WS broadcast
    while ws_rx.try_recv().is_ok() {}
    for preset in [
        "silk_amber",
        "indigo_kram",
        "jade_celadon",
        "lotus_rose",
        "spice_cinnamon",
        "royal_amethyst",
        "ban_chiang",
    ] {
        let (st, _) = call(
            &app,
            "PUT",
            "/api/settings/theme",
            Some(&admin_token),
            Some(json!({ "preset": preset })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
    }
    let mut saw_theme = false;
    while let Ok(raw) = ws_rx.try_recv() {
        let ev: Value = serde_json::from_str(&raw).unwrap();
        saw_theme |= ev["event"] == "theme_changed" && ev["preset"] == "ban_chiang";
    }
    assert!(saw_theme);

    // =========================================================================
    // 6. Multi-Shop BCAiChatOA + Multi-Role Shop Team (`owner`/`admin`/`agent`/`marketer`)
    // =========================================================================
    // Regular user (Kong, role == "user") creates 2 separate OA shops!
    let (status, oa1) = call(
        &app,
        "POST",
        "/api/oa",
        Some(&kong_token),
        Some(json!({
            "handle": "@baan_craft",
            "display_name": "บ้านเชียง คราฟต์ คาเฟ่",
            "category": "คาเฟ่ & เบเกอรี่",
            "bio": "กาแฟดริปและเครื่องปั้นดินเผาทำมือ",
            "calls_enabled": true,
            "ai_enabled": false
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{oa1}");
    let oa1_id = oa1["id"].as_str().unwrap().to_string();
    assert_eq!(oa1["my_role"], "owner");
    assert_eq!(oa1["calls_enabled"], true);

    let (status, oa2) = call(
        &app,
        "POST",
        "/api/oa",
        Some(&kong_token),
        Some(json!({
            "handle": "baan_pottery",
            "display_name": "บ้านเชียง เซรามิก สตูดิโอ",
            "category": "งานฝีมือ"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{oa2}");
    assert_eq!(oa2["my_role"], "owner");

    let (status, my_oas) = call(&app, "GET", "/api/oa/mine", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        my_oas.as_array().unwrap().len(),
        2,
        "single user must own multiple OA shops"
    );

    // Create 3 staff users: shop_admin (via @bc_id), agent_staff (via Thai phone), marketer_staff (via Gmail)
    let (_, shop_adm_auth) = call(
        &app,
        "POST",
        "/api/auth/google",
        None,
        Some(json!({ "id_token": "valid_id_shopadm", "display_name": "แอดมินร้าน" })),
    )
    .await;
    let shop_adm_id = shop_adm_auth["user"]["id"].as_str().unwrap().to_string();
    let shop_adm_bc = shop_adm_auth["user"]["bc_id"].as_str().unwrap().to_string();
    let shop_adm_tok = shop_adm_auth["token"].as_str().unwrap().to_string();

    let (_, agent_otp) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "0863334444" })),
    )
    .await;
    let (_, agent_auth) = call(
        &app,
        "POST",
        "/api/auth/otp/verify",
        None,
        Some(json!({
            "challenge_id": agent_otp["challenge_id"],
            "otp_code": "654321",
            "display_name": "น้องเมย์ ตอบแชท"
        })),
    )
    .await;
    let agent_id = agent_auth["user"]["id"].as_str().unwrap().to_string();
    let agent_tok = agent_auth["token"].as_str().unwrap().to_string();

    let (_, mkt_auth) = call(
        &app,
        "POST",
        "/api/auth/google",
        None,
        Some(json!({ "id_token": "valid_id_mkt", "display_name": "ฝ่ายการตลาด" })),
    )
    .await;
    let mkt_id = mkt_auth["user"]["id"].as_str().unwrap().to_string();
    let mkt_tok = mkt_auth["token"].as_str().unwrap().to_string();

    // Owner adds shop_admin as "admin" via bc_id query, and agent_staff as "agent" via Thai phone query
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/admins"),
        Some(&kong_token),
        Some(json!({ "query": shop_adm_bc, "role": "admin" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/admins"),
        Some(&kong_token),
        Some(json!({ "query": "086-333-4444", "role": "agent" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // shop_admin CANNOT add someone as "admin" (403), CAN add marketer_staff as "marketer" via Gmail query!
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/admins"),
        Some(&shop_adm_tok),
        Some(json!({ "query": "mkt@example.com", "role": "admin" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, oa_with_team) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/admins"),
        Some(&shop_adm_tok),
        Some(json!({ "query": "mkt@example.com", "role": "marketer" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{oa_with_team}");
    assert_eq!(oa_with_team["my_role"], "admin");
    assert_eq!(oa_with_team["staff_roles"][&agent_id], "agent");
    assert_eq!(oa_with_team["staff_roles"][&mkt_id], "marketer");

    // GET /api/oa/:id/admins lists owner + admin + agent + marketer
    let (status, staff_list) = call(
        &app,
        "GET",
        &format!("/api/oa/{oa1_id}/admins"),
        Some(&agent_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let staff_arr = staff_list.as_array().unwrap();
    assert_eq!(staff_arr.len(), 4);
    assert_eq!(staff_arr[0]["role"], "owner");
    assert!(staff_arr.iter().any(|s| s["user_id"] == agent_id && s["role"] == "agent"));
    assert!(staff_arr.iter().any(|s| s["user_id"] == mkt_id && s["role"] == "marketer"));

    // Customer (Prae) discovers & follows oa1 -> receives greeting + ConversationDto with Rich Menu
    let (status, disc) = call(
        &app,
        "GET",
        "/api/oa/discover?q=baan_craft",
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(disc.as_array().unwrap()[0]["id"], oa1_id);

    let (status, fol_res) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/follow"),
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{fol_res}");
    let oa_conv_id = fol_res["conversation_id"].as_str().unwrap().to_string();
    assert_eq!(fol_res["conversation"]["oa_id"], oa1_id);
    assert_eq!(fol_res["conversation"]["oa_handle"], "baan_craft");
    assert!(!fol_res["conversation"]["rich_menu"].as_array().unwrap().is_empty());

    // Batch-fetched GET /api/conversations also populates oa_id, oa_handle & rich_menu
    let (status, prae_convs) = call(&app, "GET", "/api/conversations", Some(&prae_token), None).await;
    assert_eq!(status, StatusCode::OK);
    let prae_oa_conv = prae_convs
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == oa_conv_id)
        .unwrap();
    assert_eq!(prae_oa_conv["oa_id"], oa1_id);
    assert!(!prae_oa_conv["rich_menu"].as_array().unwrap().is_empty());

    // Role Enforcement: Marketer CAN manage auto-replies, coupons, broadcasts & rich_menu, CANNOT chat/edit profile
    let (status, rule) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/auto-replies"),
        Some(&mkt_tok),
        Some(json!({
            "keyword": "โปรโมชั่น",
            "match_mode": "contains",
            "reply_text": "วันนี้ซื้อกาแฟดริป 2 แก้ว ลดทันที 20% ค่ะ!"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{rule}");

    let (status, coupon) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/coupons"),
        Some(&mkt_tok),
        Some(json!({
            "code": "CRAFT20",
            "title": "ส่วนลดกาแฟดริป 20%",
            "discount_text": "ลด 20%",
            "max_claims": 10
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{coupon}");
    let coupon_id = coupon["id"].as_str().unwrap().to_string();

    // Marketer updates ONLY rich_menu -> 200 OK; updates display_name -> 403 Forbidden
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/oa/{oa1_id}"),
        Some(&mkt_tok),
        Some(json!({
            "rich_menu": [
                { "id": "rm1", "label": "โปรโมชั่นพิเศษ", "subtitle": "กดดูส่วนลด", "action_type": "keyword", "action_value": "โปรโมชั่น", "icon": "local_offer" }
            ]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/oa/{oa1_id}"),
        Some(&mkt_tok),
        Some(json!({ "display_name": "แอบเปลี่ยนชื่อร้าน" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/oa/{oa1_id}/chats"),
        Some(&mkt_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "marketer must not access customer chats");

    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/conversations/{oa_conv_id}/messages"),
        Some(&mkt_tok),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "marketer must NOT leak into conversation admin_ids or read customer OA messages"
    );

    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{oa_conv_id}/messages"),
        Some(&mkt_tok),
        Some(json!({ "type": "text", "content": "แอบส่งในห้องลูกค้า" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, bc_res) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/broadcasts"),
        Some(&mkt_tok),
        Some(json!({
            "content": "แจ้งโปรใหม่ประจำสัปดาห์!",
            "coupon_id": coupon_id
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{bc_res}");
    assert_eq!(bc_res["recipient_count"], 1);

    // Role Enforcement: Agent CAN reply to customer chat, update CRM & redeem coupon, CANNOT broadcast/edit profile/create coupon
    let (status, ov_agent) = call(
        &app,
        "GET",
        &format!("/api/oa/{oa1_id}/overview"),
        Some(&agent_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ov_agent["oa"]["my_role"], "agent");

    let (status, chats_list) = call(
        &app,
        "GET",
        &format!("/api/oa/{oa1_id}/chats"),
        Some(&agent_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(chats_list.as_array().unwrap().len(), 1);

    let (status, agent_reply) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/chats/{oa_conv_id}/messages"),
        Some(&agent_tok),
        Some(json!({ "content": "สวัสดีคุณแพร น้องเมย์ยินดีดูแลนะคะ" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{agent_reply}");

    let (status, crm_upd) = call(
        &app,
        "PUT",
        &format!("/api/oa/{oa1_id}/followers/{prae_id}/crm"),
        Some(&agent_tok),
        Some(json!({ "tags": ["VIP", "สายกาแฟ"], "crm_note": "ชอบเมล็ดคั่วอ่อน", "ai_paused": false })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(crm_upd["tags"], json!(["VIP", "สายกาแฟ"]));

    for (method, uri, body) in [
        (
            "POST",
            format!("/api/oa/{oa1_id}/broadcasts"),
            Some(json!({ "content": "แอบบรอดแคสต์" })),
        ),
        (
            "POST",
            format!("/api/oa/{oa1_id}/coupons"),
            Some(json!({ "code": "NOPE", "title": "แอบสร้างคูปอง" })),
        ),
        (
            "POST",
            format!("/api/oa/{oa1_id}/auto-replies"),
            Some(json!({ "keyword": "x", "reply_text": "y" })),
        ),
        (
            "PUT",
            format!("/api/oa/{oa1_id}"),
            Some(json!({ "bio": "แอบแก้โปรไฟล์ร้าน" })),
        ),
    ] {
        let (st, _) = call(&app, method, &uri, Some(&agent_tok), body).await;
        assert_eq!(
            st,
            StatusCode::FORBIDDEN,
            "agent must get 403 on {method} {uri}"
        );
    }

    // Customer sends keyword "โปรโมชั่น" -> triggers OA auto-reply rule!
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{oa_conv_id}/messages"),
        Some(&prae_token),
        Some(json!({ "type": "text", "content": "ขอดูโปรโมชั่นหน่อยค่ะ" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, oa_msgs) = call(
        &app,
        "GET",
        &format!("/api/conversations/{oa_conv_id}/messages"),
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(oa_msgs
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["content"] == "วันนี้ซื้อกาแฟดริป 2 แก้ว ลดทันที 20% ค่ะ!"));

    // Customer claims coupon & Agent redeems it
    let (status, claimed) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/coupons/{coupon_id}/claim"),
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(claimed["is_claimed"], true);

    let (status, redeemed) = call(
        &app,
        "POST",
        &format!("/api/oa/{oa1_id}/coupons/{coupon_id}/redeem"),
        Some(&agent_tok),
        Some(json!({ "user_id": prae_id })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(redeemed["is_redeemed"], true);

    // PUT /api/oa/:id/admins/:uid & DELETE /api/oa/:id/admins/:uid
    let (status, role_changed) = call(
        &app,
        "PUT",
        &format!("/api/oa/{oa1_id}/admins/{mkt_id}"),
        Some(&kong_token),
        Some(json!({ "role": "agent" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(role_changed["staff_roles"][&mkt_id], "agent");

    // Promoted to agent -> sync_oa_conversations_admins grants access to both OA chats & conversation messages
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/oa/{oa1_id}/chats"),
        Some(&mkt_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/conversations/{oa_conv_id}/messages"),
        Some(&mkt_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Change back to marketer -> sync_oa_conversations_admins revokes conversation admin_ids immediately
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/oa/{oa1_id}/admins/{mkt_id}"),
        Some(&kong_token),
        Some(json!({ "role": "marketer" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/oa/{oa1_id}/chats"),
        Some(&mkt_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/conversations/{oa_conv_id}/messages"),
        Some(&mkt_tok),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "demoting agent -> marketer must revoke GET /api/conversations/:oa_conv_id/messages"
    );

    // Also verify adding a marketer to an OA with pre-existing seeded customer conversation keeps 403 on both endpoints
    let (status, _) = call(
        &app,
        "POST",
        "/api/oa/oa_test_chabanchiang/admins",
        Some(&test_tokens[0]),
        Some(json!({ "query": "@phoom", "role": "marketer" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(
        &app,
        "GET",
        "/api/oa/oa_test_chabanchiang/chats",
        Some(&test_tokens[2]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &app,
        "GET",
        "/api/conversations/conv_oa_test_chabanchiang/messages",
        Some(&test_tokens[2]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/oa/oa_test_chabanchiang/admins/{}", TEST_USER_IDS[2]),
        Some(&test_tokens[0]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // =========================================================================
    // 7. LiveKit SFU Voice/Video Calls + OA calls_enabled + Timeout + WS Filtering
    // =========================================================================
    // Disable OA calls -> customer & agent blocked with 400 Bad Request
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/oa/{oa1_id}"),
        Some(&kong_token),
        Some(json!({ "calls_enabled": false })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, dis_err) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&prae_token),
        Some(json!({ "conversation_id": oa_conv_id, "call_type": "audio" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(dis_err["error"].as_str().unwrap().contains("ปิดการรับสาย"));

    // Re-enable OA calls -> marketer gets 403, customer starts call, agent accepts!
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/oa/{oa1_id}"),
        Some(&kong_token),
        Some(json!({ "calls_enabled": true })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&mkt_tok),
        Some(json!({ "conversation_id": oa_conv_id, "call_type": "audio" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "marketer must not start OA calls");

    while ws_rx.try_recv().is_ok() {}
    let (status, oa_call_start) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&prae_token),
        Some(json!({ "conversation_id": oa_conv_id, "call_type": "video" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{oa_call_start}");
    let oa_call_id = oa_call_start["call"]["id"].as_str().unwrap().to_string();
    assert_eq!(
        oa_call_start["livekit_url"],
        "ws://127.0.0.1:7880",
        "livekit_url must NEVER append /rtc"
    );

    // Decode & verify HS256 LiveKit JWT claims (including quoted api_key / api_secret resilience)
    let lk_tok = oa_call_start["token"].as_str().unwrap();
    let mut lk_val = Validation::new(Algorithm::HS256);
    lk_val.validate_aud = false;
    let decoded = jsonwebtoken::decode::<LiveKitClaims>(
        lk_tok,
        &DecodingKey::from_secret(TEST_LK_SECRET.as_bytes()),
        &lk_val,
    )
    .expect("valid LiveKit HS256 JWT");
    assert_eq!(decoded.claims.iss, TEST_LK_KEY);
    assert_eq!(decoded.claims.sub, prae_id);
    assert!(decoded.claims.video.room_join);
    assert!(decoded.claims.video.can_publish);
    assert!(decoded.claims.video.can_subscribe);
    assert!(decoded.claims.video.can_publish_data);
    assert_eq!(
        decoded.claims.video.room,
        oa_call_start["call"]["room_name"].as_str().unwrap()
    );

    let prae_user_doc = state
        .db
        .collection::<bcaichat_backend::models::UserDoc>("users")
        .find_one(mongodb::bson::doc! { "_id": &prae_id })
        .await
        .unwrap()
        .unwrap();
    for (q_key, q_sec) in [
        (
            format!("\"{TEST_LK_KEY}\""),
            format!("\"{TEST_LK_SECRET}\""),
        ),
        (
            format!(" '{TEST_LK_KEY}' "),
            format!(" '{TEST_LK_SECRET}' "),
        ),
    ] {
        let q_tok = mint_livekit_token(&q_key, &q_sec, "room_quote_check", &prae_user_doc)
            .unwrap_or_else(|_| panic!("mint_livekit_token with quoted credentials"));
        let q_dec = jsonwebtoken::decode::<LiveKitClaims>(
            &q_tok,
            &DecodingKey::from_secret(TEST_LK_SECRET.as_bytes()),
            &lk_val,
        )
        .expect("quoted LiveKit credentials must sign with unquoted secret");
        assert_eq!(q_dec.claims.iss, TEST_LK_KEY);
    }

    // Check WS filtering (`can_receive`): owner, agent, shop_admin & customer receive `call_incoming`, while marketer & outsider do NOT!
    let mut incoming_raw = String::new();
    while let Ok(raw) = ws_rx.try_recv() {
        let ev: Value = serde_json::from_str(&raw).unwrap();
        if ev["event"] == "call_incoming" && ev["call"]["id"] == oa_call_id {
            incoming_raw = raw;
            break;
        }
    }
    assert!(!incoming_raw.is_empty(), "call_incoming WS event must be broadcast");
    assert!(can_receive(&state, &kong_id, "", &incoming_raw).await);
    assert!(can_receive(&state, &agent_id, "", &incoming_raw).await);
    assert!(can_receive(&state, &shop_adm_id, "", &incoming_raw).await);
    assert!(can_receive(&state, &prae_id, "", &incoming_raw).await);
    assert!(
        !can_receive(&state, &mkt_id, "", &incoming_raw).await,
        "marketer must not receive call_incoming"
    );
    assert!(
        !can_receive(&state, &boss_id, "", &incoming_raw).await,
        "outsider must not receive call_incoming"
    );
    // One account on two apps: the shop's staff get the shop call on the shop app only,
    // the customer gets it on the chat app only.
    for staff_id in [&kong_id, &agent_id, &shop_adm_id] {
        assert!(can_receive(&state, staff_id, "oa", &incoming_raw).await);
        assert!(
            !can_receive(&state, staff_id, "chat", &incoming_raw).await,
            "shop staff must not get a shop call on the chat app"
        );
    }
    assert!(can_receive(&state, &prae_id, "chat", &incoming_raw).await);
    assert!(
        !can_receive(&state, &prae_id, "oa", &incoming_raw).await,
        "customer must not get a shop call on the shop app"
    );

    // Shop room events without named targets (a customer writing to the shop) follow the same split;
    // a marketer is not inbox staff and gets none.
    let shop_room_event =
        json!({ "event": "oa_customer_message", "conversation_id": oa_conv_id }).to_string();
    for (user_id, on_legacy, on_chat, on_shop) in [
        (&agent_id, true, false, true),
        (&prae_id, true, true, false),
        (&mkt_id, false, false, false),
    ] {
        assert_eq!(can_receive(&state, user_id, "", &shop_room_event).await, on_legacy);
        assert_eq!(can_receive(&state, user_id, "chat", &shop_room_event).await, on_chat);
        assert_eq!(can_receive(&state, user_id, "oa", &shop_room_event).await, on_shop);
    }

    // Device registration records which app the install is; an unknown app name is rejected.
    let device_body = |client_app: Option<&str>| {
        let mut body = json!({
            "device_id": "it-kong-shop-app", "token": "it-token-kong-shop-app",
            "platform": "android", "popup": true, "sound": true,
            "sounds": { "normal": "pop", "urgent": "urgent", "ai": "robot" },
        });
        if let Some(name) = client_app {
            body["app"] = json!(name);
        }
        body
    };
    let devices_coll = state.db.collection::<mongodb::bson::Document>("device_tokens");
    for (sent, stored) in [(Some("oa"), "oa"), (None, "")] {
        let (status, res) =
            call(&app, "POST", "/api/devices", Some(&kong_token), Some(device_body(sent))).await;
        assert_eq!(status, StatusCode::OK, "{res}");
        let saved = devices_coll
            .find_one(mongodb::bson::doc! { "_id": "it-kong-shop-app" })
            .await
            .unwrap()
            .unwrap();
        assert_eq!(saved.get_str("app").unwrap(), stored);
    }
    let (status, _) = call(
        &app,
        "POST",
        "/api/devices",
        Some(&kong_token),
        Some(device_body(Some("shop"))),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) =
        call(&app, "DELETE", "/api/devices/it-kong-shop-app", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::OK);

    // GET /api/calls/active
    let (status, active_res) = call(
        &app,
        "GET",
        &format!("/api/calls/active?conversation_id={oa_conv_id}"),
        Some(&agent_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(active_res["calls"].as_array().unwrap().len(), 1);

    // Multi-staff OA call lifecycle:
    // 1) Agent declines -> call stays "ringing" for Owner & Shop Admin (NOT terminated!)
    while ws_rx.try_recv().is_ok() {}
    let (status, agent_dec_res) = call(
        &app,
        "POST",
        &format!("/api/calls/{oa_call_id}/decline"),
        Some(&agent_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{agent_dec_res}");
    assert_eq!(
        agent_dec_res["call"]["status"], "ringing",
        "1 staff declining an OA call must keep other staff ringing"
    );
    let dec_parts = agent_dec_res["call"]["participants"].as_array().unwrap();
    let part_state = |arr: &[Value], uid: &str| -> String {
        arr.iter()
            .find(|p| p["user_id"] == uid)
            .and_then(|p| p["state"].as_str())
            .unwrap_or("")
            .to_string()
    };
    assert_eq!(part_state(dec_parts, &agent_id), "declined");
    assert_eq!(part_state(dec_parts, &kong_id), "ringing");
    assert_eq!(part_state(dec_parts, &shop_adm_id), "ringing");
    assert_eq!(part_state(dec_parts, &prae_id), "joined");

    let mut saw_partial_declined_ws = false;
    let mut saw_partial_part_upd_ws = false;
    while let Ok(raw) = ws_rx.try_recv() {
        let ev: Value = serde_json::from_str(&raw).unwrap();
        if ev["call"]["id"] == oa_call_id {
            assert_ne!(
                ev["event"], "call_ended",
                "partial OA decline must not broadcast call_ended"
            );
            if ev["event"] == "call_declined" && ev["declined_by"] == agent_id {
                saw_partial_declined_ws = true;
            }
            if ev["event"] == "call_participant_updated" {
                saw_partial_part_upd_ws = true;
            }
        }
    }
    assert!(saw_partial_declined_ws);
    assert!(saw_partial_part_upd_ws);

    // Owner still sees OA call as active/ringing & accepts -> second ringing staff (`shop_adm`) transitions to `answered_elsewhere`!
    let (status, owner_active_res) = call(
        &app,
        "GET",
        &format!("/api/calls/active?conversation_id={oa_conv_id}"),
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(owner_active_res["calls"].as_array().unwrap().len(), 1);

    let (status, acc_res) = call(
        &app,
        "POST",
        &format!("/api/calls/{oa_call_id}/accept"),
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{acc_res}");
    assert_eq!(acc_res["call"]["status"], "active");
    assert!(acc_res["call"]["answered_at"].is_string());
    let acc_parts = acc_res["call"]["participants"].as_array().unwrap();
    assert_eq!(part_state(acc_parts, &kong_id), "joined");
    assert_eq!(part_state(acc_parts, &prae_id), "joined");
    assert_eq!(part_state(acc_parts, &agent_id), "declined");
    assert_eq!(
        part_state(acc_parts, &shop_adm_id),
        "answered_elsewhere",
        "other ringing shop staff must transition to answered_elsewhere when a colleague answers"
    );

    // GET /api/calls/:id/token
    let (status, tok_res) = call(
        &app,
        "GET",
        &format!("/api/calls/{oa_call_id}/token"),
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(!tok_res["token"].as_str().unwrap().is_empty());

    // Hangup -> status == "ended", duration_sec >= 1, call_log bubble inserted
    let (status, hang_res) = call(
        &app,
        "POST",
        &format!("/api/calls/{oa_call_id}/hangup"),
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{hang_res}");
    assert_eq!(hang_res["call"]["status"], "ended");
    assert!(hang_res["call"]["duration_sec"].as_u64().unwrap() >= 1);

    let (_, oa_msgs_after_call) = call(
        &app,
        "GET",
        &format!("/api/conversations/{oa_conv_id}/messages"),
        Some(&prae_token),
        None,
    )
    .await;
    let last_bubble = oa_msgs_after_call.as_array().unwrap().last().unwrap();
    assert_eq!(last_bubble["type"], "call_log");
    assert_eq!(last_bubble["card_payload"]["call_id"], oa_call_id);
    assert_eq!(last_bubble["card_payload"]["status"], "ended");

    // Remove marketer from OA team & verify list shrinks to 3
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/oa/{oa1_id}/admins/{mkt_id}"),
        Some(&shop_adm_tok),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, staff_after_del) = call(
        &app,
        "GET",
        &format!("/api/oa/{oa1_id}/admins"),
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(staff_after_del.as_array().unwrap().len(), 3);

    // Decline call in direct chat
    let (status, d_call) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&kong_token),
        Some(json!({ "conversation_id": direct_conv_id, "call_type": "audio" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let d_call_id = d_call["call"]["id"].as_str().unwrap().to_string();
    let (status, dec_res) = call(
        &app,
        "POST",
        &format!("/api/calls/{d_call_id}/decline"),
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(dec_res["call"]["status"], "declined");
    assert_eq!(dec_res["call"]["duration_sec"], 0);

    // 3-Way Group Call lifecycle on "แก๊งเพื่อนวันหยุด" (`conv_group_test_friends`):
    // Slot 3 (ภูมิ) calls -> Slot 2 (แพรไหม) declines (call stays ringing for Slot 1 & Slot 4) ->
    // BOTH Slot 1 (ต้นน้ำ) & Slot 4 (ใบบัว) accept (3 active joined) ->
    // Slot 4 hangs up (partial leave: 2 remain joined, status stays "active") ->
    // Slot 3 hangs up (< 2 remain -> call terminates with status == "ended" + call_log bubble)
    let (status, grp_start) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&test_tokens[2]),
        Some(json!({ "conversation_id": "conv_group_test_friends", "call_type": "video" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{grp_start}");
    let grp_call_id = grp_start["call"]["id"].as_str().unwrap().to_string();
    assert_eq!(grp_start["call"]["status"], "ringing");

    while ws_rx.try_recv().is_ok() {}
    let (status, grp_dec) = call(
        &app,
        "POST",
        &format!("/api/calls/{grp_call_id}/decline"),
        Some(&test_tokens[1]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{grp_dec}");
    assert_eq!(grp_dec["call"]["status"], "ringing");
    let grp_dec_parts = grp_dec["call"]["participants"].as_array().unwrap();
    assert_eq!(part_state(grp_dec_parts, TEST_USER_IDS[2]), "joined");
    assert_eq!(part_state(grp_dec_parts, TEST_USER_IDS[1]), "declined");
    assert_eq!(part_state(grp_dec_parts, TEST_USER_IDS[0]), "ringing");
    assert_eq!(part_state(grp_dec_parts, TEST_USER_IDS[3]), "ringing");

    let (status, grp_acc_1) = call(
        &app,
        "POST",
        &format!("/api/calls/{grp_call_id}/accept"),
        Some(&test_tokens[0]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{grp_acc_1}");
    assert_eq!(grp_acc_1["call"]["status"], "active");
    let grp_acc_1_parts = grp_acc_1["call"]["participants"].as_array().unwrap();
    assert_eq!(
        part_state(grp_acc_1_parts, TEST_USER_IDS[3]),
        "ringing",
        "non-OA group call accept must keep remaining group members ringing"
    );

    let (status, grp_acc_4) = call(
        &app,
        "POST",
        &format!("/api/calls/{grp_call_id}/accept"),
        Some(&test_tokens[3]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{grp_acc_4}");
    assert_eq!(grp_acc_4["call"]["status"], "active");
    let grp_acc_4_parts = grp_acc_4["call"]["participants"].as_array().unwrap();
    assert_eq!(
        grp_acc_4_parts
            .iter()
            .filter(|p| p["state"] == "joined")
            .count(),
        3
    );

    // Partial hangup: Slot 4 leaves while Slot 3 & Slot 1 remain talking -> call stays "active"!
    while ws_rx.try_recv().is_ok() {}
    let (status, grp_partial_hang) = call(
        &app,
        "POST",
        &format!("/api/calls/{grp_call_id}/hangup"),
        Some(&test_tokens[3]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{grp_partial_hang}");
    assert_eq!(
        grp_partial_hang["call"]["status"], "active",
        "1 of 3 active group call participants hanging up must NOT end the call for the remaining 2"
    );
    let grp_partial_parts = grp_partial_hang["call"]["participants"].as_array().unwrap();
    assert_eq!(part_state(grp_partial_parts, TEST_USER_IDS[3]), "left");
    assert_eq!(part_state(grp_partial_parts, TEST_USER_IDS[2]), "joined");
    assert_eq!(part_state(grp_partial_parts, TEST_USER_IDS[0]), "joined");

    let mut saw_grp_leave_upd = false;
    while let Ok(raw) = ws_rx.try_recv() {
        let ev: Value = serde_json::from_str(&raw).unwrap();
        if ev["call"]["id"] == grp_call_id {
            assert_ne!(
                ev["event"], "call_ended",
                "partial group hangup must not broadcast call_ended"
            );
            if ev["event"] == "call_participant_updated" {
                saw_grp_leave_upd = true;
            }
        }
    }
    assert!(saw_grp_leave_upd);

    // Final hangup: Slot 3 leaves -> only 1 joined remains (< 2) -> terminates call & logs bubble!
    let (status, grp_final_hang) = call(
        &app,
        "POST",
        &format!("/api/calls/{grp_call_id}/hangup"),
        Some(&test_tokens[2]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{grp_final_hang}");
    assert_eq!(grp_final_hang["call"]["status"], "ended");
    assert!(grp_final_hang["call"]["duration_sec"].as_u64().unwrap() >= 1);

    let (_, grp_msgs_after) = call(
        &app,
        "GET",
        "/api/conversations/conv_group_test_friends/messages",
        Some(&test_tokens[0]),
        None,
    )
    .await;
    let grp_last_bubble = grp_msgs_after.as_array().unwrap().last().unwrap();
    assert_eq!(grp_last_bubble["type"], "call_log");
    assert_eq!(grp_last_bubble["card_payload"]["call_id"], grp_call_id);
    assert_eq!(grp_last_bubble["card_payload"]["status"], "ended");

    // Fast Ringing Timeout -> "missed" + call_log bubble + WS "call_ended"
    let mut fast_cfg = config.clone();
    fast_cfg.call_ring_timeout_ms = 180;
    let fast_state = AppState {
        config: fast_cfg,
        db: state.db.clone(),
        minio: state.minio.clone(),
        ws_hub: state.ws_hub.clone(),
        push: None,
        token_versions: state.token_versions.clone(),
    };
    let fast_app = create_router(fast_state);

    while ws_rx.try_recv().is_ok() {}
    let (status, t_call) = call(
        &fast_app,
        "POST",
        "/api/calls/start",
        Some(&kong_token),
        Some(json!({ "conversation_id": direct_conv_id, "call_type": "audio" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let t_call_id = t_call["call"]["id"].as_str().unwrap().to_string();

    tokio::time::sleep(Duration::from_millis(360)).await;

    let (_, active_after_timeout) = call(
        &fast_app,
        "GET",
        &format!("/api/calls/active?conversation_id={direct_conv_id}"),
        Some(&kong_token),
        None,
    )
    .await;
    assert!(
        active_after_timeout["calls"].as_array().unwrap().is_empty(),
        "timed-out call must no longer be active"
    );

    let (_, direct_msgs) = call(
        &fast_app,
        "GET",
        &format!("/api/conversations/{direct_conv_id}/messages"),
        Some(&kong_token),
        None,
    )
    .await;
    let missed_bubble = direct_msgs.as_array().unwrap().last().unwrap();
    assert_eq!(missed_bubble["type"], "call_log");
    assert_eq!(missed_bubble["card_payload"]["call_id"], t_call_id);
    assert_eq!(missed_bubble["card_payload"]["status"], "missed");

    let mut saw_missed_ws = false;
    while let Ok(raw) = ws_rx.try_recv() {
        let ev: Value = serde_json::from_str(&raw).unwrap();
        if ev["event"] == "call_ended"
            && ev["call"]["id"] == t_call_id
            && ev["call"]["status"] == "missed"
        {
            saw_missed_ws = true;
        }
    }
    assert!(saw_missed_ws, "timeout must broadcast call_ended with status=missed");

    // =========================================================================
    // 9. Wave 2 (#52 & #53): Privacy, Reset QR, Add/Delete Friend, Mute & LINE Silent Block
    // =========================================================================
    let (status, mind_auth) = call(
        &app,
        "POST",
        "/api/auth/google",
        None,
        Some(json!({ "id_token": "valid_id_mind", "display_name": "มายด์ ซีรีส์" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let mind_id = mind_auth["user"]["id"].as_str().unwrap().to_string();
    let mind_token = mind_auth["token"].as_str().unwrap().to_string();
    let old_mind_qr = mind_auth["user"]["qr_token"].as_str().unwrap().to_string();

    let (_, mind_otp) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        Some(&mind_token),
        Some(json!({ "phone": "0865554444", "purpose": "link" })),
    )
    .await;
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/link/phone",
        Some(&mind_token),
        Some(json!({
            "challenge_id": mind_otp["challenge_id"],
            "otp_code": "654321"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Reset QR token -> old QR must fail, new QR via deep-link URL must work
    let (status, qr_res) = call(
        &app,
        "POST",
        "/api/users/me/reset-qr",
        Some(&mind_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{qr_res}");
    let new_mind_qr = qr_res["qr_token"].as_str().unwrap().to_string();
    assert_ne!(old_mind_qr, new_mind_qr);

    let (status, _) = call(
        &app,
        "POST",
        "/api/friends/add",
        Some(&boss_token),
        Some(json!({ "qr_token": old_mind_qr })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Disable allow_add_by_phone on Mind -> phone search empty & add by phone returns 403
    let (status, upd_priv) = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&mind_token),
        Some(json!({
            "allow_add_by_phone": false,
            "dnd_mode": "until_8am"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(upd_priv["allow_add_by_phone"], false);
    assert!(upd_priv["dnd_until"].is_string());

    let (_, phone_search) = call(
        &app,
        "GET",
        "/api/users/search?q=0865554444&by=phone",
        Some(&boss_token),
        None,
    )
    .await;
    assert!(phone_search.as_array().unwrap().is_empty());

    let (status, _) = call(
        &app,
        "POST",
        "/api/friends/add",
        Some(&boss_token),
        Some(json!({ "query": "0865554444" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Exact QR via deep-link URL still succeeds even when phone discovery is off
    let (status, add_qr_res) = call(
        &app,
        "POST",
        "/api/friends/add",
        Some(&boss_token),
        Some(json!({ "query": format!("https://bcaichat.local/add?qr={new_mind_qr}") })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{add_qr_res}");
    let boss_mind_conv_id = add_qr_res["conversation_id"].as_str().unwrap().to_string();

    // Hide vs Silent Block
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/friends/{boss_id}"),
        Some(&mind_token),
        Some(json!({ "is_hidden": true })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{boss_mind_conv_id}/messages"),
        Some(&boss_token),
        Some(json!({ "type": "text", "content": "ทักตอนถูกซ่อน" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, mind_msgs_hidden) = call(
        &app,
        "GET",
        &format!("/api/conversations/{boss_mind_conv_id}/messages"),
        Some(&mind_token),
        None,
    )
    .await;
    assert!(mind_msgs_hidden
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["content"] == "ทักตอนถูกซ่อน"));

    // Mind blocks Boss
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/friends/{boss_id}"),
        Some(&mind_token),
        Some(json!({ "is_blocked": true })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Blocker (Mind) cannot send or call until unblocking -> 400
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{boss_mind_conv_id}/messages"),
        Some(&mind_token),
        Some(json!({ "type": "text", "content": "ส่งไม่ได้เพราะบล็อกเอง" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&mind_token),
        Some(json!({ "conversation_id": boss_mind_conv_id, "call_type": "audio" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Blocked sender (Boss) gets 200 OK (silent drop!), sees own message, but Mind never sees it!
    while ws_rx.try_recv().is_ok() {}
    let (status, silent_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{boss_mind_conv_id}/messages"),
        Some(&boss_token),
        Some(json!({ "type": "text", "content": "ข้อความขณะโดนบล็อกเงียบ" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{silent_msg}");

    // Personal room events without named targets: members only, never on the shop app.
    let room_event =
        json!({ "event": "conversation_updated", "conversation_id": boss_mind_conv_id }).to_string();
    for client_app in ["", "chat"] {
        assert!(can_receive(&state, &boss_id, client_app, &room_event).await);
        assert!(
            !can_receive(&state, &kong_id, client_app, &room_event).await,
            "non-member must not get room events"
        );
    }
    assert!(!can_receive(&state, &boss_id, "oa", &room_event).await);
    let missing_room =
        json!({ "event": "conversation_updated", "conversation_id": "conv_missing" }).to_string();
    assert!(!can_receive(&state, &boss_id, "", &missing_room).await);

    let mut checked_silent_ws = false;
    while let Ok(raw) = ws_rx.try_recv() {
        let ev: Value = serde_json::from_str(&raw).unwrap();
        if ev["event"] == "new_message" && ev["message"]["id"] == silent_msg["id"] {
            assert!(can_receive(&state, &boss_id, "", &raw).await);
            assert!(can_receive(&state, &boss_id, "chat", &raw).await);
            assert!(
                !can_receive(&state, &boss_id, "oa", &raw).await,
                "personal chat must not reach the shop app"
            );
            assert!(!can_receive(&state, &mind_id, "", &raw).await);
            checked_silent_ws = true;
        }
    }
    assert!(checked_silent_ws);

    let (_, mind_msgs_blocked) = call(
        &app,
        "GET",
        &format!("/api/conversations/{boss_mind_conv_id}/messages"),
        Some(&mind_token),
        None,
    )
    .await;
    assert!(!mind_msgs_blocked
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["content"] == "ข้อความขณะโดนบล็อกเงียบ"));

    // Blocked 1-1 call from Boss -> Mind excluded from target_user_ids & call_log hidden from Mind
    let (status, blk_call) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&boss_token),
        Some(json!({ "conversation_id": boss_mind_conv_id, "call_type": "audio" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let blk_targets = blk_call["call"]["target_user_ids"].as_array().unwrap();
    assert!(!blk_targets.iter().any(|u| u.as_str() == Some(mind_id.as_str())));
    let blk_call_id = blk_call["call"]["id"].as_str().unwrap();
    let _ = call(
        &app,
        "POST",
        &format!("/api/calls/{blk_call_id}/hangup"),
        Some(&boss_token),
        None,
    )
    .await;

    // Unblock -> messages flow normally again, then DELETE /api/friends/:id
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/friends/{boss_id}"),
        Some(&mind_token),
        Some(json!({ "is_blocked": false })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, del_friend_res) = call(
        &app,
        "DELETE",
        &format!("/api/friends/{boss_id}"),
        Some(&mind_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(del_friend_res["ok"], true);

    // Timed conversation mute (1h -> until_8am -> off) on /api/conversations/:id
    let (status, muted_conv) = call(
        &app,
        "PUT",
        &format!("/api/conversations/{direct_conv_id}"),
        Some(&kong_token),
        Some(json!({ "mute_duration": "1h" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(muted_conv["is_muted"], true);
    assert!(muted_conv["muted_until"].is_string());

    let (status, unmuted_conv) = call(
        &app,
        "PUT",
        &format!("/api/conversations/{direct_conv_id}/meta"),
        Some(&kong_token),
        Some(json!({ "mute_duration": "off" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(unmuted_conv["is_muted"], false);
    assert!(unmuted_conv["muted_until"].is_null());

    // =========================================================================
    // 10. Wave 3 (#56): Account Linking, Unlink Guard, PIN + Backup Codes,
    //     Recover Change Phone / Change Google, O(1) Revocation & 5-Attempt Lockout
    // =========================================================================
    // Unlink Gmail must be blocked when Boss has NO verified phone
    let (status, _) = call(
        &app,
        "DELETE",
        "/api/auth/link/google",
        Some(&boss_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Setup Recovery PIN + 6 salted backup codes on Kong
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/recovery/setup",
        Some(&kong_token),
        Some(json!({ "recovery_pin": "12ab" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, setup_res) = call(
        &app,
        "POST",
        "/api/auth/recovery/setup",
        Some(&kong_token),
        Some(json!({ "recovery_pin": "246810" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{setup_res}");
    assert_eq!(setup_res["user"]["has_recovery_pin"], true);
    assert_eq!(setup_res["user"]["recovery_codes_remaining"], 6);
    assert!(setup_res["user"].get("recovery_pin_hash").is_none());
    assert!(setup_res["user"].get("recovery_code_hashes").is_none());
    let backup_codes: Vec<String> = setup_res["backup_codes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(backup_codes.len(), 6);
    assert!(backup_codes[0].starts_with("BCRC-"));

    // Changing PIN requires current_pin
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/recovery/setup",
        Some(&kong_token),
        Some(json!({ "recovery_pin": "135790" })),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, pin_changed) = call(
        &app,
        "POST",
        "/api/auth/recovery/setup",
        Some(&kong_token),
        Some(json!({
            "current_pin": "246810",
            "recovery_pin": "135790",
            "regenerate_codes": false
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(pin_changed["user"]["recovery_codes_remaining"], 6);

    // Scenario A: Lost SIM -> Recover & Change Phone via Google OAuth mode="recover" (NO JWT!)
    let rec_state = "state_recover_kong_phone_999";
    let start_rec = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/auth/google/start?mode=recover&state={rec_state}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(start_rec.status(), StatusCode::TEMPORARY_REDIRECT);

    let (status, comp_rec) = call(
        &app,
        "POST",
        "/api/auth/google/complete",
        None,
        Some(json!({ "state": rec_state, "id_token": "valid_id_kong" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{comp_rec}");
    assert_eq!(comp_rec["status"], "verified_for_recovery");
    assert!(comp_rec.get("token").is_none());

    let (status, poll_rec) = call(
        &app,
        "GET",
        &format!("/api/auth/google/poll?state={rec_state}"),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(poll_rec["status"], "verified_for_recovery");
    assert_eq!(poll_rec["email"], "kong@example.com");

    // Phone collision check (trying to claim Prae's already-linked phone 0891112222 -> 400)
    let (_, col_otp) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "0891112222", "purpose": "recover" })),
    )
    .await;
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/recover/change-phone",
        None,
        Some(json!({
            "method": "google",
            "google_oauth_state": rec_state,
            "new_phone_challenge_id": col_otp["challenge_id"],
            "new_phone_otp_code": "654321"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Recover & switch Kong to new phone 0928887777
    let (_, new_ph_otp) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "0928887777", "purpose": "recover" })),
    )
    .await;
    let old_kong_token = kong_token.clone();
    let (status, rec_ph_res) = call(
        &app,
        "POST",
        "/api/auth/recover/change-phone",
        None,
        Some(json!({
            "method": "google",
            "google_oauth_state": rec_state,
            "new_phone_challenge_id": new_ph_otp["challenge_id"],
            "new_phone_otp_code": "654321"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{rec_ph_res}");
    assert_eq!(rec_ph_res["recovered"], true);
    assert_eq!(rec_ph_res["user"]["id"], kong_id);
    assert_eq!(rec_ph_res["user"]["phone"], "0928887777");
    let mut kong_token = rec_ph_res["token"].as_str().unwrap().to_string();

    // Old JWT must immediately fail with 401 via O(1) in-memory token_versions!
    let (status, _) = call(&app, "GET", "/api/users/me", Some(&old_kong_token), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, me_after_rec) = call(&app, "GET", "/api/users/me", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me_after_rec["id"], kong_id);

    // Consumed Google recovery state cannot be replayed
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/recover/change-phone",
        None,
        Some(json!({
            "method": "google",
            "google_oauth_state": rec_state,
            "new_phone_challenge_id": "unused",
            "new_phone_otp_code": "654321"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Scenario B: Recover & Change Phone via 1-time Backup Code (consumes code!)
    let (_, ph_otp_b) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "0937776666", "purpose": "recover" })),
    )
    .await;
    let (status, rec_by_code) = call(
        &app,
        "POST",
        "/api/auth/recover/change-phone",
        None,
        Some(json!({
            "method": "pin_or_code",
            "identifier": "0928887777",
            "recovery_secret": backup_codes[0].to_lowercase().replace('-', ""),
            "new_phone_challenge_id": ph_otp_b["challenge_id"],
            "new_phone_otp_code": "654321"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{rec_by_code}");
    assert_eq!(rec_by_code["user"]["phone"], "0937776666");
    assert_eq!(rec_by_code["user"]["recovery_codes_remaining"], 5);
    kong_token = rec_by_code["token"].as_str().unwrap().to_string();

    // Reusing consumed backup code[0] must fail with 401
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/recover/change-phone",
        None,
        Some(json!({
            "method": "pin_or_code",
            "identifier": "0937776666",
            "recovery_secret": &backup_codes[0],
            "new_phone_challenge_id": "unused",
            "new_phone_otp_code": "654321"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Scenario C: Lost Gmail -> Collision check + Recover & Change Google via Phone OTP
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/recover/change-google",
        None,
        Some(json!({
            "method": "pin_or_code",
            "identifier": "0937776666",
            "recovery_secret": "135790",
            "new_google_id_token": "valid_id_prae"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Expire previous verified OTP cooldown not needed because verified=true does not block new OTP!
    let (status, kong_rec_otp) = call(
        &app,
        "POST",
        "/api/auth/otp/request",
        None,
        Some(json!({ "phone": "0937776666", "purpose": "recover" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{kong_rec_otp}");
    let prev_kong_tok = kong_token.clone();
    let (status, rec_google_res) = call(
        &app,
        "POST",
        "/api/auth/recover/change-google",
        None,
        Some(json!({
            "method": "phone_otp",
            "phone_challenge_id": kong_rec_otp["challenge_id"],
            "phone_otp_code": "654321",
            "new_google_id_token": "valid_id_kong_recovered"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{rec_google_res}");
    assert_eq!(rec_google_res["user"]["id"], kong_id);
    assert_eq!(
        rec_google_res["user"]["email"],
        "kong_recovered@example.com"
    );
    assert_eq!(
        call(&app, "GET", "/api/users/me", Some(&prev_kong_tok), None)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    kong_token = rec_google_res["token"].as_str().unwrap().to_string();

    // Verify Kong's OA shop & chat history remain 100% intact across phone & Gmail recovery!
    let (status, kong_oas_after) =
        call(&app, "GET", "/api/oa/mine", Some(&kong_token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(kong_oas_after
        .as_array()
        .unwrap()
        .iter()
        .any(|o| o["id"] == oa1_id));

    // Unlink Gmail succeeds for Prae (who has verified phone 0891112222), then relink
    let (status, unlinked_prae) = call(
        &app,
        "DELETE",
        "/api/auth/link/google",
        Some(&prae_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{unlinked_prae}");
    assert_eq!(unlinked_prae["user"]["email"], "");
    assert_eq!(unlinked_prae["user"]["has_google_linked"], false);
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/link/google",
        Some(&prae_token),
        Some(json!({ "id_token": "valid_id_prae" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // 5-Attempt Wrong PIN Brute-Force Lockout (429 Too Many Requests)
    let (_, lock_auth) = call(
        &app,
        "POST",
        "/api/auth/google",
        None,
        Some(json!({ "id_token": "valid_id_lockuser" })),
    )
    .await;
    let lock_tok = lock_auth["token"].as_str().unwrap();
    let (status, _) = call(
        &app,
        "POST",
        "/api/auth/recovery/setup",
        Some(lock_tok),
        Some(json!({ "recovery_pin": "112233" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    for attempt in 1..=5 {
        let (st, _) = call(
            &app,
            "POST",
            "/api/auth/recover/change-google",
            None,
            Some(json!({
                "method": "pin_or_code",
                "identifier": "lockuser@example.com",
                "recovery_secret": "999999",
                "new_google_id_token": "valid_id_lockuser_new"
            })),
        )
        .await;
        if attempt < 5 {
            assert_eq!(st, StatusCode::UNAUTHORIZED);
        } else {
            assert_eq!(st, StatusCode::TOO_MANY_REQUESTS);
        }
    }
    // Even correct PIN is rejected with 429 during the 15-minute lockout window
    let (st_locked, _) = call(
        &app,
        "POST",
        "/api/auth/recover/change-google",
        None,
        Some(json!({
            "method": "pin_or_code",
            "identifier": "lockuser@example.com",
            "recovery_secret": "112233",
            "new_google_id_token": "valid_id_lockuser_new"
        })),
    )
    .await;
    assert_eq!(st_locked, StatusCode::TOO_MANY_REQUESTS);

    // Audit Logs masked check
    let (status, rec_logs) = call(
        &app,
        "GET",
        "/api/auth/recovery/logs",
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{rec_logs}");
    let logs_arr = rec_logs["logs"].as_array().unwrap();
    assert!(logs_arr.len() >= 4);
    assert!(logs_arr[0]["id"].is_string());
    let logs_raw = rec_logs.to_string();
    assert!(!logs_raw.contains("0937776666"));
    assert!(!logs_raw.contains("135790"));
    assert!(!logs_raw.contains(&backup_codes[0]));

    // =========================================================================
    // 11. Wave 4 (#60): Share Location, Contact Card, Ladder Game, Edit Message,
    //     Forward Message & Personal Keep Memo
    // =========================================================================
    // Invalid latitude (95.0) -> 400
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{direct_conv_id}/messages"),
        Some(&kong_token),
        Some(json!({
            "type": "location",
            "location_data": {
                "latitude": 95.0,
                "longitude": 103.2618,
                "title": "พิกัดผิด"
            }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Valid Share Location -> auto-generates Google Maps URL & Thai location summary
    let (status, loc_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{direct_conv_id}/messages"),
        Some(&kong_token),
        Some(json!({
            "type": "location",
            "location_data": {
                "latitude": 17.4069,
                "longitude": 103.2618,
                "title": "พิพิธภัณฑ์บ้านเชียง",
                "address": "หนองหาน อุดรธานี"
            }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{loc_msg}");
    assert_eq!(loc_msg["type"], "location");
    assert_eq!(
        loc_msg["location_data"]["map_url"],
        "https://www.google.com/maps/search/?api=1&query=17.4069,103.2618"
    );
    assert_eq!(loc_msg["content"], "📍 ตำแหน่งที่ตั้ง: พิพิธภัณฑ์บ้านเชียง");
    let loc_msg_id = loc_msg["id"].as_str().unwrap().to_string();

    // Contact Card
    let (status, contact_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{direct_conv_id}/messages"),
        Some(&kong_token),
        Some(json!({
            "type": "contact",
            "contact_data": {
                "user_id": prae_id,
                "display_name": "แพร คาเฟ่",
                "bc_id": "@prae.bc"
            }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{contact_msg}");
    assert_eq!(contact_msg["type"], "contact");
    assert_eq!(contact_msg["contact_data"]["user_id"], prae_id);
    assert_eq!(contact_msg["content"], "👤 แนะนำเพื่อน: แพร คาเฟ่");

    // Ladder Game
    let (status, ladder_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{direct_conv_id}/messages"),
        Some(&kong_token),
        Some(json!({
            "type": "ladder",
            "ladder_data": {
                "title": "ใครเลี้ยงกาแฟบ่ายนี้",
                "entries": [
                    { "player": "ก้อง", "result": "เลี้ยงอเมริกาโน่" },
                    { "player": "แพร", "result": "รอดตัว!" }
                ]
            }
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{ladder_msg}");
    assert_eq!(ladder_msg["type"], "ladder");
    assert_eq!(
        ladder_msg["ladder_data"]["entries"].as_array().unwrap().len(),
        2
    );

    // Edit Message: non-sender gets 403, sender gets 200 + edited_at + WS "message_edited"
    let (status, editable_msg) = call(
        &app,
        "POST",
        &format!("/api/conversations/{direct_conv_id}/messages"),
        Some(&kong_token),
        Some(json!({ "type": "text", "content": "พิมพ์ผิดนิดนึง", "priority": "silent" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let edit_msg_id = editable_msg["id"].as_str().unwrap().to_string();

    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/messages/{edit_msg_id}"),
        Some(&prae_token),
        Some(json!({ "content": "แอบแก้ของคนอื่น" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    while ws_rx.try_recv().is_ok() {}
    let (status, edited_res) = call(
        &app,
        "PUT",
        &format!("/api/messages/{edit_msg_id}"),
        Some(&kong_token),
        Some(json!({ "content": "พิมพ์ถูกแล้วครับ!" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{edited_res}");
    assert_eq!(edited_res["content"], "พิมพ์ถูกแล้วครับ!");
    assert!(edited_res["edited_at"].is_string());

    let mut saw_edit_ws = false;
    while let Ok(raw) = ws_rx.try_recv() {
        let ev: Value = serde_json::from_str(&raw).unwrap();
        if ev["event"] == "message_edited" && ev["message"]["id"] == edit_msg_id {
            saw_edit_ws = true;
        }
    }
    assert!(saw_edit_ws, "editing message must broadcast message_edited");

    // Personal Keep Memo: POST /api/conversations/keep + POST /api/messages/:id/save-to-keep
    let (status, keep_conv) = call(
        &app,
        "POST",
        "/api/conversations/keep",
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{keep_conv}");
    let expected_keep_id = format!("conv_keep_{kong_id}");
    assert_eq!(keep_conv["id"], expected_keep_id);
    assert_eq!(keep_conv["type"], "keep");
    assert_eq!(keep_conv["is_pinned"], false);

    let (_, personal_convs) = call(
        &app,
        "GET",
        "/api/conversations?folder=personal",
        Some(&kong_token),
        None,
    )
    .await;
    assert!(personal_convs
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["id"] == expected_keep_id));

    let (status, saved_keep_msg) = call(
        &app,
        "POST",
        &format!("/api/messages/{loc_msg_id}/save-to-keep"),
        Some(&kong_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved_keep_msg}");
    assert_eq!(saved_keep_msg["conversation_id"], expected_keep_id);
    assert_eq!(saved_keep_msg["type"], "location");
    assert!(saved_keep_msg["forwarded_from"].is_string());

    // Forward Message to multiple conversations
    let (status, fwd_res) = call(
        &app,
        "POST",
        &format!("/api/messages/{loc_msg_id}/forward"),
        Some(&kong_token),
        Some(json!({
            "target_conversation_ids": [&expected_keep_id, &direct_conv_id]
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{fwd_res}");
    assert_eq!(fwd_res["forwarded_count"], 2);
    assert!(fwd_res["messages"][0]["forwarded_from"].is_string());

    // Drop isolated test DB cleanly
    let _ = state.db.drop().await;
}

#[tokio::test]
async fn test_quick_test_users_disabled_and_fail_closed_defaults() {
    // 1. Fail-closed config resolution when neither ENABLE_TEST_USERS nor loopback PUBLIC_BASE_URL is explicitly set
    assert!(!resolve_enable_test_users(None, None));
    assert!(!resolve_enable_test_users(Some(""), Some("")));
    assert!(!resolve_enable_test_users(
        None,
        Some("https://chat.bcaichat.app")
    ));
    assert!(resolve_enable_test_users(
        None,
        Some("http://127.0.0.1:8096")
    ));
    assert!(!resolve_enable_test_users(
        Some("false"),
        Some("http://127.0.0.1:8096")
    ));

    // 2. When enable_test_users == false, seed_initial_data skips 5 test users & POST /api/auth/test-login returns 403 Forbidden
    let run_short = &uuid::Uuid::new_v4().simple().to_string()[..8];
    let mut config = AppConfig::from_env();
    config.mongodb_db = format!("bcaichat_api_it_notest_{run_short}");
    config.enable_test_users = false;
    config.deepseek_api_key.clear();

    let state = AppState::init(config).await.expect("init AppState");
    seed_initial_data(&state).await.expect("seed initial data");

    let users_coll = state.db.collection::<mongodb::bson::Document>("users");
    let seeded_test_count = users_coll
        .count_documents(mongodb::bson::doc! { "_id": { "$in": Vec::from(TEST_USER_IDS) } })
        .await
        .expect("count test users");
    assert_eq!(
        seeded_test_count, 0,
        "TEST_USER_IDS must NOT be seeded when enable_test_users == false"
    );

    let oa_coll = state.db.collection::<mongodb::bson::Document>("official_accounts");
    let seeded_oa_count = oa_coll
        .count_documents(mongodb::bson::doc! { "_id": "oa_test_chabanchiang" })
        .await
        .expect("count test shop");
    assert_eq!(seeded_oa_count, 0);

    let app = create_router(state.clone());

    let (status, auth_cfg) = call(&app, "GET", "/api/auth/config", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(auth_cfg["demo_enabled"], false);
    assert_eq!(auth_cfg["test_users_enabled"], false);
    assert_eq!(auth_cfg["test_users"].as_array().unwrap().len(), 0);

    let (status, err_res) = call(
        &app,
        "POST",
        "/api/auth/test-login",
        None,
        Some(json!({ "slot": 1 })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{err_res}");

    let _ = state.db.drop().await;
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut req = Request::builder().method(method).uri(uri);
    if let Some(t) = token {
        req = req.header("authorization", format!("Bearer {t}"));
    }
    let req = match body {
        Some(b) => req
            .header("content-type", "application/json")
            .body(Body::from(b.to_string())),
        None => req.body(Body::empty()),
    }
    .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}
