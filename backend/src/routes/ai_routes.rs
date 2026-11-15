use axum::{extract::State, Json};
use bson::doc;
use chrono::Utc;
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, time::Duration};
use uuid::Uuid;

use crate::{
    auth::{AdminUser, ApiError, AuthUser},
    models::{
        mask_secret_key, AiSettingsDoc, AiSettingsDto, ConversationDoc, LastMessageSummary,
        MessageDoc, MessageDto, OaAccountDoc, OaCouponDoc, UserDoc,
    },
    AppState,
};

pub const DEFAULT_PERSONAL_AI_PROMPT: &str = "คุณคือ BC AI ผู้ช่วยส่วนตัวและเพื่อนคู่คิดประจำแอป BC Ai Chat ช่วยสรุปแชทกลุ่มเพื่อนและครอบครัว วางแผนทริปเที่ยว แนะนำร้านอร่อย ช่วยคำนวณหารค่าข้าว เกลาข้อความให้น่ารักสุภาพเป็นกันเอง และดูแลความเป็นส่วนตัวของผู้ใช้";

fn has_legacy_prompt_marker(prompt: &str) -> bool {
    // Matches legacy enterprise prompt markers so existing DB settings upgrade cleanly on boot
    prompt.contains("\u{0e2d}\u{0e07}\u{0e04}\u{0e4c}\u{0e01}\u{0e23}")
        || prompt.contains("\u{0e43}\u{0e1a}\u{0e40}\u{0e2a}\u{0e19}\u{0e2d}\u{0e23}\u{0e32}\u{0e04}\u{0e32}")
}

pub async fn get_effective_ai_settings(state: &AppState) -> Result<AiSettingsDoc, String> {
    let coll = state.db.collection::<AiSettingsDoc>("ai_settings");
    if let Some(mut doc_item) = coll
        .find_one(doc! { "_id": "default" })
        .await
        .map_err(|e| e.to_string())?
    {
        let mut changed = false;
        if !state.config.deepseek_api_key.is_empty()
            && !state.config.deepseek_api_key.starts_with("your_")
            && doc_item.api_key != state.config.deepseek_api_key
        {
            doc_item.api_key = state.config.deepseek_api_key.clone();
            changed = true;
        }
        if has_legacy_prompt_marker(&doc_item.system_prompt) {
            doc_item.system_prompt = DEFAULT_PERSONAL_AI_PROMPT.to_string();
            changed = true;
        }
        if changed {
            let _ = coll
                .update_one(
                    doc! { "_id": "default" },
                    doc! {
                        "$set": {
                            "api_key": &doc_item.api_key,
                            "system_prompt": &doc_item.system_prompt,
                        }
                    },
                )
                .await;
        }
        return Ok(doc_item);
    }

    let default_doc = AiSettingsDoc {
        id: "default".to_string(),
        enabled: true,
        api_key: state.config.deepseek_api_key.clone(),
        model: if state.config.deepseek_model.is_empty() {
            "deepseek-chat".to_string()
        } else {
            state.config.deepseek_model.clone()
        },
        base_url: if state.config.deepseek_base_url.is_empty() {
            "https://api.deepseek.com".to_string()
        } else {
            state.config.deepseek_base_url.clone()
        },
        system_prompt: DEFAULT_PERSONAL_AI_PROMPT.to_string(),
        auto_reply_in_groups: true,
        redact_confidential: true,
        updated_at: Utc::now().to_rfc3339(),
    };

    let _ = coll.insert_one(&default_doc).await;
    Ok(default_doc)
}

fn to_settings_dto(doc: &AiSettingsDoc) -> AiSettingsDto {
    let (has_api_key, masked_key) = mask_secret_key(&doc.api_key);
    AiSettingsDto {
        enabled: doc.enabled,
        has_api_key,
        masked_key,
        model: doc.model.clone(),
        base_url: doc.base_url.clone(),
        system_prompt: doc.system_prompt.clone(),
        auto_reply_in_groups: doc.auto_reply_in_groups,
        redact_confidential: doc.redact_confidential,
        updated_at: doc.updated_at.clone(),
    }
}

