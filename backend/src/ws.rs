use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Query, State,
    },
    http::StatusCode,
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::broadcast;

use bson::doc;

use crate::{auth::verify_jwt, AppState};

#[derive(Clone)]
pub struct WsHub {
    pub tx: broadcast::Sender<String>,
    /// Open sockets per "user_id:device_id"; such devices get no push.
    online: Arc<Mutex<HashMap<String, usize>>>,
}

impl WsHub {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(1024);
        Self {
            tx,
            online: Arc::default(),
        }
    }

    pub fn device_online(&self, user_id: &str, device_id: &str) -> bool {
        let key = format!("{user_id}:{device_id}");
        self.online.lock().unwrap().contains_key(&key)
    }

    fn set_online(&self, key: &str, open: bool) {
        let mut online = self.online.lock().unwrap();
        let n = online.entry(key.to_string()).or_insert(0);
        if open {
            *n += 1;
        } else {
            *n = n.saturating_sub(1);
            if *n == 0 {
                online.remove(key);
            }
        }
    }

    pub fn broadcast_event(&self, payload: Value) {
        if let Ok(text) = serde_json::to_string(&payload) {
            let _ = self.tx.send(text);
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct WsQuery {
    pub token: Option<String>,
    /// App install id, so push skips devices that are connected.
    pub device: Option<String>,
    /// Client app of this socket ("chat" or "oa"); clients that predate the
    /// app split send none and get every event.
    #[serde(default)]
    pub app: Option<String>,
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Query(query): Query<WsQuery>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let Some(claims) = query
        .token
        .as_deref()
        .and_then(|t| verify_jwt(t, &state.config.jwt_secret).ok())
        .filter(|c| crate::auth::is_token_version_valid(&state, &c.sub, c.tv))
    else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let user_id = claims.sub;
    let Some(app) = crate::client_app::parse(query.app.as_deref()) else {
        return StatusCode::BAD_REQUEST.into_response();
    };

    let device_key = query
        .device
        .filter(|d| !d.is_empty() && d.len() <= 64)
        .map(|d| format!("{user_id}:{d}"));
    ws.on_upgrade(move |socket| handle_socket(socket, state, user_id, device_key, app))
        .into_response()
}

/// Server pings this often; a socket silent for PING_EVERY * 3 is dropped so a
/// phone that lost its network counts as offline (and gets push) soon.
const PING_EVERY: Duration = Duration::from_secs(20);

async fn handle_socket(
    socket: WebSocket,
    state: AppState,
    user_id: String,
    device_key: Option<String>,
    app: &'static str,
) {
    if let Some(key) = &device_key {
        state.ws_hub.set_online(key, true);
    }
    let (mut sender, mut receiver) = socket.split();
    let mut rx = state.ws_hub.tx.subscribe();

    let welcome = json!({
        "event": "connected",
        "user_id": user_id,
    });
    if let Ok(text) = serde_json::to_string(&welcome) {
        let _ = sender.send(Message::Text(text.into())).await;
    }

    let send_state = state.clone();
    let send_uid = user_id.clone();
    let mut send_task = tokio::spawn(async move {
        let mut ping = tokio::time::interval(PING_EVERY);
        loop {
            let out = tokio::select! {
                _ = ping.tick() => Message::Ping(Vec::new().into()),
                msg = rx.recv() => match msg {
                    Ok(msg) if can_receive(&send_state, &send_uid, app, &msg).await => {
                        Message::Text(msg.into())
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                },
            };
            if sender.send(out).await.is_err() {
                break;
            }
        }
    });

    let ws_hub = state.ws_hub.clone();
    let recv_db = state.db.clone();
    let uid = user_id.clone();
    let mut recv_task = tokio::spawn(async move {
        // Any frame (pong included) proves the client is still there.
        while let Ok(Some(Ok(msg))) =
            tokio::time::timeout(PING_EVERY * 3, receiver.next()).await
        {
            if let Message::Text(text) = msg {
                if let Ok(val) = serde_json::from_str::<Value>(&text) {
                    if val.get("event").and_then(|v| v.as_str()) == Some("typing") {
                        let excluded: Vec<String> = match recv_db
                            .collection::<crate::models::FriendshipDoc>("friendships")
                            .find(doc! { "friend_id": &uid, "is_blocked": true })
                            .await
                        {
                            Ok(cur) => futures_util::TryStreamExt::try_collect::<Vec<_>>(cur)
                                .await
                                .unwrap_or_default()
                                .into_iter()
                                .map(|f| f.user_id)
                                .collect(),
                            Err(_) => Vec::new(),
                        };
                        ws_hub.broadcast_event(json!({
                            "event": "typing",
                            "user_id": uid,
                            "conversation_id": val.get("conversation_id"),
                            "excluded_user_ids": excluded,
                        }));
                    }
                }
            } else if let Message::Close(_) = msg {
                break;
            }
        }
    });

    tokio::select! {
        _ = (&mut send_task) => recv_task.abort(),
        _ = (&mut recv_task) => send_task.abort(),
    };
    if let Some(key) = &device_key {
        state.ws_hub.set_online(key, false);
    }
}

/// One user's side of a conversation. The projection keeps at most that user
/// in each list, so a large group costs the same as a direct chat.
#[derive(Debug, Deserialize)]
struct RecipientRelation {
    #[serde(default)]
    member_ids: Vec<String>,
    #[serde(default)]
    admin_ids: Vec<String>,
    #[serde(default)]
    oa_id: Option<String>,
}

async fn recipient_relation(
    state: &AppState,
    conv_id: &str,
    user_id: &str,
) -> Option<RecipientRelation> {
    state
        .db
        .collection::<RecipientRelation>("conversations")
        .find_one(doc! { "_id": conv_id })
        .projection(doc! {
            "member_ids": { "$elemMatch": { "$eq": user_id } },
            "admin_ids": { "$elemMatch": { "$eq": user_id } },
            "oa_id": 1,
        })
        .await
        .ok()
        .flatten()
}

/// Room events (anything with conversation_id) go only to that room's members,
/// and only to the client app that handles the room for them (`client_app`);
/// org-wide events (theme, mini-apps) go to everyone.
// ponytail: one indexed lookup per room event per socket; cache memberships per socket if traffic grows.
pub async fn can_receive(state: &AppState, user_id: &str, app: &str, raw: &str) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(raw) else {
        return false;
    };
    // O(1) in-memory block exclusion check before touching MongoDB
    if let Some(excluded) = v.get("excluded_user_ids").and_then(|e| e.as_array()) {
        if excluded.iter().any(|x| x.as_str() == Some(user_id)) {
            return false;
        }
    }
    let event_name = v.get("event").and_then(|e| e.as_str()).unwrap_or("");
    if v.get("excluded_user_ids").is_none() {
        let actor_opt = match event_name {
            "new_message" | "message_edited" => v
                .get("message")
                .and_then(|m| m.get("sender_id"))
                .and_then(|s| s.as_str()),
            "typing" => v.get("user_id").and_then(|s| s.as_str()),
            "call_incoming" => v
                .get("call")
                .and_then(|c| c.get("initiator_id"))
                .and_then(|s| s.as_str()),
            _ => None,
        };
        if let Some(actor_id) = actor_opt {
            if actor_id != user_id {
                let is_blocked = state
                    .db
                    .collection::<bson::Document>("friendships")
                    .count_documents(doc! {
                        "user_id": user_id,
                        "friend_id": actor_id,
                        "is_blocked": true,
                    })
                    .await
                    .unwrap_or(0)
                    > 0;
                if is_blocked {
                    return false;
                }
            }
        }
    }
    let is_call_event = event_name.starts_with("call_");
    let conv_id = v.get("conversation_id").and_then(|c| c.as_str());
    let mut is_target = false;
    if let Some(targets) = v.get("target_user_ids").and_then(|t| t.as_array()) {
        is_target = targets.iter().any(|x| x.as_str() == Some(user_id));
        if !is_target && (is_call_event || conv_id.is_none()) {
            return false;
        }
    }
    let Some(conv_id) = conv_id else {
        return true;
    };
    // A named target on a client that predates the app split needs no lookup.
    if is_target && app.is_empty() {
        return true;
    }
    let Some(relation) = recipient_relation(state, conv_id, user_id).await else {
        return false;
    };
    let is_member = !relation.member_ids.is_empty();
    let is_admin = !relation.admin_ids.is_empty();
    (is_target || is_member || is_admin)
        && crate::client_app::receives(app, relation.oa_id.is_some(), is_member, is_admin)
}

#[cfg(test)]
mod tests {
    use super::WsHub;

    #[test]
    fn device_counts_as_online_until_its_last_socket_closes() {
        let hub = WsHub::new();
        hub.set_online("u1:d1", true);
        hub.set_online("u1:d1", true);
        hub.set_online("u1:d1", false);
        assert!(hub.device_online("u1", "d1"));
        assert!(!hub.device_online("u2", "d1"), "another user's socket must not count");
        hub.set_online("u1:d1", false);
        assert!(!hub.device_online("u1", "d1"));
    }
}
