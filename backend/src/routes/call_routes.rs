use axum::{
    extract::{Path, Query, State},
    Json,
};
use bson::doc;
use chrono::{DateTime, Utc};
use futures_util::TryStreamExt;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

use crate::{
    auth::{ApiError, AuthUser},
    models::{
        CallParticipantState, CallSessionDoc, CallSessionDto, ConversationDoc, FriendshipDoc,
        LastMessageSummary, MessageDoc, MessageDto, OaAccountDoc, UserDoc,
    },
    AppState,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveKitVideoGrant {
    #[serde(rename = "roomJoin")]
    pub room_join: bool,
    pub room: String,
    #[serde(rename = "canPublish")]
    pub can_publish: bool,
    #[serde(rename = "canSubscribe")]
    pub can_subscribe: bool,
    #[serde(rename = "canPublishData")]
    pub can_publish_data: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveKitClaims {
    pub iss: String,
    pub sub: String,
    pub nbf: usize,
    pub exp: usize,
    pub name: String,
    pub metadata: String,
    pub video: LiveKitVideoGrant,
}

pub fn clean_livekit_url(raw: &str) -> String {
    let cleaned = raw
        .trim()
        .trim_end_matches('/')
        .trim_end_matches("/rtc")
        .trim_end_matches('/');
    if cleaned.is_empty() {
        "ws://127.0.0.1:7880".to_string()
    } else {
        cleaned.to_string()
    }
}

pub fn mint_livekit_token(
    api_key: &str,
    api_secret: &str,
    room_name: &str,
    user: &UserDoc,
) -> Result<String, ApiError> {
    let key = api_key.trim().trim_matches(['"', '\'']).trim();
    let secret = api_secret.trim().trim_matches(['"', '\'']).trim();
    if key.is_empty() || secret.is_empty() {
        return Err(ApiError::bad_request(
            "ระบบโทรเสียง/วิดีโอ (LiveKit) ยังไม่ได้ตั้งค่าคีย์เชื่อมต่อ",
        ));
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| ApiError::internal(e.to_string()))?
        .as_secs() as usize;

    let metadata = json!({
        "user_id": user.id,
        "display_name": user.display_name,
        "avatar_url": user.avatar_url,
        "bc_id": user.bc_id,
    })
    .to_string();

    let claims = LiveKitClaims {
        iss: key.to_string(),
        sub: user.id.clone(),
        nbf: now.saturating_sub(10),
        exp: now + 6 * 3600,
        name: user.display_name.clone(),
        metadata,
        video: LiveKitVideoGrant {
            room_join: true,
            room: room_name.to_string(),
            can_publish: true,
            can_subscribe: true,
            can_publish_data: true,
        },
    };

    encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .map_err(|e| ApiError::internal(format!("สร้างโทเคน LiveKit ไม่สำเร็จ: {e}")))
}

fn is_bot_or_system_user(uid: &str) -> bool {
    uid == "user_ai" || uid == "user_official" || uid.starts_with("user_oa_")
}

async fn resolve_call_access_and_targets(
    state: &AppState,
    conv_id: &str,
    caller_id: &str,
    check_oa_calls_enabled: bool,
) -> Result<(ConversationDoc, Option<OaAccountDoc>, Vec<String>), ApiError> {
    let conv = state
        .db
        .collection::<ConversationDoc>("conversations")
        .find_one(doc! { "_id": conv_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบห้องแชท"))?;

    let mut oa_doc: Option<OaAccountDoc> = None;
    if let Some(ref oa_id) = conv.oa_id {
        let oa = state
            .db
            .collection::<OaAccountDoc>("oa_accounts")
            .find_one(doc! { "_id": oa_id })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .ok_or_else(|| ApiError::not_found("ไม่พบบัญชีร้านค้า"))?;

        let is_customer_member = conv
            .member_ids
            .iter()
            .any(|id| id == caller_id && !is_bot_or_system_user(id));
        let is_call_staff = matches!(
            crate::routes::oa_routes::resolve_oa_staff_role(&oa, caller_id).as_deref(),
            Some("owner" | "admin" | "agent")
        );
        if !is_customer_member && !is_call_staff {
            return Err(ApiError::forbidden(
                "เฉพาะลูกค้าในห้องแชท เจ้าของร้าน แอดมินร้าน หรือคนตอบแชท (Agent) เท่านั้นที่ใช้งานการโทรได้",
            ));
        }
        if check_oa_calls_enabled && !oa.calls_enabled {
            return Err(ApiError::bad_request(
                "ร้านค้านี้ปิดการรับสายโทรเสียงและวิดีโอชั่วคราว",
            ));
        }
        oa_doc = Some(oa);
    } else {
        let allowed = conv.member_ids.iter().any(|id| id == caller_id)
            || conv.admin_ids.iter().any(|id| id == caller_id);
        if !allowed {
            return Err(ApiError::forbidden("คุณไม่ได้เป็นสมาชิกของห้องแชทนี้"));
        }
    }

    let mut targets: Vec<String> = if let Some(ref oa) = oa_doc {
        let mut t: Vec<String> = conv
            .member_ids
            .iter()
            .filter(|id| !is_bot_or_system_user(id))
            .cloned()
            .collect();
        if !is_bot_or_system_user(&oa.owner_id) {
            t.push(oa.owner_id.clone());
        }
        for aid in &oa.admin_ids {
            if !is_bot_or_system_user(aid)
                && matches!(
                    crate::routes::oa_routes::resolve_oa_staff_role(oa, aid).as_deref(),
                    Some("admin" | "agent")
                )
            {
                t.push(aid.clone());
            }
        }
        t
    } else {
        conv.member_ids
            .iter()
            .chain(conv.admin_ids.iter())
            .filter(|id| !is_bot_or_system_user(id))
            .cloned()
            .collect()
    };
    if !targets.iter().any(|id| id == caller_id) {
        targets.push(caller_id.to_string());
    }
    targets.sort();
    targets.dedup();

    Ok((conv, oa_doc, targets))
}

fn format_duration_thai(duration_sec: u64) -> String {
    let mins = duration_sec / 60;
    let secs = duration_sec % 60;
    if mins > 0 {
        format!("{mins}:{secs:02} นาที")
    } else {
        format!("0:{secs:02} วินาที")
    }
}

fn build_call_log_text(call_type: &str, status: &str, duration_sec: u64) -> String {
    let is_video = call_type == "video";
    match (is_video, status) {
        (true, "missed") => "🎥 สายวิดีโอคอลที่ไม่ได้รับ".to_string(),
        (false, "missed") => "📞 สายโทรเสียงที่ไม่ได้รับ".to_string(),
        (true, "declined") => "🎥 ปฏิเสธสายวิดีโอคอล".to_string(),
        (false, "declined") => "📞 ปฏิเสธสายโทรเสียง".to_string(),
        (true, _) if duration_sec > 0 => {
            format!("🎥 วิดีโอคอล • {}", format_duration_thai(duration_sec))
        }
        (false, _) if duration_sec > 0 => {
            format!("📞 สายสนทนาเสียง • {}", format_duration_thai(duration_sec))
        }
        (true, _) => "🎥 ยกเลิกวิดีโอคอล".to_string(),
        (false, _) => "📞 ยกเลิกสายโทรเสียง".to_string(),
    }
}

async fn insert_call_log_and_broadcast(state: &AppState, call: &CallSessionDoc) {
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let Ok(Some(mut conv)) = conv_coll
        .find_one(doc! { "_id": &call.conversation_id })
        .await
    else {
        return;
    };

    let now = call
        .ended_at
        .clone()
        .unwrap_or_else(|| Utc::now().to_rfc3339());
    let msg_id = Uuid::new_v4().to_string();
    let content = build_call_log_text(&call.call_type, &call.status, call.duration_sec);
    let payload = json!({
        "call_id": call.id,
        "call_type": call.call_type,
        "status": call.status,
        "duration_sec": call.duration_sec,
        "initiator_id": call.initiator_id,
        "initiator_name": call.initiator_name,
        "end_reason": call.end_reason,
    });

    let msg_doc = MessageDoc {
        id: msg_id.clone(),
        conversation_id: conv.id.clone(),
        sender_id: call.initiator_id.clone(),
        sender_name: call.initiator_name.clone(),
        sender_avatar: call.initiator_avatar.clone(),
        msg_type: "call_log".to_string(),
        content: content.clone(),
        sticker_code: None,
        attachment: None,
        card_payload: Some(payload),
        flex_payload: None,
        reply_to: None,
        read_by: vec![call.initiator_id.clone()],
        is_unsent: false,
        is_confidential: false,
        confidential_pin: None,
        expire_at: None,
        priority: "normal".to_string(),
        task_status: None,
        accepted_by: None,
        accepted_at: None,
        reactions: HashMap::new(),
        mentions: Vec::new(),
        audio_duration_sec: None,
        poll: None,
        event_data: None,
        location_data: None,
        contact_data: None,
        ladder_data: None,
        edited_at: None,
        forwarded_from: None,
        deleted_for: conv
            .member_ids
            .iter()
            .filter(|uid| !is_bot_or_system_user(uid) && !call.target_user_ids.contains(uid))
            .cloned()
            .collect(),
        created_at: now.clone(),
    };

    let excluded_for_log = msg_doc.deleted_for.clone();

    if state
        .db
        .collection::<MessageDoc>("messages")
        .insert_one(&msg_doc)
        .await
        .is_err()
    {
        return;
    }

    if !(conv.conv_type == "direct" && conv.oa_id.is_none() && call.target_user_ids.len() <= 1) {
        conv.last_message = Some(LastMessageSummary {
            id: msg_id,
            sender_id: call.initiator_id.clone(),
            sender_name: call.initiator_name.clone(),
            msg_type: "call_log".to_string(),
            content,
            created_at: now.clone(),
            read_count: 0,
        });
        conv.updated_at = now;
        let _ = conv_coll.replace_one(doc! { "_id": &conv.id }, &conv).await;
    }

    let call_dto = CallSessionDto::from(call.clone());
    let msg_dto = MessageDto::from(msg_doc);

    state.ws_hub.broadcast_event(json!({
        "event": "call_ended",
        "conversation_id": conv.id,
        "target_user_ids": &call_dto.target_user_ids,
        "excluded_user_ids": &excluded_for_log,
        "call": &call_dto,
    }));
    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": conv.id,
        "target_user_ids": &call_dto.target_user_ids,
        "excluded_user_ids": &excluded_for_log,
        "message": &msg_dto,
    }));
    state.ws_hub.broadcast_event(json!({
        "event": "conversation_updated",
        "conversation_id": conv.id,
        "target_user_ids": &call_dto.target_user_ids,
        "excluded_user_ids": &excluded_for_log,
    }));

    crate::push::notify_call_cancelled(state, &conv, &call_dto);
}

async fn expire_ringing_call_if_unanswered(state: &AppState, call_id: &str) {
    let calls_coll = state.db.collection::<CallSessionDoc>("call_sessions");
    let Ok(Some(mut call)) = calls_coll
        .find_one(doc! { "_id": call_id, "status": "ringing" })
        .await
    else {
        return;
    };

    let now = Utc::now().to_rfc3339();
    call.status = "missed".to_string();
    call.ended_at = Some(now.clone());
    call.duration_sec = 0;
    call.end_reason = Some("timeout".to_string());
    for p in &mut call.participants {
        if p.state == "ringing" {
            p.state = "missed".to_string();
            p.updated_at = now.clone();
        } else if p.state == "joined" {
            p.state = "left".to_string();
            p.updated_at = now.clone();
        }
    }

    let participants_bson = bson::to_bson(&call.participants).unwrap_or(bson::Bson::Array(vec![]));
    let res = calls_coll
        .update_one(
            doc! { "_id": call_id, "status": "ringing" },
            doc! {
                "$set": {
                    "status": "missed",
                    "ended_at": &call.ended_at,
                    "duration_sec": 0_i64,
                    "end_reason": "timeout",
                    "participants": participants_bson,
                }
            },
        )
        .await;

    if let Ok(upd) = res {
        if upd.modified_count == 1 {
            insert_call_log_and_broadcast(state, &call).await;
        }
    }
}

fn default_call_type() -> String {
    "audio".to_string()
}

#[derive(Debug, Deserialize)]
pub struct StartCallRequest {
    pub conversation_id: String,
    #[serde(default = "default_call_type")]
    pub call_type: String,
}

pub async fn start_call_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<StartCallRequest>,
) -> Result<Json<Value>, ApiError> {
    let conv_id = payload.conversation_id.trim();
    if conv_id.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุห้องแชทที่ต้องการโทร"));
    }

    let call_type = payload.call_type.trim().to_lowercase();
    if call_type != "audio" && call_type != "video" {
        return Err(ApiError::bad_request(
            "ประเภทการโทรต้องเป็น audio หรือ video เท่านั้น",
        ));
    }

    let (conv, oa_doc, raw_targets) =
        resolve_call_access_and_targets(&state, conv_id, &auth.user_id, true).await?;

    if raw_targets
        .iter()
        .filter(|id| *id != &auth.user_id)
        .count()
        == 0
    {
        return Err(ApiError::bad_request(
            "ห้องแชทนี้ไม่มีผู้รับสายที่รองรับการโทรเสียงหรือวิดีโอ",
        ));
    }

    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");
    if conv.conv_type == "direct" && conv.oa_id.is_none() {
        if let Some(peer_id) = raw_targets.iter().find(|id| *id != &auth.user_id) {
            let caller_blocked_peer = friends_coll
                .count_documents(doc! {
                    "user_id": &auth.user_id,
                    "friend_id": peer_id,
                    "is_blocked": true,
                })
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?
                > 0;
            if caller_blocked_peer {
                return Err(ApiError::bad_request(
                    "คุณได้บล็อกผู้ใช้นี้ กรุณาปลดบล็อกก่อนโทรออก",
                ));
            }
        }
    }

    let excluded_user_ids: Vec<String> = friends_coll
        .find(doc! {
            "friend_id": &auth.user_id,
            "user_id": { "$in": &raw_targets },
            "is_blocked": true,
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect::<Vec<FriendshipDoc>>()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .into_iter()
        .map(|f| f.user_id)
        .collect();

    let target_user_ids: Vec<String> = raw_targets
        .into_iter()
        .filter(|uid| uid == &auth.user_id || !excluded_user_ids.contains(uid))
        .collect();

    let users_coll = state.db.collection::<UserDoc>("users");
    let user_docs: Vec<UserDoc> = users_coll
        .find(doc! { "_id": { "$in": &target_user_ids } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let user_map: HashMap<String, UserDoc> =
        user_docs.into_iter().map(|u| (u.id.clone(), u)).collect();

    let caller = user_map
        .get(&auth.user_id)
        .cloned()
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้โทร"))?;

    let room_name = format!("bc_call_{}", Uuid::new_v4().simple());
    let token = mint_livekit_token(
        &state.config.livekit_api_key,
        &state.config.livekit_api_secret,
        &room_name,
        &caller,
    )?;
    let livekit_url = clean_livekit_url(&state.config.livekit_url);

    let now = Utc::now().to_rfc3339();
    let participants: Vec<CallParticipantState> = target_user_ids
        .iter()
        .map(|uid| {
            let (dname, avatar) = user_map
                .get(uid)
                .map(|u| (u.display_name.clone(), u.avatar_url.clone()))
                .unwrap_or_else(|| (uid.clone(), String::new()));
            let is_caller = uid == &auth.user_id;
            CallParticipantState {
                user_id: uid.clone(),
                display_name: dname,
                avatar_url: avatar,
                state: if is_caller {
                    "joined".to_string()
                } else {
                    "ringing".to_string()
                },
                muted_audio: false,
                video_enabled: is_caller && call_type == "video",
                updated_at: now.clone(),
            }
        })
        .collect();

    let call_id = format!("call_{}", Uuid::new_v4().simple());
    let call_doc = CallSessionDoc {
        id: call_id.clone(),
        conversation_id: conv.id.clone(),
        room_name,
        call_type,
        status: "ringing".to_string(),
        initiator_id: caller.id.clone(),
        initiator_name: caller.display_name.clone(),
        initiator_avatar: caller.avatar_url.clone(),
        oa_id: oa_doc.map(|o| o.id).or(conv.oa_id.clone()),
        target_user_ids: target_user_ids.clone(),
        participants,
        started_at: now,
        answered_at: None,
        ended_at: None,
        duration_sec: 0,
        end_reason: None,
    };

    state
        .db
        .collection::<CallSessionDoc>("call_sessions")
        .insert_one(&call_doc)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let call_dto = CallSessionDto::from(call_doc);

    state.ws_hub.broadcast_event(json!({
        "event": "call_incoming",
        "conversation_id": conv.id,
        "target_user_ids": &call_dto.target_user_ids,
        "excluded_user_ids": &excluded_user_ids,
        "call": &call_dto,
    }));
    crate::push::notify_incoming_call(&state, &conv, &call_dto);

    let timeout_ms = state.config.call_ring_timeout_ms;
    let bg_state = state.clone();
    let bg_call_id = call_id;
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(timeout_ms)).await;
        expire_ringing_call_if_unanswered(&bg_state, &bg_call_id).await;
    });

    Ok(Json(json!({
        "call": call_dto,
        "livekit_url": livekit_url,
        "token": token,
    })))
}

