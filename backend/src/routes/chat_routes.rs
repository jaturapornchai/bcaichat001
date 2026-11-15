use axum::{
    extract::{Path, Query, State},
    Json,
};
use bson::{doc, Regex};
use chrono::{DateTime, Utc};
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use crate::{
    auth::{ApiError, AuthUser},
    models::{
        compute_timed_window, resolve_effective_mute, AlbumDoc, AlbumDto, AttachmentInfo,
        ContactCardData, ConversationDoc, ConversationDto, ConversationMemberDto, EventData,
        FileDoc, FriendshipDoc, LadderGameData, LastMessageSummary, LocationData, MessageDoc,
        MessageDto, NoteComment, NoteDoc, NoteDto, OaAccountDoc, PinnedMessageSummary, PollData,
        PollOption, ReplyInfo, UserConvMeta, UserDoc, VaultFileItem, VaultLinkItem, VaultResponse,
    },
    seed::{ensure_direct_conversation, ensure_keep_conversation_for_user},
    AppState,
};

#[derive(Debug, Deserialize)]
pub struct ListConversationsQuery {
    pub folder: Option<String>,
}

/// Loads a conversation only for its members.
pub async fn require_member(
    state: &AppState,
    conv_id: &str,
    user_id: &str,
) -> Result<ConversationDoc, ApiError> {
    let conv = state
        .db
        .collection::<ConversationDoc>("conversations")
        .find_one(doc! { "_id": conv_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบห้องแชท"))?;
    let is_oa_staff = conv.oa_id.is_some() && conv.admin_ids.iter().any(|id| id == user_id);
    if !conv.member_ids.iter().any(|id| id == user_id) && !is_oa_staff {
        return Err(ApiError::forbidden("คุณไม่ได้เป็นสมาชิกของห้องแชทนี้"));
    }
    Ok(conv)
}

fn resolve_user_conv_meta(
    conv: &ConversationDoc,
    user_id: &str,
) -> (String, bool, bool, Option<String>, bool) {
    let (is_muted, muted_until) = resolve_effective_mute(conv, user_id, Utc::now());
    if let Some(meta) = conv.user_meta.get(user_id) {
        let folder = if meta.folder.is_empty() {
            conv.folder.clone()
        } else {
            meta.folder.clone()
        };
        (folder, meta.is_pinned, is_muted, muted_until, meta.is_archived)
    } else {
        (
            conv.folder.clone(),
            conv.is_pinned,
            is_muted,
            muted_until,
            conv.is_archived,
        )
    }
}

pub fn generate_invite_token() -> String {
    format!(
        "BCINV-{}",
        &Uuid::new_v4().simple().to_string()[..8].to_uppercase()
    )
}

pub async fn build_conversation_dto(
    state: &AppState,
    mut conv: ConversationDoc,
    current_user_id: &str,
) -> Result<ConversationDto, String> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    if conv.conv_type == "group" && conv.invite_token.is_empty() {
        conv.invite_token = generate_invite_token();
        let _ = state
            .db
            .collection::<ConversationDoc>("conversations")
            .update_one(
                doc! { "_id": &conv.id },
                doc! { "$set": { "invite_token": &conv.invite_token } },
            )
            .await;
    }

    let user_cursor = users_coll
        .find(doc! { "_id": { "$in": &conv.member_ids } })
        .await
        .map_err(|e| e.to_string())?;
    let member_docs: Vec<UserDoc> = user_cursor
        .try_collect()
        .await
        .map_err(|e| e.to_string())?;

    let members: Vec<ConversationMemberDto> = member_docs
        .iter()
        .map(|u| ConversationMemberDto {
            id: u.id.clone(),
            email: u.email.clone(),
            phone: u.phone.clone(),
            display_name: u.display_name.clone(),
            bc_id: u.bc_id.clone(),
            avatar_url: u.avatar_url.clone(),
            status_message: u.status_message.clone(),
            role: u.role.clone(),
            department: if u.department.is_empty() {
                "เพื่อน".to_string()
            } else {
                u.department.clone()
            },
            job_title: if u.job_title.is_empty() {
                "เพื่อน".to_string()
            } else {
                u.job_title.clone()
            },
        })
        .collect();

    let (resolved_name, resolved_avatar) =
        if conv.conv_type == "direct" || conv.conv_type == "official" {
            if let Some(other) = member_docs.iter().find(|u| u.id != current_user_id) {
                (other.display_name.clone(), other.avatar_url.clone())
            } else {
                (conv.name.clone(), conv.avatar_url.clone())
            }
        } else {
            (conv.name.clone(), conv.avatar_url.clone())
        };

    let (folder, is_pinned, is_muted, muted_until, is_archived) =
        resolve_user_conv_meta(&conv, current_user_id);

    let is_blocked_by_me = if conv.conv_type == "direct" && conv.oa_id.is_none() {
        if let Some(other_id) = conv.member_ids.iter().find(|id| *id != current_user_id) {
            state
                .db
                .collection::<bson::Document>("friendships")
                .count_documents(doc! {
                    "user_id": current_user_id,
                    "friend_id": other_id,
                    "is_blocked": true,
                })
                .await
                .unwrap_or(0)
                > 0
        } else {
            false
        }
    } else {
        false
    };

    let unread_count = msg_coll
        .count_documents(doc! {
            "conversation_id": &conv.id,
            "sender_id": { "$ne": current_user_id },
            "read_by": { "$ne": current_user_id },
            "deleted_for": { "$ne": current_user_id },
            "is_unsent": false,
        })
        .await
        .unwrap_or(0) as usize;

    let mut last_message = conv.last_message.clone();
    if let Some(lm_id) = last_message.as_ref().map(|lm| lm.id.clone()) {
        if let Ok(Some(mdoc)) = msg_coll.find_one(doc! { "_id": &lm_id }).await {
            if mdoc.deleted_for.iter().any(|uid| uid == current_user_id) {
                last_message = None;
            } else if let Some(ref mut lm) = last_message {
                lm.read_count = mdoc
                    .read_by
                    .iter()
                    .filter(|uid| *uid != &mdoc.sender_id)
                    .count();
                if mdoc.is_unsent {
                    lm.content = mdoc.content;
                }
            }
        }
    }

    let (oa_handle, rich_menu) = if let Some(ref oid) = conv.oa_id {
        if let Ok(Some(oa)) = state
            .db
            .collection::<OaAccountDoc>("oa_accounts")
            .find_one(doc! { "_id": oid })
            .await
        {
            (Some(oa.handle), oa.rich_menu)
        } else {
            (conv.oa_handle.clone(), Vec::new())
        }
    } else {
        (conv.oa_handle.clone(), Vec::new())
    };

    let member_count = conv.member_ids.len().max(members.len());
    Ok(ConversationDto {
        id: conv.id,
        conv_type: conv.conv_type,
        name: resolved_name,
        avatar_url: resolved_avatar,
        folder,
        is_pinned,
        is_muted,
        muted_until,
        is_blocked_by_me,
        is_archived,
        invite_token: conv.invite_token,
        admin_ids: conv.admin_ids,
        member_ids: conv.member_ids,
        oa_id: conv.oa_id,
        oa_handle,
        rich_menu,
        pinned_message: conv.pinned_message,
        unread_count,
        member_count,
        members,
        last_message,
        created_at: conv.created_at,
        updated_at: conv.updated_at,
    })
}

pub async fn list_conversations_handler(
    auth: AuthUser,
    Query(query): Query<ListConversationsQuery>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ConversationDto>>, ApiError> {
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let cursor = conv_coll
        .find(doc! { "member_ids": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let docs: Vec<ConversationDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let folder_filter = query
        .folder
        .unwrap_or_else(|| "all".to_string())
        .to_lowercase();

    // Batch fetch all member users in 1 query (prevent N+1)
    let mut all_member_ids: Vec<String> = docs
        .iter()
        .flat_map(|c| c.member_ids.iter().cloned())
        .collect();
    all_member_ids.sort();
    all_member_ids.dedup();

    let users_coll = state.db.collection::<UserDoc>("users");
    let user_cursor = users_coll
        .find(doc! { "_id": { "$in": &all_member_ids } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let all_users: Vec<UserDoc> = user_cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let user_map: HashMap<String, UserDoc> =
        all_users.into_iter().map(|u| (u.id.clone(), u)).collect();

    // Batch fetch last messages in 1 query
    let last_msg_ids: Vec<String> = docs
        .iter()
        .filter_map(|c| c.last_message.as_ref().map(|lm| lm.id.clone()))
        .collect();
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let lm_cursor = msg_coll
        .find(doc! { "_id": { "$in": &last_msg_ids } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let lm_docs: Vec<MessageDoc> = lm_cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let lm_map: HashMap<String, MessageDoc> =
        lm_docs.into_iter().map(|m| (m.id.clone(), m)).collect();

    // Batch fetch OA accounts in 1 query (prevent N+1)
    let mut all_oa_ids: Vec<String> = docs.iter().filter_map(|c| c.oa_id.clone()).collect();
    all_oa_ids.sort();
    all_oa_ids.dedup();
    let oa_map: HashMap<String, OaAccountDoc> = if all_oa_ids.is_empty() {
        HashMap::new()
    } else {
        state
            .db
            .collection::<OaAccountDoc>("oa_accounts")
            .find(doc! { "_id": { "$in": &all_oa_ids } })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .try_collect::<Vec<OaAccountDoc>>()
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .into_iter()
            .map(|o| (o.id.clone(), o))
            .collect()
    };

    // Batch unread counts across ALL conversations in 1 MongoDB aggregate (0 N+1 queries)
    let conv_ids: Vec<String> = docs.iter().map(|c| c.id.clone()).collect();
    let mut unread_map: HashMap<String, usize> = HashMap::new();
    if !conv_ids.is_empty() {
        let pipeline = vec![
            doc! {
                "$match": {
                    "conversation_id": { "$in": &conv_ids },
                    "sender_id": { "$ne": &auth.user_id },
                    "read_by": { "$ne": &auth.user_id },
                    "deleted_for": { "$ne": &auth.user_id },
                    "is_unsent": false,
                }
            },
            doc! {
                "$group": {
                    "_id": "$conversation_id",
                    "count": { "$sum": 1_i32 }
                }
            },
        ];
        if let Ok(mut agg_cursor) = msg_coll.aggregate(pipeline).await {
            while let Ok(Some(row)) = agg_cursor.try_next().await {
                if let Ok(cid) = row.get_str("_id") {
                    let cnt = row
                        .get_i32("count")
                        .map(|v| v as usize)
                        .or_else(|_| row.get_i64("count").map(|v| v as usize))
                        .unwrap_or(0);
                    unread_map.insert(cid.to_string(), cnt);
                }
            }
        }
    }

    // Batch fetch blocked friend IDs in 1 query for is_blocked_by_me
    let blocked_friend_ids: HashSet<String> = state
        .db
        .collection::<FriendshipDoc>("friendships")
        .find(doc! { "user_id": &auth.user_id, "is_blocked": true })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect::<Vec<FriendshipDoc>>()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .into_iter()
        .map(|f| f.friend_id)
        .collect();

    let mut dtos = Vec::with_capacity(docs.len());
    for mut conv in docs {
        if conv.conv_type == "group" && conv.invite_token.is_empty() {
            conv.invite_token = generate_invite_token();
            let _ = conv_coll
                .update_one(
                    doc! { "_id": &conv.id },
                    doc! { "$set": { "invite_token": &conv.invite_token } },
                )
                .await;
        }

        let member_docs: Vec<&UserDoc> = conv
            .member_ids
            .iter()
            .filter_map(|id| user_map.get(id))
            .collect();

        let members: Vec<ConversationMemberDto> = member_docs
            .iter()
            .map(|u| ConversationMemberDto {
                id: u.id.clone(),
                email: u.email.clone(),
                phone: u.phone.clone(),
                display_name: u.display_name.clone(),
                bc_id: u.bc_id.clone(),
                avatar_url: u.avatar_url.clone(),
                status_message: u.status_message.clone(),
                role: u.role.clone(),
                department: if u.department.is_empty() {
                    "เพื่อน".to_string()
                } else {
                    u.department.clone()
                },
                job_title: if u.job_title.is_empty() {
                    "เพื่อน".to_string()
                } else {
                    u.job_title.clone()
                },
            })
            .collect();

        let (resolved_name, resolved_avatar) =
            if conv.conv_type == "direct" || conv.conv_type == "official" {
                if let Some(other) = member_docs.iter().find(|u| u.id != auth.user_id) {
                    (other.display_name.clone(), other.avatar_url.clone())
                } else {
                    (conv.name.clone(), conv.avatar_url.clone())
                }
            } else {
                (conv.name.clone(), conv.avatar_url.clone())
            };

        let (folder, is_pinned, is_muted, muted_until, is_archived) =
            resolve_user_conv_meta(&conv, &auth.user_id);

        let is_blocked_by_me = conv.conv_type == "direct"
            && conv.oa_id.is_none()
            && conv
                .member_ids
                .iter()
                .any(|id| id != &auth.user_id && blocked_friend_ids.contains(id));

        let unread_count = unread_map.get(&conv.id).copied().unwrap_or(0);

        let mut last_message = conv.last_message.clone();
        if let Some(lm_id) = last_message.as_ref().map(|lm| lm.id.clone()) {
            if let Some(mdoc) = lm_map.get(&lm_id) {
                if mdoc.deleted_for.iter().any(|uid| uid == &auth.user_id) {
                    last_message = None;
                } else if let Some(ref mut lm) = last_message {
                    lm.read_count = mdoc
                        .read_by
                        .iter()
                        .filter(|uid| *uid != &mdoc.sender_id)
                        .count();
                    if mdoc.is_unsent {
                        lm.content = mdoc.content.clone();
                    }
                }
            }
        }

        let (oa_handle, rich_menu) = if let Some(ref oid) = conv.oa_id {
            if let Some(oa) = oa_map.get(oid) {
                (Some(oa.handle.clone()), oa.rich_menu.clone())
            } else {
                (conv.oa_handle.clone(), Vec::new())
            }
        } else {
            (conv.oa_handle.clone(), Vec::new())
        };

        let member_count = conv.member_ids.len().max(members.len());
        let dto = ConversationDto {
            id: conv.id,
            conv_type: conv.conv_type,
            name: resolved_name,
            avatar_url: resolved_avatar,
            folder,
            is_pinned,
            is_muted,
            muted_until,
            is_blocked_by_me,
            is_archived,
            invite_token: conv.invite_token,
            admin_ids: conv.admin_ids,
            member_ids: conv.member_ids,
            oa_id: conv.oa_id,
            oa_handle,
            rich_menu,
            pinned_message: conv.pinned_message,
            unread_count,
            member_count,
            members,
            last_message,
            created_at: conv.created_at,
            updated_at: conv.updated_at,
        };

        let keep = match folder_filter.as_str() {
            "all" | "" => true,
            "personal" => {
                (dto.folder == "personal" || dto.conv_type == "keep") && !dto.is_archived
            }
            "family" | "work" => {
                (dto.folder == "family" || dto.folder == "work") && !dto.is_archived
            }
            "group" | "groups" => {
                (dto.conv_type == "group" || dto.folder == "group") && !dto.is_archived
            }
            "pinned" => dto.is_pinned && !dto.is_archived,
            "unread" => dto.unread_count > 0 && !dto.is_archived,
            "archived" | "archive" => dto.is_archived,
            "keep" => dto.conv_type == "keep",
            other => dto.folder == other,
        };

        if keep {
            dtos.push(dto);
        }
    }

    dtos.sort_by(|a, b| {
        b.is_pinned
            .cmp(&a.is_pinned)
            .then_with(|| b.updated_at.cmp(&a.updated_at))
    });

    Ok(Json(dtos))
}

#[derive(Debug, Deserialize)]
pub struct CreateDirectConvRequest {
    pub friend_id: String,
}

pub async fn create_direct_conversation_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<CreateDirectConvRequest>,
) -> Result<Json<ConversationDto>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let friend = users_coll
        .find_one(doc! { "_id": payload.friend_id.trim() })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลเพื่อนที่ระบุ"))?;

    let conv = ensure_direct_conversation(
        &state,
        &me,
        &friend,
        "direct",
        "personal",
        false,
        "เริ่มการสนทนาใหม่",
    )
    .await
    .map_err(ApiError::internal)?;

    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct CreateGroupConvRequest {
    pub name: String,
    pub folder: Option<String>,
    #[serde(default)]
    pub member_ids: Vec<String>,
    pub avatar_url: Option<String>,
}

pub async fn create_group_conversation_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<CreateGroupConvRequest>,
) -> Result<Json<ConversationDto>, ApiError> {
    let name = payload.name.trim().to_string();
    if name.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุชื่อกลุ่มแชท"));
    }

    let users_coll = state.db.collection::<UserDoc>("users");
    let me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let mut members = payload.member_ids;
    if !members.contains(&auth.user_id) {
        members.insert(0, auth.user_id.clone());
    }
    members.sort();
    members.dedup();

    let now = Utc::now().to_rfc3339();
    let conv_id = Uuid::new_v4().to_string();
    let msg_id = Uuid::new_v4().to_string();
    let sys_text = format!("{} สร้างกลุ่ม \"{}\"", me.display_name, name);

    let avatar = payload
        .avatar_url
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| {
            format!(
                "https://ui-avatars.com/api/?name={}&background=812920&color=fff&bold=true",
                urlencoding::encode(&name)
            )
        });

    let conv = ConversationDoc {
        id: conv_id.clone(),
        conv_type: "group".to_string(),
        name,
        avatar_url: avatar,
        folder: payload.folder.unwrap_or_else(|| "group".to_string()),
        is_pinned: false,
        is_muted: false,
        is_archived: false,
        invite_token: generate_invite_token(),
        admin_ids: vec![me.id.clone()],
        member_ids: members,
        oa_id: None,
        oa_handle: None,
        user_meta: HashMap::new(),
        pinned_message: None,
        last_message: Some(LastMessageSummary {
            id: msg_id.clone(),
            sender_id: me.id.clone(),
            sender_name: me.display_name.clone(),
            msg_type: "system".to_string(),
            content: sys_text.clone(),
            created_at: now.clone(),
            read_count: 0,
        }),
        created_at: now.clone(),
        updated_at: now.clone(),
    };

    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    conv_coll
        .insert_one(&conv)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let sys_msg = MessageDoc {
        id: msg_id,
        conversation_id: conv_id.clone(),
        sender_id: me.id.clone(),
        sender_name: me.display_name,
        sender_avatar: me.avatar_url,
        msg_type: "system".to_string(),
        content: sys_text,
        sticker_code: None,
        attachment: None,
        card_payload: None,
        flex_payload: None,
        reply_to: None,
        read_by: vec![me.id],
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
        deleted_for: Vec::new(),
        created_at: now,
    };
    let _ = msg_coll.insert_one(sys_msg).await;

    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;

    state.ws_hub.broadcast_event(json!({
        "event": "conversation_updated",
        "conversation_id": conv_id,
    }));

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct UpdateConvMetaRequest {
    pub folder: Option<String>,
    pub is_pinned: Option<bool>,
    pub is_muted: Option<bool>,
    pub mute_duration: Option<String>,
    pub muted_until: Option<String>,
    pub is_archived: Option<bool>,
    pub name: Option<String>,
    pub avatar_url: Option<String>,
}

pub async fn update_conversation_meta_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateConvMetaRequest>,
) -> Result<Json<ConversationDto>, ApiError> {
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;

    let (cur_folder, cur_pinned, cur_muted, cur_muted_until, cur_archived) =
        resolve_user_conv_meta(&conv, &auth.user_id);
    let entry = conv
        .user_meta
        .entry(auth.user_id.clone())
        .or_insert(UserConvMeta {
            folder: cur_folder,
            is_pinned: cur_pinned,
            is_muted: cur_muted,
            muted_until: cur_muted_until,
            is_archived: cur_archived,
        });

    if let Some(folder) = payload.folder {
        let f = folder.trim().to_string();
        if !f.is_empty() {
            entry.folder = f;
        }
    }
    if let Some(pinned) = payload.is_pinned {
        entry.is_pinned = pinned;
    }

    if let Some(ref mode) = payload.mute_duration {
        let trimmed = mode.trim();
        if !trimmed.is_empty() {
            match compute_timed_window(trimmed, Utc::now()) {
                Some((false, _)) => {
                    entry.is_muted = false;
                    entry.muted_until = None;
                }
                Some((true, Some(until))) => {
                    entry.is_muted = true;
                    entry.muted_until = Some(until);
                }
                Some((true, None)) => {
                    entry.is_muted = true;
                    entry.muted_until = None;
                }
                None => {
                    return Err(ApiError::bad_request(
                        "รูปแบบ mute_duration ไม่ถูกต้อง (รองรับ off, 1h, 8h, until_8am, forever)",
                    ));
                }
            }
        }
    } else if let Some(raw_until) = payload.muted_until {
        let trimmed = raw_until.trim();
        if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("off") {
            entry.is_muted = false;
            entry.muted_until = None;
        } else if DateTime::parse_from_rfc3339(trimmed).is_ok() {
            entry.is_muted = true;
            entry.muted_until = Some(trimmed.to_string());
        } else {
            return Err(ApiError::bad_request("รูปแบบเวลา muted_until ไม่ถูกต้อง"));
        }
    } else if let Some(muted) = payload.is_muted {
        entry.is_muted = muted;
        if !muted {
            entry.muted_until = None;
        }
    }

    if let Some(archived) = payload.is_archived {
        entry.is_archived = archived;
    }

    if let Some(name) = payload.name {
        if !name.trim().is_empty() {
            conv.name = name.trim().to_string();
        }
    }
    if let Some(avatar) = payload.avatar_url {
        if !avatar.trim().is_empty() {
            conv.avatar_url = avatar.trim().to_string();
        }
    }

    conv_coll
        .replace_one(doc! { "_id": &conv_id }, &conv)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;

    state.ws_hub.broadcast_event(json!({
        "event": "conversation_updated",
        "conversation_id": conv_id,
    }));

    Ok(Json(dto))
}

async fn insert_and_broadcast_system_msg(
    state: &AppState,
    conv: &mut ConversationDoc,
    actor: &UserDoc,
    sys_text: String,
) -> Result<(), String> {
    let now = Utc::now().to_rfc3339();
    let msg_id = Uuid::new_v4().to_string();
    let sys_msg = MessageDoc {
        id: msg_id.clone(),
        conversation_id: conv.id.clone(),
        sender_id: actor.id.clone(),
        sender_name: actor.display_name.clone(),
        sender_avatar: actor.avatar_url.clone(),
        msg_type: "system".to_string(),
        content: sys_text.clone(),
        sticker_code: None,
        attachment: None,
        card_payload: None,
        flex_payload: None,
        reply_to: None,
        read_by: vec![actor.id.clone()],
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
        deleted_for: Vec::new(),
        created_at: now.clone(),
    };

    state
        .db
        .collection::<MessageDoc>("messages")
        .insert_one(&sys_msg)
        .await
        .map_err(|e| e.to_string())?;

    conv.last_message = Some(LastMessageSummary {
        id: msg_id,
        sender_id: actor.id.clone(),
        sender_name: actor.display_name.clone(),
        msg_type: "system".to_string(),
        content: sys_text,
        created_at: now.clone(),
        read_count: 0,
    });
    conv.updated_at = now;

    state
        .db
        .collection::<ConversationDoc>("conversations")
        .replace_one(doc! { "_id": &conv.id }, &*conv)
        .await
        .map_err(|e| e.to_string())?;

    let msg_dto = MessageDto::from(sys_msg);
    state.ws_hub.broadcast_event(json!({
        "event": "conversation_updated",
        "conversation_id": conv.id,
    }));
    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": conv.id,
        "message": msg_dto,
    }));

    Ok(())
}

#[derive(Debug, Deserialize)]
pub struct AddGroupMembersRequest {
    #[serde(default)]
    pub member_ids: Vec<String>,
    pub user_id: Option<String>,
}

pub async fn add_group_members_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<AddGroupMembersRequest>,
) -> Result<Json<ConversationDto>, ApiError> {
    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;
    let users_coll = state.db.collection::<UserDoc>("users");

    let actor = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let mut requested = payload.member_ids;
    if let Some(uid) = payload.user_id {
        if !uid.trim().is_empty() {
            requested.push(uid.trim().to_string());
        }
    }
    requested.retain(|id| !id.trim().is_empty());
    if requested.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุสมาชิกที่ต้องการเชิญเข้ากลุ่ม"));
    }

    let found_users: Vec<UserDoc> = users_coll
        .find(doc! { "_id": { "$in": &requested } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let mut added_names = Vec::new();
    for u in found_users {
        if !conv.member_ids.contains(&u.id) {
            conv.member_ids.push(u.id);
            added_names.push(u.display_name);
        }
    }

    if !added_names.is_empty() {
        let sys_text = format!(
            "{} เชิญ {} เข้าสู่กลุ่ม",
            actor.display_name,
            added_names.join(", ")
        );
        insert_and_broadcast_system_msg(&state, &mut conv, &actor, sys_text)
            .await
            .map_err(ApiError::internal)?;
    }

    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(dto))
}

