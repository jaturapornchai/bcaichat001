//! Push alerts for new chat messages through Firebase Cloud Messaging
//! (HTTP v1). Sent only to devices with no WebSocket open: a running app
//! alerts by itself (NotificationService in the frontend).

use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use bson::doc;
use chrono::Utc;
use futures::{StreamExt, TryStreamExt};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;

use crate::{
    config::AppConfig,
    models::{
        is_conv_effectively_muted, CallSessionDto, ConversationDoc, FriendshipDoc, MessageDto,
        UserDoc,
    },
    AppState,
};

/// Sound codes the frontend ships (assets/sounds + Android res/raw/alert_<code>).
pub const SOUND_CODES: &[&str] = &[
    "ting", "pop", "chime", "marimba", "bell", "soft", "urgent", "robot", NO_SOUND,
];
pub const NO_SOUND: &str = "none";
const AI_USER_ID: &str = "user_ai";
const SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AlertSounds {
    pub normal: String,
    pub urgent: String,
    pub ai: String,
}

/// One app install (device_id is made by the app), owned by the signed-in user.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub user_id: String,
    pub token: String,
    pub platform: String,
    pub popup: bool,
    pub sound: bool,
    pub sounds: AlertSounds,
    /// Client app that registered the device ("chat" or "oa"); empty for
    /// installs that predate the app split, which get every push.
    #[serde(default)]
    pub app: String,
    pub updated_at: String,
}

#[derive(Deserialize)]
struct ServiceAccount {
    project_id: String,
    client_email: String,
    private_key: String,
    #[serde(default)]
    private_key_id: Option<String>,
    token_uri: String,
}

pub struct Fcm {
    pub project_id: String,
    client_email: String,
    key_id: Option<String>,
    key: EncodingKey,
    token_uri: String,
    api_base: String,
    http: reqwest::Client,
    access: Mutex<Option<(String, Instant)>>,
}

impl Fcm {
    /// None (push off) when FCM_SERVICE_ACCOUNT_FILE is unset or unreadable.
    pub fn from_config(config: &AppConfig) -> Option<Arc<Self>> {
        let path = config.fcm_service_account_file.trim();
        if path.is_empty() {
            tracing::info!("push off: FCM_SERVICE_ACCOUNT_FILE not set");
            return None;
        }
        let loaded = std::fs::read_to_string(path)
            .map_err(|e| e.to_string())
            .and_then(|s| serde_json::from_str::<ServiceAccount>(&s).map_err(|e| e.to_string()))
            .and_then(|sa| {
                EncodingKey::from_rsa_pem(sa.private_key.as_bytes())
                    .map(|key| (sa, key))
                    .map_err(|e| e.to_string())
            });
        match loaded {
            Ok((sa, key)) => {
                tracing::info!("push on: FCM project {}", sa.project_id);
                Some(Arc::new(Self {
                    project_id: sa.project_id,
                    client_email: sa.client_email,
                    key_id: sa.private_key_id,
                    key,
                    token_uri: sa.token_uri,
                    api_base: config.fcm_api_base.clone(),
                    http: reqwest::Client::new(),
                    access: Mutex::new(None),
                }))
            }
            Err(e) => {
                tracing::warn!("push off: cannot load FCM service account: {e}");
                None
            }
        }
    }