#[derive(Debug, Deserialize)]
pub struct ActiveCallsQuery {
    pub conversation_id: Option<String>,
}

pub async fn list_active_calls_handler(
    auth: AuthUser,
    Query(query): Query<ActiveCallsQuery>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let mut filter = doc! {
        "status": { "$in": ["ringing", "active"] },
        "target_user_ids": &auth.user_id,
    };
    if let Some(ref cid) = query.conversation_id {
        let trimmed = cid.trim();
        if !trimmed.is_empty() {
            let _ = resolve_call_access_and_targets(&state, trimmed, &auth.user_id, false).await?;
            filter = doc! {
                "conversation_id": trimmed,
                "status": { "$in": ["ringing", "active"] },
            };
        }
    }

    let mut calls: Vec<CallSessionDoc> = state
        .db
        .collection::<CallSessionDoc>("call_sessions")
        .find(filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    calls.sort_by(|a, b| b.started_at.cmp(&a.started_at));
    let dtos: Vec<CallSessionDto> = calls.into_iter().map(CallSessionDto::from).collect();

    Ok(Json(json!({ "calls": dtos })))
}

async fn load_authorized_call(
    state: &AppState,
    call_id: &str,
    user_id: &str,
) -> Result<CallSessionDoc, ApiError> {
    let call = state
        .db
        .collection::<CallSessionDoc>("call_sessions")
        .find_one(doc! { "_id": call_id.trim() })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลสายสนทนานี้"))?;

    if !call.target_user_ids.iter().any(|id| id == user_id) {
        let _ = resolve_call_access_and_targets(state, &call.conversation_id, user_id, false).await?;
    }
    Ok(call)
}

pub async fn accept_call_handler(
    auth: AuthUser,
    Path(call_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let mut call = load_authorized_call(&state, &call_id, &auth.user_id).await?;
    if call.status != "ringing" && call.status != "active" {
        return Err(ApiError::bad_request("สายสนทนานี้สิ้นสุดไปแล้ว"));
    }

    let user = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let conv = state
        .db
        .collection::<ConversationDoc>("conversations")
        .find_one(doc! { "_id": &call.conversation_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let token = mint_livekit_token(
        &state.config.livekit_api_key,
        &state.config.livekit_api_secret,
        &call.room_name,
        &user,
    )?;
    let livekit_url = clean_livekit_url(&state.config.livekit_url);

    let now = Utc::now().to_rfc3339();
    if call.status == "ringing" {
        call.status = "active".to_string();
    }
    if call.answered_at.is_none() {
        call.answered_at = Some(now.clone());
    }
    if !call.target_user_ids.iter().any(|id| id == &user.id) {
        call.target_user_ids.push(user.id.clone());
    }

    if let Some(p) = call.participants.iter_mut().find(|p| p.user_id == user.id) {
        p.state = "joined".to_string();
        p.display_name = user.display_name.clone();
        p.avatar_url = user.avatar_url.clone();
        p.video_enabled = call.call_type == "video";
        p.updated_at = now.clone();
    } else {
        call.participants.push(CallParticipantState {
            user_id: user.id.clone(),
            display_name: user.display_name.clone(),
            avatar_url: user.avatar_url.clone(),
            state: "joined".to_string(),
            muted_audio: false,
            video_enabled: call.call_type == "video",
            updated_at: now.clone(),
        });
    }

    if let Some(ref conv_doc) = conv {
        if conv_doc.oa_id.is_some() && !conv_doc.member_ids.iter().any(|id| id == &user.id) {
            for p in &mut call.participants {
                if p.user_id != user.id
                    && p.state == "ringing"
                    && !conv_doc.member_ids.iter().any(|id| id == &p.user_id)
                {
                    p.state = "answered_elsewhere".to_string();
                    p.updated_at = now.clone();
                }
            }
        }
    }

    state
        .db
        .collection::<CallSessionDoc>("call_sessions")
        .replace_one(doc! { "_id": &call.id }, &call)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let call_dto = CallSessionDto::from(call);

    state.ws_hub.broadcast_event(json!({
        "event": "call_accepted",
        "conversation_id": &call_dto.conversation_id,
        "target_user_ids": &call_dto.target_user_ids,
        "accepted_by": &auth.user_id,
        "call": &call_dto,
    }));
    state.ws_hub.broadcast_event(json!({
        "event": "call_participant_updated",
        "conversation_id": &call_dto.conversation_id,
        "target_user_ids": &call_dto.target_user_ids,
        "call": &call_dto,
    }));

    Ok(Json(json!({
        "call": call_dto,
        "livekit_url": livekit_url,
        "token": token,
    })))
}

pub async fn get_call_token_handler(
    auth: AuthUser,
    Path(call_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let call = load_authorized_call(&state, &call_id, &auth.user_id).await?;
    if call.status != "ringing" && call.status != "active" {
        return Err(ApiError::bad_request("สายสนทนานี้สิ้นสุดไปแล้ว"));
    }

    let user = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let token = mint_livekit_token(
        &state.config.livekit_api_key,
        &state.config.livekit_api_secret,
        &call.room_name,
        &user,
    )?;
    let livekit_url = clean_livekit_url(&state.config.livekit_url);

    Ok(Json(json!({
        "call": CallSessionDto::from(call),
        "livekit_url": livekit_url,
        "token": token,
    })))
}

async fn terminate_call_session(
    state: &AppState,
    call_id: &str,
    actor_id: &str,
    final_status: &str,
    reason: &str,
) -> Result<CallSessionDto, ApiError> {
    let mut call = load_authorized_call(state, call_id, actor_id).await?;
    if call.status != "ringing" && call.status != "active" {
        return Ok(CallSessionDto::from(call));
    }

    let ended_dt = Utc::now();
    let ended_str = ended_dt.to_rfc3339();
    let duration_sec = if let Some(ref ans) = call.answered_at {
        DateTime::parse_from_rfc3339(ans)
            .ok()
            .map(|dt| {
                let secs = (ended_dt - dt.with_timezone(&Utc)).num_seconds();
                secs.max(1) as u64
            })
            .unwrap_or(1)
    } else {
        0
    };

    call.status = final_status.to_string();
    call.ended_at = Some(ended_str.clone());
    call.duration_sec = duration_sec;
    call.end_reason = Some(reason.to_string());

    for p in &mut call.participants {
        if p.user_id == actor_id && final_status == "declined" {
            p.state = "declined".to_string();
            p.updated_at = ended_str.clone();
        } else if p.state == "joined" {
            p.state = "left".to_string();
            p.updated_at = ended_str.clone();
        } else if p.state == "ringing" {
            p.state = if final_status == "declined" {
                "declined".to_string()
            } else {
                "missed".to_string()
            };
            p.updated_at = ended_str.clone();
        }
    }

    let calls_coll = state.db.collection::<CallSessionDoc>("call_sessions");
    let participants_bson = bson::to_bson(&call.participants).unwrap_or(bson::Bson::Array(vec![]));
    let upd = calls_coll
        .update_one(
            doc! { "_id": &call.id, "status": { "$in": ["ringing", "active"] } },
            doc! {
                "$set": {
                    "status": &call.status,
                    "ended_at": &call.ended_at,
                    "duration_sec": call.duration_sec as i64,
                    "end_reason": &call.end_reason,
                    "participants": participants_bson,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    if upd.modified_count == 1 {
        insert_call_log_and_broadcast(state, &call).await;
    } else if let Ok(Some(latest)) = calls_coll.find_one(doc! { "_id": &call.id }).await {
        call = latest;
    }

    Ok(CallSessionDto::from(call))
}

pub async fn decline_call_handler(
    auth: AuthUser,
    Path(call_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let mut call = load_authorized_call(&state, &call_id, &auth.user_id).await?;
    if call.status != "ringing" && call.status != "active" {
        return Ok(Json(json!({ "call": CallSessionDto::from(call) })));
    }

    let now = Utc::now().to_rfc3339();
    if let Some(p) = call
        .participants
        .iter_mut()
        .find(|p| p.user_id == auth.user_id)
    {
        p.state = "declined".to_string();
        p.updated_at = now.clone();
    } else {
        call.participants.push(CallParticipantState {
            user_id: auth.user_id.clone(),
            display_name: auth.user_id.clone(),
            avatar_url: String::new(),
            state: "declined".to_string(),
            muted_audio: false,
            video_enabled: false,
            updated_at: now.clone(),
        });
    }

    let other_ringing = call
        .participants
        .iter()
        .filter(|p| {
            p.user_id != call.initiator_id && p.user_id != auth.user_id && p.state == "ringing"
        })
        .count();
    let joined_count = call
        .participants
        .iter()
        .filter(|p| p.state == "joined")
        .count();

    if other_ringing > 0 || (call.status == "active" && joined_count >= 2) {
        let calls_coll = state.db.collection::<CallSessionDoc>("call_sessions");
        let participants_bson =
            bson::to_bson(&call.participants).map_err(|e| ApiError::internal(e.to_string()))?;
        let upd = calls_coll
            .update_one(
                doc! { "_id": &call.id, "status": { "$in": ["ringing", "active"] } },
                doc! { "$set": { "participants": participants_bson } },
            )
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;

        if upd.matched_count == 0 {
            if let Ok(Some(latest)) = calls_coll.find_one(doc! { "_id": &call.id }).await {
                return Ok(Json(json!({ "call": CallSessionDto::from(latest) })));
            }
        }

        let call_dto = CallSessionDto::from(call);
        state.ws_hub.broadcast_event(json!({
            "event": "call_declined",
            "conversation_id": &call_dto.conversation_id,
            "target_user_ids": &call_dto.target_user_ids,
            "declined_by": &auth.user_id,
            "call": &call_dto,
        }));
        state.ws_hub.broadcast_event(json!({
            "event": "call_participant_updated",
            "conversation_id": &call_dto.conversation_id,
            "target_user_ids": &call_dto.target_user_ids,
            "call": &call_dto,
        }));
        return Ok(Json(json!({ "call": call_dto })));
    }

    let dto = terminate_call_session(&state, &call_id, &auth.user_id, "declined", "declined").await?;
    Ok(Json(json!({ "call": dto })))
}

pub async fn hangup_call_handler(
    auth: AuthUser,
    Path(call_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let mut call = load_authorized_call(&state, &call_id, &auth.user_id).await?;
    if call.status == "active" {
        let other_joined = call
            .participants
            .iter()
            .filter(|p| p.user_id != auth.user_id && p.state == "joined")
            .count();
        if other_joined >= 2 {
            let now = Utc::now().to_rfc3339();
            if let Some(p) = call
                .participants
                .iter_mut()
                .find(|p| p.user_id == auth.user_id)
            {
                p.state = "left".to_string();
                p.updated_at = now;
            }
            let calls_coll = state.db.collection::<CallSessionDoc>("call_sessions");
            let participants_bson =
                bson::to_bson(&call.participants).map_err(|e| ApiError::internal(e.to_string()))?;
            let upd = calls_coll
                .update_one(
                    doc! { "_id": &call.id, "status": "active" },
                    doc! { "$set": { "participants": participants_bson } },
                )
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?;

            if upd.matched_count == 0 {
                if let Ok(Some(latest)) = calls_coll.find_one(doc! { "_id": &call.id }).await {
                    return Ok(Json(json!({ "call": CallSessionDto::from(latest) })));
                }
            }

            let call_dto = CallSessionDto::from(call);
            state.ws_hub.broadcast_event(json!({
                "event": "call_participant_updated",
                "conversation_id": &call_dto.conversation_id,
                "target_user_ids": &call_dto.target_user_ids,
                "call": &call_dto,
            }));
            return Ok(Json(json!({ "call": call_dto })));
        }
    }

    let dto = terminate_call_session(&state, &call_id, &auth.user_id, "ended", "hangup").await?;
    Ok(Json(json!({ "call": dto })))
}
