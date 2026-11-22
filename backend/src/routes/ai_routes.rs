use axum::{extract::State, Json};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use bson::doc;
use chrono::Utc;
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    time::{Duration, Instant},
};
use uuid::Uuid;

use crate::{
    auth::{AdminUser, ApiError, AuthUser},
    config::AppConfig,
    doc_extract::{
        canonical_image_mime, classify_attachment, extract_document_text, is_pdf_attachment,
        AttachmentKind, MAX_DOCUMENT_DOWNLOAD_BYTES, MAX_IMAGE_VISION_BYTES, SCANNED_PDF_NOTE,
    },
    models::{
        mask_secret_key, AiAnalyzeMessageResponse, AiConnectionTestResponse, AiSettingsDoc,
        AiSettingsDto, AttachmentInfo, ConversationDoc, FileDoc, LastMessageSummary, MessageDoc,
        MessageDto, OaAccountDoc, OaCouponDoc, UserDoc,
    },
    AppState,
};

pub const DEFAULT_PERSONAL_AI_PROMPT: &str = "คุณคือ BC AI ผู้ช่วยส่วนตัวและเพื่อนคู่คิดประจำแอป BC Ai Chat ช่วยสรุปแชทกลุ่มเพื่อนและครอบครัว อ่านและวิเคราะห์รูปภาพหรือเอกสารแนบ วางแผนทริปเที่ยว แนะนำร้านอร่อย ช่วยคำนวณหารค่าข้าว เกลาข้อความให้น่ารักสุภาพเป็นกันเอง และดูแลความเป็นส่วนตัวของผู้ใช้";
pub const DEFAULT_AI_BASE_URL: &str = "https://ollama.com";
pub const DEFAULT_AI_MODEL: &str = "deepseek-v4.1-flash";
pub const PUBLIC_AI_BRAND_MODEL: &str = "BC AI";

// Token-saving auto-routing budgets
const AI_MAX_TOKENS_TEST: u32 = 96;
const AI_MAX_TOKENS_SUGGEST_REPLY: u32 = 220;
const AI_MAX_TOKENS_ASSIST: u32 = 384;
const AI_MAX_TOKENS_CHAT: u32 = 512;
const AI_MAX_TOKENS_ANALYZE: u32 = 768;

const AI_HISTORY_LIMIT_CHAT: i64 = 12;
const AI_HISTORY_LIMIT_SUMMARIZE: i64 = 25;
const AI_HISTORY_ENTRY_MAX_CHARS: usize = 500;
const AI_ROOM_MAX_IMAGES: usize = 2;
const AI_ROOM_MAX_DOCS: usize = 2;

fn resolve_default_base_url(cfg: &AppConfig) -> String {
    let trimmed = cfg.ai_base_url.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        DEFAULT_AI_BASE_URL.to_string()
    } else {
        trimmed.to_string()
    }
}