pub async fn get_ai_settings_handler(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<AiSettingsDto>, ApiError> {
    let settings = get_effective_ai_settings(&state)
        .await
        .map_err(ApiError::internal)?;
    Ok(Json(to_settings_dto(&settings)))
}

#[derive(Debug, Deserialize)]
pub struct UpdateAiSettingsRequest {
    pub enabled: Option<bool>,
    pub api_key: Option<String>,
    pub clear_api_key: Option<bool>,
    pub model: Option<String>,
    pub base_url: Option<String>,
    pub system_prompt: Option<String>,
    pub auto_reply_in_groups: Option<bool>,
    pub redact_confidential: Option<bool>,
}

pub async fn update_ai_settings_handler(
    _admin: AdminUser,
    State(state): State<AppState>,
    Json(payload): Json<UpdateAiSettingsRequest>,
) -> Result<Json<AiSettingsDto>, ApiError> {
    let mut settings = get_effective_ai_settings(&state)
        .await
        .map_err(ApiError::internal)?;

    if let Some(enabled) = payload.enabled {
        settings.enabled = enabled;
    }
    if payload.clear_api_key == Some(true) {
        settings.api_key = String::new();
    } else if let Some(ref key) = payload.api_key {
        let trimmed = key.trim();
        if !trimmed.is_empty() && !trimmed.contains("****") {
            settings.api_key = trimmed.to_string();
        }
    }
    if let Some(model) = payload.model {
        if !model.trim().is_empty() {
            settings.model = model.trim().to_string();
        }
    }
    if let Some(base_url) = payload.base_url {
        if !base_url.trim().is_empty() {
            settings.base_url = base_url.trim().trim_end_matches('/').to_string();
        }
    }
    if let Some(prompt) = payload.system_prompt {
        if !prompt.trim().is_empty() {
            settings.system_prompt = prompt.trim().to_string();
        }
    }
    if let Some(auto_group) = payload.auto_reply_in_groups {
        settings.auto_reply_in_groups = auto_group;
    }
    if let Some(redact) = payload.redact_confidential {
        settings.redact_confidential = redact;
    }
    settings.updated_at = Utc::now().to_rfc3339();

    let coll = state.db.collection::<AiSettingsDoc>("ai_settings");
    coll.replace_one(doc! { "_id": "default" }, &settings)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(to_settings_dto(&settings)))
}

const PLAIN_TEXT_RULE: &str = "รูปแบบคำตอบ: ข้อความธรรมดาสำหรับแอปแชทส่วนตัว ห้ามใช้ Markdown (ห้ามมี ** หรือ # และห้ามทำตาราง) ถ้าต้องแจกแจงให้ขึ้นบรรทัดใหม่แล้วขึ้นต้นด้วย \"- \" ตอบเป็นภาษาไทยที่เป็นกันเองและอบอุ่น เว้นแต่ถูกขอให้ใช้ภาษาอื่น และห้ามปนอักษรจีนหรือญี่ปุ่นเข้ามาในประโยคไทย";

fn to_plain_text(reply: &str) -> String {
    reply
        .trim()
        .lines()
        .filter_map(|raw_row| {
            let t = raw_row.trim();
            if t.starts_with('|') {
                let cells: Vec<&str> = t
                    .trim_matches('|')
                    .split('|')
                    .map(str::trim)
                    .filter(|c| !c.is_empty())
                    .collect();
                if cells.iter().all(|c| c.chars().all(|ch| ch == '-' || ch == ':')) {
                    return None;
                }
                return Some(format!("- {}", cells.join(" · ")));
            }
            Some(t.trim_start_matches('#').trim_start().to_string())
        })
        .collect::<Vec<_>>()
        .join("\n")
        .replace("**", "")
}

fn split_summary(text: &str) -> (String, Vec<String>, Vec<String>) {
    let (mut points, mut actions, mut decisions) = (Vec::new(), Vec::new(), Vec::new());
    let mut section = 0; // 0 key points, 1 action items, 2 agreements
    for raw_row in text.lines() {
        let t = raw_row.trim();
        let item = t
            .strip_prefix("- ")
            .or_else(|| t.strip_prefix("• "))
            .map(str::trim);
        if item.is_none() && t.chars().count() <= 40 {
            if t.contains("สิ่งที่ต้องทำ") {
                section = 1;
                continue;
            }
            if t.contains("ข้อตกลง") {
                section = 2;
                continue;
            }
            if t.contains("ประเด็นสำคัญ") {
                section = 0;
                continue;
            }
        }
        match (section, item) {
            (1, Some(i)) if i != "ไม่มี" => actions.push(i.to_string()),
            (2, Some(i)) if i != "ไม่มี" => decisions.push(i.to_string()),
            (0, _) if !t.is_empty() => points.push(t.to_string()),
            _ => {}
        }
    }
    (points.join("\n"), actions, decisions)
}