    /// OAuth access token from the service account, reused until near expiry.
    async fn access_token(&self) -> Result<String, String> {
        let mut cached = self.access.lock().await;
        if let Some((token, until)) = cached.as_ref() {
            if Instant::now() < *until {
                return Ok(token.clone());
            }
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        let claims = json!({
            "iss": self.client_email,
            "scope": SCOPE,
            "aud": self.token_uri,
            "iat": now,
            "exp": now + 3600,
        });
        let mut header = Header::new(Algorithm::RS256);
        header.kid = self.key_id.clone();
        let assertion =
            jsonwebtoken::encode(&header, &claims, &self.key).map_err(|e| e.to_string())?;
        let res: Value = self
            .http
            .post(&self.token_uri)
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", assertion.as_str()),
            ])
            .send()
            .await
            .map_err(|e| e.to_string())?
            .json()
            .await
            .map_err(|e| e.to_string())?;
        let token = res["access_token"]
            .as_str()
            .ok_or_else(|| format!("no access_token: {}", res["error"]))?
            .to_string();
        let ttl = res["expires_in"].as_u64().unwrap_or(3600).saturating_sub(300);
        *cached = Some((token.clone(), Instant::now() + Duration::from_secs(ttl)));
        Ok(token)
    }

    /// Ok(false) = FCM says the token is gone (app uninstalled / token rotated).
    /// Retries transient 429/5xx responses with bounded backoff.
    async fn send(&self, message: Value) -> Result<bool, String> {
        const RETRY_DELAYS_MS: [u64; 3] = [100, 300, 900];
        let url = format!(
            "{}/v1/projects/{}/messages:send",
            self.api_base, self.project_id
        );
        let payload = json!({ "message": message });
        let mut last_err = String::new();

        for attempt in 0..=RETRY_DELAYS_MS.len() {
            let access = self.access_token().await?;
            let res = self
                .http
                .post(&url)
                .bearer_auth(access)
                .json(&payload)
                .send()
                .await
                .map_err(|e| e.to_string())?;
            let status = res.status();
            if status.is_success() {
                return Ok(true);
            }
            let body: Value = res.json().await.unwrap_or(Value::Null);
            let unregistered = body["error"]["details"]
                .as_array()
                .is_some_and(|d| d.iter().any(|x| x["errorCode"] == "UNREGISTERED"));
            if unregistered {
                return Ok(false);
            }
            if status.as_u16() == 401 {
                *self.access.lock().await = None;
            }
            last_err = format!("FCM {status}: {}", body["error"]["message"]);
            let retryable = status.as_u16() == 429 || status.is_server_error();
            if retryable {
                if let Some(&delay_ms) = RETRY_DELAYS_MS.get(attempt) {
                    tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                    continue;
                }
            }
            return Err(last_err);
        }
        Err(last_err)
    }
}