fn resolve_default_model(cfg: &AppConfig) -> String {
    let trimmed = cfg.ai_model.trim();
    if trimmed.is_empty() {
        DEFAULT_AI_MODEL.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Strips a trailing `/api` segment so `https://ollama.com/api` never becomes `/api/api/chat`.
pub(crate) fn normalize_ollama_root(base_url: &str) -> String {
    let trimmed = base_url.trim().trim_end_matches('/');
    if trimmed.to_ascii_lowercase().ends_with("/api") {
        trimmed[..trimmed.len() - 4].trim_end_matches('/').to_string()
    } else {
        trimmed.to_string()
    }
}

pub(crate) fn is_ollama_cloud_url(base_url: &str) -> bool {
    let lower = base_url.trim().to_ascii_lowercase();
    let rest = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
        .unwrap_or(&lower);
    let authority = rest.split('/').next().unwrap_or("");
    let host = authority
        .rsplit('@')
        .next()
        .unwrap_or("")
        .split(':')
        .next()
        .unwrap_or("");
    host == "ollama.com" || host.ends_with(".ollama.com")
}

pub(crate) fn is_system_ai_ready(cfg: &AppConfig) -> bool {
    if !cfg.ai_enabled {
        return false;
    }
    let base = resolve_default_base_url(cfg);
    let model = resolve_default_model(cfg);
    if base.is_empty() || model.is_empty() {
        return false;
    }
    if is_ollama_cloud_url(&base) && cfg.ai_api_key.trim().is_empty() {
        return false;
    }
    true
}

fn has_legacy_prompt_marker(prompt: &str) -> bool {
    // Matches legacy enterprise prompt markers so existing DB settings upgrade cleanly on boot
    prompt.contains("\u{0e2d}\u{0e07}\u{0e04}\u{0e4c}\u{0e01}\u{0e23}")
        || prompt.contains("\u{0e43}\u{0e1a}\u{0e40}\u{0e2a}\u{0e19}\u{0e2d}\u{0e23}\u{0e32}\u{0e04}\u{0e32}")
}

/// Scrubs any legacy credentials/URLs/models stored in MongoDB so server `.env` is the sole secret source.
pub(crate) fn scrub_legacy_ai_settings_doc(doc_item: &mut AiSettingsDoc) -> bool {
    let mut changed = false;
    if !doc_item.api_key.is_empty() {
        doc_item.api_key.clear();
        changed = true;
    }
    if !doc_item.base_url.is_empty() {
        doc_item.base_url.clear();
        changed = true;
    }
    if !doc_item.model.is_empty() {
        doc_item.model.clear();
        changed = true;
    }
    if doc_item.system_prompt.trim().is_empty()
        || has_legacy_prompt_marker(&doc_item.system_prompt)
    {
        doc_item.system_prompt = DEFAULT_PERSONAL_AI_PROMPT.to_string();
        changed = true;
    }
    if changed {
        doc_item.updated_at = Utc::now().to_rfc3339();
    }
    changed
}

pub async fn get_effective_ai_settings(state: &AppState) -> Result<AiSettingsDoc, String> {
    let coll = state.db.collection::<AiSettingsDoc>("ai_settings");
    if let Some(mut doc_item) = coll
        .find_one(doc! { "_id": "default" })
        .await
        .map_err(|e| e.to_string())?
    {
        if scrub_legacy_ai_settings_doc(&mut doc_item) {
            let _ = coll
                .update_one(
                    doc! { "_id": "default" },
                    doc! {
                        "$set": {
                            "api_key": "",
                            "base_url": "",
                            "model": "",
                            "system_prompt": &doc_item.system_prompt,
                            "updated_at": &doc_item.updated_at,
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
        api_key: String::new(),
        model: String::new(),
        base_url: String::new(),
        system_prompt: DEFAULT_PERSONAL_AI_PROMPT.to_string(),
        auto_reply_in_groups: true,
        redact_confidential: true,
        proactive_game_invites: true,
        updated_at: Utc::now().to_rfc3339(),
    };

    let _ = coll.insert_one(&default_doc).await;
    Ok(default_doc)
}

fn to_settings_dto(doc: &AiSettingsDoc, cfg: &AppConfig) -> AiSettingsDto {
    AiSettingsDto {
        enabled: doc.enabled,
        managed_by_system: true,
        system_ready: is_system_ai_ready(cfg),
        system_prompt: doc.system_prompt.clone(),
        auto_reply_in_groups: doc.auto_reply_in_groups,
        redact_confidential: doc.redact_confidential,
        proactive_game_invites: doc.proactive_game_invites,
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
    Ok(Json(to_settings_dto(&settings, &state.config)))
}

#[derive(Debug, Deserialize)]
pub struct UpdateAiSettingsRequest {
    pub enabled: Option<bool>,
    pub system_prompt: Option<String>,
    pub auto_reply_in_groups: Option<bool>,
    pub redact_confidential: Option<bool>,
    pub proactive_game_invites: Option<bool>,
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
    if let Some(proactive) = payload.proactive_game_invites {
        settings.proactive_game_invites = proactive;
    }
    settings.api_key.clear();
    settings.base_url.clear();
    settings.model.clear();
    settings.updated_at = Utc::now().to_rfc3339();

    let coll = state.db.collection::<AiSettingsDoc>("ai_settings");
    coll.replace_one(doc! { "_id": "default" }, &settings)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(to_settings_dto(&settings, &state.config)))
}

fn apply_optional_bearer(req: reqwest::RequestBuilder, api_key: &str) -> reqwest::RequestBuilder {
    let (has_key, _) = mask_secret_key(api_key);
    if has_key {
        req.header("Authorization", format!("Bearer {}", api_key.trim()))
    } else {
        req
    }
}

/// Tests the server-managed `.env` AI engine (ignores any client body; never leaks URL/model/key).
pub async fn test_ai_connection_handler(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Json<AiConnectionTestResponse>, ApiError> {
    if !is_system_ai_ready(&state.config) {
        return Ok(Json(AiConnectionTestResponse {
            ok: false,
            latency_ms: 0,
            reply: None,
            error: Some(
                "ระบบ BC AI ยังไม่ได้เปิดใช้งานหรือยังไม่พร้อมเชื่อมต่อ กรุณาติดต่อผู้ดูแลระบบเซิร์ฟเวอร์"
                    .to_string(),
            ),
        }));
    }

    let base_url = resolve_default_base_url(&state.config);
    let model = resolve_default_model(&state.config);
    let api_key = state.config.ai_api_key.as_str();

    let messages = vec![
        AiChatMessage::text(
            "system",
            "คุณคือผู้ช่วย BC AI ของแอป BC Ai Chat ตอบเป็นภาษาไทยที่สุภาพสั้นๆ 1 ประโยค ห้ามใช้ Markdown",
        ),
        AiChatMessage::text(
            "user",
            "ทักทายสั้นๆ 1 ประโยค เพื่อยืนยันว่าระบบพร้อมใช้งาน",
        ),
    ];

    let started = Instant::now();
    let timeout = Duration::from_secs(state.config.ai_timeout_secs);

    match execute_local_ai_request(
        &state.minio.http,
        &base_url,
        &model,
        api_key,
        &messages,
        timeout,
        AI_MAX_TOKENS_TEST,
    )
    .await
    {
        Ok(out) => Ok(Json(AiConnectionTestResponse {
            ok: true,
            latency_ms: started.elapsed().as_millis() as u64,
            reply: Some(out.reply),
            error: None,
        })),
        Err(err) => Ok(Json(AiConnectionTestResponse {
            ok: false,
            latency_ms: started.elapsed().as_millis() as u64,
            reply: None,
            error: Some(err),
        })),
    }
}

const PLAIN_TEXT_RULE: &str = "รูปแบบคำตอบ: ข้อความธรรมดาสำหรับแอปแชทส่วนตัว ห้ามใช้ Markdown (ห้ามมี ** หรือ # และห้ามทำตาราง) ถ้าต้องแจกแจงให้ขึ้นบรรทัดใหม่แล้วขึ้นต้นด้วย \"- \" ตอบเป็นภาษาไทยที่เป็นกันเองและอบอุ่น กระชับได้ใจความ เว้นแต่ถูกขอให้ใช้ภาษาอื่น และห้ามปนอักษรจีนหรือญี่ปุ่นเข้ามาในประโยคไทย";

pub(crate) fn strip_think_blocks(input: &str) -> String {
    // ASCII lowercasing preserves 1-to-1 UTF-8 byte offsets for Thai & Unicode text.
    let lower = input.to_ascii_lowercase();
    let mut out = String::with_capacity(input.len());
    let mut cursor = 0usize;

    while let Some(rel_open) = lower[cursor..].find("<think>") {
        let open_idx = cursor + rel_open;
        out.push_str(&input[cursor..open_idx]);
        let after_open = open_idx + "<think>".len();
        if let Some(rel_close) = lower[after_open..].find("</think>") {
            cursor = after_open + rel_close + "</think>".len();
        } else {
            // Unclosed trailing <think>... block: drop everything from <think> to end.
            cursor = input.len();
            break;
        }
    }

    if cursor < input.len() {
        out.push_str(&input[cursor..]);
    }

    // Handle orphan closing </think> when a model omits the opening tag.
    let out_lower = out.to_ascii_lowercase();
    if let Some(close_idx) = out_lower.rfind("</think>") {
        return out[close_idx + "</think>".len()..].trim().to_string();
    }

    out.trim().to_string()
}

pub(crate) fn to_plain_text(reply: &str) -> String {
    let cleaned = strip_think_blocks(reply);
    cleaned
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
                if cells
                    .iter()
                    .all(|c| c.chars().all(|ch| ch == '-' || ch == ':'))
                {
                    return None;
                }
                return Some(format!("- {}", cells.join(" · ")));
            }
            Some(t.trim_start_matches('#').trim_start().to_string())
        })
        .collect::<Vec<_>>()
        .join("\n")
        .replace("**", "")
        .trim()
        .to_string()
}

fn strip_list_prefix(line: &str) -> Option<&str> {
    let t = line.trim();
    for prefix in ["- ", "• ", "* ", "– ", "— "] {
        if let Some(rest) = t.strip_prefix(prefix) {
            return Some(rest.trim());
        }
    }
    let digit_len = t.bytes().take_while(|b| b.is_ascii_digit()).count();
    if digit_len > 0 && digit_len <= 2 {
        let after_digits = &t[digit_len..];
        if let Some(rest) = after_digits
            .strip_prefix(". ")
            .or_else(|| after_digits.strip_prefix(") "))
            .or_else(|| after_digits.strip_prefix('.'))
            .or_else(|| after_digits.strip_prefix(')'))
        {
            return Some(rest.trim());
        }
    }
    None
}

fn trim_wrapping_quotes(s: &str) -> &str {
    let t = s.trim();
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        t[1..t.len() - 1].trim()
    } else {
        t
    }
}

pub(crate) fn parse_suggest_reply_bullets(reply: &str) -> Vec<String> {
    let mut prefixed = Vec::new();
    let mut plain = Vec::new();

    for raw_line in reply.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(rest) = strip_list_prefix(trimmed) {
            let item = trim_wrapping_quotes(rest);
            if !item.is_empty() && !prefixed.iter().any(|s| s == item) {
                prefixed.push(item.to_string());
                if prefixed.len() == 3 {
                    break;
                }
            }
        } else {
            let item = trim_wrapping_quotes(trimmed);
            if !item.is_empty() && !plain.iter().any(|s| s == item) {
                plain.push(item.to_string());
            }
        }
    }

    if !prefixed.is_empty() {
        prefixed
    } else {
        plain.into_iter().take(3).collect()
    }
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

pub(crate) fn is_message_confidential_for_ai(m: &MessageDoc, redact_confidential: bool) -> bool {
    redact_confidential && (m.is_confidential || m.confidential_pin.is_some())
}

fn truncate_chars(raw: &str, max_chars: usize) -> String {
    if raw.chars().count() <= max_chars {
        raw.to_string()
    } else {
        let cut: String = raw.chars().take(max_chars).collect();
        format!("{cut}...")
    }
}

pub(crate) fn history_text(m: &MessageDoc, redact_confidential: bool) -> String {
    if is_message_confidential_for_ai(m, redact_confidential) {
        "[ข้อความลับส่วนตัวล็อก PIN - ปกปิดข้อมูลอัตโนมัติ]".to_string()
    } else if m.sender_id == "user_ai" || m.sender_id.starts_with("user_oa_") {
        truncate_chars(&m.content, AI_HISTORY_ENTRY_MAX_CHARS)
    } else {
        let att_suffix = m
            .attachment
            .as_ref()
            .map(|a| format!(" [แนบไฟล์: {}]", a.file_name))
            .unwrap_or_default();
        let line = format!("{}: {}{}{}", m.sender_name, m.content, att_suffix, task_note(m));
        truncate_chars(&line, AI_HISTORY_ENTRY_MAX_CHARS)
    }
}

fn task_note(m: &MessageDoc) -> String {
    match (m.task_status.as_deref(), m.accepted_by.as_deref()) {
        (Some("accepted"), Some(by)) => format!(" [สถานะ: {} รับดูแลแล้ว]", by),
        (Some("done"), Some(by)) => format!(" [สถานะ: {} ทำเสร็จแล้ว]", by),
        _ => String::new(),
    }
}

async fn fetch_recent_messages(
    state: &AppState,
    conversation_id: &str,
    limit: i64,
) -> Result<Vec<MessageDoc>, String> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let cursor = msg_coll
        .find(doc! { "conversation_id": conversation_id, "is_unsent": false })
        .sort(doc! { "created_at": -1 })
        .limit(limit)
        .await
        .map_err(|e| e.to_string())?;
    let mut history: Vec<MessageDoc> = cursor.try_collect().await.map_err(|e| e.to_string())?;
    history.reverse();
    Ok(history)
}

#[derive(Debug, Clone)]
pub(crate) struct AiImageInput {
    pub mime_type: String,
    pub base64_data: String,
}

#[derive(Debug, Clone)]
pub(crate) struct AiChatMessage {
    pub role: String,
    pub content: String,
    pub images: Vec<AiImageInput>,
}

impl AiChatMessage {
    pub(crate) fn text(role: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: role.into(),
            content: content.into(),
            images: Vec::new(),
        }
    }

    pub(crate) fn with_images(
        role: impl Into<String>,
        content: impl Into<String>,
        images: Vec<AiImageInput>,
    ) -> Self {
        Self {
            role: role.into(),
            content: content.into(),
            images,
        }
    }
}

pub(crate) fn build_ollama_messages_json(messages: &[AiChatMessage]) -> Vec<Value> {
    messages
        .iter()
        .map(|m| {
            if m.images.is_empty() {
                json!({
                    "role": m.role,
                    "content": m.content,
                })
            } else {
                let imgs: Vec<&str> = m.images.iter().map(|i| i.base64_data.as_str()).collect();
                json!({
                    "role": m.role,
                    "content": m.content,
                    "images": imgs,
                })
            }
        })
        .collect()
}

pub(crate) fn build_openai_messages_json(messages: &[AiChatMessage]) -> Vec<Value> {
    messages
        .iter()
        .map(|m| {
            if m.images.is_empty() {
                json!({
                    "role": m.role,
                    "content": m.content,
                })
            } else {
                let mut parts = vec![json!({
                    "type": "text",
                    "text": m.content,
                })];
                for img in &m.images {
                    parts.push(json!({
                        "type": "image_url",
                        "image_url": {
                            "url": format!("data:{};base64,{}", img.mime_type, img.base64_data),
                        }
                    }));
                }
                json!({
                    "role": m.role,
                    "content": parts,
                })
            }
        })
        .collect()
}

fn strip_images_from_messages(messages: &[AiChatMessage]) -> Vec<AiChatMessage> {
    messages
        .iter()
        .map(|m| AiChatMessage::text(m.role.clone(), m.content.clone()))
        .collect()
}

fn is_vision_unsupported_error(err_lower: &str) -> bool {
    err_lower.contains("image")
        || err_lower.contains("vision")
        || err_lower.contains("multimodal")
        || err_lower.contains("does not support")
}

const NON_VISION_MODEL_NOTE: &str = "\n\n(หมายเหตุ: ระบบ BC AI กำลังทำงานในโหมดข้อความเท่านั้น ยังไม่สามารถอ่านรายละเอียดจากรูปภาพได้ชั่วคราว)";

#[derive(Debug)]
struct LiveAiCallOutput {
    reply: String,
}

async fn call_ollama_chat_endpoint(
    http: &reqwest::Client,
    endpoint: &str,
    model: &str,
    api_key: &str,
    messages: &[Value],
    timeout: Duration,
    max_tokens: u32,
    include_think_flag: bool,
) -> Result<reqwest::Response, reqwest::Error> {
    let mut req_body = json!({
        "model": model,
        "messages": messages,
        "stream": false,
        "options": {
            "temperature": 0.4,
            "num_predict": max_tokens,
        }
    });
    if include_think_flag {
        if let Some(obj) = req_body.as_object_mut() {
            obj.insert("think".to_string(), json!(false));
        }
    }
    apply_optional_bearer(
        http.post(endpoint)
            .timeout(timeout)
            .header("Content-Type", "application/json")
            .json(&req_body),
        api_key,
    )
    .send()
    .await
}

fn extract_ollama_raw(val: &Value) -> Option<String> {
    let raw = val
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(|t| t.as_str())?;
    let cleaned = strip_think_blocks(raw);
    (!cleaned.is_empty()).then_some(cleaned)
}

fn extract_openai_raw(val: &Value) -> Option<String> {
    let raw = val
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|t| t.as_str())?;
    let cleaned = strip_think_blocks(raw);
    (!cleaned.is_empty()).then_some(cleaned)
}

fn extract_ollama_reply(val: &Value) -> Option<String> {
    let raw = val
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(|t| t.as_str())?;
    let cleaned = to_plain_text(raw);
    (!cleaned.is_empty()).then_some(cleaned)
}

fn extract_openai_reply(val: &Value) -> Option<String> {
    let raw = val
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|t| t.as_str())?;
    let cleaned = to_plain_text(raw);
    (!cleaned.is_empty()).then_some(cleaned)
}

async fn execute_local_ai_request(
    http: &reqwest::Client,
    base_url: &str,
    model: &str,
    api_key: &str,
    messages: &[AiChatMessage],
    timeout: Duration,
    max_tokens: u32,
) -> Result<LiveAiCallOutput, String> {
    execute_local_ai_request_inner(http, base_url, model, api_key, messages, timeout, max_tokens, true)
        .await
}