const SUMMARY_PROMPT: &str = "สรุปบทสนทนาและนัดหมายในห้องแชทนี้ แบ่งเป็น 3 หัวข้อ ใช้ชื่อหัวข้อตามนี้ บรรทัดละหัวข้อ:\nประเด็นสำคัญ:\nสิ่งที่ต้องทำต่อ:\nข้อตกลงร่วมกัน:\nใต้แต่ละหัวข้อเขียนเป็นข้อ ข้อละบรรทัด ขึ้นต้นด้วย \"- \" ข้อในสิ่งที่ต้องทำต่อให้ใส่ชื่อเพื่อนหรือสมาชิกไว้ท้ายข้อในวงเล็บ ถ้าหัวข้อใดไม่มีให้เขียน \"- ไม่มี\"";

fn history_text(m: &MessageDoc, redact_confidential: bool) -> String {
    if redact_confidential && m.confidential_pin.is_some() {
        "[ข้อความลับส่วนตัวล็อก PIN - ปกปิดข้อมูลอัตโนมัติ]".to_string()
    } else if m.sender_id == "user_ai" || m.sender_id.starts_with("user_oa_") {
        m.content.clone()
    } else {
        format!("{}: {}{}", m.sender_name, m.content, task_note(m))
    }
}

fn task_note(m: &MessageDoc) -> String {
    match (m.task_status.as_deref(), m.accepted_by.as_deref()) {
        (Some("accepted"), Some(by)) => format!(" [สถานะ: {} รับดูแลแล้ว]", by),
        (Some("done"), Some(by)) => format!(" [สถานะ: {} ทำเสร็จแล้ว]", by),
        _ => String::new(),
    }
}

pub async fn call_deepseek_brain(
    state: &AppState,
    custom_system_prompt: Option<&str>,
    user_prompt: &str,
    history: &[MessageDoc],
) -> (String, String, bool) {
    let settings = match get_effective_ai_settings(state).await {
        Ok(s) => s,
        Err(_) => {
            let fallback = generate_smart_context_reply(user_prompt, history);
            return (fallback, "deepseek-chat".to_string(), false);
        }
    };

    let (has_key, _) = mask_secret_key(&settings.api_key);
    let sys_prompt = format!(
        "{}\n\n{}",
        custom_system_prompt.unwrap_or(&settings.system_prompt),
        PLAIN_TEXT_RULE
    );

    if has_key && settings.enabled {
        let mut api_messages = vec![json!({
            "role": "system",
            "content": sys_prompt,
        })];

        for m in history.iter().rev().take(15).rev() {
            if m.is_unsent {
                continue;
            }
            let content_text = history_text(m, settings.redact_confidential);
            let role = if m.sender_id == "user_ai" || m.sender_id.starts_with("user_oa_") {
                "assistant"
            } else {
                "user"
            };
            api_messages.push(json!({
                "role": role,
                "content": content_text,
            }));
        }

        api_messages.push(json!({
            "role": "user",
            "content": user_prompt,
        }));

        let endpoint = if settings.base_url.ends_with("/v1") {
            format!("{}/chat/completions", settings.base_url)
        } else {
            format!("{}/v1/chat/completions", settings.base_url)
        };

        let req_body = json!({
            "model": settings.model,
            "messages": api_messages,
            "temperature": 0.4,
            "max_tokens": 1024,
        });

        if let Ok(resp) = state
            .minio
            .http
            .post(&endpoint)
            .timeout(Duration::from_secs(20))
            .header("Authorization", format!("Bearer {}", settings.api_key))
            .header("Content-Type", "application/json")
            .json(&req_body)
            .send()
            .await
        {
            if resp.status().is_success() {
                if let Ok(val) = resp.json::<Value>().await {
                    if let Some(reply) = val
                        .get("choices")
                        .and_then(|c| c.get(0))
                        .and_then(|c| c.get("message"))
                        .and_then(|m| m.get("content"))
                        .and_then(|t| t.as_str())
                    {
                        return (to_plain_text(reply), settings.model, true);
                    }
                }
            }
        }
    }

    let smart_reply = generate_smart_context_reply(user_prompt, history);
    (smart_reply, settings.model, false)
}

