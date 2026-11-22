use axum::{
    extract::{Path, Query, State},
    Json,
};
use bson::{doc, Regex};
use chrono::Utc;
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use crate::{
    auth::{ApiError, AuthUser},
    models::{
        ConversationDoc, LastMessageSummary, MessageDoc, MessageDto, OaAccountDoc, OaAccountDto,
        OaAutoReplyRuleDoc, OaBroadcastDoc, OaCouponDoc, OaCustomerChatDto, OaFollowerDoc,
        OaRichMenuItem, OaStaffMemberDto, UserDoc,
    },
    routes::{
        ai_routes::{insert_bot_message, maybe_trigger_oa_ai_reply},
        chat_routes::build_conversation_dto,
    },
    sms, AppState,
};

fn default_starter_rich_menu() -> Vec<OaRichMenuItem> {
    vec![
        OaRichMenuItem {
            id: "rm_menu".to_string(),
            label: "สินค้าและบริการ".to_string(),
            subtitle: "ดูรายการแนะนำ".to_string(),
            action_type: "keyword".to_string(),
            action_value: "สนใจดูสินค้าและบริการ".to_string(),
            icon: "storefront".to_string(),
        },
        OaRichMenuItem {
            id: "rm_promo".to_string(),
            label: "โปรโมชั่น & คูปอง".to_string(),
            subtitle: "เช็กส่วนลดล่าสุด".to_string(),
            action_type: "keyword".to_string(),
            action_value: "โปรโมชั่น".to_string(),
            icon: "local_offer".to_string(),
        },
        OaRichMenuItem {
            id: "rm_hours".to_string(),
            label: "เวลาเปิด-ปิด / ติดต่อ".to_string(),
            subtitle: "ข้อมูลหน้าร้าน".to_string(),
            action_type: "keyword".to_string(),
            action_value: "เวลาเปิด-ปิด".to_string(),
            icon: "schedule".to_string(),
        },
    ]
}

fn normalize_oa_handle(raw: &str) -> Result<String, String> {
    let cleaned: String = raw
        .trim()
        .trim_start_matches('@')
        .to_lowercase();
    if cleaned.len() < 2 || cleaned.len() > 32 {
        return Err("Handle ร้านค้าต้องยาว 2–32 ตัวอักษร (ภาษาอังกฤษ ตัวเลข จุด หรือ _ / -)".to_string());
    }
    if !cleaned
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '_' || c == '-')
    {
        return Err("Handle ร้านค้าใช้ได้เฉพาะ a-z, 0-9, ., _ และ -".to_string());
    }
    Ok(cleaned)
}

fn sanitize_rich_menu(items: Vec<OaRichMenuItem>) -> Vec<OaRichMenuItem> {
    items
        .into_iter()
        .filter(|m| !m.label.trim().is_empty())
        .take(6)
        .enumerate()
        .map(|(idx, mut m)| {
            if m.id.trim().is_empty() {
                m.id = format!("rm_{}", idx + 1);
            }
            m.label = m.label.trim().chars().take(36).collect();
            m.subtitle = m.subtitle.trim().chars().take(48).collect();
            m.action_type = match m.action_type.trim() {
                "coupon" | "url" | "ai_prompt" => m.action_type.trim().to_string(),
                _ => "keyword".to_string(),
            };
            if m.action_value.trim().is_empty() {
                m.action_value = m.label.clone();
            }
            if m.icon.trim().is_empty() {
                m.icon = "touch_app".to_string();
            }
            m
        })
        .collect()
}

pub fn normalize_staff_role_value(raw: &str) -> Option<String> {
    match raw.trim().to_lowercase().as_str() {
        "admin" => Some("admin".to_string()),
        "agent" => Some("agent".to_string()),
        "marketer" => Some("marketer".to_string()),
        _ => None,
    }
}

pub fn resolve_oa_staff_role(oa: &OaAccountDoc, user_id: &str) -> Option<String> {
    if oa.owner_id == user_id {
        return Some("owner".to_string());
    }
    if oa.admin_ids.iter().any(|id| id == user_id) {
        let role = oa
            .staff_roles
            .get(user_id)
            .and_then(|r| normalize_staff_role_value(r))
            .unwrap_or_else(|| "admin".to_string());
        return Some(role);
    }
    None
}

fn normalized_staff_roles_map(oa: &OaAccountDoc) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for uid in &oa.admin_ids {
        if uid == &oa.owner_id {
            continue;
        }
        let r = oa
            .staff_roles
            .get(uid)
            .and_then(|v| normalize_staff_role_value(v))
            .unwrap_or_else(|| "admin".to_string());
        map.insert(uid.clone(), r);
    }
    map
}

fn to_oa_dto(
    oa: OaAccountDoc,
    follower: Option<&OaFollowerDoc>,
    viewer_id: Option<&str>,
) -> OaAccountDto {
    let my_role = viewer_id.and_then(|uid| resolve_oa_staff_role(&oa, uid));
    let staff_roles = normalized_staff_roles_map(&oa);
    OaAccountDto {
        id: oa.id,
        handle: oa.handle,
        display_name: oa.display_name,
        category: oa.category,
        bio: oa.bio,
        avatar_url: oa.avatar_url,
        theme_color: oa.theme_color,
        greeting_message: oa.greeting_message,
        business_hours: oa.business_hours,
        owner_id: oa.owner_id,
        admin_ids: oa.admin_ids,
        staff_roles,
        my_role,
        bot_user_id: oa.bot_user_id,
        is_verified: oa.is_verified,
        is_active: oa.is_active,
        calls_enabled: oa.calls_enabled,
        ai_enabled: oa.ai_enabled,
        ai_knowledge_prompt: oa.ai_knowledge_prompt,
        rich_menu: oa.rich_menu,
        follower_count: oa.follower_count,
        is_following: follower.map(|f| f.is_following).unwrap_or(false),
        conversation_id: follower.map(|f| f.conversation_id.clone()),
        created_at: oa.created_at,
        updated_at: oa.updated_at,
    }
}

async fn load_oa_with_role(
    state: &AppState,
    oa_id: &str,
    user_id: &str,
) -> Result<(OaAccountDoc, String), ApiError> {
    let oa = state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .find_one(doc! { "_id": oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบร้านค้าที่ระบุ"))?;

    let role = resolve_oa_staff_role(&oa, user_id)
        .ok_or_else(|| ApiError::forbidden("เฉพาะทีมงานของร้านค้านี้เท่านั้น"))?;
    Ok((oa, role))
}

async fn require_oa_any_staff(
    state: &AppState,
    oa_id: &str,
    user_id: &str,
) -> Result<OaAccountDoc, ApiError> {
    let (oa, _) = load_oa_with_role(state, oa_id, user_id).await?;
    Ok(oa)
}

async fn require_oa_chat_staff(
    state: &AppState,
    oa_id: &str,
    user_id: &str,
) -> Result<OaAccountDoc, ApiError> {
    let (oa, role) = load_oa_with_role(state, oa_id, user_id).await?;
    if !matches!(role.as_str(), "owner" | "admin" | "agent") {
        return Err(ApiError::forbidden(
            "เฉพาะเจ้าของร้าน แอดมินร้าน หรือคนตอบแชท (Agent) เท่านั้นที่ใช้งานส่วนนี้ได้",
        ));
    }
    Ok(oa)
}

async fn require_oa_marketing_staff(
    state: &AppState,
    oa_id: &str,
    user_id: &str,
) -> Result<OaAccountDoc, ApiError> {
    let (oa, role) = load_oa_with_role(state, oa_id, user_id).await?;
    if !matches!(role.as_str(), "owner" | "admin" | "marketer") {
        return Err(ApiError::forbidden(
            "เฉพาะเจ้าของร้าน แอดมินร้าน หรือฝ่ายการตลาด (Marketer) เท่านั้นที่จัดการบรอดแคสต์ คูปอง และตอบอัตโนมัติได้",
        ));
    }
    Ok(oa)
}

async fn get_oa_bot_user(state: &AppState, oa: &OaAccountDoc) -> UserDoc {
    let users_coll = state.db.collection::<UserDoc>("users");
    if let Ok(Some(u)) = users_coll.find_one(doc! { "_id": &oa.bot_user_id }).await {
        return u;
    }
    UserDoc {
        id: oa.bot_user_id.clone(),
        email: format!("oa+{}@bcaichat.local", oa.handle),
        phone: String::new(),
        phone_verified: false,
        email_verified: false,
        display_name: oa.display_name.clone(),
        bc_id: format!("@{}", oa.handle),
        avatar_url: oa.avatar_url.clone(),
        status_message: oa.bio.clone(),
        qr_token: format!("BCOA_{}", oa.id),
        role: "user".to_string(),
        department: oa.category.clone(),
        job_title: "ร้านค้า".to_string(),
        google_id: None,
        is_oa_bot: true,
        oa_id: Some(oa.id.clone()),
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
        created_at: oa.created_at.clone(),
    }
}

async fn insert_oa_bot_message_raw(
    state: &AppState,
    conv: &mut ConversationDoc,
    bot_user: &UserDoc,
    msg_type: &str,
    content: &str,
    card_payload: Option<Value>,
) -> Result<MessageDto, String> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");

    let now = Utc::now().to_rfc3339();
    let msg_id = Uuid::new_v4().to_string();

    let bot_msg = MessageDoc {
        id: msg_id.clone(),
        conversation_id: conv.id.clone(),
        sender_id: bot_user.id.clone(),
        sender_name: bot_user.display_name.clone(),
        sender_avatar: bot_user.avatar_url.clone(),
        msg_type: msg_type.to_string(),
        content: content.to_string(),
        sticker_code: None,
        attachment: None,
        card_payload,
        flex_payload: None,
        reply_to: None,
        read_by: vec![bot_user.id.clone()],
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

    msg_coll
        .insert_one(&bot_msg)
        .await
        .map_err(|e| e.to_string())?;

    conv.last_message = Some(LastMessageSummary {
        id: msg_id,
        sender_id: bot_user.id.clone(),
        sender_name: bot_user.display_name.clone(),
        msg_type: msg_type.to_string(),
        content: content.chars().take(120).collect(),
        created_at: now.clone(),
        read_count: 0,
    });
    conv.updated_at = now;

    let _ = conv_coll
        .replace_one(doc! { "_id": &conv.id }, &*conv)
        .await;

    let dto = MessageDto::from(bot_msg);
    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": conv.id,
        "message": dto,
    }));
    crate::push::notify_new_message(state, conv, &dto);

    Ok(dto)
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
pub struct DiscoverOaQuery {
    pub q: Option<String>,
    pub category: Option<String>,
}