async fn execute_local_ai_request_inner(
    http: &reqwest::Client,
    base_url: &str,
    model: &str,
    api_key: &str,
    messages: &[AiChatMessage],
    timeout: Duration,
    max_tokens: u32,
    plain_text: bool,
) -> Result<LiveAiCallOutput, String> {
    let extract_ollama = if plain_text {
        extract_ollama_reply
    } else {
        extract_ollama_raw
    };
    let extract_openai = if plain_text {
        extract_openai_reply
    } else {
        extract_openai_raw
    };
    let base = base_url.trim().trim_end_matches('/');
    let ollama_root = normalize_ollama_root(base);
    let force_openai = base.to_ascii_lowercase().ends_with("/v1");
    let has_images = messages.iter().any(|m| !m.images.is_empty());

    if !force_openai {
        let ollama_endpoint = format!("{ollama_root}/api/chat");
        let ollama_messages = build_ollama_messages_json(messages);
        let resp = call_ollama_chat_endpoint(
            http,
            &ollama_endpoint,
            model,
            api_key,
            &ollama_messages,
            timeout,
            max_tokens,
            true,
        )
        .await
        .map_err(|e| {
            if e.is_timeout() {
                "ระบบ BC AI ใช้เวลาตอบกลับนานเกินกำหนด กรุณาลองใหม่อีกครั้ง".to_string()
            } else {
                "ไม่สามารถเชื่อมต่อระบบ BC AI ได้ชั่วคราว กรุณาลองใหม่อีกครั้ง".to_string()
            }
        })?;

        let status = resp.status();
        if status.is_success() {
            let val = resp
                .json::<Value>()
                .await
                .map_err(|_| "ไม่สามารถอ่านคำตอบจากระบบ BC AI ได้".to_string())?;
            if let Some(reply) = extract_ollama(&val) {
                return Ok(LiveAiCallOutput { reply });
            }
            return Err("ระบบ BC AI ไม่ส่งข้อความตอบกลับ".to_string());
        }

        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(
                "ระบบ BC AI ยังไม่ได้รับอนุญาตเชื่อมต่อ กรุณาติดต่อผู้ดูแลระบบเซิร์ฟเวอร์".to_string(),
            );
        }

        let err_body = resp.text().await.unwrap_or_default();
        let err_lower = err_body.to_ascii_lowercase();

        // Retry once without `think` flag on builds that reject the field.
        if status == reqwest::StatusCode::BAD_REQUEST && err_lower.contains("think") {
            if let Ok(retry_resp) = call_ollama_chat_endpoint(
                http,
                &ollama_endpoint,
                model,
                api_key,
                &ollama_messages,
                timeout,
                max_tokens,
                false,
            )
            .await
            {
                if retry_resp.status().is_success() {
                    if let Ok(val) = retry_resp.json::<Value>().await {
                        if let Some(reply) = extract_ollama(&val) {
                            return Ok(LiveAiCallOutput { reply });
                        }
                    }
                }
            }
        }

        // Graceful fallback when a non-vision model rejects image inputs with HTTP 400.
        if has_images
            && status == reqwest::StatusCode::BAD_REQUEST
            && is_vision_unsupported_error(&err_lower)
        {
            let text_only = build_ollama_messages_json(&strip_images_from_messages(messages));
            if let Ok(retry_resp) = call_ollama_chat_endpoint(
                http,
                &ollama_endpoint,
                model,
                api_key,
                &text_only,
                timeout,
                max_tokens,
                true,
            )
            .await
            {
                if retry_resp.status().is_success() {
                    if let Ok(val) = retry_resp.json::<Value>().await {
                        if let Some(reply) = extract_ollama(&val) {
                            return Ok(LiveAiCallOutput {
                                reply: if plain_text {
                                    format!("{reply}{NON_VISION_MODEL_NOTE}")
                                } else {
                                    reply
                                },
                            });
                        }
                    }
                }
            }
        }

        if status == reqwest::StatusCode::NOT_FOUND
            && err_lower.contains("model")
            && err_lower.contains("not found")
        {
            return Err(
                "ระบบ BC AI ยังไม่พร้อมให้บริการชั่วคราว กรุณาติดต่อผู้ดูแลระบบเซิร์ฟเวอร์".to_string(),
            );
        }

        if status != reqwest::StatusCode::NOT_FOUND
            && status != reqwest::StatusCode::METHOD_NOT_ALLOWED
        {
            return Err("ระบบ BC AI ไม่สามารถตอบกลับได้ชั่วคราว กรุณาลองใหม่อีกครั้ง".to_string());
        }
    }

    let openai_endpoint = if force_openai {
        format!("{base}/chat/completions")
    } else {
        format!("{ollama_root}/v1/chat/completions")
    };
    let openai_messages = build_openai_messages_json(messages);
    let req_body = json!({
        "model": model,
        "messages": openai_messages,
        "temperature": 0.4,
        "max_tokens": max_tokens,
    });

    let resp = apply_optional_bearer(
        http.post(&openai_endpoint)
            .timeout(timeout)
            .header("Content-Type", "application/json")
            .json(&req_body),
        api_key,
    )
    .send()
    .await
    .map_err(|e| {
        if e.is_timeout() {
            "ระบบ BC AI ใช้เวลาตอบกลับนานเกินกำหนด กรุณาลองใหม่อีกครั้ง".to_string()
        } else {
            "ไม่สามารถเชื่อมต่อระบบ BC AI ได้ชั่วคราว กรุณาลองใหม่อีกครั้ง".to_string()
        }
    })?;

    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err(
            "ระบบ BC AI ยังไม่ได้รับอนุญาตเชื่อมต่อ กรุณาติดต่อผู้ดูแลระบบเซิร์ฟเวอร์".to_string(),
        );
    }

    if !status.is_success() {
        let err_body = resp.text().await.unwrap_or_default();
        let err_lower = err_body.to_ascii_lowercase();
        if has_images
            && status == reqwest::StatusCode::BAD_REQUEST
            && is_vision_unsupported_error(&err_lower)
        {
            let text_only_body = json!({
                "model": model,
                "messages": build_openai_messages_json(&strip_images_from_messages(messages)),
                "temperature": 0.4,
                "max_tokens": max_tokens,
            });
            if let Ok(retry_resp) = apply_optional_bearer(
                http.post(&openai_endpoint)
                    .timeout(timeout)
                    .header("Content-Type", "application/json")
                    .json(&text_only_body),
                api_key,
            )
            .send()
            .await
            {
                if retry_resp.status().is_success() {
                    if let Ok(val) = retry_resp.json::<Value>().await {
                        if let Some(reply) = extract_openai(&val) {
                            return Ok(LiveAiCallOutput {
                                reply: if plain_text {
                                    format!("{reply}{NON_VISION_MODEL_NOTE}")
                                } else {
                                    reply
                                },
                            });
                        }
                    }
                }
            }
        }
        return Err("ระบบ BC AI ไม่สามารถตอบกลับได้ชั่วคราว กรุณาลองใหม่อีกครั้ง".to_string());
    }

    let val = resp
        .json::<Value>()
        .await
        .map_err(|_| "ไม่สามารถอ่านคำตอบจากระบบ BC AI ได้".to_string())?;
    let reply =
        extract_openai(&val).ok_or_else(|| "ระบบ BC AI ไม่ส่งข้อความตอบกลับ".to_string())?;

    Ok(LiveAiCallOutput { reply })
}

async fn load_or_extract_document_text(
    state: &AppState,
    att: &AttachmentInfo,
) -> Result<String, String> {
    let files_coll = state.db.collection::<FileDoc>("files");
    if let Ok(Some(file_doc)) = files_coll.find_one(doc! { "key": &att.key }).await {
        if let Some(cached) = file_doc.extracted_text {
            return Ok(cached);
        }
    }

    if att.file_size as usize > MAX_DOCUMENT_DOWNLOAD_BYTES {
        return Err("ไฟล์เอกสารมีขนาดใหญ่เกิน 20 MB เกินขีดจำกัดสำหรับให้ AI อ่าน".to_string());
    }

    let (bytes, minio_ct) = state
        .minio
        .get_object(&att.key)
        .await
        .map_err(|_| "ไม่สามารถดึงไฟล์เอกสารจากคลังจัดเก็บได้".to_string())?;

    if bytes.len() > MAX_DOCUMENT_DOWNLOAD_BYTES {
        return Err("ไฟล์เอกสารมีขนาดใหญ่เกิน 20 MB เกินขีดจำกัดสำหรับให้ AI อ่าน".to_string());
    }

    let effective_mime =
        if att.mime_type.trim().is_empty() || att.mime_type == "application/octet-stream" {
            minio_ct
        } else {
            att.mime_type.clone()
        };

    let extracted = extract_document_text(bytes, effective_mime, att.file_name.clone()).await?;
    let _ = files_coll
        .update_one(
            doc! { "key": &att.key },
            doc! { "$set": { "extracted_text": &extracted } },
        )
        .await;
    Ok(extracted)
}

pub(crate) async fn load_image_for_vision(
    state: &AppState,
    att: &AttachmentInfo,
) -> Result<AiImageInput, String> {
    if att.file_size as usize > MAX_IMAGE_VISION_BYTES {
        return Err("ไฟล์รูปภาพมีขนาดใหญ่เกิน 10 MB เกินขีดจำกัดสำหรับให้ AI วิเคราะห์".to_string());
    }

    let (bytes, minio_ct) = state
        .minio
        .get_object(&att.key)
        .await
        .map_err(|_| "ไม่สามารถดึงรูปภาพจากคลังจัดเก็บได้".to_string())?;

    if bytes.len() > MAX_IMAGE_VISION_BYTES {
        return Err("ไฟล์รูปภาพมีขนาดใหญ่เกิน 10 MB เกินขีดจำกัดสำหรับให้ AI วิเคราะห์".to_string());
    }

    let effective_mime =
        if att.mime_type.trim().is_empty() || att.mime_type == "application/octet-stream" {
            minio_ct.as_str()
        } else {
            att.mime_type.as_str()
        };

    Ok(AiImageInput {
        mime_type: canonical_image_mime(effective_mime, &att.file_name).to_string(),
        base64_data: BASE64.encode(&bytes),
    })
}

fn format_document_context_block(att: &AttachmentInfo, extracted: &str) -> String {
    if extracted.trim().is_empty() && is_pdf_attachment(&att.mime_type, &att.file_name) {
        format!("[เอกสารแนบ: {}]\n({})", att.file_name, SCANNED_PDF_NOTE)
    } else if extracted.trim().is_empty() {
        format!("[เอกสารแนบ: {}]\n(ไม่พบข้อความภายในไฟล์)", att.file_name)
    } else {
        format!("[เอกสารแนบ: {}]\n{}", att.file_name, extracted)
    }
}