pub async fn remove_group_member_handler(
    auth: AuthUser,
    Path((conv_id, member_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<ConversationDto>, ApiError> {
    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;
    let users_coll = state.db.collection::<UserDoc>("users");

    let target_id = if member_id == "me" {
        auth.user_id.clone()
    } else {
        member_id
    };

    if target_id != auth.user_id
        && !conv.admin_ids.contains(&auth.user_id)
        && auth.role != "admin"
    {
        return Err(ApiError::forbidden(
            "เฉพาะผู้ดูแลกลุ่มเท่านั้นที่สามารถลบสมาชิกอื่นได้",
        ));
    }

    let actor = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let target_name = users_coll
        .find_one(doc! { "_id": &target_id })
        .await
        .ok()
        .flatten()
        .map(|u| u.display_name)
        .unwrap_or_else(|| target_id.clone());

    conv.member_ids.retain(|id| id != &target_id);
    conv.admin_ids.retain(|id| id != &target_id);

    let sys_text = if target_id == auth.user_id {
        format!("{} ออกจากกลุ่มแล้ว", actor.display_name)
    } else {
        format!("{} นำ {} ออกจากกลุ่ม", actor.display_name, target_name)
    };

    insert_and_broadcast_system_msg(&state, &mut conv, &actor, sys_text)
        .await
        .map_err(ApiError::internal)?;

    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct JoinByTokenRequest {
    pub invite_token: String,
}

pub async fn join_conversation_by_token_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<JoinByTokenRequest>,
) -> Result<Json<ConversationDto>, ApiError> {
    let token = payload.invite_token.trim();
    if token.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุรหัสเชิญเข้ากลุ่ม"));
    }

    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let users_coll = state.db.collection::<UserDoc>("users");

    let me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let rx = Regex {
        pattern: format!("^{}$", regex_escape(token)),
        options: "i".to_string(),
    };

    let mut conv = conv_coll
        .find_one(doc! { "invite_token": rx })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("รหัสเชิญเข้ากลุ่มไม่ถูกต้องหรือหมดอายุ"))?;

    if !conv.member_ids.contains(&auth.user_id) {
        conv.member_ids.push(auth.user_id.clone());
        let sys_text = format!("{} เข้าร่วมกลุ่มผ่านรหัสเชิญ", me.display_name);
        insert_and_broadcast_system_msg(&state, &mut conv, &me, sys_text)
            .await
            .map_err(ApiError::internal)?;
    }

    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(dto))
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
pub struct PinMessageRequest {
    pub message_id: Option<String>,
}

pub async fn pin_message_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<PinMessageRequest>,
) -> Result<Json<ConversationDto>, ApiError> {
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;

    let pinned_summary = match payload.message_id {
        Some(ref mid) if !mid.trim().is_empty() => {
            let msg = msg_coll
                .find_one(doc! { "_id": mid.trim(), "conversation_id": &conv_id })
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?
                .ok_or_else(|| ApiError::not_found("ไม่พบข้อความที่ต้องการปักหมุด"))?;

            Some(PinnedMessageSummary {
                id: msg.id,
                sender_id: msg.sender_id,
                sender_name: msg.sender_name,
                msg_type: if msg.msg_type == "flex_card" {
                    "rich_card".to_string()
                } else {
                    msg.msg_type
                },
                content: msg.content,
                created_at: msg.created_at,
            })
        }
        _ => None,
    };

    conv.pinned_message = pinned_summary.clone();
    conv_coll
        .replace_one(doc! { "_id": &conv_id }, &conv)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;

    state.ws_hub.broadcast_event(json!({
        "event": "conversation_updated",
        "conversation_id": conv_id,
        "pinned_message": pinned_summary,
    }));

    Ok(Json(dto))
}