fn generate_smart_context_reply(user_prompt: &str, history: &[MessageDoc]) -> String {
    let clean_prompt = user_prompt
        .replace("@bc.ai", "")
        .replace("@BC.AI", "")
        .replace("@ai", "")
        .replace("@AI", "")
        .replace("/ai", "")
        .replace("บีซีเอไอ", "")
        .trim()
        .to_string();

    let lower = clean_prompt.to_lowercase();

    let active_msgs: Vec<&MessageDoc> = history
        .iter()
        .filter(|m| !m.is_unsent && m.sender_id != "user_ai")
        .collect();

    let mut participants: Vec<String> = Vec::new();
    let mut files_mentioned: Vec<String> = Vec::new();
    for m in &active_msgs {
        if !participants.contains(&m.sender_name) {
            participants.push(m.sender_name.clone());
        }
        if let Some(ref att) = m.attachment {
            files_mentioned.push(format!("{} (แชร์โดย {})", att.file_name, m.sender_name));
        }
    }

    if lower.contains("สรุป") || lower.contains("summary") || lower.contains("นัดหมาย") {
        let mut lines = Vec::new();
        lines.push("ประเด็นสำคัญ:".to_string());
        if active_msgs.is_empty() {
            lines.push("- ยังไม่มีข้อความสนทนาก่อนหน้าในห้องนี้".to_string());
        } else {
            lines.push(format!(
                "- สมาชิกที่ร่วมคุย ({} คน): {}",
                participants.len(),
                participants.join(", ")
            ));
            for m in active_msgs.iter().rev().take(4).rev() {
                let snippet: String = m.content.chars().take(90).collect();
                lines.push(format!("- {}: {}", m.sender_name, snippet));
            }
            if !files_mentioned.is_empty() {
                lines.push(format!(
                    "- รูปและไฟล์ในคลังถาวร: {}",
                    files_mentioned.join(", ")
                ));
            }
        }
        lines.push("สิ่งที่ต้องทำต่อ:".to_string());
        lines.push("- เช็กเวลานัดหมายและดูรูปความทรงจำในอัลบั้มถาวรของห้อง (ทุกคน)".to_string());
        lines.push("ข้อตกลงร่วมกัน:".to_string());
        lines.push("- นัดเจอกันตามแผนที่คุยไว้ผ่าน BC Ai Chat".to_string());
        return lines.join("\n");
    }

    if lower.contains("ทริป")
        || lower.contains("เที่ยว")
        || lower.contains("หาร")
        || lower.contains("กินข้าว")
        || lower.contains("คาเฟ่")
    {
        return "ไอเดียจัดทริปและมื้ออร่อยจาก BC AI ผู้ช่วยส่วนตัว:\n- แนะนำแวะคาเฟ่บรรยากาศร่มรื่นช่วงบ่าย แล้วต่อมื้อเย็นริมน้ำกับแก๊งเพื่อน\n- ใช้เครื่องมือ \"หารค่าข้าวกับเพื่อน\" หรือสร้างโพลโหวตร้านในห้องนี้ได้เลย\n- รูปถ่ายทริปทั้งหมดอัปโหลดเข้าอัลบั้มห้อง เก็บความละเอียดเต็มถาวรบน MinIO ไม่มีวันหมดอายุครับ".to_string();
    }

    if lower.contains("ความลับ") || lower.contains("ส่งผิด") || lower.contains("ลบ") || lower.contains("pin") {
        return "คำแนะนำความเป็นส่วนตัวจาก BC AI ผู้ช่วยส่วนตัว:\n- ก่อนส่งรหัสผ่านหรือข้อความสำคัญ ให้เปิดโหมดข้อความลับส่วนตัวล็อก PIN 4 หลัก\n- หากส่งรูปหรือไฟล์ผิดห้อง สามารถกดลบทำลายไฟล์ทันที ระบบจะลบออกจาก MinIO และลบออกจากหน้าจอทุกคนทันทีครับ".to_string();
    }

    let recent_context = active_msgs
        .last()
        .map(|m| format!(" (จากข้อความล่าสุดของ {}: \"{}\")", m.sender_name, m.content))
        .unwrap_or_default();

    format!(
        "🤖 BC AI ผู้ช่วยส่วนตัว ขอตอบเรื่อง \"{}\" ครับ:\n- สรุปจากบทสนทนาในห้อง{}\n- แนะนำเพิ่มเติม: กดปุ่มโพลเพื่อนัดเลือกร้านอาหาร สร้างอีเวนต์นัดเจอ เก็บรูปลงอัลบั้มถาวร หรือพิมพ์ @ai สรุป เพื่อให้ผมช่วยสรุปคุยย้อนหลังได้เลยครับ",
        if clean_prompt.is_empty() {
            "ชวนคุยและดูแลนัดหมายในห้องแชท"
        } else {
            &clean_prompt
        },
        recent_context
    )
}