pub async fn discover_oas_handler(
    auth: AuthUser,
    Query(query): Query<DiscoverOaQuery>,
    State(state): State<AppState>,
) -> Result<Json<Vec<OaAccountDto>>, ApiError> {
    let oa_coll = state.db.collection::<OaAccountDoc>("oa_accounts");
    let fol_coll = state.db.collection::<OaFollowerDoc>("oa_followers");

    let mut filter = doc! { "is_active": true };
    if let Some(ref cat) = query.category {
        if !cat.trim().is_empty() && cat.trim() != "ทั้งหมด" {
            filter.insert("category", cat.trim());
        }
    }
    if let Some(ref q) = query.q {
        let trimmed = q.trim().trim_start_matches('@');
        if !trimmed.is_empty() {
            let rx = Regex {
                pattern: regex_escape(trimmed),
                options: "i".to_string(),
            };
            filter.insert(
                "$or",
                vec![
                    doc! { "display_name": rx.clone() },
                    doc! { "handle": rx.clone() },
                    doc! { "category": rx.clone() },
                    doc! { "bio": rx },
                ],
            );
        }
    }

    let cursor = oa_coll
        .find(filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut oas: Vec<OaAccountDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    oas.sort_by(|a, b| {
        b.follower_count
            .cmp(&a.follower_count)
            .then_with(|| a.display_name.cmp(&b.display_name))
    });

    let f_cursor = fol_coll
        .find(doc! { "user_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let followers: Vec<OaFollowerDoc> = f_cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let f_map: HashMap<String, OaFollowerDoc> =
        followers.into_iter().map(|f| (f.oa_id.clone(), f)).collect();

    let result = oas
        .into_iter()
        .map(|oa| {
            let fol = f_map.get(&oa.id);
            to_oa_dto(oa, fol, Some(&auth.user_id))
        })
        .collect();

    Ok(Json(result))
}

pub async fn list_my_oas_handler(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<Vec<OaAccountDto>>, ApiError> {
    let oa_coll = state.db.collection::<OaAccountDoc>("oa_accounts");
    let cursor = oa_coll
        .find(doc! {
            "$or": [
                { "owner_id": &auth.user_id },
                { "admin_ids": &auth.user_id },
            ]
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut oas: Vec<OaAccountDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    oas.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));

    Ok(Json(
        oas.into_iter()
            .map(|oa| to_oa_dto(oa, None, Some(&auth.user_id)))
            .collect(),
    ))
}

#[derive(Debug, Deserialize)]
pub struct CreateOaRequest {
    pub handle: String,
    pub display_name: String,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub bio: String,
    #[serde(default)]
    pub avatar_url: String,
    #[serde(default)]
    pub theme_color: String,
    #[serde(default)]
    pub greeting_message: String,
    #[serde(default)]
    pub business_hours: String,
    #[serde(default)]
    pub calls_enabled: Option<bool>,
    #[serde(default)]
    pub ai_enabled: Option<bool>,
    #[serde(default)]
    pub ai_knowledge_prompt: String,
    #[serde(default)]
    pub rich_menu: Option<Vec<OaRichMenuItem>>,
}

pub async fn create_oa_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<CreateOaRequest>,
) -> Result<Json<OaAccountDto>, ApiError> {
    let display_name = payload.display_name.trim().to_string();
    if display_name.is_empty() {
        return Err(ApiError::bad_request("กรุณากรอกชื่อร้านค้า"));
    }
    let handle = normalize_oa_handle(&payload.handle).map_err(ApiError::bad_request)?;

    let oa_coll = state.db.collection::<OaAccountDoc>("oa_accounts");
    if oa_coll
        .find_one(doc! { "handle": &handle })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .is_some()
    {
        return Err(ApiError::conflict("ชื่อ @Handle ของร้านค้านี้ถูกใช้งานแล้ว"));
    }
    if crate::routes::auth_routes::is_bc_id_taken(&state.db, &format!("@{}", handle), None).await?
    {
        return Err(ApiError::conflict(
            "ชื่อ @Handle ของร้านค้านี้ซ้ำกับ BC ID หรือร้านค้าที่มีอยู่แล้ว",
        ));
    }

    let now = Utc::now().to_rfc3339();
    let short = &Uuid::new_v4().simple().to_string()[..12];
    let oa_id = format!("oa_{}", short);
    let bot_user_id = format!("user_oa_{}", short);
    let avatar_url = if payload.avatar_url.trim().is_empty() {
        format!(
            "https://ui-avatars.com/api/?name={}&background=812920&color=fff&bold=true",
            urlencoding::encode(&display_name)
        )
    } else {
        payload.avatar_url.trim().to_string()
    };
    let category = if payload.category.trim().is_empty() {
        "ร้านค้า & บริการ".to_string()
    } else {
        payload.category.trim().to_string()
    };
    let greeting = if payload.greeting_message.trim().is_empty() {
        format!(
            "สวัสดีค่ะ ยินดีต้อนรับสู่ร้าน {}! กดเลือกเมนูด้านล่างหรือพิมพ์สอบถามได้เลยนะคะ",
            display_name
        )
    } else {
        payload.greeting_message.trim().to_string()
    };
    let theme_color = if payload.theme_color.trim().is_empty() {
        "#812920".to_string()
    } else {
        payload.theme_color.trim().to_string()
    };
    let business_hours = if payload.business_hours.trim().is_empty() {
        "ทุกวัน 09:00–20:00 น.".to_string()
    } else {
        payload.business_hours.trim().to_string()
    };
    let rich_menu = match payload.rich_menu {
        Some(items) => sanitize_rich_menu(items),
        None => default_starter_rich_menu(),
    };

    let oa = OaAccountDoc {
        id: oa_id.clone(),
        handle: handle.clone(),
        display_name: display_name.clone(),
        category: category.clone(),
        bio: payload.bio.trim().to_string(),
        avatar_url: avatar_url.clone(),
        theme_color,
        greeting_message: greeting,
        business_hours,
        owner_id: auth.user_id.clone(),
        admin_ids: Vec::new(),
        staff_roles: HashMap::new(),
        bot_user_id: bot_user_id.clone(),
        is_verified: true,
        is_active: true,
        calls_enabled: payload.calls_enabled.unwrap_or(true),
        ai_enabled: payload.ai_enabled.unwrap_or(true),
        ai_knowledge_prompt: payload.ai_knowledge_prompt.trim().to_string(),
        rich_menu,
        follower_count: 0,
        created_at: now.clone(),
        updated_at: now.clone(),
    };

    let bot_user = UserDoc {
        id: bot_user_id.clone(),
        email: format!("oa+{}@bcaichat.local", handle),
        phone: String::new(),
        phone_verified: false,
        email_verified: false,
        display_name: display_name.clone(),
        bc_id: format!("@{}", handle),
        avatar_url,
        status_message: oa.bio.clone(),
        qr_token: format!("BCOA_{}", oa_id),
        role: "user".to_string(),
        department: category,
        job_title: "ร้านค้า".to_string(),
        google_id: None,
        is_oa_bot: true,
        oa_id: Some(oa_id.clone()),
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
        created_at: now,
    };

    state
        .db
        .collection::<UserDoc>("users")
        .insert_one(&bot_user)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    oa_coll
        .insert_one(&oa)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(to_oa_dto(oa, None, Some(&auth.user_id))))
}

pub async fn get_oa_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OaAccountDto>, ApiError> {
    let oa = state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .find_one(doc! { "_id": &oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบร้านค้าที่ระบุ"))?;

    let follower = state
        .db
        .collection::<OaFollowerDoc>("oa_followers")
        .find_one(doc! { "oa_id": &oa.id, "user_id": &auth.user_id })
        .await
        .ok()
        .flatten();

    Ok(Json(to_oa_dto(oa, follower.as_ref(), Some(&auth.user_id))))
}

#[derive(Debug, Deserialize)]
pub struct UpdateOaRequest {
    pub display_name: Option<String>,
    pub category: Option<String>,
    pub bio: Option<String>,
    pub avatar_url: Option<String>,
    pub theme_color: Option<String>,
    pub greeting_message: Option<String>,
    pub business_hours: Option<String>,
    pub is_active: Option<bool>,
    pub calls_enabled: Option<bool>,
    pub ai_enabled: Option<bool>,
    pub ai_knowledge_prompt: Option<String>,
    pub rich_menu: Option<Vec<OaRichMenuItem>>,
}

pub async fn update_oa_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateOaRequest>,
) -> Result<Json<OaAccountDto>, ApiError> {
    let (mut oa, role) = load_oa_with_role(&state, &oa_id, &auth.user_id).await?;
    let only_rich_menu = payload.rich_menu.is_some()
        && payload.display_name.is_none()
        && payload.category.is_none()
        && payload.bio.is_none()
        && payload.avatar_url.is_none()
        && payload.theme_color.is_none()
        && payload.greeting_message.is_none()
        && payload.business_hours.is_none()
        && payload.is_active.is_none()
        && payload.calls_enabled.is_none()
        && payload.ai_enabled.is_none()
        && payload.ai_knowledge_prompt.is_none();

    match role.as_str() {
        "owner" | "admin" => {}
        "marketer" if only_rich_menu => {}
        "marketer" => {
            return Err(ApiError::forbidden(
                "ฝ่ายการตลาด (Marketer) แก้ไขได้เฉพาะเมนูทางลัด (Rich Menu) ของร้านเท่านั้น",
            ));
        }
        _ => {
            return Err(ApiError::forbidden(
                "เฉพาะเจ้าของร้านหรือแอดมินร้านเท่านั้นที่แก้ไขการตั้งค่าร้านค้าได้",
            ));
        }
    }

    if let Some(v) = payload.display_name {
        if !v.trim().is_empty() {
            oa.display_name = v.trim().to_string();
        }
    }
    if let Some(v) = payload.category {
        if !v.trim().is_empty() {
            oa.category = v.trim().to_string();
        }
    }
    if let Some(v) = payload.bio {
        oa.bio = v.trim().to_string();
    }
    if let Some(v) = payload.avatar_url {
        if !v.trim().is_empty() {
            oa.avatar_url = v.trim().to_string();
        }
    }
    if let Some(v) = payload.theme_color {
        if !v.trim().is_empty() {
            oa.theme_color = v.trim().to_string();
        }
    }
    if let Some(v) = payload.greeting_message {
        oa.greeting_message = v.trim().to_string();
    }
    if let Some(v) = payload.business_hours {
        oa.business_hours = v.trim().to_string();
    }
    if let Some(v) = payload.is_active {
        oa.is_active = v;
    }
    if let Some(v) = payload.calls_enabled {
        oa.calls_enabled = v;
    }
    if let Some(v) = payload.ai_enabled {
        oa.ai_enabled = v;
    }
    if let Some(v) = payload.ai_knowledge_prompt {
        oa.ai_knowledge_prompt = v.trim().to_string();
    }
    if let Some(rm) = payload.rich_menu {
        oa.rich_menu = sanitize_rich_menu(rm);
    }
    oa.updated_at = Utc::now().to_rfc3339();

    state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .replace_one(doc! { "_id": &oa.id }, &oa)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    // Keep bot UserDoc & OA ConversationDocs synced with updated display_name / avatar
    let _ = state
        .db
        .collection::<UserDoc>("users")
        .update_one(
            doc! { "_id": &oa.bot_user_id },
            doc! {
                "$set": {
                    "display_name": &oa.display_name,
                    "avatar_url": &oa.avatar_url,
                    "status_message": &oa.bio,
                    "department": &oa.category,
                }
            },
        )
        .await;
    let _ = state
        .db
        .collection::<ConversationDoc>("conversations")
        .update_many(
            doc! { "oa_id": &oa.id },
            doc! {
                "$set": {
                    "name": &oa.display_name,
                    "avatar_url": &oa.avatar_url,
                }
            },
        )
        .await;

    let follower = state
        .db
        .collection::<OaFollowerDoc>("oa_followers")
        .find_one(doc! { "oa_id": &oa.id, "user_id": &auth.user_id })
        .await
        .ok()
        .flatten();

    Ok(Json(to_oa_dto(oa, follower.as_ref(), Some(&auth.user_id))))
}

fn oa_inbox_staff_ids(oa: &OaAccountDoc) -> Vec<String> {
    let mut ids = vec![oa.owner_id.clone()];
    for aid in &oa.admin_ids {
        if !ids.contains(aid)
            && matches!(
                resolve_oa_staff_role(oa, aid).as_deref(),
                Some("admin" | "agent")
            )
        {
            ids.push(aid.clone());
        }
    }
    ids
}

async fn sync_oa_conversations_admins(state: &AppState, oa: &OaAccountDoc) {
    let inbox_admins = oa_inbox_staff_ids(oa);
    let _ = state
        .db
        .collection::<ConversationDoc>("conversations")
        .update_many(
            doc! { "oa_id": &oa.id },
            doc! { "$set": { "admin_ids": inbox_admins } },
        )
        .await;
}

async fn find_human_user_by_identifier(
    users_coll: &mongodb::Collection<UserDoc>,
    raw_query: &str,
) -> Result<Option<UserDoc>, ApiError> {
    let q = raw_query.trim();
    if q.is_empty() {
        return Ok(None);
    }
    let non_bot = doc! {
        "is_oa_bot": { "$ne": true },
        "_id": { "$nin": ["user_ai", "user_official"] },
    };

    if let Ok(norm_phone) = sms::normalize_thai_phone(q) {
        let mut f = non_bot.clone();
        f.insert("phone", norm_phone);
        if let Some(u) = users_coll
            .find_one(f)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
        {
            return Ok(Some(u));
        }
    }

    let with_at = if q.starts_with('@') {
        q.to_string()
    } else {
        format!("@{}", q)
    };
    let no_at = q.trim_start_matches('@').to_string();
    let mut f_bc = non_bot.clone();
    f_bc.insert(
        "bc_id",
        doc! { "$in": [q, &with_at, &no_at, q.to_lowercase(), with_at.to_lowercase(), no_at.to_lowercase()] },
    );
    if let Some(u) = users_coll
        .find_one(f_bc)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        return Ok(Some(u));
    }

    if q.contains('@') {
        let mut f_em = non_bot.clone();
        f_em.insert("email", q.to_lowercase());
        if let Some(u) = users_coll
            .find_one(f_em)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
        {
            return Ok(Some(u));
        }
    }

    let mut f_id = non_bot;
    f_id.insert("_id", q);
    users_coll
        .find_one(f_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))
}

pub async fn list_oa_admins_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<OaStaffMemberDto>>, ApiError> {
    let oa = require_oa_any_staff(&state, &oa_id, &auth.user_id).await?;

    let mut all_uids = vec![oa.owner_id.clone()];
    for uid in &oa.admin_ids {
        if !all_uids.contains(uid) {
            all_uids.push(uid.clone());
        }
    }

    let users: Vec<UserDoc> = state
        .db
        .collection::<UserDoc>("users")
        .find(doc! { "_id": { "$in": &all_uids } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let user_map: HashMap<String, UserDoc> =
        users.into_iter().map(|u| (u.id.clone(), u)).collect();

    let mut out = Vec::with_capacity(all_uids.len());
    for uid in all_uids {
        let role = if uid == oa.owner_id {
            "owner".to_string()
        } else {
            oa.staff_roles
                .get(&uid)
                .and_then(|r| normalize_staff_role_value(r))
                .unwrap_or_else(|| "admin".to_string())
        };
        if let Some(u) = user_map.get(&uid) {
            out.push(OaStaffMemberDto {
                user_id: u.id.clone(),
                display_name: u.display_name.clone(),
                bc_id: u.bc_id.clone(),
                phone: u.phone.clone(),
                email: u.email.clone(),
                avatar_url: u.avatar_url.clone(),
                role,
            });
        } else {
            out.push(OaStaffMemberDto {
                user_id: uid.clone(),
                display_name: uid,
                bc_id: String::new(),
                phone: String::new(),
                email: String::new(),
                avatar_url: String::new(),
                role,
            });
        }
    }

    Ok(Json(out))
}

#[derive(Debug, Deserialize)]
pub struct AddOaAdminRequest {
    pub query: Option<String>,
    pub user_id: Option<String>,
    pub phone: Option<String>,
    pub bc_id: Option<String>,
    pub email: Option<String>,
    pub role: Option<String>,
}

pub async fn add_oa_admin_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<AddOaAdminRequest>,
) -> Result<Json<OaAccountDto>, ApiError> {
    let (mut oa, caller_role) = load_oa_with_role(&state, &oa_id, &auth.user_id).await?;
    if caller_role != "owner" && caller_role != "admin" {
        return Err(ApiError::forbidden(
            "เฉพาะเจ้าของร้านหรือแอดมินร้านเท่านั้นที่เพิ่มสมาชิกทีมงานได้",
        ));
    }

    let target_role = match payload.role.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(raw) => normalize_staff_role_value(raw).ok_or_else(|| {
            ApiError::bad_request("บทบาททีมงานต้องเป็น admin, agent หรือ marketer เท่านั้น")
        })?,
        None => {
            if caller_role == "owner" {
                "admin".to_string()
            } else {
                "agent".to_string()
            }
        }
    };

    if caller_role == "admin" && target_role == "admin" {
        return Err(ApiError::forbidden(
            "แอดมินร้านสามารถเพิ่มทีมงานได้เฉพาะบทบาทคนตอบแชท (agent) หรือฝ่ายการตลาด (marketer) เท่านั้น",
        ));
    }

    let users_coll = state.db.collection::<UserDoc>("users");
    let mut target: Option<UserDoc> = None;

    if let Some(ref q) = payload.query {
        target = find_human_user_by_identifier(&users_coll, q).await?;
    }
    if target.is_none() {
        if let Some(ref ph) = payload.phone {
            target = find_human_user_by_identifier(&users_coll, ph).await?;
        }
    }
    if target.is_none() {
        if let Some(ref bid) = payload.bc_id {
            target = find_human_user_by_identifier(&users_coll, bid).await?;
        }
    }
    if target.is_none() {
        if let Some(ref em) = payload.email {
            target = find_human_user_by_identifier(&users_coll, em).await?;
        }
    }
    if target.is_none() {
        if let Some(ref uid) = payload.user_id {
            target = find_human_user_by_identifier(&users_coll, uid).await?;
        }
    }

    let staff = target.ok_or_else(|| {
        ApiError::not_found("ไม่พบบัญชีผู้ใช้จากเบอร์มือถือ / @BC ID / Gmail ที่ระบุ")
    })?;

    if staff.id == oa.owner_id {
        return Err(ApiError::bad_request("ผู้ใช้นี้เป็นเจ้าของร้านหลักอยู่แล้ว"));
    }

    if oa.admin_ids.contains(&staff.id) {
        let existing_role = resolve_oa_staff_role(&oa, &staff.id).unwrap_or_else(|| "admin".into());
        if caller_role == "admin" && existing_role == "admin" {
            return Err(ApiError::forbidden(
                "เฉพาะเจ้าของร้านเท่านั้นที่ปรับบทบาทของแอดมินร้านได้",
            ));
        }
    } else {
        oa.admin_ids.push(staff.id.clone());
    }
    oa.staff_roles.insert(staff.id.clone(), target_role);
    oa.updated_at = Utc::now().to_rfc3339();

    state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .replace_one(doc! { "_id": &oa.id }, &oa)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    sync_oa_conversations_admins(&state, &oa).await;

    Ok(Json(to_oa_dto(oa, None, Some(&auth.user_id))))
}

#[derive(Debug, Deserialize)]
pub struct UpdateOaStaffRoleRequest {
    pub role: String,
}

pub async fn update_oa_admin_role_handler(
    auth: AuthUser,
    Path((oa_id, uid)): Path<(String, String)>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateOaStaffRoleRequest>,
) -> Result<Json<OaAccountDto>, ApiError> {
    let (mut oa, caller_role) = load_oa_with_role(&state, &oa_id, &auth.user_id).await?;
    if caller_role != "owner" && caller_role != "admin" {
        return Err(ApiError::forbidden(
            "เฉพาะเจ้าของร้านหรือแอดมินร้านเท่านั้นที่เปลี่ยนบทบาททีมงานได้",
        ));
    }

    let target_uid = uid.trim();
    if target_uid == oa.owner_id {
        return Err(ApiError::bad_request(
            "ไม่สามารถเปลี่ยนบทบาทของเจ้าของร้านหลักได้",
        ));
    }
    if !oa.admin_ids.iter().any(|id| id == target_uid) {
        return Err(ApiError::not_found("ไม่พบสมาชิกทีมงานรายนี้ในร้านค้า"));
    }

    let new_role = normalize_staff_role_value(&payload.role).ok_or_else(|| {
        ApiError::bad_request("บทบาททีมงานต้องเป็น admin, agent หรือ marketer เท่านั้น")
    })?;

    if caller_role == "admin" {
        let current_target_role =
            resolve_oa_staff_role(&oa, target_uid).unwrap_or_else(|| "admin".to_string());
        if current_target_role == "admin" || new_role == "admin" {
            return Err(ApiError::forbidden(
                "เฉพาะเจ้าของร้านเท่านั้นที่แต่งตั้งหรือเปลี่ยนบทบาทของแอดมินร้านได้",
            ));
        }
    }

    oa.staff_roles.insert(target_uid.to_string(), new_role);
    oa.updated_at = Utc::now().to_rfc3339();

    state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .replace_one(doc! { "_id": &oa.id }, &oa)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    sync_oa_conversations_admins(&state, &oa).await;

    Ok(Json(to_oa_dto(oa, None, Some(&auth.user_id))))
}

pub async fn remove_oa_admin_handler(
    auth: AuthUser,
    Path((oa_id, uid)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<OaAccountDto>, ApiError> {
    let (mut oa, caller_role) = load_oa_with_role(&state, &oa_id, &auth.user_id).await?;
    let target_uid = uid.trim();

    if target_uid == oa.owner_id {
        return Err(ApiError::bad_request(
            "ไม่สามารถลบเจ้าของร้านหลักออกจากกิจการได้",
        ));
    }

    let is_self = target_uid == auth.user_id;
    if !is_self {
        match caller_role.as_str() {
            "owner" => {}
            "admin" => {
                let target_role =
                    resolve_oa_staff_role(&oa, target_uid).unwrap_or_else(|| "admin".to_string());
                if target_role == "admin" {
                    return Err(ApiError::forbidden(
                        "เฉพาะเจ้าของร้านเท่านั้นที่ลบแอดมินร้านได้",
                    ));
                }
            }
            _ => {
                return Err(ApiError::forbidden(
                    "คุณไม่มีสิทธิ์ลบสมาชิกทีมงานคนอื่นออกจากร้าน",
                ));
            }
        }
    }

    oa.admin_ids.retain(|id| id != target_uid);
    oa.staff_roles.remove(target_uid);
    oa.updated_at = Utc::now().to_rfc3339();

    state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .replace_one(doc! { "_id": &oa.id }, &oa)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    sync_oa_conversations_admins(&state, &oa).await;

    Ok(Json(to_oa_dto(oa, None, Some(&auth.user_id))))
}

pub async fn follow_oa_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let oa_coll = state.db.collection::<OaAccountDoc>("oa_accounts");
    let mut oa = oa_coll
        .find_one(doc! { "_id": &oa_id, "is_active": true })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบร้านค้าที่เปิดให้บริการ"))?;

    let bot_user = get_oa_bot_user(&state, &oa).await;
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let fol_coll = state.db.collection::<OaFollowerDoc>("oa_followers");
    let now = Utc::now().to_rfc3339();

    let mut conv = match conv_coll
        .find_one(doc! {
            "type": "oa",
            "oa_id": &oa.id,
            "member_ids": &auth.user_id,
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        Some(c) => c,
        None => {
            let oa_admins = oa_inbox_staff_ids(&oa);
            let new_conv = ConversationDoc {
                id: Uuid::new_v4().to_string(),
                conv_type: "oa".to_string(),
                name: oa.display_name.clone(),
                avatar_url: oa.avatar_url.clone(),
                folder: "personal".to_string(),
                is_pinned: false,
                is_muted: false,
                is_archived: false,
                invite_token: String::new(),
                admin_ids: oa_admins,
                member_ids: vec![auth.user_id.clone(), bot_user.id.clone()],
                user_meta: HashMap::new(),
                pinned_message: None,
                last_message: None,
                oa_id: Some(oa.id.clone()),
                oa_handle: Some(oa.handle.clone()),
                ai_game_auto_invite: None,
                ai_game_invite_cooldown_mins: None,
                last_ai_game_invite_at: None,
                human_msgs_since_game_invite: 0,
                created_at: now.clone(),
                updated_at: now.clone(),
            };
            conv_coll
                .insert_one(&new_conv)
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?;
            new_conv
        }
    };

    let mut follower = match fol_coll
        .find_one(doc! { "oa_id": &oa.id, "user_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
    {
        Some(mut f) => {
            f.is_following = true;
            f.conversation_id = conv.id.clone();
            f.updated_at = now.clone();
            fol_coll
                .replace_one(doc! { "_id": &f.id }, &f)
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?;
            f
        }
        None => {
            let f = OaFollowerDoc {
                id: Uuid::new_v4().to_string(),
                oa_id: oa.id.clone(),
                user_id: auth.user_id.clone(),
                conversation_id: conv.id.clone(),
                tags: Vec::new(),
                crm_note: String::new(),
                ai_paused: false,
                is_following: true,
                followed_at: now.clone(),
                updated_at: now.clone(),
            };
            fol_coll
                .insert_one(&f)
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?;
            f
        }
    };

    let count = fol_coll
        .count_documents(doc! { "oa_id": &oa.id, "is_following": true })
        .await
        .unwrap_or(0) as usize;
    oa.follower_count = count;
    oa.updated_at = now;
    let _ = oa_coll
        .update_one(
            doc! { "_id": &oa.id },
            doc! { "$set": { "follower_count": count as i64, "updated_at": &oa.updated_at } },
        )
        .await;

    // Send welcome message if this OA room has no messages yet
    let msg_count = state
        .db
        .collection::<MessageDoc>("messages")
        .count_documents(doc! { "conversation_id": &conv.id })
        .await
        .unwrap_or(0);
    if msg_count == 0 && !oa.greeting_message.trim().is_empty() {
        let _ = insert_bot_message(&state, &mut conv, &bot_user, &oa.greeting_message).await;
    }

    follower.is_following = true;
    let conv_dto = build_conversation_dto(&state, conv, &auth.user_id)
        .await
        .map_err(ApiError::internal)?;

    Ok(Json(json!({
        "oa": to_oa_dto(oa, Some(&follower), Some(&auth.user_id)),
        "conversation": conv_dto,
        "conversation_id": conv_dto.id,
    })))
}

pub async fn unfollow_oa_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<OaAccountDto>, ApiError> {
    let oa_coll = state.db.collection::<OaAccountDoc>("oa_accounts");
    let mut oa = oa_coll
        .find_one(doc! { "_id": &oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบร้านค้า"))?;

    let fol_coll = state.db.collection::<OaFollowerDoc>("oa_followers");
    let now = Utc::now().to_rfc3339();
    let _ = fol_coll
        .update_one(
            doc! { "oa_id": &oa.id, "user_id": &auth.user_id },
            doc! { "$set": { "is_following": false, "updated_at": &now } },
        )
        .await;

    let count = fol_coll
        .count_documents(doc! { "oa_id": &oa.id, "is_following": true })
        .await
        .unwrap_or(0) as usize;
    oa.follower_count = count;
    oa.updated_at = now;
    let _ = oa_coll
        .update_one(
            doc! { "_id": &oa.id },
            doc! { "$set": { "follower_count": count as i64, "updated_at": &oa.updated_at } },
        )
        .await;

    let follower = fol_coll
        .find_one(doc! { "oa_id": &oa.id, "user_id": &auth.user_id })
        .await
        .ok()
        .flatten();

    Ok(Json(to_oa_dto(oa, follower.as_ref(), Some(&auth.user_id))))
}

pub async fn oa_overview_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_any_staff(&state, &oa_id, &auth.user_id).await?;
    let fol_coll = state.db.collection::<OaFollowerDoc>("oa_followers");

    let followers: Vec<OaFollowerDoc> = fol_coll
        .find(doc! { "oa_id": &oa.id, "is_following": true })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let mut tag_counts: HashMap<String, usize> = HashMap::new();
    for f in &followers {
        for t in &f.tags {
            let trimmed = t.trim();
            if !trimmed.is_empty() {
                *tag_counts.entry(trimmed.to_string()).or_insert(0) += 1;
            }
        }
    }
    let mut tags_vec: Vec<Value> = tag_counts
        .into_iter()
        .map(|(tag, count)| json!({ "tag": tag, "count": count }))
        .collect();
    tags_vec.sort_by(|a, b| {
        b["count"]
            .as_u64()
            .unwrap_or(0)
            .cmp(&a["count"].as_u64().unwrap_or(0))
    });

    let active_chats_count = state
        .db
        .collection::<ConversationDoc>("conversations")
        .count_documents(doc! { "oa_id": &oa.id })
        .await
        .unwrap_or(0);
    let auto_reply_count = state
        .db
        .collection::<OaAutoReplyRuleDoc>("oa_auto_replies")
        .count_documents(doc! { "oa_id": &oa.id, "is_active": true })
        .await
        .unwrap_or(0);
    let coupons: Vec<OaCouponDoc> = state
        .db
        .collection::<OaCouponDoc>("oa_coupons")
        .find(doc! { "oa_id": &oa.id, "is_active": true })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .unwrap_or_default();
    let total_coupon_claims: usize = coupons.iter().map(|c| c.claimed_by.len()).sum();
    let broadcast_count = state
        .db
        .collection::<OaBroadcastDoc>("oa_broadcasts")
        .count_documents(doc! { "oa_id": &oa.id })
        .await
        .unwrap_or(0);

    Ok(Json(json!({
        "oa": to_oa_dto(oa, None, Some(&auth.user_id)),
        "stats": {
            "follower_count": followers.len(),
            "active_chats_count": active_chats_count,
            "auto_reply_count": auto_reply_count,
            "active_coupon_count": coupons.len(),
            "total_coupon_claims": total_coupon_claims,
            "broadcast_count": broadcast_count,
            "tags": tags_vec,
        }
    })))
}

#[derive(Debug, Deserialize)]
pub struct ListOaChatsQuery {
    pub q: Option<String>,
    pub tag: Option<String>,
}

pub async fn list_oa_chats_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    Query(query): Query<ListOaChatsQuery>,
    State(state): State<AppState>,
) -> Result<Json<Vec<OaCustomerChatDto>>, ApiError> {
    let oa = require_oa_chat_staff(&state, &oa_id, &auth.user_id).await?;

    let followers: Vec<OaFollowerDoc> = state
        .db
        .collection::<OaFollowerDoc>("oa_followers")
        .find(doc! { "oa_id": &oa.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let convs: Vec<ConversationDoc> = state
        .db
        .collection::<ConversationDoc>("conversations")
        .find(doc! { "oa_id": &oa.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let conv_map: HashMap<String, ConversationDoc> =
        convs.into_iter().map(|c| (c.id.clone(), c)).collect();

    let customer_ids: Vec<String> = followers.iter().map(|f| f.user_id.clone()).collect();
    let users: Vec<UserDoc> = state
        .db
        .collection::<UserDoc>("users")
        .find(doc! { "_id": { "$in": &customer_ids } })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let user_map: HashMap<String, UserDoc> =
        users.into_iter().map(|u| (u.id.clone(), u)).collect();

    let filter_tag = query.tag.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let filter_q = query
        .q
        .as_deref()
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty());

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let matched_conv_ids: Vec<String> = conv_map.keys().cloned().collect();
    let mut unread_by_conv_sender: HashMap<(String, String), usize> = HashMap::new();
    if !matched_conv_ids.is_empty() {
        let pipeline = vec![
            doc! {
                "$match": {
                    "conversation_id": { "$in": &matched_conv_ids },
                    "is_unsent": false,
                    "read_by": { "$ne": &oa.bot_user_id },
                }
            },
            doc! {
                "$group": {
                    "_id": {
                        "conv_id": "$conversation_id",
                        "sender_id": "$sender_id",
                    },
                    "count": { "$sum": 1_i32 },
                }
            },
        ];
        if let Ok(mut agg_cursor) = msg_coll.aggregate(pipeline).await {
            while let Ok(Some(row_doc)) = agg_cursor.try_next().await {
                if let Ok(id_sub) = row_doc.get_document("_id") {
                    let cid = id_sub.get_str("conv_id").unwrap_or("").to_string();
                    let sid = id_sub.get_str("sender_id").unwrap_or("").to_string();
                    let cnt = row_doc
                        .get_i32("count")
                        .map(|n| n.max(0) as usize)
                        .or_else(|_| row_doc.get_i64("count").map(|n| n.max(0) as usize))
                        .unwrap_or(0);
                    if !cid.is_empty() && !sid.is_empty() {
                        unread_by_conv_sender.insert((cid, sid), cnt);
                    }
                }
            }
        }
    }

    let mut rows = Vec::new();
    for f in followers {
        if let Some(tag) = filter_tag {
            if !f.tags.iter().any(|t| t == tag) {
                continue;
            }
        }
        let Some(conv) = conv_map.get(&f.conversation_id) else {
            continue;
        };
        let Some(cust) = user_map.get(&f.user_id) else {
            continue;
        };
        if let Some(ref q) = filter_q {
            let matched = cust.display_name.to_lowercase().contains(q)
                || cust.bc_id.to_lowercase().contains(q)
                || cust.phone.to_lowercase().contains(q)
                || cust.email.to_lowercase().contains(q)
                || f.crm_note.to_lowercase().contains(q);
            if !matched {
                continue;
            }
        }
        let unread_for_oa = unread_by_conv_sender
            .get(&(conv.id.clone(), cust.id.clone()))
            .copied()
            .unwrap_or(0);

        rows.push(OaCustomerChatDto {
            conversation_id: conv.id.clone(),
            oa_id: oa.id.clone(),
            customer_id: cust.id.clone(),
            customer_name: cust.display_name.clone(),
            customer_avatar: cust.avatar_url.clone(),
            customer_bc_id: cust.bc_id.clone(),
            customer_phone: cust.phone.clone(),
            customer_email: cust.email.clone(),
            tags: f.tags,
            crm_note: f.crm_note,
            ai_paused: f.ai_paused,
            unread_for_oa,
            last_message: conv.last_message.clone(),
            updated_at: conv.updated_at.clone(),
        });
    }

    rows.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    Ok(Json(rows))
}

// =============================================================================
// CRM v1: customer list / detail / tag summary
// =============================================================================

const MAX_CRM_TAGS: usize = 10;

/// Trim, drop empty and the "all" placeholder, de-duplicate; more than MAX_CRM_TAGS is a 400.
fn normalize_tags<'a>(raw: impl IntoIterator<Item = &'a str>) -> Result<Vec<String>, ApiError> {
    let mut out: Vec<String> = Vec::new();
    for t in raw {
        let t = t.trim();
        if !t.is_empty() && t != "ทั้งหมด" && !out.iter().any(|x| x == t) {
            out.push(t.to_string());
        }
    }
    if out.len() > MAX_CRM_TAGS {
        return Err(ApiError::bad_request("เลือกแท็กได้ไม่เกิน 10 แท็ก"));
    }
    Ok(out)
}

fn parse_tags_param(raw: Option<&str>) -> Result<Vec<String>, ApiError> {
    normalize_tags(raw.unwrap_or("").split(','))
}

/// Escape regex metacharacters so user text is matched literally (no `regex` crate here).
fn escape_regex_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        if "\\^$.|?*+()[]{}".contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

fn bson_count(d: &bson::Document, key: &str) -> usize {
    d.get_i32(key)
        .map(|n| n.max(0) as usize)
        .or_else(|_| d.get_i64(key).map(|n| n.max(0) as usize))
        .unwrap_or(0)
}

#[derive(Debug, Default, Deserialize)]
struct CustomerUserRow {
    #[serde(default)]
    display_name: String,
    #[serde(default)]
    bc_id: String,
    #[serde(default)]
    avatar_url: String,
    #[serde(default)]
    phone: String,
    #[serde(default)]
    email: String,
}

#[derive(Debug, Default, Deserialize)]
struct CustomerConvRow {
    #[serde(default)]
    last_message: Option<LastMessageSummary>,
    #[serde(default)]
    updated_at: String,
}

#[derive(Debug, Deserialize)]
struct CustomerRow {
    user_id: String,
    #[serde(default)]
    conversation_id: String,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    crm_note: String,
    #[serde(default)]
    ai_paused: bool,
    #[serde(default)]
    is_following: bool,
    #[serde(default)]
    followed_at: String,
    #[serde(default)]
    u: CustomerUserRow,
    #[serde(default)]
    c: Option<CustomerConvRow>,
}

/// followers -> users -> (optional text filter) -> conversations, trimmed to the fields the DTO needs.
fn customer_stages(
    oa_id: &str,
    following: Option<bool>,
    tags: &[String],
    uid: Option<&str>,
    q: Option<&str>,
) -> Vec<bson::Document> {
    let mut m = doc! { "oa_id": oa_id };
    if let Some(f) = following {
        m.insert("is_following", f);
    }
    if !tags.is_empty() {
        m.insert("tags", doc! { "$in": tags });
    }
    if let Some(uid) = uid {
        m.insert("user_id", uid);
    }
    let mut stages = vec![
        doc! { "$match": m },
        doc! { "$lookup": { "from": "users", "localField": "user_id", "foreignField": "_id", "as": "u" } },
        doc! { "$unwind": "$u" },
    ];
    if let Some(q) = q {
        let rx = doc! { "$regex": escape_regex_literal(q), "$options": "i" };
        stages.push(doc! { "$match": { "$or": [
            { "u.display_name": rx.clone() },
            { "u.bc_id": rx.clone() },
            { "u.phone": rx.clone() },
            { "u.email": rx.clone() },
            { "crm_note": rx },
        ] } });
    }
    stages.push(doc! { "$lookup": { "from": "conversations", "localField": "conversation_id", "foreignField": "_id", "as": "c" } });
    stages.push(doc! { "$unwind": { "path": "$c", "preserveNullAndEmptyArrays": true } });
    stages.push(doc! { "$project": {
        "user_id": 1, "conversation_id": 1, "tags": 1, "crm_note": 1, "ai_paused": 1,
        "is_following": 1, "followed_at": 1,
        "u.display_name": 1, "u.bc_id": 1, "u.avatar_url": 1, "u.phone": 1, "u.email": 1,
        "c.last_message": 1, "c.updated_at": 1,
    } });
    stages
}

/// Unread customer messages per conversation for the given rows, in one aggregation.
async fn unread_for_rows(
    state: &AppState,
    oa: &OaAccountDoc,
    rows: &[CustomerRow],
) -> HashMap<String, usize> {
    let owner_by_conv: HashMap<&str, &str> = rows
        .iter()
        .map(|r| (r.conversation_id.as_str(), r.user_id.as_str()))
        .collect();
    let mut out = HashMap::new();
    if owner_by_conv.is_empty() {
        return out;
    }
    let conv_ids: Vec<&str> = owner_by_conv.keys().copied().collect();
    let pipeline = vec![
        doc! { "$match": {
            "conversation_id": { "$in": conv_ids },
            "is_unsent": false,
            "read_by": { "$ne": &oa.bot_user_id },
        } },
        doc! { "$group": {
            "_id": { "conv_id": "$conversation_id", "sender_id": "$sender_id" },
            "count": { "$sum": 1_i32 },
        } },
    ];
    let Ok(mut cursor) = state.db.collection::<MessageDoc>("messages").aggregate(pipeline).await else {
        return out;
    };
    while let Ok(Some(row)) = cursor.try_next().await {
        let Ok(id) = row.get_document("_id") else { continue };
        let (cid, sid) = (id.get_str("conv_id").unwrap_or(""), id.get_str("sender_id").unwrap_or(""));
        if owner_by_conv.get(cid) == Some(&sid) {
            out.insert(cid.to_string(), bson_count(&row, "count"));
        }
    }
    out
}

fn customer_to_json(oa_id: &str, r: &CustomerRow, unread: usize) -> Value {
    let dto = OaCustomerChatDto {
        conversation_id: r.conversation_id.clone(),
        oa_id: oa_id.to_string(),
        customer_id: r.user_id.clone(),
        customer_name: r.u.display_name.clone(),
        customer_avatar: r.u.avatar_url.clone(),
        customer_bc_id: r.u.bc_id.clone(),
        customer_phone: r.u.phone.clone(),
        customer_email: r.u.email.clone(),
        tags: r.tags.clone(),
        crm_note: r.crm_note.clone(),
        ai_paused: r.ai_paused,
        unread_for_oa: unread,
        last_message: r.c.as_ref().and_then(|c| c.last_message.clone()),
        updated_at: r.c.as_ref().map(|c| c.updated_at.clone()).unwrap_or_default(),
    };
    let mut v = serde_json::to_value(dto).unwrap_or_default();
    if let Some(obj) = v.as_object_mut() {
        obj.insert("is_following".into(), json!(r.is_following));
        obj.insert("followed_at".into(), json!(r.followed_at));
    }
    v
}

#[derive(Debug, Deserialize)]
pub struct ListOaCustomersQuery {
    pub q: Option<String>,
    pub tags: Option<String>,
    pub following: Option<String>,
    pub sort: Option<String>,
    pub page: Option<String>,
    pub limit: Option<String>,
}

fn parse_in_range(raw: Option<&str>, default: i64, min: i64, max: i64, msg: &str) -> Result<i64, ApiError> {
    let Some(s) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(default);
    };
    s.parse::<i64>()
        .ok()
        .filter(|n| (min..=max).contains(n))
        .ok_or_else(|| ApiError::bad_request(msg))
}

pub async fn list_oa_customers_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    Query(query): Query<ListOaCustomersQuery>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_chat_staff(&state, &oa_id, &auth.user_id).await?;
    let q = query.q.as_deref().map(str::trim).filter(|s| !s.is_empty());
    if q.is_some_and(|s| s.chars().count() > 64) {
        return Err(ApiError::bad_request("คำค้นหายาวเกิน 64 ตัวอักษร"));
    }
    let tags = parse_tags_param(query.tags.as_deref())?;
    let following = match query.following.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        None => None,
        Some("true") => Some(true),
        Some("false") => Some(false),
        Some(_) => return Err(ApiError::bad_request("ค่า following ต้องเป็น true หรือ false")),
    };
    let sort = match query.sort.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        None | Some("recent") => doc! { "c.updated_at": -1, "_id": 1 },
        Some("name") => doc! { "u.display_name": 1, "_id": 1 },
        Some("followed") => doc! { "followed_at": -1, "_id": 1 },
        Some(_) => return Err(ApiError::bad_request("sort ต้องเป็น recent, name หรือ followed")),
    };
    let page = parse_in_range(query.page.as_deref(), 1, 1, i64::from(i32::MAX), "page ต้องเป็นเลขตั้งแต่ 1")?;
    let limit = parse_in_range(query.limit.as_deref(), 30, 1, 100, "limit ต้องอยู่ระหว่าง 1 ถึง 100")?;

    let mut pipeline = customer_stages(&oa.id, following, &tags, None, q);
    pipeline.push(doc! { "$sort": sort });
    pipeline.push(doc! { "$facet": {
        "items": [{ "$skip": (page - 1) * limit }, { "$limit": limit }],
        "total": [{ "$count": "n" }],
    } });
    let mut cursor = state
        .db
        .collection::<bson::Document>("oa_followers")
        .aggregate(pipeline)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let facet = cursor
        .try_next()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .unwrap_or_default();

    let rows: Vec<CustomerRow> = facet
        .get_array("items")
        .map(|a| {
            a.iter()
                .filter_map(|b| b.as_document())
                .filter_map(|d| bson::from_document(d.clone()).ok())
                .collect()
        })
        .unwrap_or_default();
    let total = facet
        .get_array("total")
        .ok()
        .and_then(|a| a.first())
        .and_then(|b| b.as_document())
        .map(|d| bson_count(d, "n"))
        .unwrap_or(0);
    let unread = unread_for_rows(&state, &oa, &rows).await;
    let items: Vec<Value> = rows
        .iter()
        .map(|r| customer_to_json(&oa.id, r, unread.get(&r.conversation_id).copied().unwrap_or(0)))
        .collect();

    Ok(Json(json!({ "items": items, "total": total, "page": page, "limit": limit })))
}

fn customer_coupon_to_json(c: &OaCouponDoc, uid: &str) -> Value {
    json!({
        "id": c.id,
        "code": c.code,
        "title": c.title,
        "discount_text": c.discount_text,
        "expires_at": c.expires_at,
        "is_redeemed": c.redeemed_by.iter().any(|u| u == uid),
        "is_active": c.is_active,
    })
}

fn customer_broadcast_to_json(b: &OaBroadcastDoc) -> Value {
    json!({
        "id": b.id,
        "msg_type": b.msg_type,
        "content": b.content,
        "target_tags": b.target_tags,
        "coupon_id": b.coupon_id,
        "created_at": b.created_at,
    })
}

pub async fn get_oa_customer_handler(
    auth: AuthUser,
    Path((oa_id, uid)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_chat_staff(&state, &oa_id, &auth.user_id).await?;
    let mut cursor = state
        .db
        .collection::<bson::Document>("oa_followers")
        .aggregate(customer_stages(&oa.id, None, &[], Some(&uid), None))
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let row: CustomerRow = cursor
        .try_next()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .and_then(|d| bson::from_document(d).ok())
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลลูกค้าในร้านนี้"))?;
    let rows = [row];
    let unread = unread_for_rows(&state, &oa, &rows).await;
    let customer = customer_to_json(
        &oa.id,
        &rows[0],
        unread.get(&rows[0].conversation_id).copied().unwrap_or(0),
    );

    let coupons: Vec<OaCouponDoc> = state
        .db
        .collection::<OaCouponDoc>("oa_coupons")
        .find(doc! { "oa_id": &oa.id, "claimed_by": &uid })
        .sort(doc! { "created_at": -1 })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let bc_coll = state.db.collection::<OaBroadcastDoc>("oa_broadcasts");
    let bc_filter = doc! { "oa_id": &oa.id, "recipient_ids": &uid };
    let broadcasts: Vec<OaBroadcastDoc> = bc_coll
        .find(bc_filter.clone())
        .sort(doc! { "created_at": -1 })
        .limit(50)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let broadcasts_received = bc_coll
        .count_documents(bc_filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(json!({
        "customer": customer,
        "coupons": coupons.iter().map(|c| customer_coupon_to_json(c, &uid)).collect::<Vec<_>>(),
        "broadcasts": broadcasts.iter().map(customer_broadcast_to_json).collect::<Vec<_>>(),
        "stats": {
            "coupons_claimed": coupons.len(),
            "coupons_redeemed": coupons.iter().filter(|c| c.redeemed_by.contains(&uid)).count(),
            "broadcasts_received": broadcasts_received,
        },
    })))
}

#[derive(Debug, Deserialize)]
pub struct CustomerTagsQuery {
    pub tags: Option<String>,
}

pub async fn list_oa_customer_tags_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    Query(query): Query<CustomerTagsQuery>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_any_staff(&state, &oa_id, &auth.user_id).await?;
    let tags = parse_tags_param(query.tags.as_deref())?;
    let coll = state.db.collection::<bson::Document>("oa_followers");
    let following = doc! { "oa_id": &oa.id, "is_following": true };

    let mut cursor = coll
        .aggregate(vec![
            doc! { "$match": following.clone() },
            doc! { "$unwind": "$tags" },
            doc! { "$group": { "_id": "$tags", "count": { "$sum": 1_i32 } } },
            doc! { "$sort": { "count": -1, "_id": 1 } },
        ])
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut tag_rows = Vec::new();
    while let Some(row) = cursor.try_next().await.map_err(|e| ApiError::internal(e.to_string()))? {
        if let Ok(tag) = row.get_str("_id") {
            tag_rows.push(json!({ "tag": tag, "count": bson_count(&row, "count") }));
        }
    }

    let total_following = coll
        .count_documents(following.clone())
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let match_count = if tags.is_empty() {
        total_following
    } else {
        let mut f = following;
        f.insert("tags", doc! { "$in": &tags });
        coll.count_documents(f)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
    };

    Ok(Json(json!({
        "tags": tag_rows,
        "total_following": total_following,
        "match_count": match_count,
    })))
}

pub async fn get_oa_chat_messages_handler(
    auth: AuthUser,
    Path((oa_id, conv_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<Vec<MessageDto>>, ApiError> {
    let oa = require_oa_chat_staff(&state, &oa_id, &auth.user_id).await?;
    let conv = state
        .db
        .collection::<ConversationDoc>("conversations")
        .find_one(doc! { "_id": &conv_id, "oa_id": &oa.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบห้องแชทของลูกค้ารายนี้"))?;

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let _ = msg_coll
        .update_many(
            doc! {
                "conversation_id": &conv.id,
                "sender_id": { "$ne": &oa.bot_user_id },
                "read_by": { "$ne": &oa.bot_user_id },
            },
            doc! { "$addToSet": { "read_by": &oa.bot_user_id } },
        )
        .await;

    let mut msgs: Vec<MessageDoc> = msg_coll
        .find(doc! { "conversation_id": &conv.id, "is_unsent": false })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    msgs.sort_by(|a, b| a.created_at.cmp(&b.created_at));

    Ok(Json(msgs.into_iter().map(MessageDto::from).collect()))
}

#[derive(Debug, Deserialize)]
pub struct SendOaMessageRequest {
    pub msg_type: Option<String>,
    pub content: Option<String>,
    pub sticker_code: Option<String>,
    pub card_payload: Option<Value>,
    pub coupon_id: Option<String>,
}

pub async fn send_oa_chat_message_handler(
    auth: AuthUser,
    Path((oa_id, conv_id)): Path<(String, String)>,
    State(state): State<AppState>,
    Json(payload): Json<SendOaMessageRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    let oa = require_oa_chat_staff(&state, &oa_id, &auth.user_id).await?;
    let mut conv = state
        .db
        .collection::<ConversationDoc>("conversations")
        .find_one(doc! { "_id": &conv_id, "oa_id": &oa.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบห้องแชทของลูกค้ารายนี้"))?;

    let bot_user = get_oa_bot_user(&state, &oa).await;
    let mut msg_type = payload
        .msg_type
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("text")
        .to_string();
    let mut content = payload.content.unwrap_or_default().trim().to_string();
    let mut card_payload = payload.card_payload;

    if let Some(ref cid) = payload.coupon_id {
        if !cid.trim().is_empty() {
            let coupon = state
                .db
                .collection::<OaCouponDoc>("oa_coupons")
                .find_one(doc! { "_id": cid.trim(), "oa_id": &oa.id })
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?
                .ok_or_else(|| ApiError::not_found("ไม่พบคูปองที่ต้องการส่ง"))?;
            msg_type = "rich_card".to_string();
            if content.is_empty() {
                content = format!("🎟️ คูปองส่วนลด: {} ({})", coupon.title, coupon.discount_text);
            }
            card_payload = Some(json!({
                "kind": "oa_coupon",
                "oa_id": oa.id,
                "oa_name": oa.display_name,
                "coupon_id": coupon.id,
                "code": coupon.code,
                "title": coupon.title,
                "discount_text": coupon.discount_text,
                "description": coupon.description,
            }));
        }
    }

    if msg_type == "text" && content.is_empty() {
        return Err(ApiError::bad_request("กรุณาพิมพ์ข้อความที่จะตอบลูกค้า"));
    }

    let dto = insert_oa_bot_message_raw(
        &state,
        &mut conv,
        &bot_user,
        &msg_type,
        &content,
        card_payload,
    )
    .await
    .map_err(ApiError::internal)?;

    Ok(Json(dto))
}

#[derive(Debug, Deserialize)]
pub struct UpdateFollowerCrmRequest {
    pub tags: Option<Vec<String>>,
    pub crm_note: Option<String>,
    pub ai_paused: Option<bool>,
}

fn follower_to_json(f: &OaFollowerDoc) -> Value {
    json!({
        "id": f.id,
        "_id": f.id,
        "oa_id": f.oa_id,
        "user_id": f.user_id,
        "conversation_id": f.conversation_id,
        "tags": f.tags,
        "crm_note": f.crm_note,
        "ai_paused": f.ai_paused,
        "is_following": f.is_following,
        "followed_at": f.followed_at,
        "updated_at": f.updated_at,
    })
}

fn auto_reply_to_json(r: &OaAutoReplyRuleDoc) -> Value {
    json!({
        "id": r.id,
        "_id": r.id,
        "oa_id": r.oa_id,
        "keyword": r.keyword,
        "match_mode": r.match_mode,
        "reply_text": r.reply_text,
        "card_payload": r.card_payload,
        "is_active": r.is_active,
        "hit_count": r.hit_count,
        "created_at": r.created_at,
    })
}

fn coupon_to_json(c: &OaCouponDoc, viewer_id: &str) -> Value {
    let is_claimed = c.claimed_by.iter().any(|u| u == viewer_id);
    let is_redeemed = c.redeemed_by.iter().any(|u| u == viewer_id);
    let claims_count = c.claimed_by.len();
    let redeemed_count = c.redeemed_by.len();
    json!({
        "id": c.id,
        "_id": c.id,
        "oa_id": c.oa_id,
        "code": c.code,
        "title": c.title,
        "description": c.description,
        "discount_text": c.discount_text,
        "expires_at": c.expires_at,
        "max_claims": c.max_claims,
        "claimed_by": c.claimed_by,
        "redeemed_by": c.redeemed_by,
        "claims_count": claims_count,
        "redeemed_count": redeemed_count,
        "is_claimed": is_claimed,
        "is_redeemed": is_redeemed,
        "is_active": c.is_active,
        "created_at": c.created_at,
    })
}

fn broadcast_to_json(b: &OaBroadcastDoc) -> Value {
    json!({
        "id": b.id,
        "_id": b.id,
        "oa_id": b.oa_id,
        "target_tag": b.target_tag,
        "target_tags": b.target_tags,
        "msg_type": b.msg_type,
        "content": b.content,
        "card_payload": b.card_payload,
        "coupon_id": b.coupon_id,
        "recipient_count": b.recipient_count,
        "sent_by": b.sent_by,
        "created_at": b.created_at,
    })
}

pub async fn update_oa_follower_crm_handler(
    auth: AuthUser,
    Path((oa_id, customer_id)): Path<(String, String)>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateFollowerCrmRequest>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_chat_staff(&state, &oa_id, &auth.user_id).await?;
    let fol_coll = state.db.collection::<OaFollowerDoc>("oa_followers");
    let mut fol = fol_coll
        .find_one(doc! { "oa_id": &oa.id, "user_id": &customer_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลลูกค้าในร้านนี้"))?;

    if let Some(tags) = payload.tags {
        let mut clean = Vec::new();
        for t in tags {
            let trimmed = t.trim().to_string();
            if !trimmed.is_empty() && !clean.contains(&trimmed) {
                clean.push(trimmed);
            }
        }
        fol.tags = clean;
    }
    if let Some(note) = payload.crm_note {
        fol.crm_note = note.trim().to_string();
    }
    if let Some(paused) = payload.ai_paused {
        fol.ai_paused = paused;
    }
    fol.updated_at = Utc::now().to_rfc3339();

    fol_coll
        .replace_one(doc! { "_id": &fol.id }, &fol)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(follower_to_json(&fol)))
}

pub async fn list_oa_auto_replies_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<Value>>, ApiError> {
    let oa = require_oa_marketing_staff(&state, &oa_id, &auth.user_id).await?;
    let mut rules: Vec<OaAutoReplyRuleDoc> = state
        .db
        .collection::<OaAutoReplyRuleDoc>("oa_auto_replies")
        .find(doc! { "oa_id": &oa.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    rules.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(Json(rules.iter().map(auto_reply_to_json).collect()))
}

#[derive(Debug, Deserialize)]
pub struct CreateAutoReplyRequest {
    pub keyword: String,
    pub match_mode: Option<String>,
    pub reply_text: String,
    pub card_payload: Option<Value>,
    pub is_active: Option<bool>,
}

pub async fn create_oa_auto_reply_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<CreateAutoReplyRequest>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_marketing_staff(&state, &oa_id, &auth.user_id).await?;
    let keyword = payload.keyword.trim().to_string();
    let reply_text = payload.reply_text.trim().to_string();
    if keyword.is_empty() || reply_text.is_empty() {
        return Err(ApiError::bad_request(
            "กรุณากรอกคำค้นหา (Keyword) และข้อความตอบกลับอัตโนมัติ",
        ));
    }

    let rule = OaAutoReplyRuleDoc {
        id: Uuid::new_v4().to_string(),
        oa_id: oa.id,
        keyword,
        match_mode: match payload.match_mode.as_deref().map(str::trim) {
            Some("exact") => "exact".to_string(),
            _ => "contains".to_string(),
        },
        reply_text,
        card_payload: payload.card_payload,
        is_active: payload.is_active.unwrap_or(true),
        hit_count: 0,
        created_at: Utc::now().to_rfc3339(),
    };

    state
        .db
        .collection::<OaAutoReplyRuleDoc>("oa_auto_replies")
        .insert_one(&rule)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(auto_reply_to_json(&rule)))
}

pub async fn delete_oa_auto_reply_handler(
    auth: AuthUser,
    Path((oa_id, rule_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_marketing_staff(&state, &oa_id, &auth.user_id).await?;
    state
        .db
        .collection::<OaAutoReplyRuleDoc>("oa_auto_replies")
        .delete_one(doc! { "_id": &rule_id, "oa_id": &oa.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(json!({ "ok": true })))
}

pub async fn list_oa_coupons_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<Value>>, ApiError> {
    let _oa = state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .find_one(doc! { "_id": &oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบร้านค้า"))?;

    let mut coupons: Vec<OaCouponDoc> = state
        .db
        .collection::<OaCouponDoc>("oa_coupons")
        .find(doc! { "oa_id": &oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    coupons.sort_by(|a, b| b.created_at.cmp(&a.created_at));

    let items = coupons
        .iter()
        .map(|c| coupon_to_json(c, &auth.user_id))
        .collect();

    Ok(Json(items))
}

#[derive(Debug, Deserialize)]
pub struct CreateCouponRequest {
    pub code: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub discount_text: String,
    pub expires_at: Option<String>,
    pub max_claims: Option<u32>,
}

pub async fn create_oa_coupon_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<CreateCouponRequest>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_marketing_staff(&state, &oa_id, &auth.user_id).await?;
    let title = payload.title.trim().to_string();
    let code = payload.code.trim().to_uppercase();
    if title.is_empty() || code.is_empty() {
        return Err(ApiError::bad_request("กรุณากรอกชื่อคูปองและรหัสคูปอง"));
    }

    let coupon = OaCouponDoc {
        id: Uuid::new_v4().to_string(),
        oa_id: oa.id,
        code,
        title,
        description: payload.description.trim().to_string(),
        discount_text: if payload.discount_text.trim().is_empty() {
            "สิทธิพิเศษ".to_string()
        } else {
            payload.discount_text.trim().to_string()
        },
        expires_at: payload.expires_at,
        max_claims: payload.max_claims.unwrap_or(0),
        claimed_by: Vec::new(),
        redeemed_by: Vec::new(),
        is_active: true,
        created_at: Utc::now().to_rfc3339(),
    };

    state
        .db
        .collection::<OaCouponDoc>("oa_coupons")
        .insert_one(&coupon)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(coupon_to_json(&coupon, &auth.user_id)))
}

pub async fn claim_oa_coupon_handler(
    auth: AuthUser,
    Path((oa_id, coupon_id)): Path<(String, String)>,
    State(state): State<AppState>,
) -> Result<Json<Value>, ApiError> {
    let coll = state.db.collection::<OaCouponDoc>("oa_coupons");
    let mut coupon = coll
        .find_one(doc! { "_id": &coupon_id, "oa_id": &oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบคูปองส่วนลดที่ระบุ"))?;

    if !coupon.is_active {
        return Err(ApiError::bad_request("คูปองนี้ปิดการใช้งานแล้ว"));
    }

    let already = coupon.claimed_by.contains(&auth.user_id);
    if !already {
        if coupon.max_claims > 0 && coupon.claimed_by.len() >= coupon.max_claims as usize {
            return Err(ApiError::bad_request("คูปองนี้ถูกเก็บครบจำนวนสิทธิ์แล้ว"));
        }
        coupon.claimed_by.push(auth.user_id.clone());
        coll.update_one(
            doc! { "_id": &coupon.id },
            doc! { "$addToSet": { "claimed_by": &auth.user_id } },
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    }

    let coupon_val = coupon_to_json(&coupon, &auth.user_id);
    let mut out = coupon_val.clone();
    if let Some(obj) = out.as_object_mut() {
        obj.insert("coupon".to_string(), coupon_val);
        obj.insert("already_claimed".to_string(), json!(already));
        obj.insert("is_claimed".to_string(), json!(true));
    }
    Ok(Json(out))
}

#[derive(Debug, Deserialize)]
pub struct RedeemCouponRequest {
    pub user_id: Option<String>,
}

pub async fn redeem_oa_coupon_handler(
    auth: AuthUser,
    Path((oa_id, coupon_id)): Path<(String, String)>,
    State(state): State<AppState>,
    payload: Option<Json<RedeemCouponRequest>>,
) -> Result<Json<Value>, ApiError> {
    let oa = state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .find_one(doc! { "_id": &oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบร้านค้า"))?;

    let is_shop_staff = matches!(
        resolve_oa_staff_role(&oa, &auth.user_id).as_deref(),
        Some("owner" | "admin" | "agent")
    );
    let target_uid = payload
        .and_then(|p| p.0.user_id)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| auth.user_id.clone());

    if target_uid != auth.user_id && !is_shop_staff {
        return Err(ApiError::forbidden("เฉพาะแอดมินร้านเท่านั้นที่ยืนยันสิทธิ์ให้ลูกค้ารายอื่นได้"));
    }

    let coll = state.db.collection::<OaCouponDoc>("oa_coupons");
    let mut coupon = coll
        .find_one(doc! { "_id": &coupon_id, "oa_id": &oa_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบคูปองส่วนลด"))?;

    if !coupon.claimed_by.contains(&target_uid) {
        if is_shop_staff {
            coupon.claimed_by.push(target_uid.clone());
        } else {
            return Err(ApiError::bad_request("กรุณากดรับคูปองก่อนใช้สิทธิ์"));
        }
    }
    if !coupon.redeemed_by.contains(&target_uid) {
        coupon.redeemed_by.push(target_uid.clone());
    }

    coll.update_one(
        doc! { "_id": &coupon.id },
        doc! {
            "$addToSet": {
                "claimed_by": &target_uid,
                "redeemed_by": &target_uid,
            }
        },
    )
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;

    let coupon_val = coupon_to_json(&coupon, &target_uid);
    let mut out = coupon_val.clone();
    if let Some(obj) = out.as_object_mut() {
        obj.insert("coupon".to_string(), coupon_val);
        obj.insert("is_redeemed".to_string(), json!(true));
    }
    Ok(Json(out))
}

pub async fn list_oa_broadcasts_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<Value>>, ApiError> {
    let oa = require_oa_marketing_staff(&state, &oa_id, &auth.user_id).await?;
    let mut list: Vec<OaBroadcastDoc> = state
        .db
        .collection::<OaBroadcastDoc>("oa_broadcasts")
        .find(doc! { "oa_id": &oa.id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    list.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(Json(list.iter().map(broadcast_to_json).collect()))
}

#[derive(Debug, Deserialize)]
pub struct SendBroadcastRequest {
    pub target_tag: Option<String>,
    #[serde(default)]
    pub target_tags: Vec<String>,
    pub msg_type: Option<String>,
    pub content: Option<String>,
    pub card_payload: Option<Value>,
    pub coupon_id: Option<String>,
}

pub async fn send_oa_broadcast_handler(
    auth: AuthUser,
    Path(oa_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SendBroadcastRequest>,
) -> Result<Json<Value>, ApiError> {
    let oa = require_oa_marketing_staff(&state, &oa_id, &auth.user_id).await?;
    let bot_user = get_oa_bot_user(&state, &oa).await;

    let tags = normalize_tags(
        payload
            .target_tags
            .iter()
            .map(String::as_str)
            .chain(payload.target_tag.as_deref()),
    )?;

    let mut msg_type = payload
        .msg_type
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("text")
        .to_string();
    let mut content = payload.content.unwrap_or_default().trim().to_string();
    let mut card_payload = payload.card_payload;

    if let Some(ref cid) = payload.coupon_id {
        if !cid.trim().is_empty() {
            let coupon = state
                .db
                .collection::<OaCouponDoc>("oa_coupons")
                .find_one(doc! { "_id": cid.trim(), "oa_id": &oa.id })
                .await
                .map_err(|e| ApiError::internal(e.to_string()))?
                .ok_or_else(|| ApiError::not_found("ไม่พบคูปองที่ต้องการบรอดแคสต์"))?;
            msg_type = "rich_card".to_string();
            if content.is_empty() {
                content = format!("📢 โปรโมชั่นจาก {}: {} ({})", oa.display_name, coupon.title, coupon.discount_text);
            }
            card_payload = Some(json!({
                "kind": "oa_coupon",
                "oa_id": oa.id,
                "oa_name": oa.display_name,
                "coupon_id": coupon.id,
                "code": coupon.code,
                "title": coupon.title,
                "discount_text": coupon.discount_text,
                "description": coupon.description,
            }));
        }
    }

    if content.is_empty() && msg_type == "text" {
        return Err(ApiError::bad_request("กรุณากรอกข้อความที่จะบรอดแคสต์ให้ลูกค้า"));
    }

    let mut fol_filter = doc! { "oa_id": &oa.id, "is_following": true };
    if !tags.is_empty() {
        fol_filter.insert("tags", doc! { "$in": &tags });
    }

    let followers: Vec<OaFollowerDoc> = state
        .db
        .collection::<OaFollowerDoc>("oa_followers")
        .find(fol_filter)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let conv_ids: Vec<String> = followers
        .iter()
        .map(|f| f.conversation_id.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    let mut convs: Vec<ConversationDoc> = if conv_ids.is_empty() {
        vec![]
    } else {
        state
            .db
            .collection::<ConversationDoc>("conversations")
            .find(doc! { "_id": { "$in": &conv_ids }, "oa_id": &oa.id })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .try_collect()
            .await
            .unwrap_or_default()
    };

    let owner_by_conv: HashMap<&str, &str> = followers
        .iter()
        .map(|f| (f.conversation_id.as_str(), f.user_id.as_str()))
        .collect();
    let mut recipient_ids: Vec<String> = Vec::new();
    for conv in convs.iter_mut() {
        if insert_oa_bot_message_raw(
            &state,
            conv,
            &bot_user,
            &msg_type,
            &content,
            card_payload.clone(),
        )
        .await
        .is_ok()
        {
            if let Some(uid) = owner_by_conv.get(conv.id.as_str()) {
                recipient_ids.push(uid.to_string());
            }
        }
    }
    let delivered = recipient_ids.len();

    let broadcast = OaBroadcastDoc {
        id: Uuid::new_v4().to_string(),
        oa_id: oa.id.clone(),
        target_tag: tags.first().cloned(),
        target_tags: tags,
        recipient_ids,
        msg_type,
        content,
        card_payload,
        coupon_id: payload.coupon_id,
        recipient_count: delivered,
        sent_by: auth.user_id,
        created_at: Utc::now().to_rfc3339(),
    };

    state
        .db
        .collection::<OaBroadcastDoc>("oa_broadcasts")
        .insert_one(&broadcast)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(json!({
        "broadcast": broadcast_to_json(&broadcast),
        "recipient_count": delivered,
    })))
}

// =============================================================================
// Customer Message Hook (Notify Owner/Admins + Auto-Reply Rules + OA AI)
// =============================================================================

pub async fn handle_customer_message_to_oa(
    state: &AppState,
    conv: &mut ConversationDoc,
    msg: &MessageDoc,
) {
    let Some(ref oa_id) = conv.oa_id.clone() else {
        return;
    };
    let Ok(Some(oa)) = state
        .db
        .collection::<OaAccountDoc>("oa_accounts")
        .find_one(doc! { "_id": oa_id })
        .await
    else {
        return;
    };

    if msg.sender_id == oa.bot_user_id || msg.sender_id.starts_with("user_oa_") {
        return;
    }

    // 1. Live WebSocket alert + Push Notification to OA Owner & Inbox Staff (excluding marketers)
    let oa_recipients = oa_inbox_staff_ids(&oa);
    let msg_dto = MessageDto::from(msg.clone());
    state.ws_hub.broadcast_event(json!({
        "event": "oa_customer_message",
        "oa_id": oa.id,
        "conversation_id": conv.id,
        "customer_id": msg.sender_id,
        "message": &msg_dto,
    }));
    crate::push::notify_target_users(state, conv, &msg_dto, &oa_recipients);

    let has_media_attachment =
        msg.attachment.is_some() && matches!(msg.msg_type.as_str(), "image" | "file");
    if msg.is_unsent || (!has_media_attachment && (msg.msg_type != "text" || msg.content.trim().is_empty())) {
        return;
    }

    // 2. Check customer CRM AI pause flag
    let follower = state
        .db
        .collection::<OaFollowerDoc>("oa_followers")
        .find_one(doc! { "oa_id": &oa.id, "user_id": &msg.sender_id })
        .await
        .ok()
        .flatten();
    let ai_paused = follower.map(|f| f.ai_paused).unwrap_or(false);

    let bot_user = get_oa_bot_user(state, &oa).await;
    let normalized_text = msg.content.trim().to_lowercase();

    // 3. Evaluate active keyword Auto-Reply rules first (for text messages or captioned attachments)
    if !normalized_text.is_empty()
        && !normalized_text.starts_with("[ส่งรูปภาพ]")
        && !normalized_text.starts_with("[ไฟล์]")
    {
        let rules_coll = state.db.collection::<OaAutoReplyRuleDoc>("oa_auto_replies");
        let rules: Vec<OaAutoReplyRuleDoc> = match rules_coll
            .find(doc! { "oa_id": &oa.id, "is_active": true })
            .await
        {
            Ok(cursor) => cursor.try_collect().await.unwrap_or_default(),
            Err(_) => vec![],
        };

        for rule in rules {
            let kw = rule.keyword.trim().to_lowercase();
            if kw.is_empty() {
                continue;
            }
            let matched = if rule.match_mode == "exact" {
                normalized_text == kw
            } else {
                normalized_text.contains(&kw)
            };
            if matched {
                let _ = rules_coll
                    .update_one(
                        doc! { "_id": &rule.id },
                        doc! { "$inc": { "hit_count": 1_i64 } },
                    )
                    .await;
                let msg_type = if rule.card_payload.is_some() {
                    "rich_card"
                } else {
                    "text"
                };
                let _ = insert_oa_bot_message_raw(
                    state,
                    conv,
                    &bot_user,
                    msg_type,
                    &rule.reply_text,
                    rule.card_payload,
                )
                .await;
                return;
            }
        }
    }

    // 4. Fallback to OA AI Storefront Assistant if not paused & enabled
    if !ai_paused && oa.ai_enabled {
        let _ = maybe_trigger_oa_ai_reply(state, &oa, &bot_user, conv, msg).await;
    }
}
