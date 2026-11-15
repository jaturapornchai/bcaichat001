use chrono::{DateTime, Days, Duration, FixedOffset, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub fn default_true() -> bool {
    true
}

/// Computes the next 08:00 AM in Thailand time (UTC+7) as an RFC3339 UTC timestamp.
pub fn next_thai_8am_utc_rfc3339(now: DateTime<Utc>) -> String {
    let bkk = FixedOffset::east_opt(7 * 3600).expect("valid UTC+7 offset");
    let local_now = now.with_timezone(&bkk);
    let today_8am_naive = local_now
        .date_naive()
        .and_hms_opt(8, 0, 0)
        .expect("valid 08:00:00");
    let target_naive = if local_now.naive_local() < today_8am_naive {
        today_8am_naive
    } else {
        local_now
            .date_naive()
            .checked_add_days(Days::new(1))
            .expect("valid next day")
            .and_hms_opt(8, 0, 0)
            .expect("valid 08:00:00")
    };
    bkk.from_local_datetime(&target_naive)
        .single()
        .expect("unambiguous UTC+7 local time")
        .with_timezone(&Utc)
        .to_rfc3339()
}

/// Parses a duration preset ("off" | "1h" | "8h" | "until_8am" | "forever") into (is_enabled, until_rfc3339).
pub fn compute_timed_window(mode: &str, now: DateTime<Utc>) -> Option<(bool, Option<String>)> {
    match mode.trim().to_lowercase().as_str() {
        "off" | "none" | "unmute" | "false" | "0" => Some((false, None)),
        "1h" => Some((true, Some((now + Duration::hours(1)).to_rfc3339()))),
        "8h" => Some((true, Some((now + Duration::hours(8)).to_rfc3339()))),
        "until_8am" | "8am" => Some((true, Some(next_thai_8am_utc_rfc3339(now)))),
        "forever" | "always" | "on" | "true" => Some((true, None)),
        _ => None,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserDoc {
    #[serde(rename = "_id")]
    pub id: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub phone: String,
    #[serde(default)]
    pub phone_verified: bool,
    #[serde(default)]
    pub email_verified: bool,
    pub display_name: String,
    pub bc_id: String,
    pub avatar_url: String,
    pub status_message: String,
    pub qr_token: String,
    pub role: String,
    #[serde(default)]
    pub department: String,
    #[serde(default)]
    pub job_title: String,
    #[serde(default)]
    pub google_id: Option<String>,
    #[serde(default)]
    pub is_oa_bot: bool,
    #[serde(default)]
    pub oa_id: Option<String>,
    #[serde(default = "default_true")]
    pub allow_add_by_phone: bool,
    #[serde(default = "default_true")]
    pub allow_add_by_id: bool,
    #[serde(default = "default_true")]
    pub allow_add_by_email: bool,
    #[serde(default = "default_true")]
    pub notify_preview: bool,
    #[serde(default = "default_true")]
    pub notify_on_mention: bool,
    #[serde(default)]
    pub dnd_until: Option<String>,
    #[serde(default)]
    pub recovery_pin_hash: Option<String>,
    #[serde(default)]
    pub recovery_code_hashes: Vec<String>,
    #[serde(default)]
    pub recovery_failed_attempts: u32,
    #[serde(default)]
    pub recovery_locked_until: Option<String>,
    #[serde(default)]
    pub token_version: u32,
    #[serde(default)]
    pub last_recovered_at: Option<String>,
    pub created_at: String,
}

impl UserDoc {
    pub fn is_dnd_active(&self, now: DateTime<Utc>) -> bool {
        self.dnd_until
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .is_some_and(|dt| dt.with_timezone(&Utc) > now)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserDto {
    pub id: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub phone: String,
    #[serde(default)]
    pub phone_verified: bool,
    #[serde(default)]
    pub email_verified: bool,
    #[serde(default)]
    pub has_google_linked: bool,
    pub display_name: String,
    pub bc_id: String,
    pub avatar_url: String,
    pub status_message: String,
    pub qr_token: String,
    pub role: String,
    pub department: String,
    pub job_title: String,
    #[serde(default)]
    pub is_oa_bot: bool,
    #[serde(default)]
    pub oa_id: Option<String>,
    #[serde(default = "default_true")]
    pub allow_add_by_phone: bool,
    #[serde(default = "default_true")]
    pub allow_add_by_id: bool,
    #[serde(default = "default_true")]
    pub allow_add_by_email: bool,
    #[serde(default = "default_true")]
    pub notify_preview: bool,
    #[serde(default = "default_true")]
    pub notify_on_mention: bool,
    #[serde(default)]
    pub dnd_until: Option<String>,
    #[serde(default)]
    pub has_recovery_pin: bool,
    #[serde(default)]
    pub recovery_codes_remaining: usize,
    #[serde(default)]
    pub last_recovered_at: Option<String>,
    pub created_at: String,
}

impl From<UserDoc> for UserDto {
    fn from(u: UserDoc) -> Self {
        let now = Utc::now();
        let active_dnd = if u.is_dnd_active(now) {
            u.dnd_until.clone()
        } else {
            None
        };
        let has_google = u
            .google_id
            .as_ref()
            .is_some_and(|g| !g.trim().is_empty())
            || (u.email_verified && !u.email.trim().is_empty());
        Self {
            id: u.id,
            email: u.email,
            phone: u.phone,
            phone_verified: u.phone_verified,
            email_verified: u.email_verified,
            has_google_linked: has_google,
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
            is_oa_bot: u.is_oa_bot,
            oa_id: u.oa_id,
            allow_add_by_phone: u.allow_add_by_phone,
            allow_add_by_id: u.allow_add_by_id,
            allow_add_by_email: u.allow_add_by_email,
            has_recovery_pin: u
                .recovery_pin_hash
                .as_deref()
                .is_some_and(|h| !h.trim().is_empty()),
            recovery_codes_remaining: u.recovery_code_hashes.len(),
            last_recovered_at: u.last_recovered_at,
            notify_preview: u.notify_preview,
            notify_on_mention: u.notify_on_mention,
            dnd_until: active_dnd,
            created_at: u.created_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FriendshipDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub user_id: String,
    pub friend_id: String,
    #[serde(default)]
    pub is_favorite: bool,
    #[serde(default)]
    pub is_blocked: bool,
    #[serde(default)]
    pub is_hidden: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FriendDto {
    pub id: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub phone: String,
    #[serde(default)]
    pub phone_verified: bool,
    #[serde(default)]
    pub email_verified: bool,
    pub display_name: String,
    pub bc_id: String,
    pub avatar_url: String,
    pub status_message: String,
    pub qr_token: String,
    pub role: String,
    pub department: String,
    pub job_title: String,
    #[serde(default)]
    pub is_favorite: bool,
    #[serde(default)]
    pub is_blocked: bool,
    #[serde(default)]
    pub is_hidden: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UserConvMeta {
    #[serde(default)]
    pub folder: String,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub is_muted: bool,
    #[serde(default)]
    pub muted_until: Option<String>,
    #[serde(default)]
    pub is_archived: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PinnedMessageSummary {
    pub id: String,
    pub sender_id: String,
    pub sender_name: String,
    #[serde(rename = "type")]
    pub msg_type: String,
    pub content: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LastMessageSummary {
    pub id: String,
    pub sender_id: String,
    pub sender_name: String,
    #[serde(rename = "type")]
    pub msg_type: String,
    pub content: String,
    pub created_at: String,
    #[serde(default)]
    pub read_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationDoc {
    #[serde(rename = "_id")]
    pub id: String,
    #[serde(rename = "type")]
    pub conv_type: String, // "direct" | "group" | "official" | "oa"
    pub name: String,
    pub avatar_url: String,
    pub folder: String, // "personal" | "family" | "group"
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub is_muted: bool,
    #[serde(default)]
    pub is_archived: bool,
    #[serde(default)]
    pub invite_token: String,
    #[serde(default)]
    pub admin_ids: Vec<String>,
    pub member_ids: Vec<String>,
    #[serde(default)]
    pub oa_id: Option<String>,
    #[serde(default)]
    pub oa_handle: Option<String>,
    #[serde(default)]
    pub user_meta: HashMap<String, UserConvMeta>,
    #[serde(default)]
    pub pinned_message: Option<PinnedMessageSummary>,
    #[serde(default)]
    pub last_message: Option<LastMessageSummary>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationMemberDto {
    pub id: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub phone: String,
    pub display_name: String,
    pub bc_id: String,
    pub avatar_url: String,
    pub status_message: String,
    pub role: String,
    pub department: String,
    pub job_title: String,
}

/// Evaluates effective mute state for `user_id` at `now`.
/// If `muted_until` is set and has already passed, returns `(false, None)`.
pub fn resolve_effective_mute(
    conv: &ConversationDoc,
    user_id: &str,
    now: DateTime<Utc>,
) -> (bool, Option<String>) {
    if let Some(entry) = conv.user_meta.get(user_id) {
        if let Some(ref raw_until) = entry.muted_until {
            let trimmed = raw_until.trim();
            if !trimmed.is_empty() {
                if let Ok(dt) = DateTime::parse_from_rfc3339(trimmed) {
                    if dt.with_timezone(&Utc) > now {
                        return (true, Some(trimmed.to_string()));
                    }
                    return (false, None);
                }
            }
        }
        return (entry.is_muted, None);
    }
    (conv.is_muted, None)
}

pub fn is_conv_effectively_muted(conv: &ConversationDoc, user_id: &str, now: DateTime<Utc>) -> bool {
    resolve_effective_mute(conv, user_id, now).0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationDto {
    pub id: String,
    #[serde(rename = "type")]
    pub conv_type: String,
    pub name: String,
    pub avatar_url: String,
    pub folder: String,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub is_muted: bool,
    #[serde(default)]
    pub muted_until: Option<String>,
    #[serde(default)]
    pub is_blocked_by_me: bool,
    #[serde(default)]
    pub is_archived: bool,
    #[serde(default)]
    pub invite_token: String,
    #[serde(default)]
    pub admin_ids: Vec<String>,
    #[serde(default)]
    pub member_ids: Vec<String>,
    #[serde(default)]
    pub oa_id: Option<String>,
    #[serde(default)]
    pub oa_handle: Option<String>,
    #[serde(default)]
    pub rich_menu: Vec<OaRichMenuItem>,
    pub pinned_message: Option<PinnedMessageSummary>,
    pub unread_count: usize,
    pub member_count: usize,
    pub members: Vec<ConversationMemberDto>,
    pub last_message: Option<LastMessageSummary>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachmentInfo {
    pub key: String,
    pub url: String,
    pub file_name: String,
    pub mime_type: String,
    pub file_size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplyInfo {
    pub id: String,
    pub sender_name: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PollOption {
    pub id: String,
    pub text: String,
    #[serde(default)]
    pub voter_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PollData {
    pub question: String,
    #[serde(default)]
    pub options: Vec<PollOption>,
    #[serde(default)]
    pub allow_multiple: bool,
    #[serde(default)]
    pub is_anonymous: bool,
    #[serde(default)]
    pub is_closed: bool,
    #[serde(default)]
    pub closed_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventData {
    pub title: String,
    #[serde(default)]
    pub description: String,
    pub starts_at: String,
    #[serde(default)]
    pub ends_at: Option<String>,
    #[serde(default)]
    pub location: String,
    #[serde(default)]
    pub going_ids: Vec<String>,
    #[serde(default)]
    pub maybe_ids: Vec<String>,
    #[serde(default)]
    pub not_going_ids: Vec<String>,
}

pub fn default_priority() -> String {
    "normal".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocationData {
    pub latitude: f64,
    pub longitude: f64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub map_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContactCardData {
    pub user_id: String,
    pub display_name: String,
    #[serde(default)]
    pub bc_id: String,
    #[serde(default)]
    pub avatar_url: String,
    #[serde(default)]
    pub status_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LadderEntry {
    pub player: String,
    pub result: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LadderGameData {
    pub title: String,
    #[serde(default)]
    pub entries: Vec<LadderEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub conversation_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar: String,
    #[serde(rename = "type")]
    pub msg_type: String, // "text"|"sticker"|"image"|"file"|"audio"|"rich_card"|"poll"|"event"|"system"
    pub content: String,
    #[serde(default)]
    pub sticker_code: Option<String>,
    #[serde(default)]
    pub attachment: Option<AttachmentInfo>,
    #[serde(default)]
    pub card_payload: Option<serde_json::Value>,
    #[serde(default)]
    pub flex_payload: Option<serde_json::Value>,
    #[serde(default)]
    pub reply_to: Option<ReplyInfo>,
    #[serde(default)]
    pub read_by: Vec<String>,
    #[serde(default)]
    pub is_unsent: bool,
    #[serde(default)]
    pub is_confidential: bool,
    #[serde(default)]
    pub confidential_pin: Option<String>,
    #[serde(default)]
    pub expire_at: Option<String>,
    #[serde(default = "default_priority")]
    pub priority: String,
    #[serde(default)]
    pub task_status: Option<String>,
    #[serde(default)]
    pub accepted_by: Option<String>,
    #[serde(default)]
    pub accepted_at: Option<String>,
    #[serde(default)]
    pub reactions: HashMap<String, Vec<String>>,
    #[serde(default)]
    pub mentions: Vec<String>,
    #[serde(default)]
    pub audio_duration_sec: Option<u32>,
    #[serde(default)]
    pub poll: Option<PollData>,
    #[serde(default)]
    pub event_data: Option<EventData>,
    #[serde(default)]
    pub location_data: Option<LocationData>,
    #[serde(default)]
    pub contact_data: Option<ContactCardData>,
    #[serde(default)]
    pub ladder_data: Option<LadderGameData>,
    #[serde(default)]
    pub edited_at: Option<String>,
    #[serde(default)]
    pub forwarded_from: Option<String>,
    #[serde(default)]
    pub deleted_for: Vec<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageDto {
    pub id: String,
    pub conversation_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar: String,
    #[serde(rename = "type")]
    pub msg_type: String,
    pub content: String,
    pub sticker_code: Option<String>,
    pub attachment: Option<AttachmentInfo>,
    #[serde(default)]
    pub card_payload: Option<serde_json::Value>,
    #[serde(default)]
    pub flex_payload: Option<serde_json::Value>,
    pub reply_to: Option<ReplyInfo>,
    pub read_by: Vec<String>,
    pub read_count: usize,
    pub is_unsent: bool,
    pub is_confidential: bool,
    pub confidential_pin: Option<String>,
    pub expire_at: Option<String>,
    pub priority: String,
    pub task_status: Option<String>,
    pub accepted_by: Option<String>,
    pub accepted_at: Option<String>,
    #[serde(default)]
    pub reactions: HashMap<String, Vec<String>>,
    #[serde(default)]
    pub mentions: Vec<String>,
    #[serde(default)]
    pub audio_duration_sec: Option<u32>,
    #[serde(default)]
    pub poll: Option<PollData>,
    #[serde(default)]
    pub event_data: Option<EventData>,
    #[serde(default)]
    pub location_data: Option<LocationData>,
    #[serde(default)]
    pub contact_data: Option<ContactCardData>,
    #[serde(default)]
    pub ladder_data: Option<LadderGameData>,
    #[serde(default)]
    pub edited_at: Option<String>,
    #[serde(default)]
    pub forwarded_from: Option<String>,
    pub created_at: String,
}

impl From<MessageDoc> for MessageDto {
    fn from(m: MessageDoc) -> Self {
        let read_count = m
            .read_by
            .iter()
            .filter(|uid| *uid != &m.sender_id)
            .count();
        let normalized_type = if m.msg_type == "flex_card" {
            "rich_card".to_string()
        } else {
            m.msg_type
        };
        let payload = m.card_payload.or(m.flex_payload);
        Self {
            id: m.id,
            conversation_id: m.conversation_id,
            sender_id: m.sender_id,
            sender_name: m.sender_name,
            sender_avatar: m.sender_avatar,
            msg_type: normalized_type,
            content: m.content,
            sticker_code: m.sticker_code,
            attachment: m.attachment,
            card_payload: payload.clone(),
            flex_payload: payload,
            reply_to: m.reply_to,
            read_by: m.read_by,
            read_count,
            is_unsent: m.is_unsent,
            is_confidential: m.is_confidential,
            confidential_pin: m.confidential_pin,
            expire_at: m.expire_at,
            priority: if m.priority.is_empty() {
                "normal".to_string()
            } else {
                m.priority
            },
            task_status: m.task_status,
            accepted_by: m.accepted_by,
            accepted_at: m.accepted_at,
            reactions: m.reactions,
            mentions: m.mentions,
            audio_duration_sec: m.audio_duration_sec,
            poll: m.poll,
            event_data: m.event_data,
            location_data: m.location_data,
            contact_data: m.contact_data,
            ladder_data: m.ladder_data,
            edited_at: m.edited_at,
            forwarded_from: m.forwarded_from,
            created_at: m.created_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoteComment {
    pub id: String,
    pub user_id: String,
    pub user_name: String,
    pub content: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoteDoc {
    #[serde(rename = "_id")]
    pub id: String,
    #[serde(default)]
    pub conversation_id: Option<String>,
    pub owner_id: String,
    pub owner_name: String,
    pub title: String,
    pub content: String,
    #[serde(default)]
    pub attachments: Vec<AttachmentInfo>,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub liked_by: Vec<String>,
    #[serde(default)]
    pub comments: Vec<NoteComment>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NoteDto {
    pub id: String,
    pub conversation_id: Option<String>,
    pub owner_id: String,
    pub user_id: String,
    pub owner_name: String,
    pub title: String,
    pub content: String,
    #[serde(default)]
    pub attachments: Vec<AttachmentInfo>,
    #[serde(default)]
    pub attachment: Option<AttachmentInfo>,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub liked_by: Vec<String>,
    #[serde(default)]
    pub comments: Vec<NoteComment>,
    pub created_at: String,
    pub updated_at: String,
}

impl From<NoteDoc> for NoteDto {
    fn from(n: NoteDoc) -> Self {
        let first_att = n.attachments.first().cloned();
        let uid = n.owner_id.clone();
        Self {
            id: n.id,
            conversation_id: n.conversation_id,
            owner_id: n.owner_id,
            user_id: uid,
            owner_name: n.owner_name,
            title: n.title,
            content: n.content,
            attachments: n.attachments,
            attachment: first_att,
            is_pinned: n.is_pinned,
            liked_by: n.liked_by,
            comments: n.comments,
            created_at: n.created_at,
            updated_at: n.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlbumDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub conversation_id: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub photos: Vec<AttachmentInfo>,
    pub created_by: String,
    pub created_by_name: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlbumDto {
    pub id: String,
    pub conversation_id: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub photos: Vec<AttachmentInfo>,
    pub created_by: String,
    pub created_by_name: String,
    pub created_at: String,
    pub updated_at: String,
}

impl From<AlbumDoc> for AlbumDto {
    fn from(a: AlbumDoc) -> Self {
        Self {
            id: a.id,
            conversation_id: a.conversation_id,
            title: a.title,
            description: a.description,
            photos: a.photos,
            created_by: a.created_by,
            created_by_name: a.created_by_name,
            created_at: a.created_at,
            updated_at: a.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub key: String,
    pub url: String,
    pub file_name: String,
    pub mime_type: String,
    pub file_size: u64,
    pub uploader_id: String,
    pub uploader_name: String,
    #[serde(default)]
    pub conversation_id: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileDto {
    pub id: String,
    pub key: String,
    pub url: String,
    pub file_name: String,
    pub mime_type: String,
    pub file_size: u64,
    pub uploader_id: String,
    pub uploader_name: String,
    pub conversation_id: Option<String>,
    pub created_at: String,
}

impl From<FileDoc> for FileDto {
    fn from(f: FileDoc) -> Self {
        Self {
            id: f.id,
            key: f.key,
            url: f.url,
            file_name: f.file_name,
            mime_type: f.mime_type,
            file_size: f.file_size,
            uploader_id: f.uploader_id,
            uploader_name: f.uploader_name,
            conversation_id: f.conversation_id,
            created_at: f.created_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MiniAppDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub app_code: String,
    pub title: String,
    pub subtitle: String,
    pub category: String,
    pub icon_name: String,
    pub color_hex: String,
    pub entry_url: String,
    pub is_active: bool,
    pub sort_order: i32,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MiniAppDto {
    pub id: String,
    pub app_code: String,
    pub code: String,
    pub title: String,
    pub subtitle: String,
    pub category: String,
    pub icon_name: String,
    pub icon: String,
    pub color_hex: String,
    pub color: String,
    pub entry_url: String,
    pub url: String,
    pub is_active: bool,
    pub enabled: bool,
    pub sort_order: i32,
    pub created_at: String,
    pub updated_at: String,
}

impl From<MiniAppDoc> for MiniAppDto {
    fn from(m: MiniAppDoc) -> Self {
        Self {
            id: m.id,
            code: m.app_code.clone(),
            app_code: m.app_code,
            title: m.title,
            subtitle: m.subtitle,
            category: m.category,
            icon: m.icon_name.clone(),
            icon_name: m.icon_name,
            color: m.color_hex.clone(),
            color_hex: m.color_hex,
            url: m.entry_url.clone(),
            entry_url: m.entry_url,
            enabled: m.is_active,
            is_active: m.is_active,
            sort_order: m.sort_order,
            created_at: m.created_at,
            updated_at: m.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultFileItem {
    pub id: String,
    pub message_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub key: String,
    pub url: String,
    pub file_name: String,
    pub mime_type: String,
    pub file_size: u64,
    pub is_confidential: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultLinkItem {
    pub id: String,
    pub message_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub url: String,
    pub content: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultResponse {
    pub images: Vec<VaultFileItem>,
    pub files: Vec<VaultFileItem>,
    pub links: Vec<VaultLinkItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSettingsDoc {
    #[serde(rename = "_id")]
    pub id: String,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub api_key: String,
    pub model: String,
    pub base_url: String,
    pub system_prompt: String,
    #[serde(default)]
    pub auto_reply_in_groups: bool,
    #[serde(default)]
    pub redact_confidential: bool,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiSettingsDto {
    pub enabled: bool,
    pub has_api_key: bool,
    pub masked_key: String,
    pub model: String,
    pub base_url: String,
    pub system_prompt: String,
    pub auto_reply_in_groups: bool,
    pub redact_confidential: bool,
    pub updated_at: String,
}

pub fn mask_secret_key(raw: &str) -> (bool, String) {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.starts_with("your-")
        || trimmed.starts_with("your_")
        || trimmed.starts_with("replace_")
    {
        return (false, "".to_string());
    }
    (true, "****-**** (ตั้งค่าแล้ว)".to_string())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthSettingsDoc {
    #[serde(rename = "_id")]
    pub id: String,
    #[serde(default)]
    pub smsmkt_api_key: String,
    #[serde(default)]
    pub smsmkt_secret_key: String,
    #[serde(default)]
    pub smsmkt_project_key: String,
    #[serde(default)]
    pub smsmkt_sender_name: String,
    #[serde(default)]
    pub google_client_id: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthSettingsDto {
    pub smsmkt_has_keys: bool,
    pub smsmkt_masked_api_key: String,
    pub smsmkt_masked_secret_key: String,
    pub smsmkt_project_key: String,
    pub smsmkt_sender_name: String,
    pub phone_otp_ready: bool,
    pub google_client_id: String,
    pub google_enabled: bool,
    pub credit_info: Option<serde_json::Value>,
    pub credit_error: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OtpSessionDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub phone: String,
    pub smsmkt_token: String,
    pub ref_code: String,
    #[serde(default)]
    pub purpose: String, // "auth" | "link"
    #[serde(default)]
    pub target_user_id: Option<String>,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default)]
    pub verified: bool,
    pub created_at: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GoogleOAuthStateDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub mode: String, // "login" | "link" | "recover"
    #[serde(default)]
    pub link_user_id: Option<String>,
    pub nonce: String,
    #[serde(default)]
    pub status: String, // "pending" | "completed" | "verified_for_recovery" | "consumed" | "error"
    #[serde(default)]
    pub verified_google_sub: Option<String>,
    #[serde(default)]
    pub verified_google_email: Option<String>,
    #[serde(default)]
    pub result_token: Option<String>,
    #[serde(default)]
    pub result_user: Option<UserDto>,
    #[serde(default)]
    pub error_message: Option<String>,
    pub created_at: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountRecoveryLogDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub user_id: String,
    pub action: String,
    pub method: String,
    pub detail_masked: String,
    pub created_at: String,
}

// =============================================================================
// BCAiChatOA — ระบบบัญชีร้านค้าทางการสำหรับเจ้าของกิจการสื่อสารกับลูกค้า
// =============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaRichMenuItem {
    pub id: String,
    pub label: String,
    #[serde(default)]
    pub subtitle: String,
    /// "keyword" | "coupon" | "url" | "ai_prompt"
    #[serde(default = "default_rich_menu_action")]
    pub action_type: String,
    #[serde(default)]
    pub action_value: String,
    #[serde(default)]
    pub icon: String,
}

fn default_rich_menu_action() -> String {
    "keyword".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaAccountDoc {
    #[serde(rename = "_id")]
    pub id: String,
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
    pub owner_id: String,
    #[serde(default)]
    pub admin_ids: Vec<String>,
    #[serde(default)]
    pub staff_roles: HashMap<String, String>,
    pub bot_user_id: String,
    #[serde(default)]
    pub is_verified: bool,
    #[serde(default)]
    pub is_active: bool,
    #[serde(default = "default_true")]
    pub calls_enabled: bool,
    #[serde(default)]
    pub ai_enabled: bool,
    #[serde(default)]
    pub ai_knowledge_prompt: String,
    #[serde(default)]
    pub rich_menu: Vec<OaRichMenuItem>,
    #[serde(default)]
    pub follower_count: usize,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaAccountDto {
    pub id: String,
    pub handle: String,
    pub display_name: String,
    pub category: String,
    pub bio: String,
    pub avatar_url: String,
    pub theme_color: String,
    pub greeting_message: String,
    pub business_hours: String,
    pub owner_id: String,
    pub admin_ids: Vec<String>,
    #[serde(default)]
    pub staff_roles: HashMap<String, String>,
    #[serde(default)]
    pub my_role: Option<String>,
    pub bot_user_id: String,
    pub is_verified: bool,
    pub is_active: bool,
    #[serde(default = "default_true")]
    pub calls_enabled: bool,
    pub ai_enabled: bool,
    pub ai_knowledge_prompt: String,
    pub rich_menu: Vec<OaRichMenuItem>,
    pub follower_count: usize,
    #[serde(default)]
    pub is_following: bool,
    #[serde(default)]
    pub conversation_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaStaffMemberDto {
    pub user_id: String,
    pub display_name: String,
    pub bc_id: String,
    #[serde(default)]
    pub phone: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub avatar_url: String,
    pub role: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaFollowerDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub oa_id: String,
    pub user_id: String,
    pub conversation_id: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub crm_note: String,
    #[serde(default)]
    pub ai_paused: bool,
    #[serde(default)]
    pub is_following: bool,
    pub followed_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaCustomerChatDto {
    pub conversation_id: String,
    pub oa_id: String,
    pub customer_id: String,
    pub customer_name: String,
    pub customer_avatar: String,
    pub customer_bc_id: String,
    #[serde(default)]
    pub customer_phone: String,
    #[serde(default)]
    pub customer_email: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub crm_note: String,
    #[serde(default)]
    pub ai_paused: bool,
    pub unread_for_oa: usize,
    pub last_message: Option<LastMessageSummary>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaAutoReplyRuleDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub oa_id: String,
    pub keyword: String,
    /// "contains" | "exact"
    #[serde(default = "default_match_mode")]
    pub match_mode: String,
    pub reply_text: String,
    #[serde(default)]
    pub card_payload: Option<serde_json::Value>,
    #[serde(default = "default_true")]
    pub is_active: bool,
    #[serde(default)]
    pub hit_count: u64,
    pub created_at: String,
}

fn default_match_mode() -> String {
    "contains".to_string()
}


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaCouponDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub oa_id: String,
    pub code: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub discount_text: String,
    #[serde(default)]
    pub expires_at: Option<String>,
    #[serde(default)]
    pub max_claims: u32,
    #[serde(default)]
    pub claimed_by: Vec<String>,
    #[serde(default)]
    pub redeemed_by: Vec<String>,
    #[serde(default = "default_true")]
    pub is_active: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaBroadcastDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub oa_id: String,
    #[serde(default)]
    pub target_tag: Option<String>,
    /// "text" | "rich_card" | "coupon"
    pub msg_type: String,
    pub content: String,
    #[serde(default)]
    pub card_payload: Option<serde_json::Value>,
    #[serde(default)]
    pub coupon_id: Option<String>,
    pub recipient_count: usize,
    pub sent_by: String,
    pub created_at: String,
}

// =============================================================================
// LiveKit Voice & Video Call Sessions
// =============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CallParticipantState {
    pub user_id: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub avatar_url: String,
    /// "ringing" | "joined" | "declined" | "left" | "missed"
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub muted_audio: bool,
    #[serde(default)]
    pub video_enabled: bool,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CallSessionDoc {
    #[serde(rename = "_id")]
    pub id: String,
    pub conversation_id: String,
    pub room_name: String,
    pub call_type: String, // "audio" | "video"
    pub status: String,    // "ringing" | "active" | "ended" | "missed" | "declined"
    pub initiator_id: String,
    #[serde(default)]
    pub initiator_name: String,
    #[serde(default)]
    pub initiator_avatar: String,
    #[serde(default)]
    pub oa_id: Option<String>,
    #[serde(default)]
    pub target_user_ids: Vec<String>,
    #[serde(default)]
    pub participants: Vec<CallParticipantState>,
    pub started_at: String,
    #[serde(default)]
    pub answered_at: Option<String>,
    #[serde(default)]
    pub ended_at: Option<String>,
    #[serde(default)]
    pub duration_sec: u64,
    #[serde(default)]
    pub end_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CallSessionDto {
    pub id: String,
    pub conversation_id: String,
    pub room_name: String,
    pub call_type: String,
    pub status: String,
    pub initiator_id: String,
    #[serde(default)]
    pub initiator_name: String,
    #[serde(default)]
    pub initiator_avatar: String,
    #[serde(default)]
    pub oa_id: Option<String>,
    #[serde(default)]
    pub target_user_ids: Vec<String>,
    #[serde(default)]
    pub participants: Vec<CallParticipantState>,
    pub started_at: String,
    #[serde(default)]
    pub answered_at: Option<String>,
    #[serde(default)]
    pub ended_at: Option<String>,
    #[serde(default)]
    pub duration_sec: u64,
    #[serde(default)]
    pub end_reason: Option<String>,
}

impl From<CallSessionDoc> for CallSessionDto {
    fn from(c: CallSessionDoc) -> Self {
        Self {
            id: c.id,
            conversation_id: c.conversation_id,
            room_name: c.room_name,
            call_type: c.call_type,
            status: c.status,
            initiator_id: c.initiator_id,
            initiator_name: c.initiator_name,
            initiator_avatar: c.initiator_avatar,
            oa_id: c.oa_id,
            target_user_ids: c.target_user_ids,
            participants: c.participants,
            started_at: c.started_at,
            answered_at: c.answered_at,
            ended_at: c.ended_at,
            duration_sec: c.duration_sec,
            end_reason: c.end_reason,
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thai_8am_rolls_to_same_or_next_morning_utc_plus_7() {
        // 00:30 UTC = 07:30 BKK -> same day 08:00 BKK = 01:00 UTC
        let before = DateTime::parse_from_rfc3339("2026-11-15T00:30:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let res1 = DateTime::parse_from_rfc3339(&next_thai_8am_utc_rfc3339(before))
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(res1.to_rfc3339(), "2026-11-15T01:00:00+00:00");

        // 02:15 UTC = 09:15 BKK -> next day 08:00 BKK = 2026-11-16T01:00:00Z
        let after = DateTime::parse_from_rfc3339("2026-11-15T02:15:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let res2 = DateTime::parse_from_rfc3339(&next_thai_8am_utc_rfc3339(after))
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(res2.to_rfc3339(), "2026-11-16T01:00:00+00:00");
    }
}