#[derive(Debug, Deserialize)]
pub struct SummarizeRequest {
    pub conversation_id: String,
    pub post_to_chat: Option<bool>,
}

pub async fn summarize_conversation_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<SummarizeRequest>,
) -> Result<Json<Value>, ApiError> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    let mut conv = crate::routes::chat_routes::require_member(
        &state,
        payload.conversation_id.trim(),
        &auth.user_id,
    )
    .await?;

    let cursor = msg_coll
        .find(doc! { "conversation_id": &conv.id, "is_unsent": false })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut history: Vec<MessageDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    history.sort_by(|a, b| a.created_at.cmp(&b.created_at));

    let (summary_text, model, live_api) =
        call_deepseek_brain(&state, None, SUMMARY_PROMPT, &history).await;
    let (points, mut action_items, mut decisions) = split_summary(&summary_text);
    let parsed = !action_items.is_empty() && !points.is_empty();
    let summary = if parsed { points } else { summary_text.clone() };

    let mut participants = Vec::new();
    for m in &history {
        if m.sender_id != "user_ai" && !participants.contains(&m.sender_name) {
            participants.push(m.sender_name.clone());
        }
        if !parsed {
            if let Some(ref att) = m.attachment {
                action_items.push(format!(
                    "เปิดดูไฟล์หรือรูป '{}' ที่แชร์โดย {}",
                    att.file_name, m.sender_name
                ));
            }
        }
    }

    if action_items.is_empty() {
        action_items.push("เช็กเวลานัดหมายและอัลบั้มรูปในห้องแชท".to_string());
    }

    if decisions.is_empty() {
        if let Some(ref pinned) = conv.pinned_message {
            decisions.push(format!("ข้อความปักหมุดของห้อง: {}", pinned.content));
        }
    }

    if payload.post_to_chat == Some(true) {
        let _ = insert_ai_message(&state, &mut conv, &summary_text).await;
    }

    Ok(Json(json!({
        "conversation_id": conv.id,
        "conversation_name": conv.name,
        "summary": summary,
        "action_items": action_items,
        "decisions": decisions,
        "participants": participants,
        "message_count": history.len(),
        "model": model,
        "live_api": live_api,
    })))
}

#[derive(Debug, Deserialize)]
pub struct AssistRequest {
    pub conversation_id: Option<String>,
    pub prompt: Option<String>,
    pub mode: Option<String>, // "polish" | "casual" | "suggest_reply" | "translate_en" | "action_plan"
}