async fn enrich_attachments_for_messages(
    state: &AppState,
    primary_msgs: &[&MessageDoc],
    history: &[MessageDoc],
    redact_confidential: bool,
    max_images: usize,
    max_docs: usize,
) -> (Vec<AiImageInput>, Vec<String>) {
    let mut images: Vec<AiImageInput> = Vec::new();
    let mut doc_blocks: Vec<String> = Vec::new();
    let mut seen_keys: HashSet<String> = HashSet::new();

    let candidates = primary_msgs.iter().copied().chain(history.iter().rev());

    for m in candidates {
        if images.len() >= max_images && doc_blocks.len() >= max_docs {
            break;
        }
        if m.is_unsent || is_message_confidential_for_ai(m, redact_confidential) {
            continue;
        }
        let Some(ref att) = m.attachment else {
            continue;
        };
        if att.key.trim().is_empty() || !seen_keys.insert(att.key.clone()) {
            continue;
        }

        match classify_attachment(&att.mime_type, &att.file_name) {
            AttachmentKind::Image if images.len() < max_images => {
                if let Ok(img) = load_image_for_vision(state, att).await {
                    images.push(img);
                }
            }
            AttachmentKind::Document if doc_blocks.len() < max_docs => {
                if let Ok(extracted) = load_or_extract_document_text(state, att).await {
                    doc_blocks.push(format_document_context_block(att, &extracted));
                }
            }
            _ => {}
        }
    }

    (images, doc_blocks)
}

fn can_call_live_ai(state: &AppState, settings: &AiSettingsDoc) -> bool {
    settings.enabled && is_system_ai_ready(&state.config)
}

/// Calls the server-managed `.env` BC AI to generate structured JSON (think: false, token-budgeted).
pub(crate) async fn generate_system_ai_json(
    state: &AppState,
    system_prompt: &str,
    user_prompt: &str,
    max_tokens: u32,
) -> Option<String> {
    generate_system_ai_json_with_images(state, system_prompt, user_prompt, &[], max_tokens).await
}

pub(crate) async fn generate_system_ai_json_with_images(
    state: &AppState,
    system_prompt: &str,
    user_prompt: &str,
    images: &[AiImageInput],
    max_tokens: u32,
) -> Option<String> {
    let settings = get_effective_ai_settings(state).await.ok()?;
    if !can_call_live_ai(state, &settings) {
        return None;
    }
    let base_url = resolve_default_base_url(&state.config);
    let model = resolve_default_model(&state.config);
    let api_key = state.config.ai_api_key.as_str();
    let timeout = Duration::from_secs(state.config.ai_timeout_secs);

    let messages = vec![
        AiChatMessage::text("system", system_prompt),
        if images.is_empty() {
            AiChatMessage::text("user", user_prompt)
        } else {
            AiChatMessage::with_images("user", user_prompt, images.to_vec())
        },
    ];

    execute_local_ai_request_inner(
        &state.minio.http,
        &base_url,
        &model,
        api_key,
        &messages,
        timeout,
        max_tokens,
        false,
    )
    .await
    .ok()
    .map(|out| out.reply)
}

pub(crate) async fn call_local_ai_brain_multimodal(
    state: &AppState,
    custom_system_prompt: Option<&str>,
    user_prompt: &str,
    history: &[MessageDoc],
    images: &[AiImageInput],
    doc_blocks: &[String],
    max_tokens: u32,
    history_window: usize,
) -> (String, String, bool) {
    let settings = match get_effective_ai_settings(state).await {
        Ok(s) => s,
        Err(_) => {
            let fallback = generate_smart_context_reply(user_prompt, history);
            return (fallback, PUBLIC_AI_BRAND_MODEL.to_string(), false);
        }
    };

    if can_call_live_ai(state, &settings) {
        let base_url = resolve_default_base_url(&state.config);
        let model = resolve_default_model(&state.config);
        let api_key = state.config.ai_api_key.as_str();

        let sys_prompt = format!(
            "{}\n\n{}",
            custom_system_prompt.unwrap_or(&settings.system_prompt),
            PLAIN_TEXT_RULE
        );

        let mut api_messages = vec![AiChatMessage::text("system", sys_prompt)];

        for m in history.iter().rev().take(history_window).rev() {
            if m.is_unsent {
                continue;
            }
            let content_text = history_text(m, settings.redact_confidential);
            let role = if m.sender_id == "user_ai" || m.sender_id.starts_with("user_oa_") {
                "assistant"
            } else {
                "user"
            };
            api_messages.push(AiChatMessage::text(role, content_text));
        }

        let final_user_prompt = if doc_blocks.is_empty() {
            user_prompt.to_string()
        } else {
            format!(
                "{}\n\nเนื้อหาจากเอกสารแนบ:\n{}",
                user_prompt,
                doc_blocks.join("\n\n")
            )
        };

        api_messages.push(AiChatMessage::with_images(
            "user",
            final_user_prompt,
            images.to_vec(),
        ));

        let timeout = Duration::from_secs(state.config.ai_timeout_secs);
        if let Ok(out) = execute_local_ai_request(
            &state.minio.http,
            &base_url,
            &model,
            api_key,
            &api_messages,
            timeout,
            max_tokens,
        )
        .await
        {
            return (out.reply, PUBLIC_AI_BRAND_MODEL.to_string(), true);
        }
    }

    let smart_reply = generate_smart_context_reply(user_prompt, history);
    (smart_reply, PUBLIC_AI_BRAND_MODEL.to_string(), false)
}

pub async fn call_local_ai_brain(
    state: &AppState,
    custom_system_prompt: Option<&str>,
    user_prompt: &str,
    history: &[MessageDoc],
) -> (String, String, bool) {
    call_local_ai_brain_multimodal(
        state,
        custom_system_prompt,
        user_prompt,
        history,
        &[],
        &[],
        AI_MAX_TOKENS_CHAT,
        AI_HISTORY_LIMIT_CHAT as usize,
    )
    .await
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
        return "ไอเดียจัดทริปและมื้ออร่อยจาก BC AI ผู้ช่วยส่วนตัว:\n- แนะนำแวะคาเฟ่บรรยากาศร่มรื่นช่วงบ่าย แล้วต่อมื้อเย็นริมน้ำกับแก๊งเพื่อน\n- ใช้เครื่องมือ \"หารค่าข้าวกับเพื่อน\" หรือสร้างโพลโหวตร้านในห้องนี้ได้เลย\n- รูปถ่ายทริปทั้งหมดอัปโหลดเข้าอัลบั้มห้อง เก็บความละเอียดเต็มถาวร ไม่มีวันหมดอายุครับ".to_string();
    }

    if lower.contains("ความลับ")
        || lower.contains("ส่งผิด")
        || lower.contains("ลบ")
        || lower.contains("pin")
    {
        return "คำแนะนำความเป็นส่วนตัวจาก BC AI ผู้ช่วยส่วนตัว:\n- ก่อนส่งรหัสผ่านหรือข้อความสำคัญ ให้เปิดโหมดข้อความลับส่วนตัวล็อก PIN 4 หลัก\n- หากส่งรูปหรือไฟล์ผิดห้อง สามารถกดลบทำลายไฟล์ทันที ระบบจะลบออกจากหน้าจอทุกคนทันทีครับ".to_string();
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

    let message_count = msg_coll
        .count_documents(doc! { "conversation_id": &conv.id, "is_unsent": false })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let history = fetch_recent_messages(&state, &conv.id, AI_HISTORY_LIMIT_SUMMARIZE)
        .await
        .map_err(ApiError::internal)?;

    let settings = get_effective_ai_settings(&state)
        .await
        .map_err(ApiError::internal)?;
    let (images, doc_blocks) = if can_call_live_ai(&state, &settings) {
        enrich_attachments_for_messages(
            &state,
            &[],
            &history,
            settings.redact_confidential,
            AI_ROOM_MAX_IMAGES,
            AI_ROOM_MAX_DOCS,
        )
        .await
    } else {
        (Vec::new(), Vec::new())
    };

    let (summary_text, model, live_api) = call_local_ai_brain_multimodal(
        &state,
        None,
        SUMMARY_PROMPT,
        &history,
        &images,
        &doc_blocks,
        AI_MAX_TOKENS_ANALYZE,
        AI_HISTORY_LIMIT_SUMMARIZE as usize,
    )
    .await;
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
        "message_count": message_count,
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

fn build_offline_assist_fallback(
    mode: &str,
    raw_prompt: &str,
    history: &[MessageDoc],
) -> (String, Vec<String>) {
    match mode {
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
                format!(
                    "ฝากเช็กหน่อยน้า: {} ดูรูปในอัลบั้มห้องได้เลยจ้า",
                    raw_prompt
                ),
            ];
            (polished, suggs)
        }
        "translate_en" => {
            let translated = if raw_prompt.is_empty() {
                "Hey everyone! Feel free to check out our trip photos in the shared album anytime."
                    .to_string()
            } else {
                format!(
                    "Hey! Just a quick note about \"{}\" — let me know what works best for you!",
                    raw_prompt
                )
            };
            let suggs = vec![translated.clone()];
            (translated, suggs)
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
            (s1.clone(), vec![s1, s2, s3])
        }
        _ => {
            let reply = generate_smart_context_reply(raw_prompt, history);
            let suggs = vec![
                "โอเคเลย เดี๋ยวจัดการให้เรียบร้อยจ้า".to_string(),
                "ขอบคุณมากนะ เปิดดูรูปในคลังไฟล์เรียบร้อยแล้ว!".to_string(),
            ];
            (reply, suggs)
        }
    }
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
            history = fetch_recent_messages(&state, cid.trim(), AI_HISTORY_LIMIT_CHAT)
                .await
                .unwrap_or_default();
        }
    }

    let settings = get_effective_ai_settings(&state)
        .await
        .map_err(ApiError::internal)?;

    let (result_text, suggestions, live_api) = if can_call_live_ai(&state, &settings) {
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

        let max_tokens = if mode == "suggest_reply" {
            AI_MAX_TOKENS_SUGGEST_REPLY
        } else {
            AI_MAX_TOKENS_ASSIST
        };

        let (reply, _, is_live) = call_local_ai_brain_multimodal(
            &state,
            None,
            &instruction,
            &history,
            &[],
            &[],
            max_tokens,
            AI_HISTORY_LIMIT_CHAT as usize,
        )
        .await;
        if is_live {
            if mode == "suggest_reply" {
                let suggs = parse_suggest_reply_bullets(&reply);
                let primary = suggs.first().cloned().unwrap_or(reply);
                (primary, suggs, true)
            } else {
                (reply, Vec::new(), true)
            }
        } else {
            let (fallback_text, fallback_suggs) =
                build_offline_assist_fallback(&mode, &raw_prompt, &history);
            (fallback_text, fallback_suggs, false)
        }
    } else {
        let (fallback_text, fallback_suggs) =
            build_offline_assist_fallback(&mode, &raw_prompt, &history);
        (fallback_text, fallback_suggs, false)
    };

    Ok(Json(json!({
        "mode": mode,
        "result": result_text,
        "suggestions": suggestions,
        "model": PUBLIC_AI_BRAND_MODEL,
        "live_api": live_api,
    })))
}

#[derive(Debug, Deserialize)]
pub struct AnalyzeMessageRequest {
    pub message_id: String,
    pub prompt: Option<String>,
    pub post_to_chat: Option<bool>,
}

