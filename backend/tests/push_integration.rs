//! Push path end to end against a mock FCM + mock Google OAuth:
//! service-account JWT -> OAuth token -> messages:send, device validation,
//! 503 retry, UNREGISTERED cleanup, and incoming/cancelled LiveKit call pushes.
//! Zero real SMSMKT or external network calls.

use std::{
    collections::HashMap,
    path::Path,
    process::Command,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    body::Body,
    extract::{Query, State},
    http::{HeaderMap, Request, StatusCode, Uri},
    routing::{get, post},
    Form, Json, Router,
};
use bcaichat_backend::{config::AppConfig, create_router, seed::seed_initial_data, AppState};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde_json::{json, Value};
use tower::ServiceExt;

#[derive(Clone, Default)]
struct MockFcm {
    assertions: Arc<Mutex<Vec<String>>>,
    sends: Arc<Mutex<Vec<Value>>>,
}

async fn mock_token(
    State(m): State<MockFcm>,
    Form(form): Form<HashMap<String, String>>,
) -> Json<Value> {
    assert_eq!(
        form["grant_type"],
        "urn:ietf:params:oauth:grant-type:jwt-bearer"
    );
    m.assertions.lock().unwrap().push(form["assertion"].clone());
    Json(json!({ "access_token": "mock-access", "expires_in": 3600, "token_type": "Bearer" }))
}

async fn mock_google_tokeninfo(
    Query(q): Query<HashMap<String, String>>,
) -> (StatusCode, Json<Value>) {
    let Some(id_token) = q.get("id_token") else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "invalid_token" })),
        );
    };
    let Some(slug) = id_token.strip_prefix("valid_push_") else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "invalid_token" })),
        );
    };
    (
        StatusCode::OK,
        Json(json!({
            "aud": "mock-push-google-client.apps.googleusercontent.com",
            "sub": format!("gsub_push_{slug}"),
            "email": format!("{slug}@push.example.com"),
            "email_verified": "true",
            "name": format!("สมาชิก {slug}"),
            "picture": "",
        })),
    )
}

async fn mock_send(
    State(m): State<MockFcm>,
    uri: Uri,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    assert_eq!(uri.path(), "/v1/projects/test-proj/messages:send");
    assert_eq!(headers["authorization"], "Bearer mock-access");
    let tok = body["message"]["token"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let dead = tok == "dead-token";
    let prev_attempts = {
        let mut sends = m.sends.lock().unwrap();
        let count = sends
            .iter()
            .filter(|s| s["message"]["token"].as_str() == Some(tok.as_str()))
            .count();
        sends.push(body);
        count
    };
    if tok.starts_with("tok-503-") && prev_attempts == 0 {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "code": 503,
                    "status": "UNAVAILABLE",
                    "message": "The service is currently unavailable."
                }
            })),
        );
    }
    if dead {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({
                "error": {
                    "code": 404,
                    "status": "NOT_FOUND",
                    "message": "Requested entity was not found.",
                    "details": [{
                        "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                        "errorCode": "UNREGISTERED"
                    }]
                }
            })),
        );
    }
    (
        StatusCode::OK,
        Json(json!({ "name": "projects/test-proj/messages/1" })),
    )
}

fn openssl(args: &[&str]) -> String {
    let git_openssl = r"C:\Program Files\Git\usr\bin\openssl.exe";
    let out = Command::new("openssl")
        .args(args)
        .output()
        .or_else(|_| {
            if Path::new(git_openssl).exists() {
                Command::new(git_openssl).args(args).output()
            } else {
                Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "openssl not found",
                ))
            }
        })
        .expect("openssl on PATH or Git usr/bin");
    assert!(out.status.success(), "openssl {args:?} failed");
    String::from_utf8(out.stdout).unwrap()
}