pub async fn list_messages_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    require_member(&state, &conv_id, &auth.user_id).await?;
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let files_coll = state.db.collection::<FileDoc>("files");

    let cursor = msg_coll
        .find(doc! { "conversation_id": &conv_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let docs: Vec<MessageDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let now_str = Utc::now().to_rfc3339();
    let mut active_docs = Vec::new();

    for m in docs {
        let is_expired = m
            .expire_at
            .as_ref()
            .map(|exp| !exp.is_empty() && exp.as_str() <= now_str.as_str())
            .unwrap_or(false);

        if is_expired {
            if let Some(ref att) = m.attachment {
                let _ = state.minio.delete_object(&att.key).await;
                let _ = files_coll.delete_many(doc! { "key": &att.key }).await;
            }
            let _ = msg_coll.delete_one(doc! { "_id": &m.id }).await;
        } else if !m.deleted_for.contains(&auth.user_id) {
            active_docs.push(m);
        }
    }

    active_docs.sort_by(|a, b| a.created_at.cmp(&b.created_at));
    Ok(Json(active_docs.into_iter().map(MessageDto::from).collect()))
}

#[derive(Debug, Deserialize)]
pub struct SendMessageRequest {
    #[serde(rename = "type")]
    pub msg_type: Option<String>,
    pub content: Option<String>,
    pub sticker_code: Option<String>,
    pub attachment: Option<AttachmentInfo>,
    pub card_payload: Option<Value>,
    pub flex_payload: Option<Value>,
    pub reply_to_id: Option<String>,
    pub reply_to: Option<ReplyInfo>,
    #[serde(default)]
    pub is_confidential: bool,
    pub confidential_pin: Option<String>,
    pub expire_at: Option<String>,
    pub priority: Option<String>,
    pub task_status: Option<String>,
    #[serde(default)]
    pub mentions: Option<Vec<String>>,
    pub audio_duration_sec: Option<u32>,
    pub poll: Option<PollData>,
    pub event_data: Option<EventData>,
    pub location_data: Option<LocationData>,
    pub contact_data: Option<ContactCardData>,
    pub ladder_data: Option<LadderGameData>,
    pub forwarded_from: Option<String>,
}

pub async fn send_message_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SendMessageRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    let sender = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ส่ง"))?;

    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;

    // Check friendship blocks (1-1 sender block -> 400; 1-1 recipient block -> LINE silent drop; group -> WS/push exclusion)
    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");
    let other_member_ids: Vec<String> = conv
        .member_ids
        .iter()
        .filter(|id| *id != &sender.id)
        .cloned()
        .collect();

    if conv.conv_type == "direct" && conv.oa_id.is_none() {
        if let Some(peer_id) = other_member_ids.first() {
            let blocked_by_sender = friends_coll
                .count_documents(doc! {
                    "user_id": &sender.id,
                    "friend_id": peer_id,
                    "is_blocked": true,
                })
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?
                > 0;
            if blocked_by_sender {
                return Err(ApiError::bad_request(
                    "คุณได้บล็อกผู้ใช้นี้ กรุณาปลดบล็อกก่อนส่งข้อความ",
                ));
            }
        }
    }

    let excluded_user_ids: Vec<String> = if other_member_ids.is_empty() {
        Vec::new()
    } else {
        friends_coll
            .find(doc! {
                "friend_id": &sender.id,
                "user_id": { "$in": &other_member_ids },
                "is_blocked": true,
            })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .try_collect::<Vec<FriendshipDoc>>()
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .into_iter()
            .map(|f| f.user_id)
            .collect()
    };

    let is_direct_silently_blocked = conv.conv_type == "direct"
        && conv.oa_id.is_none()
        && other_member_ids
            .first()
            .is_some_and(|pid| excluded_user_ids.contains(pid));

    let mut location_data = payload.location_data;
    if let Some(ref mut loc) = location_data {
        if !loc.latitude.is_finite()
            || !loc.longitude.is_finite()
            || !(-90.0..=90.0).contains(&loc.latitude)
            || !(-180.0..=180.0).contains(&loc.longitude)
        {
            return Err(ApiError::bad_request("พิกัดละติจูด/ลองจิจูดไม่ถูกต้อง"));
        }
        if loc.map_url.trim().is_empty() {
            loc.map_url = format!(
                "https://www.google.com/maps/search/?api=1&query={},{}",
                loc.latitude, loc.longitude
            );
        }
        if loc.title.trim().is_empty() {
            loc.title = format!("{:.5}, {:.5}", loc.latitude, loc.longitude);
        } else {
            loc.title = loc.title.trim().to_string();
        }
        loc.address = loc.address.trim().to_string();
    }

    let raw_type = payload
        .msg_type
        .map(|t| t.trim().to_lowercase())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| {
            if location_data.is_some() {
                "location".to_string()
            } else if payload.contact_data.is_some() {
                "contact".to_string()
            } else if payload.ladder_data.is_some() {
                "ladder".to_string()
            } else {
                "text".to_string()
            }
        });
    let msg_type = if raw_type == "flex_card" {
        "rich_card".to_string()
    } else {
        raw_type
    };

    if msg_type == "location" && location_data.is_none() {
        return Err(ApiError::bad_request("พิกัดละติจูด/ลองจิจูดไม่ถูกต้อง"));
    }

    let effective_card = payload.card_payload.or(payload.flex_payload);

    let mut content = payload.content.unwrap_or_default().trim().to_string();
    if content.is_empty() {
        content = match msg_type.as_str() {
            "sticker" => "[ส่งสติกเกอร์]".to_string(),
            "image" => "[ส่งรูปภาพ]".to_string(),
            "audio" => "[ข้อความเสียง]".to_string(),
            "file" => payload
                .attachment
                .as_ref()
                .map(|a| format!("[ไฟล์] {}", a.file_name))
                .unwrap_or_else(|| "[ส่งไฟล์เอกสาร]".to_string()),
            "rich_card" => effective_card
                .as_ref()
                .and_then(|f| f.get("title").and_then(|t| t.as_str()))
                .map(|t| format!("[การ์ดโต้ตอบ] {}", t))
                .unwrap_or_else(|| "[การ์ดโต้ตอบ]".to_string()),
            "poll" => payload
                .poll
                .as_ref()
                .map(|p| format!("📊 โพล: {}", p.question))
                .unwrap_or_else(|| "[โพลโหวต]".to_string()),
            "event" => payload
                .event_data
                .as_ref()
                .map(|e| format!("📅 นัดหมาย: {}", e.title))
                .unwrap_or_else(|| "[นัดหมาย]".to_string()),
            "location" => location_data
                .as_ref()
                .map(|l| format!("📍 ตำแหน่งที่ตั้ง: {}", l.title))
                .unwrap_or_else(|| "📍 ตำแหน่งที่ตั้ง".to_string()),
            "contact" => payload
                .contact_data
                .as_ref()
                .map(|c| format!("👤 แนะนำเพื่อน: {}", c.display_name.trim()))
                .unwrap_or_else(|| "👤 แนะนำเพื่อน".to_string()),
            "ladder" => payload
                .ladder_data
                .as_ref()
                .map(|g| format!("🎲 เกมสุ่มบันได: {}", g.title.trim()))
                .unwrap_or_else(|| "🎲 เกมสุ่มบันได".to_string()),
            _ => "".to_string(),
        };
    }

    let mut reply_info = payload.reply_to;
    if reply_info.is_none() {
        if let Some(ref rid) = payload.reply_to_id {
            if !rid.trim().is_empty() {
                if let Ok(Some(orig)) = msg_coll.find_one(doc! { "_id": rid.trim() }).await {
                    reply_info = Some(ReplyInfo {
                        id: orig.id,
                        sender_name: orig.sender_name,
                        content: orig.content,
                    });
                }
            }
        }
    }

    let mut mentions = payload.mentions.unwrap_or_default();
    let lower_content = content.to_lowercase();
    if lower_content.contains("@all") && !mentions.iter().any(|m| m == "all" || m == "@all") {
        mentions.push("@all".to_string());
    }
    if (lower_content.contains("@ai") || lower_content.contains("@bc.ai"))
        && !mentions.iter().any(|m| m == "user_ai" || m == "@bc.ai")
    {
        mentions.push("user_ai".to_string());
    }

    let now = Utc::now().to_rfc3339();
    let msg_id = Uuid::new_v4().to_string();

    let priority = payload
        .priority
        .map(|p| p.trim().to_lowercase())
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "normal".to_string());

    let task_status = if payload.task_status.is_some() {
        payload.task_status
    } else if priority == "urgent" {
        Some("open".to_string())
    } else {
        None
    };

    let msg_doc = MessageDoc {
        id: msg_id.clone(),
        conversation_id: conv_id.clone(),
        sender_id: sender.id.clone(),
        sender_name: sender.display_name.clone(),
        sender_avatar: sender.avatar_url.clone(),
        msg_type: msg_type.clone(),
        content: content.clone(),
        sticker_code: payload.sticker_code,
        attachment: payload.attachment,
        card_payload: effective_card.clone(),
        flex_payload: effective_card,
        reply_to: reply_info,
        read_by: vec![sender.id.clone()],
        is_unsent: false,
        is_confidential: payload.is_confidential,
        confidential_pin: payload.confidential_pin,
        expire_at: payload.expire_at,
        priority,
        task_status,
        accepted_by: None,
        accepted_at: None,
        reactions: HashMap::new(),
        mentions,
        audio_duration_sec: payload.audio_duration_sec,
        poll: payload.poll,
        event_data: payload.event_data,
        location_data,
        contact_data: payload.contact_data,
        ladder_data: payload.ladder_data,
        edited_at: None,
        forwarded_from: payload
            .forwarded_from
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        deleted_for: if is_direct_silently_blocked {
            excluded_user_ids.clone()
        } else {
            Vec::new()
        },
        created_at: now.clone(),
    };

    msg_coll
        .insert_one(&msg_doc)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let sender_id_clone = sender.id.clone();

    if !is_direct_silently_blocked {
        let preview_content = if payload.is_confidential {
            format!("🔒 [ข้อความลับส่วนตัวล็อก PIN] {}", content)
        } else {
            content
        };

        conv.last_message = Some(LastMessageSummary {
            id: msg_id,
            sender_id: sender.id,
            sender_name: sender.display_name,
            msg_type,
            content: preview_content,
            created_at: now.clone(),
            read_count: 0,
        });
        conv.updated_at = now;

        let _ = conv_coll
            .replace_one(doc! { "_id": &conv_id }, &conv)
            .await;
    }

    let dto = MessageDto::from(msg_doc.clone());

    if is_direct_silently_blocked {
        state.ws_hub.broadcast_event(json!({
            "event": "new_message",
            "conversation_id": conv_id,
            "target_user_ids": [&sender_id_clone],
            "excluded_user_ids": &excluded_user_ids,
            "message": dto,
        }));
        return Ok(Json(dto));
    }

    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": conv_id,
        "excluded_user_ids": &excluded_user_ids,
        "message": dto,
    }));
    crate::push::notify_new_message(&state, &conv, &dto);

    if conv.oa_id.is_some() {
        crate::routes::oa_routes::handle_customer_message_to_oa(&state, &mut conv, &msg_doc).await;
    } else {
        // Trigger BC AI Co-Pilot if message is in 1-1 chat with AI or mentions @ai
        let _ = crate::routes::ai_routes::maybe_trigger_ai_reply(&state, &mut conv, &msg_doc).await;
    }

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct ReactMessageRequest {
    pub emoji: String,
}