pub async fn assist_message_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<AssistRequest>,
) -> Result<Json<Value>, ApiError> {
    let mode = payload
        .mode
        .unwrap_or_else(|| "polish".to_string())
        .to_lowercase();
    let raw_prompt = payload.prompt.unwrap_or_default().trim().to_string();

    let mut history: Vec<MessageDoc> = Vec::new();
    if let Some(ref cid) = payload.conversation_id {
        if !cid.trim().is_empty() {
            crate::routes::chat_routes::require_member(&state, cid.trim(), &auth.user_id).await?;
            let msg_coll = state.db.collection::<MessageDoc>("messages");
            if let Ok(cursor) = msg_coll
                .find(doc! { "conversation_id": cid.trim(), "is_unsent": false })
                .await
            {
                if let Ok(mut docs) = cursor.try_collect::<Vec<MessageDoc>>().await {
                    docs.sort_by(|a, b| a.created_at.cmp(&b.created_at));
                    history = docs;
                }
            }
        }
    }

    let settings = get_effective_ai_settings(&state)
        .await
        .map_err(ApiError::internal)?;
    let (has_key, _) = mask_secret_key(&settings.api_key);

    let (result_text, suggestions, live_api) = if has_key && settings.enabled {
        let instruction = match mode.as_str() {
            "formal" | "polish" | "polite" => format!(
                "ช่วยเกลาข้อความต่อไปนี้ให้น่ารัก สุภาพ และเป็นธรรมชาติสำหรับคุยกับเพื่อนหรือครอบครัว (ส่งคืนเฉพาะข้อความที่เกลาแล้ว): {}",
                raw_prompt
            ),
            "casual" | "friendly" => format!(
                "ช่วยแต่งข้อความชวนคุยแบบเป็นกันเอง สดใส สำหรับส่งในกลุ่มเพื่อนสนิท (ส่งคืนเฉพาะข้อความที่แต่งแล้ว): {}",
                raw_prompt
            ),
            "translate_en" => format!(
                "แปลข้อความต่อไปนี้เป็นภาษาอังกฤษที่เป็นธรรมชาติสำหรับแชทคุยกับเพื่อนในชีวิตประจำวัน: {}",
                raw_prompt
            ),
            "suggest_reply" => {
                let me = state
                    .db
                    .collection::<UserDoc>("users")
                    .find_one(doc! { "_id": &auth.user_id })
                    .await
                    .ok()
                    .flatten()
                    .map(|u| u.display_name)
                    .unwrap_or_else(|| "ฉัน".to_string());
                format!(
                    "ร่างข้อความที่ {me} จะพิมพ์ตอบข้อความล่าสุดในห้องนี้ เขียนในมุมของ {me} เอง สั้น น่ารัก เป็นกันเอง 3 แบบ แต่ละแบบขึ้นต้นด้วย \"- \" ส่งคืนเฉพาะ 3 ข้อความนี้ ไม่ต้องเกริ่นและไม่ต้องถามกลับ"
                )
            }
            "action_plan" => format!(
                "ช่วยสรุปแผนเที่ยวหรือนัดหมายเป็นข้อๆ อ่านง่ายจากหัวข้อต่อไปนี้: {}",
                raw_prompt
            ),
            _ => raw_prompt.clone(),
        };

        let (reply, _, is_live) = call_deepseek_brain(&state, None, &instruction, &history).await;
        if is_live {
            (reply, Vec::new(), true)
        } else {
            let suggs = vec![reply.clone()];
            (reply, suggs, false)
        }
    } else {
        match mode.as_str() {
            "formal" | "polish" | "polite" | "casual" | "friendly" => {
                let polished = if raw_prompt.is_empty() {
                    "เสาร์นี้ถ้าว่างแวะมาเจอกันกินข้าวและนั่งคุยชิลๆ ด้วยกันนะครับ".to_string()
                } else {
                    format!(
                        "{} ถ้าสะดวกช่วงไหนทักบอกในแชทได้เลยนะ ขอบคุณมากจ้า 😊",
                        raw_prompt
                    )
                };
                let suggs = vec![
                    polished.clone(),
                    format!("แวะมาบอกข่าวดี: {} แล้วเจอกันตามนัดนะ!", raw_prompt),
                    format!("ฝากเช็กหน่อยน้า: {} ดูรูปในอัลบั้มห้องได้เลยจ้า", raw_prompt),
                ];
                (polished, suggs, false)
            }
            "translate_en" => {
                let translated = if raw_prompt.is_empty() {
                    "Hey everyone! Feel free to check out our trip photos in the shared album anytime.".to_string()
                } else {
                    format!(
                        "Hey! Just a quick note about \"{}\" — let me know what works best for you!",
                        raw_prompt
                    )
                };
                let suggs = vec![translated.clone()];
                (translated, suggs, false)
            }
            "suggest_reply" => {
                let last_sender = history
                    .iter()
                    .rev()
                    .find(|m| m.sender_id != "user_ai")
                    .map(|m| m.sender_name.clone())
                    .unwrap_or_else(|| "เพื่อน".to_string());
                let s1 = format!("ได้เลยจ้า {} เดี๋ยวเจอกันตามที่นัดไว้นะ!", last_sender);
                let s2 = "เห็นรูปในอัลบั้มแล้วสวยมากเลย ขอบคุณที่แชร์เข้ากลุ่มนะ 😊".to_string();
                let s3 = "จัดไปเลย! เดี๋ยวช่วยดูแผนเที่ยวและโหวตร้านอาหารในโพลให้จ้า".to_string();
                (s1.clone(), vec![s1, s2, s3], false)
            }
            _ => {
                let (reply, _, _) = call_deepseek_brain(&state, None, &raw_prompt, &history).await;
                let suggs = vec![
                    "โอเคเลย เดี๋ยวจัดการให้เรียบร้อยจ้า".to_string(),
                    "ขอบคุณมากนะ เปิดดูรูปในคลังไฟล์เรียบร้อยแล้ว!".to_string(),
                ];
                (reply, suggs, false)
            }
        }
    };

    Ok(Json(json!({
        "mode": mode,
        "result": result_text,
        "suggestions": suggestions,
        "model": settings.model,
        "live_api": live_api,
    })))
}