#[tokio::test]
async fn test_push_to_offline_devices_and_call_notifications_through_fcm() {
    let run_short = &uuid::Uuid::new_v4().simple().to_string()[..8];
    let dir = std::env::temp_dir().join(format!("bcaichat_push_{run_short}"));
    std::fs::create_dir_all(&dir).unwrap();
    let key_file = dir.join("key.pem");
    let private_pem = openssl(&[
        "genpkey",
        "-algorithm",
        "RSA",
        "-pkeyopt",
        "rsa_keygen_bits:2048",
    ]);
    std::fs::write(&key_file, &private_pem).unwrap();
    let public_pem = openssl(&["pkey", "-in", key_file.to_str().unwrap(), "-pubout"]);

    let mock = MockFcm::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let mock_app = Router::new()
        .route("/token", post(mock_token))
        .route("/tokeninfo", get(mock_google_tokeninfo))
        .fallback(mock_send)
        .with_state(mock.clone());
    tokio::spawn(async move { axum::serve(listener, mock_app).await.unwrap() });

    let sa_file = dir.join("service-account.json");
    std::fs::write(
        &sa_file,
        json!({
            "type": "service_account",
            "project_id": "test-proj",
            "private_key_id": "test-key-id",
            "private_key": private_pem,
            "client_email": "push@test-proj.example.com",
            "token_uri": format!("{base}/token"),
        })
        .to_string(),
    )
    .unwrap();

    let mut config = AppConfig::from_env();
    config.mongodb_db = format!("bcaichat_push_it_{run_short}");
    config.fcm_service_account_file = sa_file.to_string_lossy().into_owned();
    config.fcm_api_base = base.clone();
    config.fcm_web_api_key.clear();
    config.google_oauth_verify_base = base.clone();
    config.google_client_id = "mock-push-google-client.apps.googleusercontent.com".to_string();
    config.smsmkt_base_url = base.clone();
    config.livekit_url = "ws://127.0.0.1:7880".to_string();
    config.livekit_api_key = "bcaichat_lk_dev_key".to_string();
    config.livekit_api_secret = "bcaichat_lk_dev_secret_key_2026_local_only".to_string(); // pragma: allowlist secret
    config.deepseek_api_key.clear();

    let state = AppState::init(config).await.expect("init AppState");
    assert!(state.push.is_some(), "push must load the service account");
    seed_initial_data(&state).await.expect("seed");
    let app = create_router(state.clone());

    // Register 5 real verified accounts through mocked Google OAuth
    let mut tokens = Vec::new();
    let mut user_ids = Vec::new();
    let mut user_names = Vec::new();
    for idx in 1..=5 {
        let (status, body) = call(
            &app,
            "POST",
            "/api/auth/google",
            None,
            Some(json!({ "id_token": format!("valid_push_u{idx}") })),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "google auth {idx}: {body}");
        tokens.push(body["token"].as_str().unwrap().to_string());
        user_ids.push(body["user"]["id"].as_str().unwrap().to_string());
        user_names.push(body["user"]["display_name"].as_str().unwrap().to_string());
    }

    // Create a 5-member group room
    let (status, group) = call(
        &app,
        "POST",
        "/api/conversations/group",
        Some(&tokens[0]),
        Some(json!({
            "name": "แก๊งเพื่อนสนิท 5 คน",
            "member_ids": [&user_ids[1], &user_ids[2], &user_ids[3], &user_ids[4]],
            "folder": "group"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let group_id = group["id"].as_str().unwrap().to_string();

    let dev = |n: usize| format!("test-{n}-{run_short}");
    let sounds = json!({ "normal": "chime", "urgent": "urgent", "ai": "robot" });
    let register = |n: usize, token: &str, popup: bool| {
        json!({
            "device_id": dev(n),
            "token": token,
            "platform": "android",
            "popup": popup,
            "sound": true,
            "sounds": sounds
        })
    };

    // Input rules
    let mut bad = register(9, "tok", true);
    bad["platform"] = json!("symbian_os");
    let (status, _) = call(&app, "POST", "/api/devices", Some(&tokens[1]), Some(bad)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let mut bad = register(9, "tok", true);
    bad["sounds"]["normal"] = json!("../../etc");
    let (status, _) = call(&app, "POST", "/api/devices", Some(&tokens[1]), Some(bad)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = call(&app, "POST", "/api/devices", None, Some(register(9, "tok", true))).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // u1 = sender, u2 = normal, u3 = UNREGISTERED dead-token, u4 = popup off, u5 = 503 then 200
    let ok_token = format!("tok-ok-{run_short}");
    let own_token = format!("tok-own-{run_short}");
    let flaky_token = format!("tok-503-{run_short}");
    for (i, (token, popup)) in [
        (own_token.as_str(), true),
        (ok_token.as_str(), true),
        ("dead-token", true),
        ("tok-quiet", false),
        (flaky_token.as_str(), true),
    ]
    .into_iter()
    .enumerate()
    {
        let (status, body) = call(
            &app,
            "POST",
            "/api/devices",
            Some(&tokens[i]),
            Some(register(i + 1, token, popup)),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["push"], true);
    }

    // Only the device owner can remove a device
    let devices = state.db.collection::<bson::Document>("device_tokens");
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/devices/{}", dev(2)),
        Some(&tokens[0]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(devices
        .find_one(bson::doc! { "_id": dev(2) })
        .await
        .unwrap()
        .is_some());

    let (status, cfg) = call(&app, "GET", "/api/push/config", Some(&tokens[1]), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(cfg, json!({ "enabled": true, "web": null }));

    let text = format!("ชวนไปกินข้าวเสาร์นี้ {run_short}");
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{group_id}/messages"),
        Some(&tokens[0]),
        Some(json!({ "type": "text", "content": text })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let mut gone = false;
    for _ in 0..40 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let sent = mock.sends.lock().unwrap().len();
        gone = devices
            .find_one(bson::doc! { "_id": dev(3) })
            .await
            .unwrap()
            .is_none();
        if sent >= 4 && gone {
            break;
        }
    }

    let sends = mock.sends.lock().unwrap().clone();
    let to: Vec<&str> = sends
        .iter()
        .filter_map(|s| s["message"]["token"].as_str())
        .collect();
    assert_eq!(
        to.iter().filter(|&&t| t == flaky_token.as_str()).count(),
        2,
        "503 response must be retried and succeed on the next attempt: {to:?}"
    );
    assert_eq!(
        sends.len(),
        4,
        "offline devices with pop-ups on (including 1 retry): {to:?}"
    );
    assert!(to.contains(&ok_token.as_str()) && to.contains(&"dead-token"));
    assert!(gone, "UNREGISTERED token must be deleted");
    assert!(
        devices
            .find_one(bson::doc! { "_id": dev(5) })
            .await
            .unwrap()
            .is_some(),
        "transient 503 token must not be deleted"
    );

    let msg = &sends
        .iter()
        .find(|s| s["message"]["token"] == ok_token.as_str())
        .unwrap()["message"];
    assert_eq!(msg["data"]["conversation_id"], group_id);
    assert_eq!(msg["data"]["silent"], "0");
    assert_eq!(msg["android"]["priority"], "high");
    assert_eq!(msg["android"]["notification"]["channel_id"], "push_chime");
    assert_eq!(msg["android"]["notification"]["sound"], "alert_chime");
    assert_eq!(msg["android"]["notification"]["tag"], group_id);
    assert_eq!(msg["android"]["notification"]["title"], "แก๊งเพื่อนสนิท 5 คน");
    assert_eq!(
        msg["android"]["notification"]["body"],
        format!("{}: {text}", user_names[0])
    );

    // One OAuth exchange, with an RS256 JWT Google would accept
    let assertions = mock.assertions.lock().unwrap().clone();
    assert_eq!(assertions.len(), 1, "access token must be cached");
    let mut v = Validation::new(Algorithm::RS256);
    v.set_audience(&[format!("{base}/token")]);
    v.set_issuer(&["push@test-proj.example.com"]);
    let jwt = jsonwebtoken::decode::<Value>(
        &assertions[0],
        &DecodingKey::from_rsa_pem(public_pem.as_bytes()).unwrap(),
        &v,
    )
    .expect("valid JWT");
    assert_eq!(jwt.header.kid.as_deref(), Some("test-key-id"));
    assert_eq!(
        jwt.claims["scope"],
        "https://www.googleapis.com/auth/firebase.messaging"
    );

    // Incoming video call push & cancel push on hangup
    mock.sends.lock().unwrap().clear();
    let (status, started) = call(
        &app,
        "POST",
        "/api/calls/start",
        Some(&tokens[0]),
        Some(json!({ "conversation_id": group_id, "call_type": "video" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{started}");
    let call_id = started["call"]["id"].as_str().unwrap().to_string();

    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(40)).await;
        if mock.sends.lock().unwrap().len() >= 2 {
            break;
        }
    }
    let call_sends = mock.sends.lock().unwrap().clone();
    assert_eq!(
        call_sends.len(),
        2,
        "remaining 2 offline popup devices (u2 & u5) must receive incoming call push"
    );
    let call_push = &call_sends
        .iter()
        .find(|s| s["message"]["token"] == ok_token.as_str())
        .unwrap()["message"];
    assert_eq!(call_push["data"]["event"], "call_incoming");
    assert_eq!(call_push["data"]["call_id"], call_id);
    assert_eq!(call_push["data"]["call_type"], "video");
    assert_eq!(
        call_push["android"]["notification"]["channel_id"],
        "push_urgent"
    );

    mock.sends.lock().unwrap().clear();
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/calls/{call_id}/hangup"),
        Some(&tokens[0]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(40)).await;
        if mock.sends.lock().unwrap().len() >= 2 {
            break;
        }
    }
    let cancel_sends = mock.sends.lock().unwrap().clone();
    assert_eq!(cancel_sends.len(), 2);
    let cancel_push = &cancel_sends
        .iter()
        .find(|s| s["message"]["token"] == ok_token.as_str())
        .unwrap()["message"];
    assert_eq!(cancel_push["data"]["event"], "call_ended");
    assert_eq!(cancel_push["data"]["call_id"], call_id);
    assert_eq!(cancel_push["data"]["silent"], "1");

    // Wave 2 (#52): notify_preview=false masks push body to "คุณมีข้อความใหม่"
    let (status, _) = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&tokens[1]),
        Some(json!({ "notify_preview": false })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    mock.sends.lock().unwrap().clear();
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/conversations/{group_id}/messages"),
        Some(&tokens[0]),
        Some(json!({ "type": "text", "content": "ความลับห้ามโชว์พรีวิว" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(40)).await;
        if mock.sends.lock().unwrap().len() >= 2 {
            break;
        }
    }
    let masked_sends = mock.sends.lock().unwrap().clone();
    let u2_masked = &masked_sends
        .iter()
        .find(|s| s["message"]["token"] == ok_token.as_str())
        .unwrap()["message"];
    assert_eq!(
        u2_masked["android"]["notification"]["body"],
        "คุณมีข้อความใหม่"
    );
    let _ = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&tokens[1]),
        Some(json!({ "notify_preview": true })),
    )
    .await;

    // Mute room for u2 -> normal text skipped, @all mention overrides mute, Global DND suppresses even @all
    let (status, _) = call(
        &app,
        "PUT",
        &format!("/api/conversations/{group_id}"),
        Some(&tokens[1]),
        Some(json!({ "mute_duration": "1h" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    mock.sends.lock().unwrap().clear();
    let _ = call(
        &app,
        "POST",
        &format!("/api/conversations/{group_id}/messages"),
        Some(&tokens[0]),
        Some(json!({ "type": "text", "content": "ข้อความทั่วไปในห้องปิดเสียง" })),
    )
    .await;
    for _ in 0..25 {
        tokio::time::sleep(Duration::from_millis(40)).await;
        if !mock.sends.lock().unwrap().is_empty() {
            break;
        }
    }
    tokio::time::sleep(Duration::from_millis(80)).await;
    let muted_sends = mock.sends.lock().unwrap().clone();
    assert!(
        !muted_sends
            .iter()
            .any(|s| s["message"]["token"] == ok_token.as_str()),
        "muted room must suppress push when not mentioned"
    );

    mock.sends.lock().unwrap().clear();
    let _ = call(
        &app,
        "POST",
        &format!("/api/conversations/{group_id}/messages"),
        Some(&tokens[0]),
        Some(json!({ "type": "text", "content": "@all ประชุมด่วนครับ" })),
    )
    .await;
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(40)).await;
        if mock.sends.lock().unwrap().len() >= 2 {
            break;
        }
    }
    let mention_sends = mock.sends.lock().unwrap().clone();
    assert!(
        mention_sends
            .iter()
            .any(|s| s["message"]["token"] == ok_token.as_str()),
        "@all mention must override room mute when notify_on_mention=true"
    );

    // Enable Global DND on u2 -> suppresses even @all mention
    let (status, _) = call(
        &app,
        "PUT",
        "/api/users/me",
        Some(&tokens[1]),
        Some(json!({ "dnd_mode": "1h" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    mock.sends.lock().unwrap().clear();
    let _ = call(
        &app,
        "POST",
        &format!("/api/conversations/{group_id}/messages"),
        Some(&tokens[0]),
        Some(json!({ "type": "text", "content": "@all ตอนเปิดห้ามรบกวน" })),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let dnd_sends = mock.sends.lock().unwrap().clone();
    assert!(
        !dnd_sends
            .iter()
            .any(|s| s["message"]["token"] == ok_token.as_str()),
        "Global DND must suppress push notifications"
    );

    // Drop isolated test DB & temp key files
    let _ = state.db.drop().await;
    let _ = std::fs::remove_dir_all(&dir);
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