pub async fn react_message_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<ReactMessageRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let emoji = payload.emoji.trim().to_string();
    if emoji.is_empty() || emoji.chars().count() > 16 {
        return Err(ApiError::bad_request("กรุณาเลือกอีโมจิที่ถูกต้อง"));
    }

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let mut msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความ"))?;

    require_member(&state, &msg.conversation_id, &auth.user_id).await?;

    let users = msg.reactions.entry(emoji.clone()).or_default();
    if let Some(pos) = users.iter().position(|u| u == &auth.user_id) {
        users.remove(pos);
        if users.is_empty() {
            msg.reactions.remove(&emoji);
        }
    } else {
        users.push(auth.user_id.clone());
    }

    msg_coll
        .replace_one(doc! { "_id": &msg_id }, &msg)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = MessageDto::from(msg);
    state.ws_hub.broadcast_event(json!({
        "event": "message_updated",
        "conversation_id": dto.conversation_id,
        "message": dto,
    }));

    Ok(Json(dto))
}

pub async fn delete_message_for_me_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความ"))?;

    require_member(&state, &msg.conversation_id, &auth.user_id).await?;

    msg_coll
        .update_one(
            doc! { "_id": &msg_id },
            doc! { "$addToSet": { "deleted_for": &auth.user_id } },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(json!({
        "status": "ok",
        "message_id": msg_id,
    })))
}

#[derive(Debug, Deserialize)]
pub struct CreatePollRequest {
    pub question: String,
    pub options: Vec<String>,
    pub allow_multiple: Option<bool>,
    pub is_anonymous: Option<bool>,
}