pub async fn insert_bot_message(
    state: &AppState,
    conv: &mut ConversationDoc,
    bot_user: &UserDoc,
    ai_text: &str,
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
        msg_type: "text".to_string(),
        content: ai_text.to_string(),
        sticker_code: None,
        attachment: None,
        card_payload: None,
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
        msg_type: "text".to_string(),
        content: ai_text.chars().take(120).collect(),
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

pub async fn insert_ai_message(
    state: &AppState,
    conv: &mut ConversationDoc,
    ai_text: &str,
) -> Result<MessageDto, String> {
    let users_coll = state.db.collection::<UserDoc>("users");

    let ai_user = users_coll
        .find_one(doc! { "_id": "user_ai" })
        .await
        .ok()
        .flatten()
        .unwrap_or_else(|| UserDoc {
            id: "user_ai".to_string(),
            email: "ai@bcaichat.local".to_string(),
            phone: String::new(),
            phone_verified: false,
            email_verified: false,
            display_name: "🤖 BC AI ผู้ช่วยส่วนตัว".to_string(),
            bc_id: "@bc.ai".to_string(),
            avatar_url: "https://ui-avatars.com/api/?name=BC+AI&background=812920&color=fff&bold=true".to_string(),
            status_message: "ผู้ช่วย AI ส่วนตัวสำหรับทุกคนและทุกกลุ่ม".to_string(),
            qr_token: "BCQR_DEEPSEEK_AI".to_string(),
            role: "admin".to_string(),
            department: "AI ส่วนตัว".to_string(),
            job_title: "เพื่อนคู่คิด & ผู้ช่วยประจำแชท".to_string(),
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
        });

    insert_bot_message(state, conv, &ai_user, ai_text).await
}

pub async fn maybe_trigger_oa_ai_reply(
    state: &AppState,
    oa: &OaAccountDoc,
    bot_user: &UserDoc,
    conv: &mut ConversationDoc,
    trigger_msg: &MessageDoc,
) -> Option<MessageDto> {
    if !oa.ai_enabled
        || trigger_msg.is_unsent
        || trigger_msg.sender_id == bot_user.id
        || trigger_msg.sender_id.starts_with("user_oa_")
    {
        return None;
    }

    let coupons_coll = state.db.collection::<OaCouponDoc>("oa_coupons");
    let coupons: Vec<OaCouponDoc> = match coupons_coll
        .find(doc! { "oa_id": &oa.id, "is_active": true })
        .await
    {
        Ok(cursor) => cursor.try_collect().await.unwrap_or_default(),
        Err(_) => vec![],
    };
    let coupon_info = if coupons.is_empty() {
        "คูปองที่เปิดใช้งาน: ยังไม่มีคูปองพิเศษในขณะนี้".to_string()
    } else {
        let items: Vec<String> = coupons
            .iter()
            .take(5)
            .map(|c| format!("- {} (รหัส: {}, ส่วนลด: {})", c.title, c.code, c.discount_text))
            .collect();
        format!("คูปองส่วนลดที่ลูกค้ากดรับได้:\n{}", items.join("\n"))
    };

    let custom_prompt = format!(
        "คุณคือผู้ช่วยแอดมินร้าน \"{}\" (@{}) หมวดหมู่ \"{}\"\nรายละเอียดร้าน: {}\nเวลาทำการ: {}\nข้อมูลสินค้า/บริการ/โปรโมชั่นของร้าน: {}\n{}\nคำสั่ง: ตอบคำถามลูกค้าด้วยภาษาไทยที่สุภาพ กระชับ จริงใจ หากไม่มีข้อมูลราคาเฉพาะให้แจ้งลูกค้าว่าส่งข้อความถึงแอดมินร้านแล้ว",
        oa.display_name, oa.handle, oa.category, oa.bio, oa.business_hours, oa.ai_knowledge_prompt, coupon_info
    );

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let mut history: Vec<MessageDoc> = match msg_coll
        .find(doc! { "conversation_id": &conv.id, "is_unsent": false })
        .await
    {
        Ok(cursor) => cursor.try_collect().await.unwrap_or_default(),
        Err(_) => vec![],
    };
    history.sort_by(|a, b| a.created_at.cmp(&b.created_at));

    let (ai_reply_text, _, is_live) =
        call_deepseek_brain(state, Some(&custom_prompt), &trigger_msg.content, &history).await;

    let final_reply = if is_live {
        ai_reply_text
    } else {
        let knowledge_hint = if !oa.ai_knowledge_prompt.trim().is_empty() {
            oa.ai_knowledge_prompt.trim()
        } else if !oa.greeting_message.trim().is_empty() {
            oa.greeting_message.trim()
        } else {
            &oa.bio
        };
        format!(
            "สวัสดีค่ะ จากร้าน {} (@{})\n{}\n\nข้อความของท่านถูกส่งถึงทีมแอดมินร้านแล้ว จะรีบตอบกลับโดยเร็วที่สุดค่ะ",
            oa.display_name, oa.handle, knowledge_hint
        )
    };

    insert_bot_message(state, conv, bot_user, &final_reply).await.ok()
}

pub async fn maybe_trigger_ai_reply(
    state: &AppState,
    conv: &mut ConversationDoc,
    trigger_msg: &MessageDoc,
) -> Option<MessageDto> {
    if trigger_msg.sender_id == "user_ai" || trigger_msg.is_unsent {
        return None;
    }

    let is_direct_with_ai =
        conv.member_ids.len() == 2 && conv.member_ids.iter().any(|id| id == "user_ai");
    let lower_content = trigger_msg.content.to_lowercase();
    let is_mentioned = lower_content.contains("@ai")
        || lower_content.contains("@bc.ai")
        || lower_content.contains("/ai")
        || lower_content.contains("บีซีเอไอ")
        || trigger_msg.mentions.iter().any(|m| {
            let lm = m.to_lowercase();
            lm == "user_ai" || lm == "@ai" || lm == "@bc.ai"
        });

    if !is_direct_with_ai && !is_mentioned {
        return None;
    }

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let mut history: Vec<MessageDoc> = match msg_coll
        .find(doc! { "conversation_id": &conv.id, "is_unsent": false })
        .await
    {
        Ok(cursor) => cursor.try_collect().await.unwrap_or_default(),
        Err(_) => vec![],
    };
    history.sort_by(|a, b| a.created_at.cmp(&b.created_at));

    let (ai_reply_text, _, _) =
        call_deepseek_brain(state, None, &trigger_msg.content, &history).await;

    insert_ai_message(state, conv, &ai_reply_text).await.ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_sections_become_points_actions_and_agreements() {
        let text = "ประเด็นสำคัญ:\n- นัดกินหมูกระทะวันเสาร์\n- แวะคาเฟ่ถ่ายรูปตอนบ่าย\nสิ่งที่ต้องทำต่อ:\n- จองโต๊ะริมน้ำ (สมชาย)\n- เตรียมกล้องฟิล์ม (แพร)\nข้อตกลงร่วมกัน:\n- ไม่มี";
        let (points, actions, decisions) = split_summary(text);
        assert_eq!(points, "- นัดกินหมูกระทะวันเสาร์\n- แวะคาเฟ่ถ่ายรูปตอนบ่าย");
        assert_eq!(
            actions,
            vec!["จองโต๊ะริมน้ำ (สมชาย)", "เตรียมกล้องฟิล์ม (แพร)"]
        );
        assert!(decisions.is_empty());
    }

    #[test]
    fn summary_without_headings_has_no_action_items() {
        let (points, actions, _) =
            split_summary("ห้องนี้คุยเรื่องทริปวันหยุด\n- ออกเดินทางเช้าวันเสาร์");
        assert!(actions.is_empty());
        assert!(points.contains("วันเสาร์"));
    }

    #[test]
    fn ai_history_shows_task_status_without_ai_prefix() {
        let mut m: MessageDoc = serde_json::from_value(serde_json::json!({
            "_id": "m1", "conversation_id": "c1", "sender_id": "u1", "sender_name": "สมชาย", "sender_avatar": "",
            "type": "text", "content": "ฝากซื้อน้ำแข็ง 2 ถุง", "created_at": "2026-11-06T00:00:00Z"
        }))
        .unwrap();
        assert_eq!(task_note(&m), "");
        m.task_status = Some("accepted".into());
        m.accepted_by = Some("ก้อง".into());
        assert!(task_note(&m).contains("ก้อง รับดูแลแล้ว"));
        m.task_status = Some("done".into());
        assert!(task_note(&m).contains("ก้อง ทำเสร็จแล้ว"));
    }
}