pub async fn analyze_message_handler(
    auth: AuthUser,
    State(state): State<AppState>,
    Json(payload): Json<AnalyzeMessageRequest>,
) -> Result<Json<AiAnalyzeMessageResponse>, ApiError> {
    let msg_id = payload.message_id.trim();
    if msg_id.is_empty() {
        return Err(ApiError::bad_request("กรุณาระบุรหัสข้อความที่ต้องการวิเคราะห์"));
    }

    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let msg = msg_coll
        .find_one(doc! { "_id": msg_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อความที่ระบุ"))?;

    let mut conv = crate::routes::chat_routes::require_member(
        &state,
        &msg.conversation_id,
        &auth.user_id,
    )
    .await?;

    if msg.is_unsent {
        return Err(ApiError::bad_request(
            "ไม่สามารถให้ AI วิเคราะห์ข้อความที่ถูกยกเลิกการส่งแล้ว",
        ));
    }

    let settings = get_effective_ai_settings(&state)
        .await
        .map_err(ApiError::internal)?;

    if is_message_confidential_for_ai(&msg, settings.redact_confidential) {
        return Err(ApiError::forbidden(
            "ข้อความนี้เป็นข้อความลับส่วนตัวล็อก PIN ระบบปกปิดไม่ให้ AI เข้าถึงภาพหรือเอกสาร",
        ));
    }

    let custom_question = payload
        .prompt
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let (file_name, mime_type, media_kind, analysis, extracted_preview, model, live_api) =
        if let Some(ref att) = msg.attachment {
            match classify_attachment(&att.mime_type, &att.file_name) {
                AttachmentKind::Image => {
                    let img = load_image_for_vision(&state, att)
                        .await
                        .map_err(ApiError::bad_request)?;
                    let prompt_text = match custom_question {
                        Some(q) => format!(
                            "คำถามเกี่ยวกับรูปภาพ \"{}\" จากผู้ใช้: {}",
                            att.file_name, q
                        ),
                        None => format!(
                            "ช่วยวิเคราะห์รูปภาพ \"{}\" อย่างละเอียดเป็นภาษาไทย อธิบายสิ่งที่เห็น อ่านข้อความหรือตัวเลขสำคัญ (ถ้ามี) และสรุปใจความให้เข้าใจง่าย",
                            att.file_name
                        ),
                    };
                    let (reply, used_model, is_live) = call_local_ai_brain_multimodal(
                        &state,
                        None,
                        &prompt_text,
                        &[],
                        &[img],
                        &[],
                        AI_MAX_TOKENS_ANALYZE,
                        0,
                    )
                    .await;
                    let final_analysis = if is_live {
                        reply
                    } else {
                        format!(
                            "ระบบ BC AI อยู่ในโหมดสำรอง จึงยังไม่สามารถวิเคราะห์ภาพ \"{}\" แบบสดได้ในขณะนี้ กรุณาลองใหม่อีกครั้งเมื่อระบบพร้อมใช้งาน",
                            att.file_name
                        )
                    };
                    (
                        att.file_name.clone(),
                        att.mime_type.clone(),
                        "image".to_string(),
                        final_analysis,
                        None,
                        used_model,
                        is_live,
                    )
                }
                AttachmentKind::Document => {
                    let extracted = load_or_extract_document_text(&state, att)
                        .await
                        .map_err(ApiError::bad_request)?;
                    let preview = if extracted.trim().is_empty()
                        && is_pdf_attachment(&att.mime_type, &att.file_name)
                    {
                        Some(SCANNED_PDF_NOTE.to_string())
                    } else if extracted.trim().is_empty() {
                        None
                    } else {
                        let snippet: String = extracted.chars().take(500).collect();
                        Some(if extracted.chars().count() > 500 {
                            format!("{snippet}...")
                        } else {
                            snippet
                        })
                    };
                    let doc_block = format_document_context_block(att, &extracted);
                    let prompt_text = match custom_question {
                        Some(q) => format!(
                            "คำถามเกี่ยวกับเอกสาร \"{}\" จากผู้ใช้: {}",
                            att.file_name, q
                        ),
                        None => format!(
                            "ช่วยอ่านและสรุปใจความสำคัญจากเอกสาร \"{}\" เป็นภาษาไทย พร้อมระบุตัวเลข วันที่ หรือประเด็นสำคัญที่ควรรู้ (ถ้ามี)",
                            att.file_name
                        ),
                    };
                    let (reply, used_model, is_live) = call_local_ai_brain_multimodal(
                        &state,
                        None,
                        &prompt_text,
                        &[],
                        &[],
                        &[doc_block],
                        AI_MAX_TOKENS_ANALYZE,
                        0,
                    )
                    .await;
                    let final_analysis = if is_live {
                        reply
                    } else if let Some(ref pv) = preview {
                        format!(
                            "อ่านข้อความเบื้องต้นจากเอกสาร \"{}\" ได้ดังนี้ (โหมดสำรอง):\n{}",
                            att.file_name, pv
                        )
                    } else {
                        format!(
                            "ไม่สามารถดึงข้อความจากเอกสาร \"{}\" ได้ในโหมดสำรอง",
                            att.file_name
                        )
                    };
                    (
                        att.file_name.clone(),
                        att.mime_type.clone(),
                        "document".to_string(),
                        final_analysis,
                        preview,
                        used_model,
                        is_live,
                    )
                }
                AttachmentKind::Unsupported => {
                    return Err(ApiError::bad_request(format!(
                        "ยังไม่รองรับการให้ AI วิเคราะห์ไฟล์ '{}' (รองรับรูปภาพ PNG/JPG/WEBP/GIF และเอกสาร PDF/DOCX/XLSX/XLS/ODS/PPTX/TXT/CSV/MD/JSON/XML/HTML)",
                        att.file_name
                    )));
                }
            }
        } else {
            let prompt_text = match custom_question {
                Some(q) => format!(
                    "ข้อความในห้องแชท: \"{}\"\nคำถามจากผู้ใช้: {}",
                    msg.content, q
                ),
                None => format!(
                    "ช่วยสรุปและอธิบายข้อความต่อไปนี้เป็นภาษาไทยให้เข้าใจง่าย: {}",
                    msg.content
                ),
            };
            let (reply, used_model, is_live) = call_local_ai_brain_multimodal(
                &state,
                None,
                &prompt_text,
                &[],
                &[],
                &[],
                AI_MAX_TOKENS_ANALYZE,
                0,
            )
            .await;
            (
                "ข้อความในห้องแชท".to_string(),
                "text/plain".to_string(),
                "text".to_string(),
                reply,
                None,
                used_model,
                is_live,
            )
        };

    let posted_message_id = if payload.post_to_chat == Some(true) {
        let kind_label = match media_kind.as_str() {
            "image" => "ภาพ",
            "document" => "เอกสาร",
            _ => "ข้อความ",
        };
        let chat_text = format!("🤖 BC AI วิเคราะห์{kind_label} ({file_name}):\n{analysis}");
        insert_ai_message(&state, &mut conv, &chat_text)
            .await
            .ok()
            .map(|dto| dto.id)
    } else {
        None
    };

    Ok(Json(AiAnalyzeMessageResponse {
        message_id: msg.id,
        conversation_id: conv.id,
        file_name,
        mime_type,
        media_kind,
        analysis,
        extracted_preview,
        model,
        live_api,
        posted_message_id,
    }))
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

pub(crate) async fn load_ai_user(state: &AppState) -> UserDoc {
    let users_coll = state.db.collection::<UserDoc>("users");
    users_coll
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
            qr_token: "BCQR_BC_AI".to_string(),
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
        })
}

pub async fn insert_ai_message(
    state: &AppState,
    conv: &mut ConversationDoc,
    ai_text: &str,
) -> Result<MessageDto, String> {
    let ai_user = load_ai_user(state).await;
    insert_bot_message(state, conv, &ai_user, ai_text).await
}

fn is_placeholder_attachment_caption(content: &str) -> bool {
    let t = content.trim();
    t.is_empty()
        || t == "[ส่งรูปภาพ]"
        || t == "[ส่งไฟล์เอกสาร]"
        || t.starts_with("[ไฟล์] ")
}

fn build_attachment_trigger_prompt(
    trigger_msg: &MessageDoc,
    has_images: bool,
    has_docs: bool,
    is_oa: bool,
) -> String {
    if !is_placeholder_attachment_caption(&trigger_msg.content) {
        return trigger_msg.content.clone();
    }
    let fname = trigger_msg
        .attachment
        .as_ref()
        .map(|a| a.file_name.as_str())
        .unwrap_or("ไฟล์แนบ");
    if is_oa {
        if has_images {
            format!(
                "ลูกค้าส่งรูปภาพ ({fname}) เข้ามาในแชทร้านค้า ช่วยดูรายละเอียดในภาพ เช่น สินค้า สลิปโอนเงิน หรือคำถามที่ลูกค้าต้องการ แล้วตอบกลับลูกค้าอย่างสุภาพกระชับ"
            )
        } else if has_docs {
            format!(
                "ลูกค้าส่งเอกสารแนบ ({fname}) เข้ามาในแชทร้านค้า ช่วยอ่านเนื้อหาในเอกสารและตอบกลับลูกค้าอย่างสุภาพกระชับ"
            )
        } else {
            trigger_msg.content.clone()
        }
    } else if has_images {
        format!(
            "ผู้ใช้ส่งรูปภาพ ({fname}) มาให้ช่วยดู ช่วยอธิบายสิ่งที่เห็นในภาพ อ่านข้อความหรือตัวเลขสำคัญ (ถ้ามี) และสรุปให้เข้าใจง่ายเป็นภาษาไทย"
        )
    } else if has_docs {
        format!(
            "ผู้ใช้ส่งเอกสาร ({fname}) มาให้ช่วยอ่าน ช่วยสรุปใจความสำคัญและประเด็นเด่นจากเอกสารนี้เป็นภาษาไทย"
        )
    } else {
        trigger_msg.content.clone()
    }
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
        "คุณคือผู้ช่วยแอดมินร้าน \"{}\" (@{}) หมวดหมู่ \"{}\"\nรายละเอียดร้าน: {}\nเวลาทำการ: {}\nข้อมูลสินค้า/บริการ/โปรโมชั่นของร้าน: {}\n{}\nคำสั่ง: ตอบคำถามลูกค้าด้วยภาษาไทยที่สุภาพ กระชับ จริงใจ หากลูกค้าส่งภาพหรือเอกสารมาให้ช่วยอ่านและตอบตามข้อมูลจริง หากไม่มีข้อมูลราคาเฉพาะให้แจ้งลูกค้าว่าส่งข้อความถึงแอดมินร้านแล้ว",
        oa.display_name, oa.handle, oa.category, oa.bio, oa.business_hours, oa.ai_knowledge_prompt, coupon_info
    );

    let history = fetch_recent_messages(state, &conv.id, AI_HISTORY_LIMIT_CHAT)
        .await
        .unwrap_or_default();
    let replied_msg = if let Some(ref rep) = trigger_msg.reply_to {
        state
            .db
            .collection::<MessageDoc>("messages")
            .find_one(doc! { "_id": &rep.id, "conversation_id": &conv.id })
            .await
            .ok()
            .flatten()
    } else {
        None
    };

    let settings = get_effective_ai_settings(state).await.ok();
    let (images, doc_blocks) = match settings.as_ref() {
        Some(s) if can_call_live_ai(state, s) => {
            let mut primary = vec![trigger_msg];
            if let Some(ref rm) = replied_msg {
                primary.push(rm);
            }
            enrich_attachments_for_messages(
                state,
                &primary,
                &history,
                s.redact_confidential,
                AI_ROOM_MAX_IMAGES,
                AI_ROOM_MAX_DOCS,
            )
            .await
        }
        _ => (Vec::new(), Vec::new()),
    };

    let effective_prompt = build_attachment_trigger_prompt(
        trigger_msg,
        !images.is_empty(),
        !doc_blocks.is_empty(),
        true,
    );

    let (ai_reply_text, _, is_live) = call_local_ai_brain_multimodal(
        state,
        Some(&custom_prompt),
        &effective_prompt,
        &history,
        &images,
        &doc_blocks,
        AI_MAX_TOKENS_CHAT,
        AI_HISTORY_LIMIT_CHAT as usize,
    )
    .await;

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

    insert_bot_message(state, conv, bot_user, &final_reply)
        .await
        .ok()
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

    let replied_msg = if let Some(ref rep) = trigger_msg.reply_to {
        state
            .db
            .collection::<MessageDoc>("messages")
            .find_one(doc! { "_id": &rep.id, "conversation_id": &conv.id })
            .await
            .ok()
            .flatten()
    } else {
        None
    };
    let is_reply_to_ai = replied_msg
        .as_ref()
        .is_some_and(|m| m.sender_id == "user_ai");

    if !is_direct_with_ai && !is_mentioned && !is_reply_to_ai {
        return None;
    }

    let history = fetch_recent_messages(state, &conv.id, AI_HISTORY_LIMIT_CHAT)
        .await
        .unwrap_or_default();

    let settings = get_effective_ai_settings(state).await.ok();
    let (images, doc_blocks) = match settings.as_ref() {
        Some(s) if can_call_live_ai(state, s) => {
            let mut primary = vec![trigger_msg];
            if let Some(ref rm) = replied_msg {
                primary.push(rm);
            }
            enrich_attachments_for_messages(
                state,
                &primary,
                &history,
                s.redact_confidential,
                AI_ROOM_MAX_IMAGES,
                AI_ROOM_MAX_DOCS,
            )
            .await
        }
        _ => (Vec::new(), Vec::new()),
    };

    let effective_prompt = build_attachment_trigger_prompt(
        trigger_msg,
        !images.is_empty(),
        !doc_blocks.is_empty(),
        false,
    );

    let (ai_reply_text, _, _) = call_local_ai_brain_multimodal(
        state,
        None,
        &effective_prompt,
        &history,
        &images,
        &doc_blocks,
        AI_MAX_TOKENS_CHAT,
        AI_HISTORY_LIMIT_CHAT as usize,
    )
    .await;

    insert_ai_message(state, conv, &ai_reply_text).await.ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{HeaderMap, Request, StatusCode},
        routing::{get, post},
        Router,
    };
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    use tower::ServiceExt;

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
    fn ai_history_shows_task_status_and_truncates_long_entries() {
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

        m.content = "ก".repeat(900);
        let h = history_text(&m, true);
        assert!(h.chars().count() <= AI_HISTORY_ENTRY_MAX_CHARS + 3);
        assert!(h.ends_with("..."));
    }

    #[test]
    fn strip_think_blocks_removes_closed_unclosed_and_multiline_tags() {
        assert_eq!(
            to_plain_text("<think>วิเคราะห์ก่อนตอบ\nบรรทัด 2</think>\n**สวัสดีจ้า**"),
            "สวัสดีจ้า"
        );
        assert_eq!(
            to_plain_text("<THINK>hidden</THINK>ข้อ 1\n<think>hidden2</think>ข้อ 2"),
            "ข้อ 1\nข้อ 2"
        );
        assert_eq!(
            to_plain_text("คำตอบพร้อมแล้ว <think>ตัดจบกลางคันไม่ได้ปิดแท็ก"),
            "คำตอบพร้อมแล้ว"
        );
        assert_eq!(
            to_plain_text("เหตุผลที่หลุดมา</think>\nตอบสั้นๆ ครับ"),
            "ตอบสั้นๆ ครับ"
        );
        assert_eq!(to_plain_text("ไม่มีแท็กเลย ปกติ"), "ไม่มีแท็กเลย ปกติ");
    }

    #[test]
    fn parse_suggest_reply_bullets_handles_dash_bullet_and_numbers() {
        let raw_dash = "ตัวอย่างคำตอบ:\n- โอเคเลย เจอกันเย็นนี้นะ\n- ได้เลยจ้า เดี๋ยวถึงแล้วทักบอก\n- จัดไปครับ!\n- ข้อที่สี่ต้องตัดออก";
        assert_eq!(
            parse_suggest_reply_bullets(raw_dash),
            vec![
                "โอเคเลย เจอกันเย็นนี้นะ",
                "ได้เลยจ้า เดี๋ยวถึงแล้วทักบอก",
                "จัดไปครับ!",
            ]
        );

        let raw_num = "1. \"รับทราบครับ\"\n2. ขอบคุณมากจ้า\n• เดี๋ยวรีบตามไปนะ";
        assert_eq!(
            parse_suggest_reply_bullets(raw_num),
            vec!["รับทราบครับ", "ขอบคุณมากจ้า", "เดี๋ยวรีบตามไปนะ"]
        );
    }

    #[test]
    fn ollama_url_normalization_and_system_ready_check() {
        assert_eq!(normalize_ollama_root("https://ollama.com"), "https://ollama.com");
        assert_eq!(normalize_ollama_root("https://ollama.com/"), "https://ollama.com");
        assert_eq!(normalize_ollama_root("https://ollama.com/api"), "https://ollama.com");
        assert_eq!(normalize_ollama_root("https://ollama.com/api/"), "https://ollama.com");
        assert_eq!(normalize_ollama_root("http://127.0.0.1:11434/API/"), "http://127.0.0.1:11434");

        assert!(is_ollama_cloud_url("https://ollama.com"));
        assert!(is_ollama_cloud_url("https://api.ollama.com"));
        assert!(!is_ollama_cloud_url("https://evil-ollama.com"));
        assert!(!is_ollama_cloud_url("http://127.0.0.1:11434"));

        let mut cfg = AppConfig::from_env();
        cfg.ai_enabled = true;
        cfg.ai_base_url = "https://ollama.com".into();
        cfg.ai_model = "deepseek-v4.1-flash".into();
        cfg.ai_api_key.clear();
        assert!(!is_system_ai_ready(&cfg), "cloud without key must not be ready");
        cfg.ai_api_key = "cloud-secret-demo".into();
        assert!(is_system_ai_ready(&cfg));
        cfg.ai_enabled = false;
        assert!(!is_system_ai_ready(&cfg));
    }

    #[test]
    fn scrub_legacy_ai_settings_clears_db_credentials_and_urls() {
        let mut doc = AiSettingsDoc {
            id: "default".into(),
            enabled: true,
            api_key: "legacy-dummy-token-000".into(), // pragma: allowlist secret
            model: "legacy-model-id".into(),
            base_url: "https://example.invalid".into(),
            system_prompt: DEFAULT_PERSONAL_AI_PROMPT.into(),
            auto_reply_in_groups: true,
            redact_confidential: true,
            proactive_game_invites: true,
            updated_at: "2026-01-01T00:00:00Z".into(),
        };
        assert!(scrub_legacy_ai_settings_doc(&mut doc));
        assert!(doc.api_key.is_empty());
        assert!(doc.base_url.is_empty());
        assert!(doc.model.is_empty());
        assert_ne!(doc.updated_at, "2026-01-01T00:00:00Z");

        // Second pass on already-scrubbed doc is a no-op.
        assert!(!scrub_legacy_ai_settings_doc(&mut doc));
    }

    #[test]
    fn multimodal_payload_builders_format_ollama_and_openai_correctly() {
        let msgs = vec![
            AiChatMessage::text("system", "ระบบ"),
            AiChatMessage::with_images(
                "user",
                "ช่วยดูรูปนี้หน่อย",
                vec![AiImageInput {
                    mime_type: "image/png".to_string(),
                    base64_data: "iVBORw0KGgo=".to_string(),
                }],
            ),
        ];

        let ollama = build_ollama_messages_json(&msgs);
        assert_eq!(ollama[0]["content"], json!("ระบบ"));
        assert!(ollama[0].get("images").is_none());
        assert_eq!(ollama[1]["content"], json!("ช่วยดูรูปนี้หน่อย"));
        assert_eq!(ollama[1]["images"], json!(["iVBORw0KGgo="]));

        let openai = build_openai_messages_json(&msgs);
        assert_eq!(openai[0]["content"], json!("ระบบ"));
        assert_eq!(openai[1]["content"][0]["type"], json!("text"));
        assert_eq!(openai[1]["content"][0]["text"], json!("ช่วยดูรูปนี้หน่อย"));
        assert_eq!(openai[1]["content"][1]["type"], json!("image_url"));
        assert_eq!(
            openai[1]["content"][1]["image_url"]["url"],
            json!("data:image/png;base64,iVBORw0KGgo=")
        );
    }

    #[test]
    fn confidential_messages_are_redacted_for_ai() {
        let mut msg: MessageDoc = serde_json::from_value(json!({
            "_id": "m_conf",
            "conversation_id": "c1",
            "sender_id": "u1",
            "sender_name": "ต้นน้ำ",
            "sender_avatar": "",
            "type": "image",
            "content": "สลิปลับ",
            "is_confidential": true,
            "created_at": "2026-11-22T00:00:00Z"
        }))
        .unwrap();
        assert!(is_message_confidential_for_ai(&msg, true));
        assert!(!is_message_confidential_for_ai(&msg, false));
        assert!(history_text(&msg, true).contains("ปกปิดข้อมูลอัตโนมัติ"));

        msg.is_confidential = false;
        msg.confidential_pin = Some("1234".to_string());
        assert!(is_message_confidential_for_ai(&msg, true));
    }

    #[tokio::test]
    async fn mock_http_helpers_cover_ollama_openai_and_sanitized_errors() {
        let ollama_hits = Arc::new(AtomicUsize::new(0));
        let ollama_hits_ref = ollama_hits.clone();
        let ollama_app = Router::new().route(
            "/api/chat",
            post(move |headers: HeaderMap, Json(body): Json<Value>| {
                let hits = ollama_hits_ref.clone();
                async move {
                    hits.fetch_add(1, Ordering::SeqCst);
                    assert!(headers.get("authorization").is_none());
                    assert_eq!(body["stream"], json!(false));
                    assert_eq!(body["think"], json!(false));
                    Json(json!({
                        "model": body["model"],
                        "message": {
                            "role": "assistant",
                            "content": "<think>คิดในใจ</think>\nสวัสดีจาก BC AI ครับ"
                        },
                        "done": true
                    }))
                }
            }),
        );
        let ollama_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ollama_base = format!("http://{}", ollama_listener.local_addr().unwrap());
        let ollama_srv = tokio::spawn(async move {
            let _ = axum::serve(ollama_listener, ollama_app).await;
        });

        let openai_hits = Arc::new(AtomicUsize::new(0));
        let openai_hits_ref = openai_hits.clone();
        let openai_app = Router::new().route(
            "/v1/chat/completions",
            post(move |headers: HeaderMap, Json(body): Json<Value>| {
                let hits = openai_hits_ref.clone();
                async move {
                    hits.fetch_add(1, Ordering::SeqCst);
                    assert_eq!(body["model"], json!("internal-model-x"));
                    assert_eq!(
                        headers.get("authorization").and_then(|v| v.to_str().ok()),
                        Some("Bearer local-test-token")
                    );
                    Json(json!({
                        "choices": [{
                            "message": {
                                "role": "assistant",
                                "content": "<think>internal</think>ตอบกลับสำเร็จครับ"
                            }
                        }]
                    }))
                }
            }),
        );
        let openai_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let openai_base = format!("http://{}", openai_listener.local_addr().unwrap());
        let openai_srv = tokio::spawn(async move {
            let _ = axum::serve(openai_listener, openai_app).await;
        });

        let unauth_app =
            Router::new().route("/api/chat", post(|| async { StatusCode::UNAUTHORIZED }));
        let unauth_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let unauth_base = format!("http://{}", unauth_listener.local_addr().unwrap());
        let unauth_srv = tokio::spawn(async move {
            let _ = axum::serve(unauth_listener, unauth_app).await;
        });

        let http = reqwest::Client::new();

        // Ollama /api/chat + trailing /api normalization
        let out1 = execute_local_ai_request(
            &http,
            &format!("{ollama_base}/api/"),
            "internal-model-1",
            "",
            &[AiChatMessage::text("user", "สวัสดี")],
            Duration::from_secs(10),
            96,
        )
        .await
        .expect("ollama chat");
        assert_eq!(out1.reply, "สวัสดีจาก BC AI ครับ");
        assert_eq!(ollama_hits.load(Ordering::SeqCst), 1);

        // OpenAI-compatible fallback (404 on /api/chat -> /v1/chat/completions) & direct /v1
        let out2 = execute_local_ai_request(
            &http,
            &openai_base,
            "internal-model-x",
            "local-test-token",
            &[AiChatMessage::text("user", "hello")],
            Duration::from_secs(10),
            96,
        )
        .await
        .expect("openai fallback");
        assert_eq!(out2.reply, "ตอบกลับสำเร็จครับ");

        let out3 = execute_local_ai_request(
            &http,
            &format!("{openai_base}/v1"),
            "internal-model-x",
            "local-test-token",
            &[AiChatMessage::text("user", "hello")],
            Duration::from_secs(10),
            96,
        )
        .await
        .expect("openai /v1");
        assert_eq!(out3.reply, "ตอบกลับสำเร็จครับ");
        assert_eq!(openai_hits.load(Ordering::SeqCst), 2);

        // Sanitized 401 error never leaks URL, model ID, or provider name
        let err = execute_local_ai_request(
            &http,
            &unauth_base,
            "deepseek-v4.1-flash",
            "",
            &[AiChatMessage::text("user", "hi")],
            Duration::from_secs(10),
            64,
        )
        .await
        .unwrap_err();
        let err_lower = err.to_ascii_lowercase();
        assert!(!err_lower.contains("ollama") && !err_lower.contains("deepseek"));
        assert!(!err_lower.contains("http") && !err_lower.contains("api key"));

        ollama_srv.abort();
        openai_srv.abort();
        unauth_srv.abort();
    }

    #[tokio::test]
    async fn mock_http_system_managed_ai_privacy_vision_and_document_flow() {
        use std::io::Write;
        use zip::write::SimpleFileOptions;

        let mut docx_cursor = std::io::Cursor::new(Vec::new());
        {
            let mut zw = zip::ZipWriter::new(&mut docx_cursor);
            zw.start_file("word/document.xml", SimpleFileOptions::default())
                .unwrap();
            zw.write_all(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>รายงานยอดขายชาบ้านเชียง รวม 15,800 บาท</w:t></w:r></w:p>
  </w:body>
</w:document>"#
                    .as_bytes(),
            )
            .unwrap();
            zw.finish().unwrap();
        }
        let docx_bytes = Arc::new(docx_cursor.into_inner());
        let png_bytes = Arc::new(vec![
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        ]);
        let expected_b64 = BASE64.encode(png_bytes.as_slice());

        let confidential_minio_hits = Arc::new(AtomicUsize::new(0));
        let conf_hits_ref = confidential_minio_hits.clone();
        let png_ref = png_bytes.clone();
        let docx_ref = docx_bytes.clone();
        let minio_app = Router::new()
            .route(
                "/mock-bucket/test_img.png",
                get(move || {
                    let b = png_ref.clone();
                    async move { ([(axum::http::header::CONTENT_TYPE, "image/png")], (*b).clone()) }
                }),
            )
            .route(
                "/mock-bucket/test_doc.docx",
                get(move || {
                    let b = docx_ref.clone();
                    async move {
                        (
                            [(
                                axum::http::header::CONTENT_TYPE,
                                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                            )],
                            (*b).clone(),
                        )
                    }
                }),
            )
            .route(
                "/mock-bucket/secret_img.png",
                get(move || {
                    let hits = conf_hits_ref.clone();
                    async move {
                        hits.fetch_add(1, Ordering::SeqCst);
                        StatusCode::OK
                    }
                }),
            );
        let minio_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let minio_base = format!("http://{}", minio_listener.local_addr().unwrap());
        let minio_srv = tokio::spawn(async move {
            let _ = axum::serve(minio_listener, minio_app).await;
        });

        let saw_image_b64 = Arc::new(std::sync::Mutex::new(String::new()));
        let saw_doc_text = Arc::new(std::sync::Mutex::new(String::new()));
        let saw_num_predict = Arc::new(std::sync::Mutex::new(Vec::<u64>::new()));
        let saw_img_ref = saw_image_b64.clone();
        let saw_doc_ref = saw_doc_text.clone();
        let saw_np_ref = saw_num_predict.clone();
        let ollama_app = Router::new().route(
            "/api/chat",
            post(move |headers: HeaderMap, Json(body): Json<Value>| {
                let saw_img = saw_img_ref.clone();
                let saw_doc = saw_doc_ref.clone();
                let saw_np = saw_np_ref.clone();
                async move {
                    let model = body["model"].as_str().unwrap_or("");
                    if let Some(np) = body["options"]["num_predict"].as_u64() {
                        saw_np.lock().unwrap().push(np);
                    }
                    let last = body["messages"].as_array().and_then(|a| a.last()).unwrap();
                    let has_images = last
                        .get("images")
                        .and_then(|v| v.as_array())
                        .is_some_and(|a| !a.is_empty());
                    if model == "text-only-model" && has_images {
                        return (
                            StatusCode::BAD_REQUEST,
                            Json(json!({ "error": "model does not support image vision inputs" })),
                        );
                    }
                    if model != "text-only-model" {
                        assert_eq!(
                            headers.get("authorization").and_then(|v| v.to_str().ok()),
                            Some("Bearer server-secret-env-key")
                        );
                    }
                    if let Some(first_img) = last
                        .get("images")
                        .and_then(|v| v.as_array())
                        .and_then(|a| a.first())
                        .and_then(|s| s.as_str())
                    {
                        *saw_img.lock().unwrap() = first_img.to_string();
                        return (
                            StatusCode::OK,
                            Json(json!({
                                "model": model,
                                "message": { "role": "assistant", "content": "ในภาพเป็นรูปทดสอบ PNG ชัดเจนครับ" },
                                "done": true
                            })),
                        );
                    }
                    let content = last["content"].as_str().unwrap_or("");
                    *saw_doc.lock().unwrap() = content.to_string();
                    let reply = if content.contains("3 แบบ") {
                        "<think>ลับ</think>\n- ได้เลยจ้า เจอกันนะ\n- โอเคครับ เดี๋ยวรีบไป\n- จัดไปเลย!"
                    } else if content.contains("15,800") {
                        "สรุปเอกสาร: ยอดขายชาบ้านเชียงรวม 15,800 บาทครับ"
                    } else {
                        "<think>ลับ</think>พร้อมใช้งาน BC AI แล้วครับ"
                    };
                    (
                        StatusCode::OK,
                        Json(json!({
                            "model": model,
                            "message": { "role": "assistant", "content": reply },
                            "done": true
                        })),
                    )
                }
            }),
        );
        let ollama_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ollama_base = format!("http://{}", ollama_listener.local_addr().unwrap());
        let ollama_srv = tokio::spawn(async move {
            let _ = axum::serve(ollama_listener, ollama_app).await;
        });

        // Non-vision HTTP 400 graceful fallback appends sanitized Thai note (no model ID leak)
        let http = reqwest::Client::new();
        let non_vision = execute_local_ai_request(
            &http,
            &ollama_base,
            "text-only-model",
            "",
            &[AiChatMessage::with_images(
                "user",
                "ดูรูปให้หน่อย",
                vec![AiImageInput {
                    mime_type: "image/png".into(),
                    base64_data: expected_b64.clone(),
                }],
            )],
            Duration::from_secs(10),
            128,
        )
        .await
        .expect("non-vision graceful retry");
        assert!(non_vision.reply.contains("โหมดข้อความเท่านั้น"));
        assert!(!non_vision.reply.to_ascii_lowercase().contains("deepseek"));

        let run_short = &Uuid::new_v4().simple().to_string()[..8];
        let mut cfg = AppConfig::from_env();
        cfg.mongodb_db = format!("bcaichat_ai_lockdown_{run_short}");
        cfg.minio_endpoint = minio_base.clone();
        cfg.minio_bucket = "mock-bucket".to_string();
        cfg.ai_base_url = ollama_base.clone();
        cfg.ai_model = "deepseek-v4.1-flash".to_string();
        cfg.ai_api_key = "server-secret-env-key".to_string();
        cfg.ai_enabled = true;
        cfg.enable_test_users = false;

        let state = AppState::init(cfg).await.expect("init AppState");
        let app = crate::create_router(state.clone());

        let admin_id = "unit_admin_lockdown";
        let conv_id = "unit_conv_lockdown";
        let now = Utc::now().to_rfc3339();
        state
            .db
            .collection::<UserDoc>("users")
            .insert_one(UserDoc {
                id: admin_id.into(),
                email: "admin-lockdown@bcaichat.local".into(),
                phone: "0892223344".into(),
                phone_verified: true,
                email_verified: true,
                display_name: "แอดมินทดสอบ".into(),
                bc_id: "@admin_lockdown".into(),
                avatar_url: String::new(),
                status_message: String::new(),
                qr_token: "BCQR_LOCK_1".into(), // pragma: allowlist secret
                role: "admin".into(),
                department: String::new(),
                job_title: String::new(),
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
                created_at: now.clone(),
            })
            .await
            .unwrap();
        state
            .db
            .collection::<ConversationDoc>("conversations")
            .insert_one(ConversationDoc {
                id: conv_id.into(),
                conv_type: "direct".into(),
                name: "ห้องทดสอบ BC AI".into(),
                avatar_url: String::new(),
                folder: "personal".into(),
                is_pinned: false,
                is_muted: false,
                is_archived: false,
                invite_token: String::new(),
                admin_ids: vec![admin_id.into()],
                member_ids: vec![admin_id.into(), "user_ai".into()],
                oa_id: None,
                oa_handle: None,
                user_meta: HashMap::new(),
                pinned_message: None,
                last_message: None,
                ai_game_auto_invite: None,
                ai_game_invite_cooldown_mins: None,
                last_ai_game_invite_at: None,
                human_msgs_since_game_invite: 0,
                created_at: now.clone(),
                updated_at: now.clone(),
            })
            .await
            .unwrap();
        state
            .db
            .collection::<FileDoc>("files")
            .insert_one(FileDoc {
                id: "f_doc_lock".into(),
                key: "test_doc.docx".into(),
                url: format!("{minio_base}/mock-bucket/test_doc.docx"),
                file_name: "sales.docx".into(),
                mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                    .into(),
                file_size: docx_bytes.len() as u64,
                uploader_id: admin_id.into(),
                uploader_name: "แอดมินทดสอบ".into(),
                conversation_id: Some(conv_id.into()),
                extracted_text: None,
                created_at: now.clone(),
            })
            .await
            .unwrap();

        let make_msg = |id: &str, mtype: &str, key: &str, fname: &str, mime: &str, size: u64, conf: bool| {
            serde_json::from_value::<MessageDoc>(json!({
                "_id": id,
                "conversation_id": conv_id,
                "sender_id": admin_id,
                "sender_name": "แอดมินทดสอบ",
                "sender_avatar": "",
                "type": mtype,
                "content": fname,
                "is_confidential": conf,
                "attachment": {
                    "key": key,
                    "url": format!("{minio_base}/mock-bucket/{key}"),
                    "file_name": fname,
                    "mime_type": mime,
                    "file_size": size
                },
                "created_at": now
            }))
            .unwrap()
        };
        state
            .db
            .collection::<MessageDoc>("messages")
            .insert_many(vec![
                make_msg("msg_img_1", "image", "test_img.png", "photo.png", "image/png", png_bytes.len() as u64, false),
                make_msg(
                    "msg_doc_1",
                    "file",
                    "test_doc.docx",
                    "sales.docx",
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    docx_bytes.len() as u64,
                    false,
                ),
                make_msg("msg_conf_1", "image", "secret_img.png", "secret.png", "image/png", 12, true),
            ])
            .await
            .unwrap();

        let token = crate::auth::create_jwt(
            admin_id,
            "admin-lockdown@bcaichat.local",
            "admin",
            &state.config.jwt_secret,
        )
        .unwrap();

        // 1. GET /api/admin/ai-models must be REMOVED (404)
        let models_req = Request::builder()
            .method("GET")
            .uri("/api/admin/ai-models")
            .header("Authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();
        let models_resp = app.clone().oneshot(models_req).await.unwrap();
        assert_eq!(models_resp.status(), StatusCode::NOT_FOUND);

        // 2. GET /api/admin/ai-settings exposes ZERO secrets/URLs/models
        let get_req = Request::builder()
            .method("GET")
            .uri("/api/admin/ai-settings")
            .header("Authorization", format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap();
        let get_resp = app.clone().oneshot(get_req).await.unwrap();
        assert_eq!(get_resp.status(), StatusCode::OK);
        let get_json: Value = serde_json::from_slice(
            &axum::body::to_bytes(get_resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(get_json["managed_by_system"], json!(true));
        assert_eq!(get_json["system_ready"], json!(true));
        for forbidden in ["api_key", "masked_key", "has_api_key", "base_url", "model", "provider"] {
            assert!(
                get_json.get(forbidden).is_none(),
                "GET /api/admin/ai-settings must NOT expose '{forbidden}'"
            );
        }

        // 3. PUT /api/admin/ai-settings ignores injected credentials/URL/model
        let put_req = Request::builder()
            .method("PUT")
            .uri("/api/admin/ai-settings")
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .body(Body::from(
                serde_json::to_vec(&json!({
                    "enabled": true,
                    "auto_reply_in_groups": false,
                    "api_key": "evil-injected-key",
                    "base_url": "http://127.0.0.1:9",
                    "model": "evil-model"
                }))
                .unwrap(),
            ))
            .unwrap();
        let put_resp = app.clone().oneshot(put_req).await.unwrap();
        assert_eq!(put_resp.status(), StatusCode::OK);
        let put_json: Value = serde_json::from_slice(
            &axum::body::to_bytes(put_resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(put_json["auto_reply_in_groups"], json!(false));
        assert!(put_json.get("base_url").is_none());
        let db_doc = state
            .db
            .collection::<AiSettingsDoc>("ai_settings")
            .find_one(doc! { "_id": "default" })
            .await
            .unwrap()
            .unwrap();
        assert!(db_doc.api_key.is_empty() && db_doc.base_url.is_empty() && db_doc.model.is_empty());

        // 4. POST /api/admin/ai-test ignores injected body, uses server .env, returns no URL/model/provider
        let test_req = Request::builder()
            .method("POST")
            .uri("/api/admin/ai-test")
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .body(Body::from(
                serde_json::to_vec(&json!({
                    "base_url": "http://127.0.0.1:9",
                    "model": "evil-model",
                    "api_key": "evil-key"
                }))
                .unwrap(),
            ))
            .unwrap();
        let test_resp = app.clone().oneshot(test_req).await.unwrap();
        assert_eq!(test_resp.status(), StatusCode::OK);
        let test_json: Value = serde_json::from_slice(
            &axum::body::to_bytes(test_resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(test_json["ok"], json!(true));
        assert_eq!(test_json["reply"], json!("พร้อมใช้งาน BC AI แล้วครับ"));
        for forbidden in ["base_url", "model", "provider", "api_key"] {
            assert!(
                test_json.get(forbidden).is_none(),
                "POST /api/admin/ai-test must NOT expose '{forbidden}'"
            );
        }

        // 5. POST /api/ai/assist (suggest_reply) returns branded "BC AI" + 3 chips + 220 token cap
        let assist_req = Request::builder()
            .method("POST")
            .uri("/api/ai/assist")
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .body(Body::from(
                serde_json::to_vec(&json!({ "mode": "suggest_reply" })).unwrap(),
            ))
            .unwrap();
        let assist_resp = app.clone().oneshot(assist_req).await.unwrap();
        assert_eq!(assist_resp.status(), StatusCode::OK);
        let assist_json: Value = serde_json::from_slice(
            &axum::body::to_bytes(assist_resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(assist_json["model"], json!("BC AI"));
        assert_eq!(assist_json["live_api"], json!(true));
        assert_eq!(
            assist_json["suggestions"],
            json!(["ได้เลยจ้า เจอกันนะ", "โอเคครับ เดี๋ยวรีบไป", "จัดไปเลย!"])
        );

        // 6. POST /api/ai/analyze-message on PNG image + post_to_chat
        let img_req = Request::builder()
            .method("POST")
            .uri("/api/ai/analyze-message")
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .body(Body::from(
                serde_json::to_vec(&json!({
                    "message_id": "msg_img_1",
                    "post_to_chat": true
                }))
                .unwrap(),
            ))
            .unwrap();
        let img_resp = app.clone().oneshot(img_req).await.unwrap();
        assert_eq!(img_resp.status(), StatusCode::OK);
        let img_dto: AiAnalyzeMessageResponse = serde_json::from_slice(
            &axum::body::to_bytes(img_resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(img_dto.media_kind, "image");
        assert_eq!(img_dto.model, "BC AI");
        assert!(img_dto.live_api);
        assert!(img_dto.posted_message_id.is_some());
        assert_eq!(*saw_image_b64.lock().unwrap(), expected_b64);

        // 7. POST /api/ai/analyze-message on DOCX -> extracts text + caches in MongoDB
        let doc_req = Request::builder()
            .method("POST")
            .uri("/api/ai/analyze-message")
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .body(Body::from(
                serde_json::to_vec(&json!({ "message_id": "msg_doc_1" })).unwrap(),
            ))
            .unwrap();
        let doc_resp = app.clone().oneshot(doc_req).await.unwrap();
        assert_eq!(doc_resp.status(), StatusCode::OK);
        let doc_dto: AiAnalyzeMessageResponse = serde_json::from_slice(
            &axum::body::to_bytes(doc_resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(doc_dto.media_kind, "document");
        assert_eq!(doc_dto.model, "BC AI");
        assert!(doc_dto.live_api);
        assert!(doc_dto
            .extracted_preview
            .as_deref()
            .unwrap_or("")
            .contains("15,800"));
        assert!(saw_doc_text.lock().unwrap().contains("15,800"));

        let cached_file = state
            .db
            .collection::<FileDoc>("files")
            .find_one(doc! { "key": "test_doc.docx" })
            .await
            .unwrap()
            .unwrap();
        assert!(cached_file
            .extracted_text
            .as_deref()
            .unwrap_or("")
            .contains("15,800"));

        // 8. Confidential image blocked with 403 and NEVER fetched from MinIO
        let conf_req = Request::builder()
            .method("POST")
            .uri("/api/ai/analyze-message")
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .body(Body::from(
                serde_json::to_vec(&json!({ "message_id": "msg_conf_1" })).unwrap(),
            ))
            .unwrap();
        let conf_resp = app.clone().oneshot(conf_req).await.unwrap();
        assert_eq!(conf_resp.status(), StatusCode::FORBIDDEN);
        assert_eq!(confidential_minio_hits.load(Ordering::SeqCst), 0);

        // Verify token budgets were enforced (test=96, suggest_reply=220, analyze=768)
        let budgets = saw_num_predict.lock().unwrap().clone();
        assert!(budgets.contains(&96), "budgets: {budgets:?}");
        assert!(budgets.contains(&220), "budgets: {budgets:?}");
        assert!(budgets.contains(&768), "budgets: {budgets:?}");

        let _ = state.db.drop().await;
        minio_srv.abort();
        ollama_srv.abort();
    }
}