pub async fn create_poll_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<CreatePollRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let question = payload.question.trim().to_string();
    let clean_opts: Vec<String> = payload
        .options
        .into_iter()
        .map(|o| o.trim().to_string())
        .filter(|o| !o.is_empty())
        .collect();

    if question.is_empty() || clean_opts.len() < 2 {
        return Err(ApiError::bad_request(
            "กรุณาระบุคำถามโพลและตัวเลือกอย่างน้อย 2 ตัวเลือก",
        ));
    }

    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;
    let sender = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let poll_options: Vec<PollOption> = clean_opts
        .into_iter()
        .enumerate()
        .map(|(i, text)| PollOption {
            id: format!("opt_{}", i + 1),
            text,
            voter_ids: Vec::new(),
        })
        .collect();

    let poll_data = PollData {
        question: question.clone(),
        options: poll_options,
        allow_multiple: payload.allow_multiple.unwrap_or(false),
        is_anonymous: payload.is_anonymous.unwrap_or(false),
        is_closed: false,
        closed_at: None,
    };

    let now = Utc::now().to_rfc3339();
    let msg_id = Uuid::new_v4().to_string();
    let content = format!("📊 โพล: {}", question);

    let msg_doc = MessageDoc {
        id: msg_id.clone(),
        conversation_id: conv_id.clone(),
        sender_id: sender.id.clone(),
        sender_name: sender.display_name.clone(),
        sender_avatar: sender.avatar_url.clone(),
        msg_type: "poll".to_string(),
        content: content.clone(),
        sticker_code: None,
        attachment: None,
        card_payload: None,
        flex_payload: None,
        reply_to: None,
        read_by: vec![sender.id.clone()],
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
        poll: Some(poll_data),
        event_data: None,
        location_data: None,
        contact_data: None,
        ladder_data: None,
        edited_at: None,
        forwarded_from: None,
        deleted_for: Vec::new(),
        created_at: now.clone(),
    };

    state
        .db
        .collection::<MessageDoc>("messages")
        .insert_one(&msg_doc)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    conv.last_message = Some(LastMessageSummary {
        id: msg_id,
        sender_id: sender.id,
        sender_name: sender.display_name,
        msg_type: "poll".to_string(),
        content,
        created_at: now.clone(),
        read_count: 0,
    });
    conv.updated_at = now;
    let _ = state
        .db
        .collection::<ConversationDoc>("conversations")
        .replace_one(doc! { "_id": &conv_id }, &conv)
        .await;

    let dto = MessageDto::from(msg_doc);
    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": conv_id,
        "message": dto,
    }));
    crate::push::notify_new_message(&state, &conv, &dto);

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct VotePollRequest {
    #[serde(default)]
    pub option_ids: Vec<String>,
    pub option_id: Option<String>,
}

pub async fn vote_poll_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<VotePollRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let mut msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบโพล"))?;

    require_member(&state, &msg.conversation_id, &auth.user_id).await?;

    let poll = msg
        .poll
        .as_mut()
        .ok_or_else(|| ApiError::bad_request("ข้อความนี้ไม่ใช่โพลโหวต"))?;
    if poll.is_closed {
        return Err(ApiError::bad_request("โพลนี้ปิดรับการโหวตแล้ว"));
    }

    let mut chosen = payload.option_ids;
    if let Some(single) = payload.option_id {
        if !single.trim().is_empty() {
            chosen.push(single.trim().to_string());
        }
    }
    if !poll.allow_multiple && chosen.len() > 1 {
        chosen.truncate(1);
    }

    for opt in &mut poll.options {
        opt.voter_ids.retain(|uid| uid != &auth.user_id);
        if chosen.iter().any(|cid| cid == &opt.id) {
            opt.voter_ids.push(auth.user_id.clone());
        }
    }

    msg_coll
        .replace_one(doc! { "_id": &msg_id }, &msg)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = MessageDto::from(msg);
    state.ws_hub.broadcast_event(json!({
        "event": "message_updated",
        "conversation_id": dto.conversation_id,
        "message": dto,
    }));

    Ok(Json(dto))
}

pub async fn close_poll_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<MessageDto>, ApiError> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let mut msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบโพล"))?;

    require_member(&state, &msg.conversation_id, &auth.user_id).await?;
    if msg.sender_id != auth.user_id && auth.role != "admin" {
        return Err(ApiError::forbidden("เฉพาะผู้สร้างโพลหรือผู้ดูแลระบบเท่านั้นที่ปิดโพลได้"));
    }

    let poll = msg
        .poll
        .as_mut()
        .ok_or_else(|| ApiError::bad_request("ข้อความนี้ไม่ใช่โพลโหวต"))?;
    poll.is_closed = true;
    poll.closed_at = Some(Utc::now().to_rfc3339());

    msg_coll
        .replace_one(doc! { "_id": &msg_id }, &msg)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = MessageDto::from(msg);
    state.ws_hub.broadcast_event(json!({
        "event": "message_updated",
        "conversation_id": dto.conversation_id,
        "message": dto,
    }));

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct CreateEventRequest {
    pub title: String,
    pub description: Option<String>,
    pub starts_at: String,
    pub ends_at: Option<String>,
    pub location: Option<String>,
}

pub async fn create_event_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<CreateEventRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let title = payload.title.trim().to_string();
    let starts_at = payload.starts_at.trim().to_string();
    if title.is_empty() || starts_at.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุชื่อนัดหมายและวันเวลาเริ่ม"));
    }

    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;
    let sender = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let ev_data = EventData {
        title: title.clone(),
        description: payload.description.unwrap_or_default().trim().to_string(),
        starts_at,
        ends_at: payload.ends_at.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
        location: payload.location.unwrap_or_default().trim().to_string(),
        going_ids: vec![sender.id.clone()],
        maybe_ids: Vec::new(),
        not_going_ids: Vec::new(),
    };

    let now = Utc::now().to_rfc3339();
    let msg_id = Uuid::new_v4().to_string();
    let content = format!("📅 นัดหมาย: {}", title);

    let msg_doc = MessageDoc {
        id: msg_id.clone(),
        conversation_id: conv_id.clone(),
        sender_id: sender.id.clone(),
        sender_name: sender.display_name.clone(),
        sender_avatar: sender.avatar_url.clone(),
        msg_type: "event".to_string(),
        content: content.clone(),
        sticker_code: None,
        attachment: None,
        card_payload: None,
        flex_payload: None,
        reply_to: None,
        read_by: vec![sender.id.clone()],
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
        event_data: Some(ev_data),
        location_data: None,
        contact_data: None,
        ladder_data: None,
        edited_at: None,
        forwarded_from: None,
        deleted_for: Vec::new(),
        created_at: now.clone(),
    };

    state
        .db
        .collection::<MessageDoc>("messages")
        .insert_one(&msg_doc)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    conv.last_message = Some(LastMessageSummary {
        id: msg_id,
        sender_id: sender.id,
        sender_name: sender.display_name,
        msg_type: "event".to_string(),
        content,
        created_at: now.clone(),
        read_count: 0,
    });
    conv.updated_at = now;
    let _ = state
        .db
        .collection::<ConversationDoc>("conversations")
        .replace_one(doc! { "_id": &conv_id }, &conv)
        .await;

    let dto = MessageDto::from(msg_doc);
    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": conv_id,
        "message": dto,
    }));
    crate::push::notify_new_message(&state, &conv, &dto);

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct RsvpEventRequest {
    pub status: String, // "going" | "maybe" | "not_going"
}

pub async fn rsvp_event_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<RsvpEventRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let status = payload.status.trim().to_lowercase();
    if !matches!(status.as_str(), "going" | "maybe" | "not_going") {
        return Err(ApiError::bad_request(
            "สถานะตอบรับต้องเป็น going, maybe หรือ not_going",
        ));
    }

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let mut msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบนัดหมาย"))?;

    require_member(&state, &msg.conversation_id, &auth.user_id).await?;

    let ev = msg
        .event_data
        .as_mut()
        .ok_or_else(|| ApiError::bad_request("ข้อความนี้ไม่ใช่นัดหมาย"))?;

    ev.going_ids.retain(|u| u != &auth.user_id);
    ev.maybe_ids.retain(|u| u != &auth.user_id);
    ev.not_going_ids.retain(|u| u != &auth.user_id);

    match status.as_str() {
        "going" => ev.going_ids.push(auth.user_id.clone()),
        "maybe" => ev.maybe_ids.push(auth.user_id.clone()),
        _ => ev.not_going_ids.push(auth.user_id.clone()),
    }

    msg_coll
        .replace_one(doc! { "_id": &msg_id }, &msg)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = MessageDto::from(msg);
    state.ws_hub.broadcast_event(json!({
        "event": "message_updated",
        "conversation_id": dto.conversation_id,
        "message": dto,
    }));

    Ok(Json(dto))
}