/// Title/body of the alert, or None when a message should not alert.
pub fn describe(conv: &ConversationDoc, msg: &MessageDto) -> Option<(String, String)> {
    if msg.msg_type == "system" || msg.is_unsent {
        return None;
    }
    let preview = if msg.is_confidential {
        "ส่งข้อความลับ 🔒".to_string()
    } else {
        match msg.msg_type.as_str() {
            "image" => "ส่งรูปภาพ".to_string(),
            "audio" => "ส่งข้อความเสียง".to_string(),
            "file" => match msg.attachment.as_ref().map(|a| a.file_name.trim()) {
                Some(name) if !name.is_empty() => format!("ส่งไฟล์ {name}"),
                _ => "ส่งไฟล์".to_string(),
            },
            "sticker" => "ส่งสติกเกอร์".to_string(),
            "rich_card" => "ส่งการ์ดโต้ตอบ".to_string(),
            "poll" => "สร้างโพลโหวต".to_string(),
            "event" => "สร้างนัดหมาย".to_string(),
            "call_log" => {
                let text = msg.content.trim();
                if !text.is_empty() {
                    text.to_string()
                } else {
                    let is_video = msg
                        .card_payload
                        .as_ref()
                        .and_then(|c| c.get("call_type"))
                        .and_then(|v| v.as_str())
                        == Some("video");
                    let status = msg
                        .card_payload
                        .as_ref()
                        .and_then(|c| c.get("status"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("ended");
                    match (is_video, status) {
                        (true, "missed") => "🎥 สายวิดีโอคอลที่ไม่ได้รับ".to_string(),
                        (false, "missed") => "📞 สายโทรเสียงที่ไม่ได้รับ".to_string(),
                        (true, _) => "🎥 บันทึกสายวิดีโอคอล".to_string(),
                        (false, _) => "📞 บันทึกสายโทรเสียง".to_string(),
                    }
                }
            }
            _ => {
                let text = msg.content.trim();
                if text.chars().count() > 120 {
                    format!("{}…", text.chars().take(120).collect::<String>())
                } else {
                    text.to_string()
                }
            }
        }
    };
    let body = if msg.priority == "urgent" {
        format!("⚡ ด่วน: {preview}")
    } else {
        preview
    };
    Some(if conv.conv_type == "direct" {
        (msg.sender_name.clone(), body)
    } else if conv.conv_type == "oa" && msg.sender_id.starts_with("user_oa_") {
        (conv.name.clone(), body)
    } else {
        (conv.name.clone(), format!("{}: {body}", msg.sender_name))
    })
}

/// Sound code for this message on this device; NO_SOUND = quiet channel.
pub fn sound_for(device: &DeviceDoc, msg: &MessageDto) -> String {
    if !device.sound || msg.priority == "silent" {
        return NO_SOUND.to_string();
    }
    if msg.msg_type == "call_log" {
        let missed = msg
            .card_payload
            .as_ref()
            .and_then(|c| c.get("status"))
            .and_then(|v| v.as_str())
            == Some("missed");
        return if missed {
            device.sounds.normal.clone()
        } else {
            NO_SOUND.to_string()
        };
    }
    if msg.priority == "urgent" {
        device.sounds.urgent.clone()
    } else if msg.sender_id == AI_USER_ID || msg.sender_id.starts_with("user_oa_") {
        device.sounds.ai.clone()
    } else {
        device.sounds.normal.clone()
    }
}

/// FCM message body.
pub fn build_message(device: &DeviceDoc, conv_id: &str, title: &str, body: &str, sound: &str) -> Value {
    let mut notification = json!({
        "channel_id": format!("push_{sound}"),
        "tag": conv_id,
        "title": title,
        "body": body,
    });
    if sound != NO_SOUND {
        notification["sound"] = json!(format!("alert_{sound}"));
    }
    let silent = if sound == NO_SOUND { "1" } else { "0" };
    json!({
        "token": device.token,
        "data": {
            "conversation_id": conv_id,
            "title": title,
            "body": body,
            "silent": silent,
        },
        "android": { "priority": "high", "notification": notification },
        "webpush": { "headers": { "Urgency": "high" } },
    })
}

fn is_user_mentioned_in_message(u: &UserDoc, msg: &MessageDto) -> bool {
    let clean_handle = u.bc_id.trim().trim_start_matches('@').to_lowercase();
    for m in &msg.mentions {
        let ml = m.trim().to_lowercase();
        let ml_clean = ml.trim_start_matches('@');
        if ml == "all" || ml == "@all" || m == &u.id {
            return true;
        }
        if !clean_handle.is_empty() && ml_clean == clean_handle {
            return true;
        }
    }
    let content_lower = msg.content.to_lowercase();
    if content_lower.contains("@all") {
        return true;
    }
    if !clean_handle.is_empty() && content_lower.contains(&format!("@{clean_handle}")) {
        return true;
    }
    let dname = u.display_name.trim().to_lowercase();
    if !dname.is_empty() && content_lower.contains(&format!("@{dname}")) {
        return true;
    }
    false
}

/// Fire-and-forget push for a just-broadcast `new_message` to specific user IDs.
/// Whether a device's app handles `conv` for its owner (see `client_app`).
fn device_app_receives(device: &DeviceDoc, conv: &ConversationDoc) -> bool {
    let is_member = conv.member_ids.contains(&device.user_id);
    let is_admin = conv.admin_ids.contains(&device.user_id);
    crate::client_app::receives(&device.app, conv.oa_id.is_some(), is_member, is_admin)
}

pub fn notify_target_users(
    state: &AppState,
    conv: &ConversationDoc,
    msg: &MessageDto,
    target_user_ids: &[String],
) {
    let Some(fcm) = state.push.clone() else {
        return;
    };
    let Some((title, body)) = describe(conv, msg) else {
        return;
    };
    let mut candidates: Vec<String> = target_user_ids
        .iter()
        .filter(|id| **id != msg.sender_id)
        .cloned()
        .collect();
    candidates.sort();
    candidates.dedup();
    if candidates.is_empty() {
        return;
    }
    let db = state.db.clone();
    let hub = state.ws_hub.clone();
    let conv_clone = conv.clone();
    let conv_id = conv.id.clone();
    let msg = msg.clone();
    tokio::spawn(async move {
        let now = Utc::now();

        // 1. Skip users who blocked sender_id
        let blocked_senders: HashSet<String> = match db
            .collection::<FriendshipDoc>("friendships")
            .find(doc! {
                "user_id": { "$in": &candidates },
                "friend_id": &msg.sender_id,
                "is_blocked": true,
            })
            .await
        {
            Ok(cur) => cur
                .try_collect::<Vec<FriendshipDoc>>()
                .await
                .unwrap_or_default()
                .into_iter()
                .map(|f| f.user_id)
                .collect(),
            Err(_) => HashSet::new(),
        };

        // 2. Load recipient preferences (DND, notify_on_mention, notify_preview)
        let user_docs: Vec<UserDoc> = match db
            .collection::<UserDoc>("users")
            .find(doc! { "_id": { "$in": &candidates } })
            .await
        {
            Ok(cur) => cur.try_collect().await.unwrap_or_default(),
            Err(_) => Vec::new(),
        };
        let user_map: HashMap<String, UserDoc> =
            user_docs.into_iter().map(|u| (u.id.clone(), u)).collect();

        let mut eligible_preview_map: HashMap<String, bool> = HashMap::new();
        for uid in &candidates {
            if blocked_senders.contains(uid) {
                continue;
            }
            if let Some(u) = user_map.get(uid) {
                if u.is_dnd_active(now) {
                    continue;
                }
                let muted = is_conv_effectively_muted(&conv_clone, uid, now);
                if muted {
                    let mention_override =
                        u.notify_on_mention && is_user_mentioned_in_message(u, &msg);
                    if !mention_override {
                        continue;
                    }
                }
                eligible_preview_map.insert(uid.clone(), u.notify_preview);
            } else if !is_conv_effectively_muted(&conv_clone, uid, now) {
                eligible_preview_map.insert(uid.clone(), true);
            }
        }

        let others: Vec<String> = eligible_preview_map.keys().cloned().collect();
        if others.is_empty() {
            return;
        }

        let devices = db.collection::<DeviceDoc>("device_tokens");
        let found: Vec<DeviceDoc> = match devices
            .find(doc! { "user_id": { "$in": &others }, "popup": true })
            .await
        {
            Ok(cursor) => cursor.try_collect().await.unwrap_or_default(),
            Err(e) => {
                tracing::warn!("push: device lookup failed: {e}");
                return;
            }
        };
        let offline = found.into_iter().filter(|d| {
            device_app_receives(d, &conv_clone) && !hub.device_online(&d.user_id, &d.id)
        });
        futures::stream::iter(offline)
            .for_each_concurrent(8, |d| {
                let fcm = fcm.clone();
                let devices = devices.clone();
                let allow_preview = eligible_preview_map
                    .get(&d.user_id)
                    .copied()
                    .unwrap_or(true);
                let effective_body = if allow_preview {
                    body.as_str()
                } else {
                    "คุณมีข้อความใหม่"
                };
                let message =
                    build_message(&d, &conv_id, &title, effective_body, &sound_for(&d, &msg));
                async move {
                    match fcm.send(message).await {
                        Ok(true) => {}
                        Ok(false) => {
                            let _ = devices.delete_one(doc! { "_id": &d.id }).await;
                        }
                        Err(e) => tracing::warn!("push to device {} failed: {e}", d.id),
                    }
                }
            })
            .await;
    });
}

/// Fire-and-forget push for a just-broadcast `new_message` to conversation members.
pub fn notify_new_message(state: &AppState, conv: &ConversationDoc, msg: &MessageDto) {
    let mut targets: Vec<String> = conv
        .member_ids
        .iter()
        .filter(|id| **id != msg.sender_id)
        .cloned()
        .collect();
    targets.shrink_to_fit();
    notify_target_users(state, conv, msg, &targets);
}

/// Fire-and-forget high-priority FCM push for an incoming voice/video call.
pub fn notify_incoming_call(state: &AppState, conv: &ConversationDoc, call: &CallSessionDto) {
    let Some(fcm) = state.push.clone() else {
        return;
    };
    let now = Utc::now();
    let mut candidates: Vec<String> = call
        .target_user_ids
        .iter()
        .filter(|id| **id != call.initiator_id && !is_conv_effectively_muted(conv, id, now))
        .cloned()
        .collect();
    candidates.sort();
    candidates.dedup();
    if candidates.is_empty() {
        return;
    }

    let title = if conv.conv_type == "direct" {
        call.initiator_name.clone()
    } else {
        conv.name.clone()
    };
    let body = if call.call_type == "video" {
        format!("🎥 {} กำลังวิดีโอคอลหาคุณ...", call.initiator_name)
    } else {
        format!("📞 {} กำลังโทรเสียงหาคุณ...", call.initiator_name)
    };

    let db = state.db.clone();
    let hub = state.ws_hub.clone();
    let conv_clone = conv.clone();
    let conv_id = conv.id.clone();
    let call_id = call.id.clone();
    let call_type = call.call_type.clone();
    let initiator_id = call.initiator_id.clone();
    let initiator_name = call.initiator_name.clone();

    tokio::spawn(async move {
        let now_inner = Utc::now();
        let blocked_caller: HashSet<String> = match db
            .collection::<FriendshipDoc>("friendships")
            .find(doc! {
                "user_id": { "$in": &candidates },
                "friend_id": &initiator_id,
                "is_blocked": true,
            })
            .await
        {
            Ok(cur) => cur
                .try_collect::<Vec<FriendshipDoc>>()
                .await
                .unwrap_or_default()
                .into_iter()
                .map(|f| f.user_id)
                .collect(),
            Err(_) => HashSet::new(),
        };

        let dnd_users: HashSet<String> = match db
            .collection::<UserDoc>("users")
            .find(doc! { "_id": { "$in": &candidates } })
            .await
        {
            Ok(cur) => cur
                .try_collect::<Vec<UserDoc>>()
                .await
                .unwrap_or_default()
                .into_iter()
                .filter(|u| u.is_dnd_active(now_inner))
                .map(|u| u.id)
                .collect(),
            Err(_) => HashSet::new(),
        };

        let others: Vec<String> = candidates
            .into_iter()
            .filter(|id| !blocked_caller.contains(id) && !dnd_users.contains(id))
            .collect();
        if others.is_empty() {
            return;
        }

        let devices = db.collection::<DeviceDoc>("device_tokens");
        let found: Vec<DeviceDoc> = match devices
            .find(doc! { "user_id": { "$in": &others }, "popup": true })
            .await
        {
            Ok(cursor) => cursor.try_collect().await.unwrap_or_default(),
            Err(e) => {
                tracing::warn!("push: incoming call device lookup failed: {e}");
                return;
            }
        };
        let offline = found.into_iter().filter(|d| {
            device_app_receives(d, &conv_clone) && !hub.device_online(&d.user_id, &d.id)
        });
        futures::stream::iter(offline)
            .for_each_concurrent(8, |d| {
                let fcm = fcm.clone();
                let devices = devices.clone();
                let sound = if d.sound {
                    d.sounds.urgent.clone()
                } else {
                    NO_SOUND.to_string()
                };
                let silent = if sound == NO_SOUND { "1" } else { "0" };
                let mut notification = json!({
                    "channel_id": format!("push_{sound}"),
                    "tag": format!("call_{call_id}"),
                    "title": title,
                    "body": body,
                });
                if sound != NO_SOUND {
                    notification["sound"] = json!(format!("alert_{sound}"));
                }
                let message = json!({
                    "token": d.token,
                    "data": {
                        "event": "call_incoming",
                        "call_id": call_id,
                        "conversation_id": conv_id,
                        "call_type": call_type,
                        "initiator_id": initiator_id,
                        "initiator_name": initiator_name,
                        "title": title,
                        "body": body,
                        "silent": silent,
                    },
                    "android": {
                        "priority": "high",
                        "ttl": "45s",
                        "notification": notification,
                    },
                    "webpush": {
                        "headers": {
                            "Urgency": "high",
                            "TTL": "45",
                        }
                    },
                });
                async move {
                    match fcm.send(message).await {
                        Ok(true) => {}
                        Ok(false) => {
                            let _ = devices.delete_one(doc! { "_id": &d.id }).await;
                        }
                        Err(e) => tracing::warn!("incoming call push to device {} failed: {e}", d.id),
                    }
                }
            })
            .await;
    });
}

/// Fire-and-forget silent FCM data push to cancel ringing notifications on offline devices.
pub fn notify_call_cancelled(state: &AppState, conv: &ConversationDoc, call: &CallSessionDto) {
    let Some(fcm) = state.push.clone() else {
        return;
    };
    let now = Utc::now();
    let mut others: Vec<String> = call
        .target_user_ids
        .iter()
        .filter(|id| **id != call.initiator_id && !is_conv_effectively_muted(conv, id, now))
        .cloned()
        .collect();
    others.sort();
    others.dedup();
    if others.is_empty() {
        return;
    }

    let db = state.db.clone();
    let hub = state.ws_hub.clone();
    let conv_clone = conv.clone();
    let conv_id = conv.id.clone();
    let call_id = call.id.clone();
    let status = call.status.clone();

    tokio::spawn(async move {
        let devices = db.collection::<DeviceDoc>("device_tokens");
        let found: Vec<DeviceDoc> = match devices
            .find(doc! { "user_id": { "$in": &others }, "popup": true })
            .await
        {
            Ok(cursor) => cursor.try_collect().await.unwrap_or_default(),
            Err(e) => {
                tracing::warn!("push: call cancel device lookup failed: {e}");
                return;
            }
        };
        let offline = found.into_iter().filter(|d| {
            device_app_receives(d, &conv_clone) && !hub.device_online(&d.user_id, &d.id)
        });
        futures::stream::iter(offline)
            .for_each_concurrent(8, |d| {
                let fcm = fcm.clone();
                let devices = devices.clone();
                let message = json!({
                    "token": d.token,
                    "data": {
                        "event": "call_ended",
                        "call_id": call_id,
                        "conversation_id": conv_id,
                        "status": status,
                        "silent": "1",
                    },
                    "android": { "priority": "high" },
                    "webpush": { "headers": { "Urgency": "high" } },
                });
                async move {
                    match fcm.send(message).await {
                        Ok(true) => {}
                        Ok(false) => {
                            let _ = devices.delete_one(doc! { "_id": &d.id }).await;
                        }
                        Err(e) => tracing::warn!("call cancel push to device {} failed: {e}", d.id),
                    }
                }
            })
            .await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conv(kind: &str) -> ConversationDoc {
        serde_json::from_value(json!({
            "_id": "c1", "type": kind, "name": "แก๊งเพื่อนสนิท", "avatar_url": "", "folder": "group",
            "member_ids": ["a", "b"], "created_at": "", "updated_at": "",
        }))
        .unwrap()
    }

    fn msg(extra: Value) -> MessageDto {
        let mut m = json!({
            "id": "m1", "conversation_id": "c1", "sender_id": "a", "sender_name": "สมชาย",
            "sender_avatar": "", "type": "text", "content": "สวัสดี", "sticker_code": null,
            "attachment": null, "card_payload": null, "reply_to": null, "read_by": [],
            "read_count": 0, "is_unsent": false, "is_confidential": false,
            "confidential_pin": null, "expire_at": null, "priority": "normal",
            "task_status": null, "accepted_by": null, "accepted_at": null, "created_at": "",
        });
        for (k, v) in extra.as_object().unwrap() {
            m[k] = v.clone();
        }
        serde_json::from_value(m).unwrap()
    }

    fn device(sound: bool) -> DeviceDoc {
        DeviceDoc {
            id: "d1".into(),
            user_id: "b".into(),
            token: "t".into(),
            platform: "android".into(),
            popup: true,
            sound,
            sounds: AlertSounds { normal: "pop".into(), urgent: "urgent".into(), ai: "robot".into() },
            app: String::new(),
            updated_at: String::new(),
        }
    }

    #[test]
    fn push_goes_to_the_app_that_handles_the_conversation() {
        let with_app = |user: &str, app: &str| DeviceDoc {
            user_id: user.into(),
            app: app.into(),
            ..device(true)
        };
        // Personal chat: member "b" gets it on the chat app, never on the shop app.
        let personal = conv("direct");
        assert!(device_app_receives(&with_app("b", "chat"), &personal));
        assert!(!device_app_receives(&with_app("b", "oa"), &personal));
        assert!(device_app_receives(&with_app("b", ""), &personal));

        // Shop chat: "b" is the customer, "staff" answers for the shop.
        let mut shop = conv("oa");
        shop.oa_id = Some("oa1".into());
        shop.admin_ids = vec!["staff".into()];
        assert!(device_app_receives(&with_app("b", "chat"), &shop));
        assert!(!device_app_receives(&with_app("b", "oa"), &shop));
        assert!(!device_app_receives(&with_app("staff", "chat"), &shop));
        assert!(device_app_receives(&with_app("staff", "oa"), &shop));
        assert!(device_app_receives(&with_app("staff", ""), &shop));
    }

    #[test]
    fn describe_matches_the_app_wording() {
        let direct = describe(&conv("direct"), &msg(json!({}))).unwrap();
        assert_eq!(direct, ("สมชาย".into(), "สวัสดี".into()));
        let group = describe(&conv("group"), &msg(json!({ "priority": "urgent" }))).unwrap();
        assert_eq!(group, ("แก๊งเพื่อนสนิท".into(), "สมชาย: ⚡ ด่วน: สวัสดี".into()));
        let secret = describe(&conv("direct"), &msg(json!({ "is_confidential": true }))).unwrap();
        assert_eq!(secret.1, "ส่งข้อความลับ 🔒", "confidential text must not leave the server");
        let long = describe(&conv("direct"), &msg(json!({ "content": "ก".repeat(130) }))).unwrap();
        assert_eq!(long.1.chars().count(), 121);
        assert!(describe(&conv("direct"), &msg(json!({ "type": "system" }))).is_none());
        assert!(describe(&conv("direct"), &msg(json!({ "is_unsent": true }))).is_none());
        let missed_call = describe(
            &conv("direct"),
            &msg(json!({
                "type": "call_log",
                "content": "",
                "card_payload": { "call_type": "video", "status": "missed", "duration_sec": 0 }
            })),
        )
        .unwrap();
        assert_eq!(missed_call.1, "🎥 สายวิดีโอคอลที่ไม่ได้รับ");
    }

    #[test]
    fn sound_follows_kind_and_switches() {
        assert_eq!(sound_for(&device(true), &msg(json!({}))), "pop");
        assert_eq!(sound_for(&device(true), &msg(json!({ "priority": "urgent" }))), "urgent");
        assert_eq!(sound_for(&device(true), &msg(json!({ "sender_id": AI_USER_ID }))), "robot");
        assert_eq!(sound_for(&device(true), &msg(json!({ "priority": "silent" }))), NO_SOUND);
        assert_eq!(sound_for(&device(false), &msg(json!({}))), NO_SOUND);
        assert_eq!(
            sound_for(
                &device(true),
                &msg(json!({ "type": "call_log", "card_payload": { "status": "missed" } }))
            ),
            "pop"
        );
        assert_eq!(
            sound_for(
                &device(true),
                &msg(json!({ "type": "call_log", "card_payload": { "status": "ended" } }))
            ),
            NO_SOUND
        );
        let quiet = build_message(&device(false), "c1", "t", "b", NO_SOUND);
        assert_eq!(quiet["android"]["notification"]["channel_id"], "push_none");
        assert!(quiet["android"]["notification"].get("sound").is_none());
        assert_eq!(quiet["data"]["silent"], "1");
    }
}