pub async fn list_events_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    require_member(&state, &conv_id, &auth.user_id).await?;
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let cursor = msg_coll
        .find(doc! {
            "conversation_id": &conv_id,
            "type": "event",
            "is_unsent": false,
            "deleted_for": { "$ne": &auth.user_id }
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut docs: Vec<MessageDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    docs.sort_by(|a, b| {
        let sa = a.event_data.as_ref().map(|e| e.starts_at.as_str()).unwrap_or("");
        let sb = b.event_data.as_ref().map(|e| e.starts_at.as_str()).unwrap_or("");
        sa.cmp(sb).then_with(|| a.created_at.cmp(&b.created_at))
    });

    Ok(Json(docs.into_iter().map(MessageDto::from).collect()))
}

pub async fn list_albums_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<AlbumDto>>, ApiError> {
    require_member(&state, &conv_id, &auth.user_id).await?;
    let coll = state.db.collection::<AlbumDoc>("albums");
    let cursor = coll
        .find(doc! { "conversation_id": &conv_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut docs: Vec<AlbumDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    docs.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    Ok(Json(docs.into_iter().map(AlbumDto::from).collect()))
}

#[derive(Debug, Deserialize)]
pub struct CreateAlbumRequest {
    pub title: String,
    pub description: Option<String>,
    #[serde(default)]
    pub photos: Vec<AttachmentInfo>,
}

pub async fn create_album_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<CreateAlbumRequest>,
) -> Result<Json<AlbumDto>, ApiError> {
    require_member(&state, &conv_id, &auth.user_id).await?;
    let title = payload.title.trim().to_string();
    if title.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุชื่ออัลบั้มรูปภาพ"));
    }

    let user = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let now = Utc::now().to_rfc3339();
    let album = AlbumDoc {
        id: Uuid::new_v4().to_string(),
        conversation_id: conv_id.clone(),
        title,
        description: payload.description.unwrap_or_default().trim().to_string(),
        photos: payload.photos,
        created_by: user.id,
        created_by_name: user.display_name,
        created_at: now.clone(),
        updated_at: now,
    };

    state
        .db
        .collection::<AlbumDoc>("albums")
        .insert_one(&album)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = AlbumDto::from(album);
    state.ws_hub.broadcast_event(json!({
        "event": "album_updated",
        "conversation_id": conv_id,
        "album": dto,
    }));

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct AddAlbumPhotosRequest {
    pub photos: Vec<AttachmentInfo>,
}

pub async fn add_album_photos_handler(
    auth: AuthUser,
    Path(album_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<AddAlbumPhotosRequest>,
) -> Result<Json<AlbumDto>, ApiError> {
    let coll = state.db.collection::<AlbumDoc>("albums");
    let mut album = coll
        .find_one(doc! { "_id": &album_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบอัลบั้มที่ระบุ"))?;

    require_member(&state, &album.conversation_id, &auth.user_id).await?;

    album.photos.extend(payload.photos);
    album.updated_at = Utc::now().to_rfc3339();

    coll.replace_one(doc! { "_id": &album_id }, &album)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = AlbumDto::from(album);
    state.ws_hub.broadcast_event(json!({
        "event": "album_updated",
        "conversation_id": dto.conversation_id,
        "album": dto,
    }));

    Ok(Json(dto))
}

pub async fn delete_album_handler(
    auth: AuthUser,
    Path(album_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let coll = state.db.collection::<AlbumDoc>("albums");
    let album = coll
        .find_one(doc! { "_id": &album_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบอัลบั้มที่ระบุ"))?;

    require_member(&state, &album.conversation_id, &auth.user_id).await?;

    coll.delete_one(doc! { "_id": &album_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    state.ws_hub.broadcast_event(json!({
        "event": "album_updated",
        "conversation_id": album.conversation_id,
        "deleted_id": album_id,
    }));

    Ok(Json(json!({
        "status": "ok",
        "id": album_id,
    })))
}

pub async fn mark_read_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    require_member(&state, &conv_id, &auth.user_id).await?;
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let res = msg_coll
        .update_many(
            doc! {
                "conversation_id": &conv_id,
                "read_by": { "$ne": &auth.user_id }
            },
            doc! {
                "$addToSet": { "read_by": &auth.user_id }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    if res.modified_count > 0 {
        state.ws_hub.broadcast_event(json!({
            "event": "message_read",
            "conversation_id": conv_id,
            "user_id": auth.user_id,
            "modified_count": res.modified_count,
        }));
    }

    Ok(Json(json!({
        "status": "ok",
        "conversation_id": conv_id,
        "modified_count": res.modified_count,
    })))
}

#[derive(Debug, Deserialize)]
pub struct UnsendQuery {
    pub hard: Option<bool>,
}

pub async fn unsend_message_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    Query(query): Query<UnsendQuery>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let hard = query.hard.unwrap_or(false);
    execute_unsend_or_purge(&auth, &msg_id, hard, &state).await
}

pub async fn purge_message_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    execute_unsend_or_purge(&auth, &msg_id, true, &state).await
}

async fn execute_unsend_or_purge(
    auth: &AuthUser,
    msg_id: &str,
    hard_delete: bool,
    state: &AppState,
) -> Result<Json<Value>, ApiError> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let files_coll = state.db.collection::<FileDoc>("files");

    let mut msg = msg_coll
        .find_one(doc! { "_id": msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความที่ต้องการยกเลิก/ลบ"))?;

    if msg.sender_id != auth.user_id {
        let is_admin = state
            .db
            .collection::<bson::Document>("users")
            .count_documents(doc! { "_id": &auth.user_id, "role": "admin" })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            > 0;
        if !is_admin {
            return Err(ApiError::forbidden("ลบได้เฉพาะข้อความของตัวเอง หรือผู้ดูแลระบบ"));
        }
    }

    let conv_id = msg.conversation_id.clone();

    let mut file_purged = false;
    if let Some(ref att) = msg.attachment {
        let _ = state.minio.delete_object(&att.key).await;
        let _ = files_coll.delete_many(doc! { "key": &att.key }).await;
        file_purged = true;
    }

    if hard_delete {
        msg_coll
            .delete_one(doc! { "_id": msg_id })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;

        if let Ok(Some(mut conv)) = conv_coll.find_one(doc! { "_id": &conv_id }).await {
            if conv
                .pinned_message
                .as_ref()
                .map(|p| p.id == msg_id)
                .unwrap_or(false)
            {
                conv.pinned_message = None;
            }
            if conv
                .last_message
                .as_ref()
                .map(|l| l.id == msg_id)
                .unwrap_or(false)
            {
                let cursor = msg_coll
                    .find(doc! { "conversation_id": &conv_id })
                    .await
                    .map_err(|e| ApiError::internal(e.to_string()))?;
                let mut remaining: Vec<MessageDoc> = cursor
                    .try_collect()
                    .await
                    .map_err(|e| ApiError::internal(e.to_string()))?;
                remaining.sort_by(|a, b| a.created_at.cmp(&b.created_at));
                conv.last_message = remaining.pop().map(|last| {
                    let rc = last
                        .read_by
                        .iter()
                        .filter(|uid| *uid != &last.sender_id)
                        .count();
                    LastMessageSummary {
                        id: last.id,
                        sender_id: last.sender_id,
                        sender_name: last.sender_name,
                        msg_type: last.msg_type,
                        content: last.content,
                        created_at: last.created_at,
                        read_count: rc,
                    }
                });
            }
            let _ = conv_coll.replace_one(doc! { "_id": &conv_id }, &conv).await;
        }
    } else {
        let unsent_text = if file_purged {
            "ยกเลิกข้อความแล้ว (ลบไฟล์ออกจากระบบถาวรแล้ว)".to_string()
        } else {
            "ยกเลิกข้อความแล้ว".to_string()
        };

        msg.is_unsent = true;
        msg.content = unsent_text.clone();
        msg.sticker_code = None;
        msg.attachment = None;
        msg.card_payload = None;
        msg.flex_payload = None;
        msg.confidential_pin = None;
        msg.poll = None;
        msg.event_data = None;

        msg_coll
            .replace_one(doc! { "_id": msg_id }, &msg)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;

        let _ = conv_coll
            .update_one(
                doc! { "_id": &conv_id, "last_message.id": msg_id },
                doc! { "$set": { "last_message.content": &unsent_text } },
            )
            .await;
    }

    state.ws_hub.broadcast_event(json!({
        "event": "message_unsent",
        "message_id": msg_id,
        "conversation_id": conv_id,
        "hard_deleted": hard_delete,
        "file_purged": file_purged,
    }));

    Ok(Json(json!({
        "status": "ok",
        "message_id": msg_id,
        "conversation_id": conv_id,
        "hard_deleted": hard_delete,
        "file_purged": file_purged,
    })))
}

pub async fn clear_confidential_messages_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    require_member(&state, &conv_id, &auth.user_id).await?;
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let files_coll = state.db.collection::<FileDoc>("files");

    let cursor = msg_coll
        .find(doc! { "conversation_id": &conv_id, "is_confidential": true })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let conf_msgs: Vec<MessageDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let mut purged_files = 0usize;
    for m in &conf_msgs {
        if let Some(ref att) = m.attachment {
            let _ = state.minio.delete_object(&att.key).await;
            let _ = files_coll.delete_many(doc! { "key": &att.key }).await;
            purged_files += 1;
        }
    }

    let del_res = msg_coll
        .delete_many(doc! { "conversation_id": &conv_id, "is_confidential": true })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    state.ws_hub.broadcast_event(json!({
        "event": "confidential_cleared",
        "conversation_id": conv_id,
        "purged_messages": del_res.deleted_count,
        "purged_files": purged_files,
    }));

    Ok(Json(json!({
        "status": "ok",
        "conversation_id": conv_id,
        "purged_messages": del_res.deleted_count,
        "purged_files": purged_files,
    })))
}

pub async fn conversation_vault_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<VaultResponse>, ApiError> {
    require_member(&state, &conv_id, &auth.user_id).await?;
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let cursor = msg_coll
        .find(doc! {
            "conversation_id": &conv_id,
            "is_unsent": false,
            "deleted_for": { "$ne": &auth.user_id }
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut messages: Vec<MessageDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    messages.sort_by(|a, b| b.created_at.cmp(&a.created_at));

    let mut images = Vec::new();
    let mut files = Vec::new();
    let mut links = Vec::new();

    for m in messages {
        if let Some(ref att) = m.attachment {
            let item = VaultFileItem {
                id: format!("vault_{}", m.id),
                message_id: m.id.clone(),
                sender_id: m.sender_id.clone(),
                sender_name: m.sender_name.clone(),
                key: att.key.clone(),
                url: att.url.clone(),
                file_name: att.file_name.clone(),
                mime_type: att.mime_type.clone(),
                file_size: att.file_size,
                is_confidential: m.is_confidential,
                created_at: m.created_at.clone(),
            };
            if m.msg_type == "image" || att.mime_type.starts_with("image/") {
                images.push(item);
            } else {
                files.push(item);
            }
        }

        for word in m.content.split_whitespace() {
            if word.starts_with("http://") || word.starts_with("https://") {
                let clean_url = word.trim_end_matches(|c: char| ".,);]\"".contains(c));
                links.push(VaultLinkItem {
                    id: format!("link_{}", m.id),
                    message_id: m.id.clone(),
                    sender_id: m.sender_id.clone(),
                    sender_name: m.sender_name.clone(),
                    url: clean_url.to_string(),
                    content: m.content.clone(),
                    created_at: m.created_at.clone(),
                });
            }
        }
    }

    Ok(Json(VaultResponse {
        images,
        files,
        links,
    }))
}

#[derive(Debug, Deserialize)]
pub struct SearchMessagesQuery {
    pub q: Option<String>,
    pub conversation_id: Option<String>,
}

pub async fn search_messages_handler(
    auth: AuthUser,
    Query(query): Query<SearchMessagesQuery>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    let q = query.q.unwrap_or_default().trim().to_string();
    if q.is_empty() {
        return Ok(Json(vec![]));
    }

    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    let allowed_conv_ids: Vec<String> = if let Some(ref cid) = query.conversation_id {
        if !cid.trim().is_empty() {
            require_member(&state, cid.trim(), &auth.user_id).await?;
            vec![cid.trim().to_string()]
        } else {
            vec![]
        }
    } else {
        let c_cursor = conv_coll
            .find(doc! { "member_ids": &auth.user_id })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;
        let c_docs: Vec<ConversationDoc> = c_cursor
            .try_collect()
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?;
        c_docs.into_iter().map(|c| c.id).collect()
    };

    if allowed_conv_ids.is_empty() {
        return Ok(Json(vec![]));
    }

    let rx = Regex {
        pattern: regex_escape(&q),
        options: "i".to_string(),
    };

    let filter = doc! {
        "conversation_id": { "$in": allowed_conv_ids },
        "is_unsent": false,
        "deleted_for": { "$ne": &auth.user_id },
        "$or": [
            { "content": rx.clone() },
            { "attachment.file_name": rx }
        ]
    };

    let cursor = msg_coll
        .find(filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut docs: Vec<MessageDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    docs.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(Json(docs.into_iter().map(MessageDto::from).collect()))
}

#[derive(Debug, Deserialize)]
pub struct ListNotesQuery {
    pub conversation_id: Option<String>,
}

pub async fn list_notes_handler(
    auth: AuthUser,
    Query(query): Query<ListNotesQuery>,
    State(state): State<AppState>,
) -> Result<Json<Vec<NoteDto>>, ApiError> {
    let notes_coll = state.db.collection::<NoteDoc>("notes");

    let filter = match query.conversation_id {
        Some(ref cid) if !cid.trim().is_empty() => {
            require_member(&state, cid.trim(), &auth.user_id).await?;
            doc! { "conversation_id": cid.trim() }
        }
        _ => {
            doc! {
                "owner_id": &auth.user_id,
                "$or": [
                    { "conversation_id": null },
                    { "conversation_id": "" }
                ]
            }
        }
    };

    let cursor = notes_coll
        .find(filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut docs: Vec<NoteDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    docs.sort_by(|a, b| {
        b.is_pinned
            .cmp(&a.is_pinned)
            .then_with(|| b.updated_at.cmp(&a.updated_at))
    });

    Ok(Json(docs.into_iter().map(NoteDto::from).collect()))
}

#[derive(Debug, Deserialize)]
pub struct CreateNoteRequest {
    pub conversation_id: Option<String>,
    pub title: String,
    pub content: String,
    #[serde(default)]
    pub attachments: Vec<AttachmentInfo>,
    pub attachment: Option<AttachmentInfo>,
    #[serde(default)]
    pub is_pinned: bool,
}

pub async fn create_note_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<CreateNoteRequest>,
) -> Result<Json<NoteDto>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let notes_coll = state.db.collection::<NoteDoc>("notes");

    let user = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบผู้ใช้"))?;

    if let Some(cid) = payload.conversation_id.as_deref().map(str::trim) {
        if !cid.is_empty() {
            require_member(&state, cid, &auth.user_id).await?;
        }
    }
    let conv_id = payload.conversation_id.and_then(|s| {
        if s.trim().is_empty() {
            None
        } else {
            Some(s.trim().to_string())
        }
    });

    let mut attachments = payload.attachments;
    if attachments.is_empty() {
        if let Some(att) = payload.attachment {
            attachments.push(att);
        }
    }

    let now = Utc::now().to_rfc3339();
    let note = NoteDoc {
        id: Uuid::new_v4().to_string(),
        conversation_id: conv_id.clone(),
        owner_id: user.id,
        owner_name: user.display_name,
        title: if payload.title.trim().is_empty() {
            "บันทึกข้อความ".to_string()
        } else {
            payload.title.trim().to_string()
        },
        content: payload.content,
        attachments,
        is_pinned: payload.is_pinned,
        liked_by: Vec::new(),
        comments: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
    };

    notes_coll
        .insert_one(&note)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = NoteDto::from(note);
    if let Some(ref cid) = conv_id {
        state.ws_hub.broadcast_event(json!({
            "event": "note_updated",
            "conversation_id": cid,
            "note": dto,
        }));
    }

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct UpdateNoteRequest {
    pub title: Option<String>,
    pub content: Option<String>,
    pub attachments: Option<Vec<AttachmentInfo>>,
    pub is_pinned: Option<bool>,
}

pub async fn update_note_handler(
    auth: AuthUser,
    Path(note_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateNoteRequest>,
) -> Result<Json<NoteDto>, ApiError> {
    let notes_coll = state.db.collection::<NoteDoc>("notes");
    let mut note = notes_coll
        .find_one(doc! { "_id": &note_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบบันทึกที่ระบุ"))?;

    if let Some(ref cid) = note.conversation_id {
        require_member(&state, cid, &auth.user_id).await?;
    } else if note.owner_id != auth.user_id {
        return Err(ApiError::forbidden("ไม่สามารถแก้ไขบันทึกส่วนตัวของผู้อื่นได้"));
    }

    if let Some(title) = payload.title {
        if !title.trim().is_empty() {
            note.title = title.trim().to_string();
        }
    }
    if let Some(content) = payload.content {
        note.content = content;
    }
    if let Some(atts) = payload.attachments {
        note.attachments = atts;
    }
    if let Some(pinned) = payload.is_pinned {
        note.is_pinned = pinned;
    }
    note.updated_at = Utc::now().to_rfc3339();

    notes_coll
        .replace_one(doc! { "_id": &note_id }, &note)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = NoteDto::from(note);
    if let Some(ref cid) = dto.conversation_id {
        state.ws_hub.broadcast_event(json!({
            "event": "note_updated",
            "conversation_id": cid,
            "note": dto,
        }));
    }

    Ok(Json(dto))
}

pub async fn delete_note_handler(
    auth: AuthUser,
    Path(note_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let notes_coll = state.db.collection::<NoteDoc>("notes");
    if let Some(note) = notes_coll
        .find_one(doc! { "_id": &note_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        if let Some(ref cid) = note.conversation_id {
            require_member(&state, cid, &auth.user_id).await?;
        } else if note.owner_id != auth.user_id {
            return Err(ApiError::forbidden("ไม่สามารถลบบันทึกส่วนตัวของผู้อื่นได้"));
        }
    }

    notes_coll
        .delete_one(doc! { "_id": &note_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(json!({
        "status": "ok",
        "id": note_id,
    })))
}

pub async fn like_note_handler(
    auth: AuthUser,
    Path(note_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<NoteDto>, ApiError> {
    let notes_coll = state.db.collection::<NoteDoc>("notes");
    let mut note = notes_coll
        .find_one(doc! { "_id": &note_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบบันทึกที่ระบุ"))?;

    if let Some(ref cid) = note.conversation_id {
        require_member(&state, cid, &auth.user_id).await?;
    } else if note.owner_id != auth.user_id {
        return Err(ApiError::forbidden("ไม่มีสิทธิ์เข้าถึงบันทึกนี้"));
    }

    if let Some(pos) = note.liked_by.iter().position(|u| u == &auth.user_id) {
        note.liked_by.remove(pos);
    } else {
        note.liked_by.push(auth.user_id.clone());
    }
    note.updated_at = Utc::now().to_rfc3339();

    notes_coll
        .replace_one(doc! { "_id": &note_id }, &note)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = NoteDto::from(note);
    if let Some(ref cid) = dto.conversation_id {
        state.ws_hub.broadcast_event(json!({
            "event": "note_updated",
            "conversation_id": cid,
            "note": dto,
        }));
    }

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct CommentNoteRequest {
    pub content: String,
}

pub async fn comment_note_handler(
    auth: AuthUser,
    Path(note_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<CommentNoteRequest>,
) -> Result<Json<NoteDto>, ApiError> {
    let content = payload.content.trim().to_string();
    if content.is_empty() {
        return Err(ApiError::bad_request("กรุณาพิมพ์ข้อความแสดงความคิดเห็น"));
    }

    let notes_coll = state.db.collection::<NoteDoc>("notes");
    let mut note = notes_coll
        .find_one(doc! { "_id": &note_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบบันทึกที่ระบุ"))?;

    if let Some(ref cid) = note.conversation_id {
        require_member(&state, cid, &auth.user_id).await?;
    } else if note.owner_id != auth.user_id {
        return Err(ApiError::forbidden("ไม่มีสิทธิ์เข้าถึงบันทึกนี้"));
    }

    let user = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let now = Utc::now().to_rfc3339();
    note.comments.push(NoteComment {
        id: Uuid::new_v4().to_string(),
        user_id: user.id,
        user_name: user.display_name,
        content,
        created_at: now.clone(),
    });
    note.updated_at = now;

    notes_coll
        .replace_one(doc! { "_id": &note_id }, &note)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = NoteDto::from(note);
    if let Some(ref cid) = dto.conversation_id {
        state.ws_hub.broadcast_event(json!({
            "event": "note_updated",
            "conversation_id": cid,
            "note": dto,
        }));
    }

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct TaskActionRequest {
    pub action: String, // "accept" | "done" | "reopen"
}

pub async fn task_action_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<TaskActionRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    let user = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let mut msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความงานที่ระบุ"))?;

    require_member(&state, &msg.conversation_id, &auth.user_id).await?;

    let now = Utc::now().to_rfc3339();
    match payload.action.trim().to_lowercase().as_str() {
        "accept" | "accepted" => {
            msg.task_status = Some("accepted".to_string());
            msg.accepted_by = Some(user.display_name);
            msg.accepted_at = Some(now);
        }
        "done" | "complete" | "completed" => {
            msg.task_status = Some("done".to_string());
            msg.accepted_by = Some(user.display_name);
            msg.accepted_at = Some(now);
        }
        "reopen" | "open" => {
            msg.task_status = Some("open".to_string());
            msg.accepted_by = None;
            msg.accepted_at = None;
        }
        _ => {
            return Err(ApiError::bad_request(
                "คำสั่ง action ไม่ถูกต้อง (รองรับ accept, done, reopen)",
            ));
        }
    }

    msg_coll
        .replace_one(doc! { "_id": &msg_id }, &msg)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = MessageDto::from(msg);
    state.ws_hub.broadcast_event(json!({
        "event": "message_updated",
        "conversation_id": dto.conversation_id,
        "message": dto,
    }));

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct ApproveCardRequest {
    pub status: String, // "อนุมัติแล้ว" | "ไม่อนุมัติ"
    pub comment: Option<String>,
}

pub async fn approve_card_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<ApproveCardRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    let user = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let mut msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบการ์ดโต้ตอบที่ระบุ"))?;

    require_member(&state, &msg.conversation_id, &auth.user_id).await?;

    let now = Utc::now().to_rfc3339();
    let status_clean = payload.status.trim().to_string();

    let mut card = msg
        .card_payload
        .take()
        .or_else(|| msg.flex_payload.take())
        .unwrap_or_else(|| json!({}));
    if let Some(obj) = card.as_object_mut() {
        obj.insert("status".to_string(), json!(status_clean));
        obj.insert("status_label".to_string(), json!(status_clean));
        obj.insert("approved_by".to_string(), json!(user.display_name));
        obj.insert("approved_at".to_string(), json!(now));
        if let Some(ref c) = payload.comment {
            if !c.trim().is_empty() {
                obj.insert("approval_comment".to_string(), json!(c.trim()));
            }
        }
    }
    msg.card_payload = Some(card.clone());
    msg.flex_payload = Some(card);
    if msg.msg_type == "flex_card" {
        msg.msg_type = "rich_card".to_string();
    }

    msg_coll
        .replace_one(doc! { "_id": &msg_id }, &msg)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = MessageDto::from(msg);
    state.ws_hub.broadcast_event(json!({
        "event": "message_updated",
        "conversation_id": dto.conversation_id,
        "message": dto,
    }));

    Ok(Json(dto))
}

// =============================================================================
// Wave 4: Edit Message, Forward Message, Personal Keep Memo (#60)
// =============================================================================

#[derive(Debug, Deserialize)]
pub struct EditMessageRequest {
    pub content: String,
}

pub async fn edit_message_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<EditMessageRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let trimmed = payload.content.trim().to_string();
    if trimmed.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุข้อความที่ต้องการแก้ไข"));
    }
    if trimmed.chars().count() > 4000 {
        return Err(ApiError::bad_request("ข้อความต้องมีความยาวไม่เกิน 4,000 ตัวอักษร"));
    }

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");

    let mut msg = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความที่ต้องการแก้ไข"))?;

    let mut conv = require_member(&state, &msg.conversation_id, &auth.user_id).await?;

    if msg.sender_id != auth.user_id {
        return Err(ApiError::forbidden(
            "คุณสามารถแก้ไขได้เฉพาะข้อความของตัวเองเท่านั้น",
        ));
    }
    if msg.is_unsent {
        return Err(ApiError::bad_request("ไม่สามารถแก้ไขข้อความที่ยกเลิกแล้วได้"));
    }
    if msg.msg_type != "text" {
        return Err(ApiError::bad_request("แก้ไขได้เฉพาะข้อความตัวอักษรเท่านั้น"));
    }

    let now = Utc::now().to_rfc3339();
    msg.content = trimmed.clone();
    msg.edited_at = Some(now.clone());

    msg_coll
        .update_one(
            doc! { "_id": &msg_id },
            doc! {
                "$set": {
                    "content": &msg.content,
                    "edited_at": &now,
                }
            },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    if let Some(ref mut lm) = conv.last_message {
        if lm.id == msg.id {
            lm.content = if msg.is_confidential {
                format!("🔒 [ข้อความลับส่วนตัวล็อก PIN] {}", trimmed)
            } else {
                trimmed
            };
            let _ = conv_coll
                .replace_one(doc! { "_id": &conv.id }, &conv)
                .await;
        }
    }

    let other_member_ids: Vec<String> = conv
        .member_ids
        .iter()
        .filter(|id| *id != &auth.user_id)
        .cloned()
        .collect();
    let excluded_user_ids: Vec<String> = if other_member_ids.is_empty() {
        Vec::new()
    } else {
        state
            .db
            .collection::<FriendshipDoc>("friendships")
            .find(doc! {
                "friend_id": &auth.user_id,
                "user_id": { "$in": &other_member_ids },
                "is_blocked": true,
            })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .try_collect::<Vec<FriendshipDoc>>()
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .into_iter()
            .map(|f| f.user_id)
            .collect()
    };

    let dto = MessageDto::from(msg);
    state.ws_hub.broadcast_event(json!({
        "event": "message_edited",
        "conversation_id": dto.conversation_id,
        "excluded_user_ids": excluded_user_ids,
        "message": dto,
    }));

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct ForwardMessageRequest {
    pub target_conversation_ids: Vec<String>,
}

pub async fn forward_message_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<ForwardMessageRequest>,
) -> Result<Json<Value>, ApiError> {
    let mut target_ids: Vec<String> = Vec::new();
    for raw in &payload.target_conversation_ids {
        let t = raw.trim();
        if !t.is_empty() && !target_ids.iter().any(|existing| existing == t) {
            target_ids.push(t.to_string());
        }
    }
    if target_ids.is_empty() || target_ids.len() > 10 {
        return Err(ApiError::bad_request(
            "กรุณาเลือกห้องปลายทางสำหรับส่งต่อ 1 ถึง 10 ห้อง",
        ));
    }

    let users_coll = state.db.collection::<UserDoc>("users");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");

    let sender = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let orig = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความต้นทาง"))?;

    require_member(&state, &orig.conversation_id, &auth.user_id).await?;
    if orig.is_unsent || orig.deleted_for.contains(&auth.user_id) {
        return Err(ApiError::bad_request(
            "ไม่สามารถส่งต่อข้อความที่ถูกลบหรือยกเลิกแล้วได้",
        ));
    }

    let mut forwarded_messages: Vec<MessageDto> = Vec::new();

    for target_conv_id in target_ids {
        let Ok(mut conv) = require_member(&state, &target_conv_id, &auth.user_id).await else {
            continue;
        };

        let other_member_ids: Vec<String> = conv
            .member_ids
            .iter()
            .filter(|id| *id != &sender.id)
            .cloned()
            .collect();

        if conv.conv_type == "direct" && conv.oa_id.is_none() {
            if let Some(peer_id) = other_member_ids.first() {
                let blocked_by_sender = friends_coll
                    .count_documents(doc! {
                        "user_id": &sender.id,
                        "friend_id": peer_id,
                        "is_blocked": true,
                    })
                    .await
                    .unwrap_or(0)
                    > 0;
                if blocked_by_sender {
                    continue;
                }
            }
        }

        let excluded_user_ids: Vec<String> = if other_member_ids.is_empty() {
            Vec::new()
        } else if let Ok(cur) = friends_coll
            .find(doc! {
                "friend_id": &sender.id,
                "user_id": { "$in": &other_member_ids },
                "is_blocked": true,
            })
            .await
        {
            cur.try_collect::<Vec<FriendshipDoc>>()
                .await
                .unwrap_or_default()
                .into_iter()
                .map(|f| f.user_id)
                .collect()
        } else {
            Vec::new()
        };

        let is_direct_silently_blocked = conv.conv_type == "direct"
            && conv.oa_id.is_none()
            && other_member_ids
                .first()
                .is_some_and(|pid| excluded_user_ids.contains(pid));

        let now = Utc::now().to_rfc3339();
        let new_id = Uuid::new_v4().to_string();

        let fwd_doc = MessageDoc {
            id: new_id.clone(),
            conversation_id: conv.id.clone(),
            sender_id: sender.id.clone(),
            sender_name: sender.display_name.clone(),
            sender_avatar: sender.avatar_url.clone(),
            msg_type: orig.msg_type.clone(),
            content: orig.content.clone(),
            sticker_code: orig.sticker_code.clone(),
            attachment: orig.attachment.clone(),
            card_payload: orig.card_payload.clone(),
            flex_payload: orig.flex_payload.clone(),
            reply_to: None,
            read_by: vec![sender.id.clone()],
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
            audio_duration_sec: orig.audio_duration_sec,
            poll: orig.poll.clone(),
            event_data: orig.event_data.clone(),
            location_data: orig.location_data.clone(),
            contact_data: orig.contact_data.clone(),
            ladder_data: orig.ladder_data.clone(),
            edited_at: None,
            forwarded_from: Some(orig.sender_name.clone()),
            deleted_for: if is_direct_silently_blocked {
                excluded_user_ids.clone()
            } else {
                Vec::new()
            },
            created_at: now.clone(),
        };

        if msg_coll.insert_one(&fwd_doc).await.is_err() {
            continue;
        }

        let dto = MessageDto::from(fwd_doc);

        if is_direct_silently_blocked {
            state.ws_hub.broadcast_event(json!({
                "event": "new_message",
                "conversation_id": conv.id,
                "target_user_ids": [&sender.id],
                "excluded_user_ids": &excluded_user_ids,
                "message": dto,
            }));
        } else {
            conv.last_message = Some(LastMessageSummary {
                id: new_id,
                sender_id: sender.id.clone(),
                sender_name: sender.display_name.clone(),
                msg_type: dto.msg_type.clone(),
                content: dto.content.clone(),
                created_at: now.clone(),
                read_count: 0,
            });
            conv.updated_at = now;
            let _ = conv_coll
                .replace_one(doc! { "_id": &conv.id }, &conv)
                .await;

            state.ws_hub.broadcast_event(json!({
                "event": "new_message",
                "conversation_id": conv.id,
                "excluded_user_ids": &excluded_user_ids,
                "message": dto,
            }));
            crate::push::notify_new_message(&state, &conv, &dto);
        }

        forwarded_messages.push(dto);
    }

    Ok(Json(json!({
        "forwarded_count": forwarded_messages.len(),
        "messages": forwarded_messages,
    })))
}

pub async fn ensure_keep_conversation_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<ConversationDto>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let conv = ensure_keep_conversation_for_user(&state, &me)
        .await
        .map_err(ApiError::internal)?;
    let dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;

    Ok(Json(dto))
}

pub async fn save_message_to_keep_handler(
    auth: AuthUser,
    Path(msg_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<MessageDto>, ApiError> {
    let users_coll = state.db.collection::<UserDoc>("users");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    let me = users_coll
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let orig = msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความต้นทาง"))?;

    require_member(&state, &orig.conversation_id, &auth.user_id).await?;
    if orig.is_unsent || orig.deleted_for.contains(&auth.user_id) {
        return Err(ApiError::bad_request(
            "ไม่สามารถบันทึกข้อความที่ถูกลบหรือยกเลิกแล้วเข้า Keep ได้",
        ));
    }

    let mut keep_conv = ensure_keep_conversation_for_user(&state, &me)
        .await
        .map_err(ApiError::internal)?;

    let now = Utc::now().to_rfc3339();
    let new_id = Uuid::new_v4().to_string();

    let saved_doc = MessageDoc {
        id: new_id.clone(),
        conversation_id: keep_conv.id.clone(),
        sender_id: me.id.clone(),
        sender_name: me.display_name.clone(),
        sender_avatar: me.avatar_url.clone(),
        msg_type: orig.msg_type.clone(),
        content: orig.content.clone(),
        sticker_code: orig.sticker_code,
        attachment: orig.attachment,
        card_payload: orig.card_payload,
        flex_payload: orig.flex_payload,
        reply_to: None,
        read_by: vec![me.id.clone()],
        is_unsent: false,
        is_confidential: false,
        confidential_pin: None,
        expire_at: None,
        priority: "silent".to_string(),
        task_status: None,
        accepted_by: None,
        accepted_at: None,
        reactions: HashMap::new(),
        mentions: Vec::new(),
        audio_duration_sec: orig.audio_duration_sec,
        poll: orig.poll,
        event_data: orig.event_data,
        location_data: orig.location_data,
        contact_data: orig.contact_data,
        ladder_data: orig.ladder_data,
        edited_at: None,
        forwarded_from: Some(orig.sender_name),
        deleted_for: Vec::new(),
        created_at: now.clone(),
    };

    msg_coll
        .insert_one(&saved_doc)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let dto = MessageDto::from(saved_doc);

    keep_conv.last_message = Some(LastMessageSummary {
        id: new_id,
        sender_id: me.id.clone(),
        sender_name: me.display_name,
        msg_type: dto.msg_type.clone(),
        content: dto.content.clone(),
        created_at: now.clone(),
        read_count: 0,
    });
    keep_conv.updated_at = now;
    let _ = conv_coll
        .replace_one(doc! { "_id": &keep_conv.id }, &keep_conv)
        .await;

    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": keep_conv.id,
        "target_user_ids": [&me.id],
        "message": dto,
    }));

    Ok(Json(dto))
}
