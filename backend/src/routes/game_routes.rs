use axum::{
    extract::{Path, Query, State},
    Json,
};
use bson::doc;
use chrono::{DateTime, Duration, FixedOffset, Timelike, Utc};
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::{Mutex, OnceLock},
    time::Duration as StdDuration,
};
use uuid::Uuid;

use crate::{
    auth::{ApiError, AuthUser},
    doc_extract::{classify_attachment, AttachmentKind},
    game_catalog::{
        fallback_challenge_prompts, fallback_hint_items, fallback_party_rounds, fallback_quiz_pack,
        fallback_undercover_pair, filter_catalog, find_game_by_id, pick_random_game,
        GameCatalogItem, GAME_CATALOG, GAME_CATEGORIES,
    },
    models::{
        ActiveGameStateDto, ConversationDoc, CreativeChallengeViewDto, CreativeEntryDoc,
        CreativeEntryDto, CreativeRoundDoc, GamePlayerDoc, GamePlayerDto, GameQuestionPackDoc,
        GameSessionDoc, GameSessionDto, GameSummaryDto, HintRaceRoundDoc, HintRaceViewDto,
        LastMessageSummary, MessageDoc, MessageDto, PartyVoteRoundDoc, PartyVoteViewDto,
        ProactiveGameInviteResponse, QuizQuestionDoc, QuizQuestionViewDto, QuizRoundAnswerDoc,
        UndercoverClueDto, UndercoverDataDoc, UndercoverViewDto, UndercoverWordPairDoc, UserDoc,
    },
    routes::{
        ai_routes::{
            generate_system_ai_json, generate_system_ai_json_with_images, get_effective_ai_settings,
            is_message_confidential_for_ai, load_ai_user, load_image_for_vision,
            strip_think_blocks, AiImageInput,
        },
        chat_routes::require_member,
    },
    AppState,
};

// =============================================================================
// In-flight Proactive Guard & Time Helpers
// =============================================================================

static PROACTIVE_IN_FLIGHT: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

struct ProactiveRoomGuard {
    conv_id: String,
}

impl ProactiveRoomGuard {
    fn try_acquire(conv_id: &str) -> Option<Self> {
        let set = PROACTIVE_IN_FLIGHT.get_or_init(|| Mutex::new(HashSet::new()));
        let mut guard = set.lock().ok()?;
        if guard.insert(conv_id.to_string()) {
            Some(Self {
                conv_id: conv_id.to_string(),
            })
        } else {
            None
        }
    }
}

impl Drop for ProactiveRoomGuard {
    fn drop(&mut self) {
        if let Some(set) = PROACTIVE_IN_FLIGHT.get() {
            if let Ok(mut guard) = set.lock() {
                guard.remove(&self.conv_id);
            }
        }
    }
}

/// Returns true when local Bangkok time (UTC+7) is between 07:00 and 22:59.
pub fn is_bangkok_awake_hour(now: DateTime<Utc>) -> bool {
    let bkk = FixedOffset::east_opt(7 * 3600).expect("valid UTC+7 offset");
    let hour = now.with_timezone(&bkk).hour();
    (7..23).contains(&hour)
}

/// Returns true if no previous AI game invite exists or the room's cooldown has elapsed.
pub fn is_proactive_cooldown_elapsed(conv: &ConversationDoc, now: DateTime<Utc>) -> bool {
    let Some(raw) = conv
        .last_ai_game_invite_at
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return true;
    };
    let Ok(last_dt) = DateTime::parse_from_rfc3339(raw) else {
        return true;
    };
    let cooldown = Duration::minutes(conv.effective_ai_game_invite_cooldown_mins() as i64);
    now.signed_duration_since(last_dt.with_timezone(&Utc)) >= cooldown
}

fn fresh_seed() -> u64 {
    let u = Uuid::new_v4().as_u128();
    let lo = u as u64;
    let hi = (u >> 64) as u64;
    let ts = Utc::now().timestamp_nanos_opt().unwrap_or(0) as u64;
    lo ^ hi.rotate_left(17) ^ ts.rotate_left(31)
}

fn clean_ai_text(raw: &str, max_chars: usize) -> String {
    let stripped = strip_think_blocks(raw);
    let compact = stripped
        .replace("**", "")
        .replace("```", "")
        .trim()
        .to_string();
    if compact.chars().count() <= max_chars {
        compact
    } else {
        compact.chars().take(max_chars).collect()
    }
}

fn extract_json_value(raw: &str) -> Option<Value> {
    let cleaned = strip_think_blocks(raw);
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
        return Some(v);
    }

    // Strip optional ```json ... ``` markdown code fences
    let unfenced = if trimmed.starts_with("```") {
        let mut lines = trimmed.lines();
        lines.next();
        let body: Vec<&str> = lines.collect();
        let body = if body.last().is_some_and(|l| l.trim().starts_with("```")) {
            &body[..body.len().saturating_sub(1)]
        } else {
            &body[..]
        };
        body.join("\n")
    } else {
        trimmed.to_string()
    };
    if let Ok(v) = serde_json::from_str::<Value>(unfenced.trim()) {
        return Some(v);
    }

    // Slice between outermost {...} or [...]
    if let (Some(start), Some(end)) = (unfenced.find('{'), unfenced.rfind('}')) {
        if start < end {
            if let Ok(v) = serde_json::from_str::<Value>(&unfenced[start..=end]) {
                return Some(v);
            }
        }
    }
    if let (Some(start), Some(end)) = (unfenced.find('['), unfenced.rfind(']')) {
        if start < end {
            if let Ok(v) = serde_json::from_str::<Value>(&unfenced[start..=end]) {
                return Some(v);
            }
        }
    }
    None
}

fn normalize_guess_text(raw: &str) -> String {
    raw.trim()
        .to_lowercase()
        .chars()
        .filter(|c| !c.is_whitespace() && !matches!(c, '.' | ',' | '!' | '?' | '"' | '\'' | '-' | '_' | 'ๆ'))
        .collect()
}

fn is_hint_guess_correct(guess: &str, answer: &str, aliases: &[String]) -> bool {
    let norm_guess = normalize_guess_text(guess);
    if norm_guess.is_empty() {
        return false;
    }
    let mut targets = Vec::with_capacity(1 + aliases.len());
    targets.push(answer);
    for a in aliases {
        targets.push(a.as_str());
    }
    for t in targets {
        let norm_t = normalize_guess_text(t);
        if norm_t.is_empty() {
            continue;
        }
        if norm_guess == norm_t {
            return true;
        }
        if norm_t.chars().count() >= 4 && norm_guess.contains(&norm_t) {
            return true;
        }
    }
    false
}

fn deterministic_hash(s: &str) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    h
}

fn default_catalog_item_for_engine(engine: &str) -> &'static GameCatalogItem {
    GAME_CATALOG
        .iter()
        .find(|item| item.engine == engine)
        .unwrap_or(&GAME_CATALOG[0])
}

// =============================================================================
// WS Broadcast & Chat Message Posting
// =============================================================================

/// Broadcasts ONLY safe status/phase metadata — NEVER secret words or unrevealed answers!
fn broadcast_game_updated(state: &AppState, game: &GameSessionDoc) {
    state.ws_hub.broadcast_event(json!({
        "event": "game_updated",
        "conversation_id": game.conversation_id,
        "game_id": game.id,
        "status": game.status,
        "phase": game.phase,
    }));
}

async fn insert_game_rich_card_message(
    state: &AppState,
    conv: &mut ConversationDoc,
    sender: &UserDoc,
    content: String,
    card_payload: Value,
) -> Result<MessageDto, String> {
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");

    let now = Utc::now().to_rfc3339();
    let msg_id = Uuid::new_v4().to_string();

    let msg_doc = MessageDoc {
        id: msg_id.clone(),
        conversation_id: conv.id.clone(),
        sender_id: sender.id.clone(),
        sender_name: sender.display_name.clone(),
        sender_avatar: sender.avatar_url.clone(),
        msg_type: "rich_card".to_string(),
        content: content.clone(),
        sticker_code: None,
        attachment: None,
        card_payload: Some(card_payload.clone()),
        flex_payload: Some(card_payload),
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
        .insert_one(&msg_doc)
        .await
        .map_err(|e| e.to_string())?;

    conv.last_message = Some(LastMessageSummary {
        id: msg_id,
        sender_id: sender.id.clone(),
        sender_name: sender.display_name.clone(),
        msg_type: "rich_card".to_string(),
        content: content.chars().take(140).collect(),
        created_at: now.clone(),
        read_count: 0,
    });
    conv.updated_at = now;

    let _ = conv_coll
        .replace_one(doc! { "_id": &conv.id }, &*conv)
        .await;

    let dto = MessageDto::from(msg_doc);
    state.ws_hub.broadcast_event(json!({
        "event": "new_message",
        "conversation_id": conv.id,
        "message": dto,
    }));
    crate::push::notify_new_message(state, conv, &dto);

    Ok(dto)
}

async fn post_game_invite_card(
    state: &AppState,
    conv: &mut ConversationDoc,
    sender: &UserDoc,
    game: &GameSessionDoc,
) -> Result<MessageDto, String> {
    let payload = json!({
        "kind": "game_invite",
        "game_id": game.id,
        "game_type": game.game_type,
        "catalog_id": game.catalog_id,
        "emoji": game.emoji,
        "category": game.category,
        "play_mode": game.play_mode,
        "title": game.title,
        "topic": game.topic,
        "proactive": game.proactive,
        "host_message": game.host_message,
    });
    let content = format!("🎮 {} — {}", game.title, game.host_message);
    insert_game_rich_card_message(state, conv, sender, content, payload).await
}

async fn post_game_result_card(state: &AppState, game: &GameSessionDoc) {
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let Ok(Some(mut conv)) = conv_coll
        .find_one(doc! { "_id": &game.conversation_id })
        .await
    else {
        return;
    };
    let ai_user = load_ai_user(state).await;

    let mut ranked = game.players.clone();
    ranked.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.display_name.cmp(&b.display_name)));

    let leaderboard_lines: Vec<String> = ranked
        .iter()
        .enumerate()
        .take(5)
        .map(|(i, p)| format!("{}. {} {} คะแนน", i + 1, p.display_name, p.score))
        .collect();
    let leaderboard_summary = if leaderboard_lines.is_empty() {
        "ไม่มีคะแนนในรอบนี้".to_string()
    } else {
        leaderboard_lines.join(" · ")
    };

    let heading = if game.game_type == "undercover" {
        if let Some(ref uc) = game.undercover {
            let spy_name = uc
                .spy_user_id
                .as_deref()
                .and_then(|sid| game.players.iter().find(|p| p.user_id == sid))
                .map(|p| p.display_name.as_str())
                .unwrap_or("สายลับ");
            let side_text = if uc.winner_side.as_deref() == Some("civilians") {
                format!("จับสายลับสำเร็จ! ({spy_name} คือสายลับ)")
            } else {
                format!("สายลับ {spy_name} เนียนรอดไปได้!")
            };
            format!(
                "{} | คำชาวบ้าน: {} · คำสายลับ: {}",
                side_text, uc.civilian_word, uc.spy_word
            )
        } else {
            "จบเกมใครคือสายลับแล้ว!".to_string()
        }
    } else if !game.winner_names.is_empty() {
        format!("ผู้ชนะ: {}", game.winner_names.join(", "))
    } else {
        "จบเกมเรียบร้อย สนุกมากเลย!".to_string()
    };

    let leaderboard_json: Vec<Value> = ranked
        .iter()
        .map(|p| {
            json!({
                "user_id": p.user_id,
                "display_name": p.display_name,
                "score": p.score,
            })
        })
        .collect();

    let card_title = format!("🏆 สรุปผล: {}", game.title);
    let payload = json!({
        "kind": "game_result",
        "game_id": game.id,
        "game_type": game.game_type,
        "catalog_id": game.catalog_id,
        "title": card_title,
        "heading": heading,
        "subtitle": leaderboard_summary,
        "highlight_value": if game.winner_names.is_empty() {
            "🎉 จบเกมแล้ว!".to_string()
        } else {
            format!("🏆 {}", game.winner_names.join(", "))
        },
        "color_hex": "#812920",
        "status_label": "จบเกม",
        "winner_names": game.winner_names,
        "leaderboard": leaderboard_json,
    });
    let content = format!(
        "🏆 สรุปผลเกม {}\n{}\n{}",
        game.title, heading, leaderboard_summary
    );

    let _ = insert_game_rich_card_message(state, &mut conv, &ai_user, content, payload).await;
}

// =============================================================================
// View Projection (Strict Per-Player Security!)
// =============================================================================

pub(crate) fn to_game_dto(doc: &GameSessionDoc, viewer_user_id: &str) -> GameSessionDto {
    let round_key = doc.round_index.to_string();
    let cur_quiz_answers = doc.round_answers.get(&round_key);
    let cur_hint = doc.hint_rounds.get(doc.round_index);
    let cur_party = doc.party_rounds.get(doc.round_index);
    let cur_creative = doc.creative_rounds.get(doc.round_index);

    let players: Vec<GamePlayerDto> = doc
        .players
        .iter()
        .map(|p| {
            let answered = match doc.game_type.as_str() {
                "quiz" => cur_quiz_answers.is_some_and(|m| m.contains_key(&p.user_id)),
                "undercover" => doc
                    .undercover
                    .as_ref()
                    .is_some_and(|u| u.clues.contains_key(&p.user_id)),
                "hint_race" => cur_hint.is_some_and(|r| {
                    r.solved_by_id.as_deref() == Some(p.user_id.as_str())
                        || r.guesses.get(&p.user_id).is_some_and(|g| !g.is_empty())
                }),
                "party_vote" => cur_party.is_some_and(|r| r.votes.contains_key(&p.user_id)),
                "creative_challenge" => {
                    cur_creative.is_some_and(|r| r.entries.iter().any(|e| e.user_id == p.user_id))
                }
                _ => false,
            };
            let voted = match doc.game_type.as_str() {
                "undercover" => doc
                    .undercover
                    .as_ref()
                    .is_some_and(|u| u.votes.contains_key(&p.user_id)),
                "party_vote" => cur_party.is_some_and(|r| r.votes.contains_key(&p.user_id)),
                _ => false,
            };
            let clue = if doc.game_type == "undercover" {
                doc.undercover
                    .as_ref()
                    .and_then(|u| u.clues.get(&p.user_id).cloned())
            } else {
                None
            };
            GamePlayerDto {
                user_id: p.user_id.clone(),
                display_name: p.display_name.clone(),
                avatar_url: p.avatar_url.clone(),
                score: p.score,
                answered,
                voted,
                clue,
            }
        })
        .collect();

    let is_active_or_finished = doc.status == "playing" || doc.status == "finished";

    // 1. Quiz view — SECURITY: never leak correct_index/explanation before round_revealed/finished
    let current_question = if doc.game_type == "quiz" && is_active_or_finished {
        let q_idx = doc.round_index.min(doc.questions.len().saturating_sub(1));
        doc.questions.get(q_idx).map(|q| {
            let is_revealed = doc.round_revealed || doc.status == "finished";
            let q_key = q_idx.to_string();
            let q_answers = doc.round_answers.get(&q_key);
            let my_choice = q_answers
                .and_then(|m| m.get(viewer_user_id))
                .map(|a| a.choice_index);
            let mut choice_counts = vec![0usize; q.options.len()];
            if is_revealed {
                if let Some(ans_map) = q_answers {
                    for a in ans_map.values() {
                        if a.choice_index < choice_counts.len() {
                            choice_counts[a.choice_index] += 1;
                        }
                    }
                }
            }
            QuizQuestionViewDto {
                question: q.question.clone(),
                options: q.options.clone(),
                correct_index: if is_revealed {
                    Some(q.correct_index)
                } else {
                    None
                },
                explanation: if is_revealed {
                    Some(q.explanation.clone())
                } else {
                    None
                },
                my_choice,
                choice_counts,
            }
        })
    } else {
        None
    };

    // 2. Undercover view — SECURITY: my_secret_word ONLY for authenticated joined player; revealed_* ONLY when finished
    let undercover = if doc.game_type == "undercover" {
        doc.undercover.as_ref().map(|u| {
            let is_joined = doc.players.iter().any(|p| p.user_id == viewer_user_id);
            let my_secret_word = if is_joined && is_active_or_finished {
                if u.spy_user_id.as_deref() == Some(viewer_user_id) {
                    Some(u.spy_word.clone())
                } else {
                    Some(u.civilian_word.clone())
                }
            } else {
                None
            };
            let clues: Vec<UndercoverClueDto> = doc
                .players
                .iter()
                .filter_map(|p| {
                    u.clues.get(&p.user_id).map(|clue| UndercoverClueDto {
                        user_id: p.user_id.clone(),
                        display_name: p.display_name.clone(),
                        clue: clue.clone(),
                    })
                })
                .collect();
            let mut vote_counts: HashMap<String, usize> = HashMap::new();
            for target_id in u.votes.values() {
                *vote_counts.entry(target_id.clone()).or_insert(0) += 1;
            }
            let is_finished = doc.status == "finished";
            let revealed_spy_name = if is_finished {
                u.spy_user_id.as_deref().and_then(|sid| {
                    doc.players
                        .iter()
                        .find(|p| p.user_id == sid)
                        .map(|p| p.display_name.clone())
                })
            } else {
                None
            };
            UndercoverViewDto {
                category: u.category.clone(),
                my_secret_word,
                my_clue: u.clues.get(viewer_user_id).cloned(),
                my_vote: u.votes.get(viewer_user_id).cloned(),
                clues,
                vote_counts,
                revealed_spy_id: if is_finished {
                    u.spy_user_id.clone()
                } else {
                    None
                },
                revealed_spy_name,
                revealed_civilian_word: if is_finished {
                    Some(u.civilian_word.clone())
                } else {
                    None
                },
                revealed_spy_word: if is_finished {
                    Some(u.spy_word.clone())
                } else {
                    None
                },
                winner_side: if is_finished {
                    u.winner_side.clone()
                } else {
                    None
                },
            }
        })
    } else {
        None
    };

    // 3. Hint Race view — SECURITY: revealed_answer is None until solved/revealed/finished
    let hint_race = if doc.game_type == "hint_race" && is_active_or_finished {
        let r_idx = doc.round_index.min(doc.hint_rounds.len().saturating_sub(1));
        doc.hint_rounds.get(r_idx).map(|r| {
            let is_revealed = r.solved_by_id.is_some() || doc.round_revealed || doc.status == "finished";
            let total_hints = r.hints.len();
            let level = r.hint_level.clamp(1, total_hints.max(1));
            let revealed_hints = if is_revealed {
                r.hints.clone()
            } else {
                r.hints.iter().take(level).cloned().collect()
            };
            HintRaceViewDto {
                revealed_hints,
                total_hints,
                hint_level: level,
                solved_by_name: r.solved_by_name.clone(),
                revealed_answer: if is_revealed {
                    Some(r.answer.clone())
                } else {
                    None
                },
                my_guesses: r
                    .guesses
                    .get(viewer_user_id)
                    .cloned()
                    .unwrap_or_default(),
            }
        })
    } else {
        None
    };

    // 4. Party Vote view — commentary shown only when round_revealed or finished
    let party_vote = if doc.game_type == "party_vote" && is_active_or_finished {
        let r_idx = doc.round_index.min(doc.party_rounds.len().saturating_sub(1));
        doc.party_rounds.get(r_idx).map(|r| {
            let is_revealed = doc.round_revealed || doc.status == "finished";
            let my_choice = r.votes.get(viewer_user_id).copied();
            let mut choice_counts = vec![0usize; r.options.len()];
            if is_revealed || my_choice.is_some() {
                for &idx in r.votes.values() {
                    if idx < choice_counts.len() {
                        choice_counts[idx] += 1;
                    }
                }
            }
            PartyVoteViewDto {
                prompt: r.prompt.clone(),
                options: r.options.clone(),
                my_choice,
                choice_counts,
                commentary: if is_revealed {
                    Some(r.commentary.clone())
                } else {
                    None
                },
            }
        })
    } else {
        None
    };

    // 5. Creative Challenge view — hide peers' answers until round_revealed/finished
    let creative_challenge = if doc.game_type == "creative_challenge" && is_active_or_finished {
        let r_idx = doc
            .round_index
            .min(doc.creative_rounds.len().saturating_sub(1));
        doc.creative_rounds.get(r_idx).map(|r| {
            let is_revealed = doc.round_revealed || doc.status == "finished";
            let my_submitted = r.entries.iter().any(|e| e.user_id == viewer_user_id);
            let entries = r
                .entries
                .iter()
                .filter(|e| is_revealed || e.user_id == viewer_user_id)
                .map(|e| CreativeEntryDto {
                    user_id: e.user_id.clone(),
                    display_name: e.display_name.clone(),
                    text: e.text.clone(),
                    image_url: e.image_url.clone(),
                    score: if is_revealed { e.score } else { None },
                    judge_comment: if is_revealed {
                        e.judge_comment.clone()
                    } else {
                        None
                    },
                })
                .collect();
            CreativeChallengeViewDto {
                prompt: r.prompt.clone(),
                tip: r.tip.clone(),
                requires_image: r.requires_image,
                my_submitted,
                entries,
            }
        })
    } else {
        None
    };

    GameSessionDto {
        id: doc.id.clone(),
        conversation_id: doc.conversation_id.clone(),
        game_type: doc.game_type.clone(),
        catalog_id: doc.catalog_id.clone(),
        emoji: doc.emoji.clone(),
        category: doc.category.clone(),
        play_mode: doc.play_mode.clone(),
        tagline: doc.tagline.clone(),
        title: doc.title.clone(),
        topic: doc.topic.clone(),
        status: doc.status.clone(),
        phase: doc.phase.clone(),
        proactive: doc.proactive,
        host_message: doc.host_message.clone(),
        created_by: doc.created_by.clone(),
        created_by_name: doc.created_by_name.clone(),
        players,
        round_index: doc.round_index,
        total_rounds: doc.total_rounds,
        round_revealed: doc.round_revealed,
        current_question,
        undercover,
        hint_race,
        party_vote,
        creative_challenge,
        winner_names: doc.winner_names.clone(),
        created_at: doc.created_at.clone(),
        updated_at: doc.updated_at.clone(),
    }
}

fn to_game_summary(doc: &GameSessionDoc) -> GameSummaryDto {
    GameSummaryDto {
        id: doc.id.clone(),
        game_type: doc.game_type.clone(),
        catalog_id: doc.catalog_id.clone(),
        emoji: doc.emoji.clone(),
        title: doc.title.clone(),
        topic: doc.topic.clone(),
        status: doc.status.clone(),
        winner_names: doc.winner_names.clone(),
        player_count: doc.players.len(),
        created_at: doc.created_at.clone(),
    }
}

// =============================================================================
// Content Generation (AI-First + MongoDB Pack Cache + 100-Game Fallback Banks)
// =============================================================================

async fn generate_quiz_questions(
    state: &AppState,
    item: &GameCatalogItem,
    topic_label: &str,
    count: usize,
    seed: u64,
) -> Vec<QuizQuestionDoc> {
    let target = count.clamp(1, 10);
    let topic_key = format!("{}::{}", item.id, topic_label.trim().to_lowercase());
    let mut questions: Vec<QuizQuestionDoc> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    let system_prompt = "คุณคือผู้สร้างโจทย์ควิซสายฟ้าภาษาไทยสำหรับแอป BC Ai Chat ตอบกลับเป็น JSON เท่านั้น ห้ามใส่ Markdown ห้ามใส่คำอธิบายนอก JSON และห้ามมีแท็ก <think>";
    let user_prompt = format!(
        "สร้างคำถามควิซสนุกๆ ภาษาไทย จำนวน {target} ข้อ สำหรับเกม \"{}\" หัวข้อ \"{}\" (แนวทาง: {})\n\
         รูปแบบ JSON:\n\
         {{\"questions\":[{{\"question\":\"...\",\"options\":[\"ตัวเลือก1\",\"ตัวเลือก2\",\"ตัวเลือก3\",\"ตัวเลือก4\"],\"correct_index\":0,\"explanation\":\"อธิบายสั้นๆ 1 ประโยค\"}}]}}\n\
         กติกา: options ต้องมีครบ 4 ตัวเลือกไม่ซ้ำกัน, correct_index เป็น 0 ถึง 3 เท่านั้น, ภาษาไทยล้วนเข้าใจง่ายและสนุก",
        item.name, topic_label, item.ai_topic_hint
    );

    let max_tokens = if target <= 5 { 950 } else { 1500 };
    if let Some(raw) = generate_system_ai_json(state, system_prompt, &user_prompt, max_tokens).await
    {
        if let Some(val) = extract_json_value(&raw) {
            let arr_opt = val
                .get("questions")
                .and_then(|q| q.as_array())
                .or_else(|| val.as_array());
            if let Some(arr) = arr_opt {
                for entry in arr {
                    let q_text = entry
                        .get("question")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 220))
                        .unwrap_or_default();
                    let opts: Vec<String> = entry
                        .get("options")
                        .and_then(|v| v.as_array())
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| x.as_str())
                                .map(|s| clean_ai_text(s, 100))
                                .filter(|s| !s.is_empty())
                                .take(4)
                                .collect()
                        })
                        .unwrap_or_default();
                    let correct_idx = entry
                        .get("correct_index")
                        .and_then(|v| v.as_u64())
                        .map(|n| n as usize);
                    let explanation = entry
                        .get("explanation")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 220))
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "เฉลยจาก BC AI!".to_string());

                    if !q_text.is_empty()
                        && opts.len() == 4
                        && correct_idx.is_some_and(|i| i < 4)
                        && seen.insert(q_text.to_lowercase())
                    {
                        questions.push(QuizQuestionDoc {
                            question: q_text,
                            options: opts,
                            correct_index: correct_idx.unwrap(),
                            explanation,
                        });
                        if questions.len() >= target {
                            break;
                        }
                    }
                }
            }
        }
    }

    // Cache fresh AI-generated quiz pack in MongoDB
    if !questions.is_empty() {
        let now = Utc::now().to_rfc3339();
        let pack = GameQuestionPackDoc {
            id: format!("quiz_{}", topic_key),
            game_type: "quiz".to_string(),
            topic_key: topic_key.clone(),
            topic_label: topic_label.to_string(),
            questions: questions.clone(),
            word_pairs: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
        };
        let _ = state
            .db
            .collection::<GameQuestionPackDoc>("game_question_packs")
            .replace_one(
                doc! { "game_type": "quiz", "topic_key": &topic_key },
                &pack,
            )
            .upsert(true)
            .await;
    }

    // Pad from cached public DB pack if AI was offline or returned fewer questions
    if questions.len() < target {
        if let Ok(Some(cached)) = state
            .db
            .collection::<GameQuestionPackDoc>("game_question_packs")
            .find_one(doc! { "game_type": "quiz", "topic_key": &topic_key })
            .await
        {
            for q in cached.questions {
                if q.options.len() == 4
                    && q.correct_index < 4
                    && seen.insert(q.question.to_lowercase())
                {
                    questions.push(q);
                    if questions.len() >= target {
                        break;
                    }
                }
            }
        }
    }

    // Pad from curated Thai fallback bank
    if questions.len() < target {
        for fb in fallback_quiz_pack(item, target + 4, seed) {
            if fb.options.len() == 4
                && fb.correct_index < 4
                && seen.insert(fb.question.to_lowercase())
            {
                questions.push(QuizQuestionDoc {
                    question: fb.question,
                    options: fb.options,
                    correct_index: fb.correct_index,
                    explanation: fb.explanation,
                });
                if questions.len() >= target {
                    break;
                }
            }
        }
    }

    questions.truncate(target);
    questions
}

async fn generate_undercover_pair(
    state: &AppState,
    item: &GameCatalogItem,
    topic_label: &str,
    seed: u64,
) -> (String, String, String) {
    let system_prompt = "คุณคือผู้สร้างคู่คำลับสำหรับเกมใครคือสายลับ (Undercover) ภาษาไทย ตอบกลับเป็น JSON เท่านั้น ห้ามใส่ Markdown ห้ามมีแท็ก <think>";
    let user_prompt = format!(
        "คิดคู่คำภาษาไทย 1 คู่ที่ใกล้เคียงกันมากแต่เป็นคนละอย่าง สำหรับเกม \"{}\" หมวด \"{}\" (แนวทาง: {})\n\
         รูปแบบ JSON: {{\"category\":\"ชื่อหมวดสั้นๆ\",\"civilian_word\":\"คำชาวบ้าน\",\"spy_word\":\"คำสายลับ\"}}\n\
         กติกา: ทั้งสองคำต้องเป็นภาษาไทยสั้นกระชับ ไม่ซ้ำกัน และสนุกเวลาให้เพื่อนใบ้คำ",
        item.name, topic_label, item.ai_topic_hint
    );

    if let Some(raw) = generate_system_ai_json(state, system_prompt, &user_prompt, 260).await {
        if let Some(val) = extract_json_value(&raw) {
            let cat = val
                .get("category")
                .and_then(|v| v.as_str())
                .map(|s| clean_ai_text(s, 60))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| topic_label.to_string());
            let civ = val
                .get("civilian_word")
                .and_then(|v| v.as_str())
                .map(|s| clean_ai_text(s, 60))
                .unwrap_or_default();
            let spy = val
                .get("spy_word")
                .and_then(|v| v.as_str())
                .map(|s| clean_ai_text(s, 60))
                .unwrap_or_default();
            if !civ.is_empty() && !spy.is_empty() && civ.to_lowercase() != spy.to_lowercase() {
                let now = Utc::now().to_rfc3339();
                let topic_key = format!("{}::{}", item.id, cat.to_lowercase());
                let pack = GameQuestionPackDoc {
                    id: format!("undercover_{}", topic_key),
                    game_type: "undercover".to_string(),
                    topic_key: topic_key.clone(),
                    topic_label: cat.clone(),
                    questions: Vec::new(),
                    word_pairs: vec![UndercoverWordPairDoc {
                        category: cat.clone(),
                        civilian_word: civ.clone(),
                        spy_word: spy.clone(),
                    }],
                    created_at: now.clone(),
                    updated_at: now,
                };
                let _ = state
                    .db
                    .collection::<GameQuestionPackDoc>("game_question_packs")
                    .replace_one(
                        doc! { "game_type": "undercover", "topic_key": &topic_key },
                        &pack,
                    )
                    .upsert(true)
                    .await;
                return (cat, civ, spy);
            }
        }
    }

    let (cat, civ, spy) = fallback_undercover_pair(item, seed);
    (cat.to_string(), civ.to_string(), spy.to_string())
}

async fn generate_hint_race_rounds(
    state: &AppState,
    item: &GameCatalogItem,
    topic_label: &str,
    count: usize,
    seed: u64,
) -> Vec<HintRaceRoundDoc> {
    let target = count.clamp(1, 8);
    let mut rounds: Vec<HintRaceRoundDoc> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    let system_prompt = "คุณคือผู้สร้างโจทย์ทายคำจากคำใบ้ 5 ระดับภาษาไทยสำหรับแอป BC Ai Chat ตอบกลับเป็น JSON เท่านั้น ห้ามใส่ Markdown ห้ามมีแท็ก <think>";
    let user_prompt = format!(
        "สร้างโจทย์ทายคำภาษาไทย {target} ข้อ สำหรับเกม \"{}\" หัวข้อ \"{}\" (แนวทาง: {})\n\
         รูปแบบ JSON: {{\"items\":[{{\"answer\":\"คำตอบ\",\"aliases\":[\"คำตอบอีกแบบ\"],\"hints\":[\"คำใบ้1ยาก\",\"คำใบ้2\",\"คำใบ้3\",\"คำใบ้4\",\"คำใบ้5ง่ายมาก\"]}}]}}\n\
         กติกา: hints ต้องมีครบ 5 ระดับจากยากไปง่าย ห้ามใส่คำตอบตรงๆ ลงในคำใบ้",
        item.name, topic_label, item.ai_topic_hint
    );

    if let Some(raw) = generate_system_ai_json(state, system_prompt, &user_prompt, 900).await {
        if let Some(val) = extract_json_value(&raw) {
            let arr_opt = val
                .get("items")
                .and_then(|v| v.as_array())
                .or_else(|| val.as_array());
            if let Some(arr) = arr_opt {
                for entry in arr {
                    let answer = entry
                        .get("answer")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 80))
                        .unwrap_or_default();
                    let aliases: Vec<String> = entry
                        .get("aliases")
                        .and_then(|v| v.as_array())
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| x.as_str())
                                .map(|s| clean_ai_text(s, 80))
                                .filter(|s| !s.is_empty())
                                .collect()
                        })
                        .unwrap_or_default();
                    let mut hints: Vec<String> = entry
                        .get("hints")
                        .and_then(|v| v.as_array())
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| x.as_str())
                                .map(|s| clean_ai_text(s, 180))
                                .filter(|s| !s.is_empty())
                                .take(5)
                                .collect()
                        })
                        .unwrap_or_default();
                    if !answer.is_empty() && hints.len() >= 3 && seen.insert(answer.to_lowercase()) {
                        while hints.len() < 5 {
                            hints.push(format!(
                                "คำใบ้เสริม: คำตอบขึ้นต้นด้วย \"{}\"",
                                answer.chars().next().unwrap_or('ก')
                            ));
                        }
                        rounds.push(HintRaceRoundDoc {
                            answer,
                            aliases,
                            hints,
                            hint_level: 1,
                            solved_by_id: None,
                            solved_by_name: None,
                            guesses: HashMap::new(),
                        });
                        if rounds.len() >= target {
                            break;
                        }
                    }
                }
            }
        }
    }

    if rounds.len() < target {
        for fb in fallback_hint_items(item, target + 4, seed) {
            if !fb.answer.is_empty()
                && !fb.hints.is_empty()
                && seen.insert(fb.answer.to_lowercase())
            {
                rounds.push(HintRaceRoundDoc {
                    answer: fb.answer,
                    aliases: fb.aliases,
                    hints: fb.hints,
                    hint_level: 1,
                    solved_by_id: None,
                    solved_by_name: None,
                    guesses: HashMap::new(),
                });
                if rounds.len() >= target {
                    break;
                }
            }
        }
    }

    rounds.truncate(target);
    rounds
}

async fn generate_party_vote_rounds(
    state: &AppState,
    item: &GameCatalogItem,
    topic_label: &str,
    count: usize,
    seed: u64,
) -> Vec<PartyVoteRoundDoc> {
    let target = count.clamp(1, 10);
    let mut rounds: Vec<PartyVoteRoundDoc> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    let system_prompt = "คุณคือพิธีกรเกมโหวตปาร์ตี้/เนื้อเรื่องภาษาไทยสุดฮาสำหรับแอป BC Ai Chat ตอบกลับเป็น JSON เท่านั้น ห้ามใส่ Markdown ห้ามมีแท็ก <think>";
    let user_prompt = format!(
        "สร้างโจทย์โหวตสนุกๆ ภาษาไทย {target} รอบ สำหรับเกม \"{}\" หัวข้อ \"{}\" (แนวทาง: {})\n\
         รูปแบบ JSON: {{\"rounds\":[{{\"prompt\":\"คำถามหรือสถานการณ์\",\"options\":[\"ตัวเลือก1\",\"ตัวเลือก2\",\"ตัวเลือก3\"],\"commentary\":\"คอมเมนต์แซวฮาๆ สั้นๆ หลังเปิดผลโหวต\"}}]}}\n\
         กติกา: options 2 ถึง 4 ข้อ, ภาษาไทยสนุกเป็นกันเองไม่หยาบคาย",
        item.name, topic_label, item.ai_topic_hint
    );

    if let Some(raw) = generate_system_ai_json(state, system_prompt, &user_prompt, 950).await {
        if let Some(val) = extract_json_value(&raw) {
            let arr_opt = val
                .get("rounds")
                .and_then(|v| v.as_array())
                .or_else(|| val.as_array());
            if let Some(arr) = arr_opt {
                for entry in arr {
                    let prompt = entry
                        .get("prompt")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 220))
                        .unwrap_or_default();
                    let options: Vec<String> = entry
                        .get("options")
                        .and_then(|v| v.as_array())
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| x.as_str())
                                .map(|s| clean_ai_text(s, 100))
                                .filter(|s| !s.is_empty())
                                .take(4)
                                .collect()
                        })
                        .unwrap_or_default();
                    let commentary = entry
                        .get("commentary")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 200))
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "เสียงส่วนใหญ่ว่าไงก็ว่าตามกันเลย!".to_string());
                    if !prompt.is_empty()
                        && (2..=4).contains(&options.len())
                        && seen.insert(prompt.to_lowercase())
                    {
                        rounds.push(PartyVoteRoundDoc {
                            prompt,
                            options,
                            commentary,
                            votes: HashMap::new(),
                            scored: false,
                        });
                        if rounds.len() >= target {
                            break;
                        }
                    }
                }
            }
        }
    }

    if rounds.len() < target {
        for fb in fallback_party_rounds(item, target + 4, seed) {
            if !fb.prompt.is_empty()
                && (2..=4).contains(&fb.options.len())
                && seen.insert(fb.prompt.to_lowercase())
            {
                rounds.push(PartyVoteRoundDoc {
                    prompt: fb.prompt,
                    options: fb.options,
                    commentary: fb.commentary,
                    votes: HashMap::new(),
                    scored: false,
                });
                if rounds.len() >= target {
                    break;
                }
            }
        }
    }

    rounds.truncate(target);
    rounds
}

async fn generate_creative_rounds(
    state: &AppState,
    item: &GameCatalogItem,
    topic_label: &str,
    count: usize,
    seed: u64,
) -> Vec<CreativeRoundDoc> {
    let target = count.clamp(1, 8);
    let fallbacks = fallback_challenge_prompts(item, target + 4, seed);
    let default_requires_image = fallbacks.first().is_some_and(|f| f.requires_image);

    let mut rounds: Vec<CreativeRoundDoc> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    let system_prompt = "คุณคือพิธีกรเกมสร้างสรรค์ภาษาไทยสุดฮาสำหรับแอป BC Ai Chat ตอบกลับเป็น JSON เท่านั้น ห้ามใส่ Markdown ห้ามมีแท็ก <think>";
    let user_prompt = format!(
        "สร้างโจทย์สร้างสรรค์ภาษาไทย {target} รอบ สำหรับเกม \"{}\" หัวข้อ \"{}\" (แนวทาง: {})\n\
         รูปแบบ JSON: {{\"rounds\":[{{\"prompt\":\"โจทย์ให้ผู้เล่นแต่งคำ/แคปชัน/ไอเดีย\",\"tip\":\"เคล็ดลับสั้นๆ\",\"requires_image\":{}}}]}}",
        item.name, topic_label, item.ai_topic_hint, default_requires_image
    );

    if let Some(raw) = generate_system_ai_json(state, system_prompt, &user_prompt, 750).await {
        if let Some(val) = extract_json_value(&raw) {
            let arr_opt = val
                .get("rounds")
                .and_then(|v| v.as_array())
                .or_else(|| val.as_array());
            if let Some(arr) = arr_opt {
                for entry in arr {
                    let prompt = entry
                        .get("prompt")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 220))
                        .unwrap_or_default();
                    let tip = entry
                        .get("tip")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 140))
                        .unwrap_or_default();
                    let requires_image = entry
                        .get("requires_image")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(default_requires_image);
                    if !prompt.is_empty() && seen.insert(prompt.to_lowercase()) {
                        rounds.push(CreativeRoundDoc {
                            prompt,
                            tip,
                            requires_image,
                            entries: Vec::new(),
                            judged: false,
                        });
                        if rounds.len() >= target {
                            break;
                        }
                    }
                }
            }
        }
    }

    if rounds.len() < target {
        for fb in fallbacks {
            if !fb.prompt.is_empty() && seen.insert(fb.prompt.to_lowercase()) {
                rounds.push(CreativeRoundDoc {
                    prompt: fb.prompt,
                    tip: fb.tip,
                    requires_image: fb.requires_image,
                    entries: Vec::new(),
                    judged: false,
                });
                if rounds.len() >= target {
                    break;
                }
            }
        }
    }

    rounds.truncate(target);
    rounds
}

async fn judge_creative_round(
    state: &AppState,
    game_title: &str,
    conv_id: &str,
    round: &mut CreativeRoundDoc,
    players: &mut [GamePlayerDoc],
) {
    if round.judged || round.entries.is_empty() {
        return;
    }

    // Collect non-confidential images for Vision judging if provided
    let mut vision_images: Vec<AiImageInput> = Vec::new();
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    for entry in &round.entries {
        if vision_images.len() >= 2 {
            break;
        }
        if let Some(ref mid) = entry.image_message_id {
            if let Ok(Some(m)) = msg_coll
                .find_one(doc! { "_id": mid, "conversation_id": conv_id, "is_unsent": false })
                .await
            {
                if !is_message_confidential_for_ai(&m, true) {
                    if let Some(ref att) = m.attachment {
                        if matches!(
                            classify_attachment(&att.mime_type, &att.file_name),
                            AttachmentKind::Image
                        ) {
                            if let Ok(img) = load_image_for_vision(state, att).await {
                                vision_images.push(img);
                            }
                        }
                    }
                }
            }
        }
    }

    let entries_json: Vec<Value> = round
        .entries
        .iter()
        .map(|e| {
            json!({
                "user_id": e.user_id,
                "display_name": e.display_name,
                "text": e.text,
                "has_image": e.image_url.is_some(),
            })
        })
        .collect();

    let system_prompt = "คุณคือกรรมการเกมสร้างสรรค์สุดอารมณ์ดีของ BC Ai Chat ให้คะแนนแต่ละผลงาน 60 ถึง 100 คะแนน พร้อมคอมเมนต์แซวสนุกๆ ภาษาไทยคนละ 1 ประโยค ตอบเป็น JSON เท่านั้น ห้ามมี Markdown ห้ามมี <think>";
    let user_prompt = format!(
        "เกม: {}\nโจทย์: {}\nผลงานผู้เล่น: {}\n\
         ตอบ JSON: {{\"judgements\":[{{\"user_id\":\"...\",\"score\":88,\"comment\":\"คอมเมนต์ฮาๆ 1 ประโยค\"}}]}}",
        game_title,
        round.prompt,
        serde_json::to_string(&entries_json).unwrap_or_default()
    );

    let mut ai_scores: HashMap<String, (i64, String)> = HashMap::new();
    if let Some(raw) =
        generate_system_ai_json_with_images(state, system_prompt, &user_prompt, &vision_images, 600)
            .await
    {
        if let Some(val) = extract_json_value(&raw) {
            let arr_opt = val
                .get("judgements")
                .and_then(|v| v.as_array())
                .or_else(|| val.as_array());
            if let Some(arr) = arr_opt {
                for j in arr {
                    let uid = j
                        .get("user_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .trim();
                    let score = j
                        .get("score")
                        .and_then(|v| v.as_i64())
                        .map(|s| s.clamp(60, 100));
                    let comment = j
                        .get("comment")
                        .and_then(|v| v.as_str())
                        .map(|s| clean_ai_text(s, 160))
                        .filter(|s| !s.is_empty());
                    if !uid.is_empty() {
                        if let (Some(sc), Some(cm)) = (score, comment) {
                            ai_scores.insert(uid.to_string(), (sc, cm));
                        }
                    }
                }
            }
        }
    }

    const FALLBACK_COMMENTS: [&str; 6] = [
        "ไอเดียจี๊ดจนกรรมการแอบขำจนชาหก เอาคะแนนไปเต็มๆ!",
        "คำคมบาดใจระดับตำนาน เล่นใหญ่โดนใจสุดๆ!",
        "ความคิดสร้างสรรค์พุ่งทะลุเพดาน ชอบความกล้าคิดนี้มาก!",
        "อ่านจบแล้วยิ้มแก้มปริ เอาไปเป็นแคปชันจริงได้เลย!",
        "จังหวะการเล่าเรื่องเป๊ะมาก กรรมการขอปรบมือรัวๆ!",
        "มุมมองไม่ซ้ำใคร สดใสและมีเสน่ห์สุดๆ ในวงนี้!",
    ];

    for entry in &mut round.entries {
        let (sc, cm) = if let Some((s, c)) = ai_scores.remove(&entry.user_id) {
            (s, c)
        } else {
            let h = deterministic_hash(&format!("{}:{}:{}", round.prompt, entry.user_id, entry.text));
            let len_bonus = (entry.text.chars().count().min(40) / 4) as i64;
            let img_bonus = if entry.image_url.is_some() { 5 } else { 0 };
            let sc = (72 + (h % 19) as i64 + len_bonus + img_bonus).clamp(60, 100);
            let cm = FALLBACK_COMMENTS[(h as usize) % FALLBACK_COMMENTS.len()].to_string();
            (sc, cm)
        };
        entry.score = Some(sc);
        entry.judge_comment = Some(cm);

        if let Some(p) = players.iter_mut().find(|p| p.user_id == entry.user_id) {
            p.score += sc;
        }
    }
    round.judged = true;
}

// =============================================================================
// Game Session Builder & Helpers
// =============================================================================

async fn recent_played_catalog_ids(state: &AppState, conv_id: &str) -> Vec<String> {
    let Ok(cursor) = state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .find(doc! { "conversation_id": conv_id })
        .sort(doc! { "created_at": -1 })
        .limit(10)
        .await
    else {
        return Vec::new();
    };
    cursor
        .try_collect::<Vec<GameSessionDoc>>()
        .await
        .unwrap_or_default()
        .into_iter()
        .map(|g| g.catalog_id)
        .filter(|id| !id.trim().is_empty())
        .collect()
}

async fn has_active_game(state: &AppState, conv_id: &str) -> Result<bool, ApiError> {
    let count = state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .count_documents(doc! {
            "conversation_id": conv_id,
            "status": { "$in": ["lobby", "playing"] }
        })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(count > 0)
}

#[allow(clippy::too_many_arguments)]
async fn build_game_session(
    state: &AppState,
    conv_id: &str,
    item: &GameCatalogItem,
    custom_topic: Option<String>,
    question_count: Option<u32>,
    proactive: bool,
    custom_host_message: Option<String>,
    creator: &UserDoc,
    auto_join_creator: bool,
    auto_start: bool,
) -> GameSessionDoc {
    let seed = fresh_seed();
    let now = Utc::now().to_rfc3339();
    let topic = custom_topic
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| item.name.to_string());

    let title = if topic == item.name {
        format!("{} {}", item.emoji, item.name)
    } else {
        format!("{} {}: {}", item.emoji, item.name, topic)
    };

    let desired_rounds = question_count
        .map(|n| n as usize)
        .unwrap_or(item.default_rounds as usize);

    let mut questions = Vec::new();
    let mut undercover = None;
    let mut hint_rounds = Vec::new();
    let mut party_rounds = Vec::new();
    let mut creative_rounds = Vec::new();
    let total_rounds: usize;

    match item.engine {
        "quiz" => {
            questions = generate_quiz_questions(state, item, &topic, desired_rounds.clamp(1, 10), seed).await;
            total_rounds = questions.len();
        }
        "undercover" => {
            let (cat, civ, spy) = generate_undercover_pair(state, item, &topic, seed).await;
            undercover = Some(UndercoverDataDoc {
                category: cat,
                civilian_word: civ,
                spy_word: spy,
                spy_user_id: None,
                clues: HashMap::new(),
                votes: HashMap::new(),
                winner_side: None,
            });
            total_rounds = 1;
        }
        "hint_race" => {
            hint_rounds =
                generate_hint_race_rounds(state, item, &topic, desired_rounds.clamp(1, 8), seed)
                    .await;
            total_rounds = hint_rounds.len();
        }
        "party_vote" => {
            party_rounds =
                generate_party_vote_rounds(state, item, &topic, desired_rounds.clamp(1, 10), seed)
                    .await;
            total_rounds = party_rounds.len();
        }
        "creative_challenge" => {
            creative_rounds =
                generate_creative_rounds(state, item, &topic, desired_rounds.clamp(1, 8), seed)
                    .await;
            total_rounds = creative_rounds.len();
        }
        _ => {
            questions = generate_quiz_questions(state, item, &topic, desired_rounds.clamp(1, 10), seed).await;
            total_rounds = questions.len();
        }
    }

    let players = if auto_join_creator {
        vec![GamePlayerDoc {
            user_id: creator.id.clone(),
            display_name: creator.display_name.clone(),
            avatar_url: creator.avatar_url.clone(),
            score: 0,
            joined_at: now.clone(),
        }]
    } else {
        Vec::new()
    };

    let host_message = custom_host_message
        .map(|s| clean_ai_text(&s, 220))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            if proactive {
                format!(
                    "ชวนทุกคนพักเบรกมาเล่น {} {} กัน! {}",
                    item.emoji, item.name, item.tagline
                )
            } else {
                format!(
                    "{} เปิดวง {} {} — {} กดเข้าร่วมแล้วมาสนุกกันเลย!",
                    creator.display_name, item.emoji, item.name, item.tagline
                )
            }
        });

    let can_auto_start = auto_start
        && item.engine != "undercover"
        && item.min_players <= 1
        && !players.is_empty();

    let (status, phase, round_started_at) = if can_auto_start {
        let playing_phase = match item.engine {
            "quiz" => "question",
            "hint_race" => "hint",
            "party_vote" => "vote",
            "creative_challenge" => "submit",
            _ => "question",
        };
        ("playing".to_string(), playing_phase.to_string(), Some(now.clone()))
    } else {
        ("lobby".to_string(), "lobby".to_string(), None)
    };

    GameSessionDoc {
        id: Uuid::new_v4().to_string(),
        conversation_id: conv_id.to_string(),
        game_type: item.engine.to_string(),
        catalog_id: item.id.to_string(),
        emoji: item.emoji.to_string(),
        category: item.category.to_string(),
        play_mode: item.play_mode.to_string(),
        tagline: item.tagline.to_string(),
        title,
        topic,
        status,
        phase,
        proactive,
        host_message,
        created_by: creator.id.clone(),
        created_by_name: creator.display_name.clone(),
        players,
        round_index: 0,
        total_rounds,
        round_revealed: false,
        round_started_at,
        questions,
        round_answers: HashMap::new(),
        undercover,
        hint_rounds,
        party_rounds,
        creative_rounds,
        winner_names: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
    }
}

fn compute_top_winners(players: &[GamePlayerDoc]) -> Vec<String> {
    let Some(max_score) = players.iter().map(|p| p.score).max() else {
        return Vec::new();
    };
    if max_score <= 0 {
        return Vec::new();
    }
    players
        .iter()
        .filter(|p| p.score == max_score)
        .map(|p| p.display_name.clone())
        .collect()
}

fn score_party_vote_round(round: &mut PartyVoteRoundDoc, players: &mut [GamePlayerDoc]) {
    if round.scored {
        return;
    }
    let mut counts: HashMap<usize, usize> = HashMap::new();
    for &choice in round.votes.values() {
        *counts.entry(choice).or_insert(0) += 1;
    }
    let max_votes = counts.values().copied().max().unwrap_or(0);
    let is_group_consensus = round.votes.len() >= 2 && max_votes >= 2;

    for (uid, &choice) in &round.votes {
        let mut pts = 50i64;
        if is_group_consensus && counts.get(&choice).copied().unwrap_or(0) == max_votes {
            pts += 50;
        }
        if let Some(p) = players.iter_mut().find(|p| &p.user_id == uid) {
            p.score += pts;
        }
    }
    round.scored = true;
}

async fn finalize_undercover_game(state: &AppState, game: &mut GameSessionDoc) {
    let Some(ref mut uc) = game.undercover else {
        return;
    };
    let spy_id = uc.spy_user_id.clone().unwrap_or_default();

    let mut vote_counts: HashMap<String, usize> = HashMap::new();
    for target in uc.votes.values() {
        *vote_counts.entry(target.clone()).or_insert(0) += 1;
    }
    let max_votes = vote_counts.values().copied().max().unwrap_or(0);
    let top_targets: Vec<&String> = vote_counts
        .iter()
        .filter(|(_, &cnt)| cnt == max_votes && max_votes > 0)
        .map(|(uid, _)| uid)
        .collect();

    let spy_caught = top_targets.len() == 1 && top_targets[0] == &spy_id;

    if spy_caught {
        uc.winner_side = Some("civilians".to_string());
        let mut winners = Vec::new();
        for p in &mut game.players {
            if p.user_id != spy_id {
                if uc.votes.get(&p.user_id).map(String::as_str) == Some(spy_id.as_str()) {
                    p.score += 100;
                    winners.push(p.display_name.clone());
                }
            }
        }
        if winners.is_empty() {
            winners = game
                .players
                .iter()
                .filter(|p| p.user_id != spy_id)
                .map(|p| p.display_name.clone())
                .collect();
        }
        game.winner_names = winners;
    } else {
        uc.winner_side = Some("spy".to_string());
        let mut spy_name = None;
        for p in &mut game.players {
            if p.user_id == spy_id {
                p.score += 150;
                spy_name = Some(p.display_name.clone());
            }
        }
        game.winner_names = spy_name.into_iter().collect();
    }

    game.status = "finished".to_string();
    game.phase = "finished".to_string();
    game.round_revealed = true;
    game.updated_at = Utc::now().to_rfc3339();

    let _ = state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .replace_one(doc! { "_id": &game.id }, &*game)
        .await;

    post_game_result_card(state, game).await;
    broadcast_game_updated(state, game);
}

// =============================================================================
// Proactive Invite Core Logic (Used by Endpoint + Scheduler + Message Trigger)
// =============================================================================

async fn run_proactive_invite(
    state: &AppState,
    conv_id: &str,
    viewer_user_id: &str,
    force: bool,
    requested_game_type: Option<&str>,
    enforce_awake_and_last_sender: bool,
) -> Result<ProactiveGameInviteResponse, ApiError> {
    let Some(_in_flight) = ProactiveRoomGuard::try_acquire(conv_id) else {
        return Ok(ProactiveGameInviteResponse {
            invited: false,
            reason: Some("กำลังสร้างคำชวนเล่นเกมให้ห้องนี้อยู่ กรุณารอสักครู่".to_string()),
            game: None,
            message: None,
        });
    };

    if has_active_game(state, conv_id).await? {
        return Ok(ProactiveGameInviteResponse {
            invited: false,
            reason: Some("ห้องนี้มีเกมที่กำลังเปิดอยู่แล้ว".to_string()),
            game: None,
            message: None,
        });
    }

    let ai_settings = get_effective_ai_settings(state)
        .await
        .map_err(ApiError::internal)?;
    if !ai_settings.enabled {
        return Ok(ProactiveGameInviteResponse {
            invited: false,
            reason: Some("ระบบ BC AI ถูกปิดใช้งานอยู่".to_string()),
            game: None,
            message: None,
        });
    }
    if !ai_settings.proactive_game_invites {
        return Ok(ProactiveGameInviteResponse {
            invited: false,
            reason: Some("ผู้ดูแลระบบปิดการชวนเล่นเกมอัตโนมัติของ BC AI ทั้งระบบ".to_string()),
            game: None,
            message: None,
        });
    }

    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let mut conv = conv_coll
        .find_one(doc! { "_id": conv_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบห้องแชท"))?;

    let now = Utc::now();

    if !force && !conv.effective_ai_game_auto_invite() {
        return Ok(ProactiveGameInviteResponse {
            invited: false,
            reason: Some("ห้องนี้ปิดการชวนเล่นเกมอัตโนมัติไว้".to_string()),
            game: None,
            message: None,
        });
    }

    if !force && !is_proactive_cooldown_elapsed(&conv, now) {
        return Ok(ProactiveGameInviteResponse {
            invited: false,
            reason: Some("ยังไม่ครบช่วงพักระหว่างการชวนเล่นเกมอัตโนมัติ".to_string()),
            game: None,
            message: None,
        });
    }

    if enforce_awake_and_last_sender {
        if !is_bangkok_awake_hour(now) {
            return Ok(ProactiveGameInviteResponse {
                invited: false,
                reason: Some("อยู่ในช่วงเวลาพักผ่อน (23:00–07:00 น.)".to_string()),
                game: None,
                message: None,
            });
        }
        if conv
            .last_message
            .as_ref()
            .is_some_and(|lm| lm.sender_id == "user_ai")
        {
            return Ok(ProactiveGameInviteResponse {
                invited: false,
                reason: Some("ข้อความล่าสุดเป็นของ BC AI แล้ว เพื่อป้องกันการโพสต์ซ้ำ".to_string()),
                game: None,
                message: None,
            });
        }
    }

    // Read recent 10 non-confidential messages to match room vibe
    let mut recent_msgs: Vec<MessageDoc> = match state
        .db
        .collection::<MessageDoc>("messages")
        .find(doc! {
            "conversation_id": conv_id,
            "is_unsent": false,
            "is_confidential": { "$ne": true },
            "confidential_pin": null,
        })
        .sort(doc! { "created_at": -1 })
        .limit(10)
        .await
    {
        Ok(cur) => cur.try_collect::<Vec<MessageDoc>>().await.unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    recent_msgs.reverse();

    let exclude_ids = recent_played_catalog_ids(state, conv_id).await;
    let seed = fresh_seed();
    let mode_for_room = if conv.conv_type == "group" && conv.oa_id.is_none() {
        "group"
    } else {
        "solo"
    };

    // Base catalog pick (respecting optional requested_game_type & avoiding last 10 games)
    let mut picked_item: &'static GameCatalogItem = if let Some(req_type) = requested_game_type
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        let matching: Vec<&'static GameCatalogItem> = filter_catalog(Some(mode_for_room), None, None)
            .into_iter()
            .filter(|g| g.engine == req_type)
            .collect();
        let fresh: Vec<&'static GameCatalogItem> = matching
            .iter()
            .copied()
            .filter(|g| !exclude_ids.iter().any(|ex| ex == g.id))
            .collect();
        let pool = if !fresh.is_empty() { fresh } else { matching };
        if !pool.is_empty() {
            pool[(seed as usize) % pool.len()]
        } else {
            pick_random_game(mode_for_room, None, &exclude_ids, seed)
        }
    } else {
        pick_random_game(mode_for_room, None, &exclude_ids, seed)
    };

    let mut custom_topic: Option<String> = None;
    let mut host_pitch: Option<String> = None;

    // Ask BC AI to pick the best fitting game from fresh candidates & write a lively Thai pitch
    let chat_snippets: Vec<String> = recent_msgs
        .iter()
        .filter(|m| m.sender_id != "user_ai" && !is_message_confidential_for_ai(m, true))
        .map(|m| {
            let snippet: String = m.content.chars().take(100).collect();
            format!("{}: {}", m.sender_name, snippet)
        })
        .collect();

    let mut candidate_items: Vec<&'static GameCatalogItem> = vec![picked_item];
    for step in 1..=7u64 {
        let c = pick_random_game(mode_for_room, None, &exclude_ids, seed.wrapping_add(step * 997));
        if requested_game_type
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .is_none_or(|rt| c.engine == rt)
            && !candidate_items.iter().any(|x| x.id == c.id)
        {
            candidate_items.push(c);
        }
    }
    let cand_lines: Vec<String> = candidate_items
        .iter()
        .map(|g| format!("- id=\"{}\" | {} {} ({}): {}", g.id, g.emoji, g.name, g.engine, g.tagline))
        .collect();

    let sys_prompt = "คุณคือ BC AI พิธีกรเกมสุดสนุกและเป็นกันเองในแอป BC Ai Chat เลือก 1 เกมที่เข้ากับบรรยากาศห้องแชทจากรายการที่ให้ พร้อมเขียนคำชวนภาษาไทย 1 ประโยคที่ชวนให้อยากกดเล่น ตอบเป็น JSON เท่านั้น ห้ามใส่ Markdown ห้ามมีแท็ก <think>";
    let usr_prompt = format!(
        "ชื่อห้อง: {}\nบทสนทนาล่าสุด:\n{}\n\nเกมที่เลือกได้:\n{}\n\n\
         ตอบ JSON: {{\"catalog_id\":\"idจากรายการ\",\"topic\":\"หัวข้อสนุกๆภาษาไทย\",\"host_message\":\"คำชวนภาษาไทยสดใส 1 ประโยค\"}}",
        conv.name,
        if chat_snippets.is_empty() {
            "(เพิ่งเริ่มคุยกันในห้อง)".to_string()
        } else {
            chat_snippets.join("\n")
        },
        cand_lines.join("\n")
    );

    if let Some(raw) = generate_system_ai_json(state, sys_prompt, &usr_prompt, 260).await {
        if let Some(val) = extract_json_value(&raw) {
            if let Some(cid) = val.get("catalog_id").and_then(|v| v.as_str()) {
                if let Some(found) = find_game_by_id(cid.trim()) {
                    let engine_ok = requested_game_type
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .is_none_or(|rt| found.engine == rt);
                    let mode_ok = mode_for_room != "solo" || found.min_players <= 1;
                    if engine_ok && mode_ok {
                        picked_item = found;
                    }
                }
            }
            if let Some(t) = val
                .get("topic")
                .and_then(|v| v.as_str())
                .map(|s| clean_ai_text(s, 80))
                .filter(|s| !s.is_empty())
            {
                custom_topic = Some(t);
            }
            if let Some(hm) = val
                .get("host_message")
                .and_then(|v| v.as_str())
                .map(|s| clean_ai_text(s, 200))
                .filter(|s| !s.is_empty())
            {
                host_pitch = Some(hm);
            }
        }
    }

    let ai_user = load_ai_user(state).await;
    let game = build_game_session(
        state,
        conv_id,
        picked_item,
        custom_topic,
        None,
        true,
        host_pitch,
        &ai_user,
        false,
        false,
    )
    .await;

    state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .insert_one(&game)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let now_iso = Utc::now().to_rfc3339();
    conv.last_ai_game_invite_at = Some(now_iso);
    conv.human_msgs_since_game_invite = 0;

    let msg_dto = post_game_invite_card(state, &mut conv, &ai_user, &game)
        .await
        .map_err(ApiError::internal)?;

    broadcast_game_updated(state, &game);

    Ok(ProactiveGameInviteResponse {
        invited: true,
        reason: None,
        game: Some(to_game_dto(&game, viewer_user_id)),
        message: Some(msg_dto),
    })
}

/// Non-blocking auto-invite check used by `send_message_handler` and the background scheduler.
pub async fn maybe_auto_proactive_invite(state: &AppState, conv_id: &str) -> bool {
    if !state.config.ai_game_proactive_enabled {
        return false;
    }
    match run_proactive_invite(state, conv_id, "user_ai", false, None, true).await {
        Ok(res) => res.invited,
        Err(_) => false,
    }
}

/// Spawns the periodic background Proactive AI Game Host (only when `AI_GAME_PROACTIVE_ENABLED=true`).
pub fn spawn_proactive_game_host(state: AppState) {
    let poll_secs = state.config.ai_game_host_poll_secs.clamp(5, 3600);
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(StdDuration::from_secs(poll_secs));
        // Skip immediate tick at boot so freshly started servers do not spam immediately.
        interval.tick().await;

        loop {
            interval.tick().await;
            let now = Utc::now();
            if !is_bangkok_awake_hour(now) {
                continue;
            }
            let Ok(ai_settings) = get_effective_ai_settings(&state).await else {
                continue;
            };
            if !ai_settings.enabled || !ai_settings.proactive_game_invites {
                continue;
            }

            let Ok(cursor) = state
                .db
                .collection::<ConversationDoc>("conversations")
                .find(doc! { "type": "group", "oa_id": null })
                .sort(doc! { "updated_at": -1 })
                .limit(50)
                .await
            else {
                continue;
            };
            let Ok(rooms) = cursor.try_collect::<Vec<ConversationDoc>>().await else {
                continue;
            };

            let mut invited_this_tick = 0usize;
            for conv in rooms {
                if invited_this_tick >= 3 {
                    break;
                }
                if !conv.effective_ai_game_auto_invite() {
                    continue;
                }
                let human_members = conv
                    .member_ids
                    .iter()
                    .filter(|id| id.as_str() != "user_ai" && id.as_str() != "user_official")
                    .count();
                if human_members < 2 {
                    continue;
                }
                let Some(ref lm) = conv.last_message else {
                    continue;
                };
                if lm.sender_id == "user_ai" || lm.sender_id == "user_official" {
                    continue;
                }
                if !is_proactive_cooldown_elapsed(&conv, now) {
                    continue;
                }
                let recent_human_activity = DateTime::parse_from_rfc3339(&lm.created_at)
                    .ok()
                    .is_some_and(|dt| {
                        let age = now.signed_duration_since(dt.with_timezone(&Utc));
                        age >= Duration::minutes(conv.effective_ai_game_invite_cooldown_mins() as i64)
                            && age <= Duration::hours(24)
                    });
                let reached_msg_threshold =
                    conv.human_msgs_since_game_invite >= state.config.ai_game_trigger_msgs;

                if (reached_msg_threshold || recent_human_activity)
                    && maybe_auto_proactive_invite(&state, &conv.id).await
                {
                    invited_this_tick += 1;
                }
            }
        }
    });
}

// =============================================================================
// HTTP Handlers
// =============================================================================

#[derive(Debug, Deserialize)]
pub struct CatalogQuery {
    pub mode: Option<String>,
    pub category: Option<String>,
    pub q: Option<String>,
}

pub async fn list_game_catalog_handler(
    _auth: AuthUser,
    Query(query): Query<CatalogQuery>,
) -> Result<Json<Value>, ApiError> {
    let games = filter_catalog(
        query.mode.as_deref(),
        query.category.as_deref(),
        query.q.as_deref(),
    );
    Ok(Json(json!({
        "total": GAME_CATALOG.len(),
        "categories": GAME_CATEGORIES,
        "games": games,
    })))
}

pub async fn get_active_game_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ActiveGameStateDto>, ApiError> {
    let conv = require_member(&state, &conv_id, &auth.user_id).await?;
    let games_coll = state.db.collection::<GameSessionDoc>("game_sessions");

    let active_doc = games_coll
        .find_one(doc! {
            "conversation_id": &conv_id,
            "status": { "$in": ["lobby", "playing"] }
        })
        .sort(doc! { "created_at": -1 })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let recent_cursor = games_coll
        .find(doc! {
            "conversation_id": &conv_id,
            "status": "finished"
        })
        .sort(doc! { "created_at": -1 })
        .limit(10)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let recent_docs: Vec<GameSessionDoc> = recent_cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let ai_settings = get_effective_ai_settings(&state)
        .await
        .map_err(ApiError::internal)?;

    Ok(Json(ActiveGameStateDto {
        active_game: active_doc.as_ref().map(|g| to_game_dto(g, &auth.user_id)),
        recent_games: recent_docs.iter().map(to_game_summary).collect(),
        ai_game_auto_invite: conv.effective_ai_game_auto_invite(),
        ai_game_invite_cooldown_mins: conv.effective_ai_game_invite_cooldown_mins(),
        proactive_enabled_globally: ai_settings.enabled && ai_settings.proactive_game_invites,
    }))
}

#[derive(Debug, Deserialize)]
pub struct CreateGameRequest {
    #[serde(default)]
    pub game_id: Option<String>,
    #[serde(default)]
    pub game_type: Option<String>,
    #[serde(default)]
    pub topic: Option<String>,
    #[serde(default)]
    pub question_count: Option<u32>,
    #[serde(default)]
    pub auto_start: Option<bool>,
}

pub async fn create_game_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<CreateGameRequest>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;
    if has_active_game(&state, &conv_id).await? {
        return Err(ApiError::conflict(
            "ห้องนี้มีเกมที่กำลังเปิดอยู่แล้ว กรุณาเล่นให้จบหรือยกเลิกเกมเดิมก่อน",
        ));
    }

    let item: &'static GameCatalogItem = if let Some(ref gid) = payload
        .game_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        find_game_by_id(gid).ok_or_else(|| ApiError::not_found("ไม่พบเกมที่เลือกในคลัง 100 เกม"))?
    } else {
        let engine = payload
            .game_type
            .as_deref()
            .map(str::trim)
            .unwrap_or("quiz")
            .to_lowercase();
        match engine.as_str() {
            "quiz" | "undercover" | "hint_race" | "party_vote" | "creative_challenge" => {
                default_catalog_item_for_engine(&engine)
            }
            _ => {
                return Err(ApiError::bad_request(
                    "ประเภทเกมไม่ถูกต้อง (รองรับ quiz, undercover, hint_race, party_vote, creative_challenge)",
                ));
            }
        }
    };

    let creator = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let game = build_game_session(
        &state,
        &conv_id,
        item,
        payload.topic,
        payload.question_count,
        false,
        None,
        &creator,
        true,
        payload.auto_start == Some(true),
    )
    .await;

    state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .insert_one(&game)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let _ = post_game_invite_card(&state, &mut conv, &creator, &game).await;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

#[derive(Debug, Deserialize, Default)]
pub struct RandomGameRequest {
    #[serde(default)]
    pub mode: Option<String>, // "auto" | "solo" | "group"
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub auto_start: Option<bool>,
}

pub async fn random_game_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    payload: Option<Json<RandomGameRequest>>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut conv = require_member(&state, &conv_id, &auth.user_id).await?;
    if has_active_game(&state, &conv_id).await? {
        return Err(ApiError::conflict(
            "ห้องนี้มีเกมที่กำลังเปิดอยู่แล้ว กรุณาเล่นให้จบหรือยกเลิกเกมเดิมก่อน",
        ));
    }

    let req = payload.map(|Json(p)| p).unwrap_or_default();
    let requested_mode = req
        .mode
        .as_deref()
        .map(str::trim)
        .unwrap_or("auto")
        .to_lowercase();

    let resolved_mode = match requested_mode.as_str() {
        "solo" => "solo",
        "group" => "group",
        _ => {
            if conv.conv_type == "group" && conv.oa_id.is_none() {
                "group"
            } else {
                "solo"
            }
        }
    };

    let exclude_ids = recent_played_catalog_ids(&state, &conv_id).await;
    let cat_filter = req
        .category
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty() && *s != "all" && *s != "ทั้งหมด");

    let item = pick_random_game(resolved_mode, cat_filter, &exclude_ids, fresh_seed());

    let creator = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let should_auto_start = (req.auto_start == Some(true)
        || (resolved_mode == "solo" && req.auto_start != Some(false)))
        && item.min_players <= 1;

    let game = build_game_session(
        &state,
        &conv_id,
        item,
        None,
        None,
        false,
        None,
        &creator,
        true,
        should_auto_start,
    )
    .await;

    state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .insert_one(&game)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let _ = post_game_invite_card(&state, &mut conv, &creator, &game).await;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

#[derive(Debug, Deserialize, Default)]
pub struct ProactiveInviteRequest {
    #[serde(default)]
    pub force: Option<bool>,
    #[serde(default)]
    pub game_type: Option<String>,
}

pub async fn proactive_invite_game_handler(
    auth: AuthUser,
    Path(conv_id): Path<String>,
    State(state): State<AppState>,
    payload: Option<Json<ProactiveInviteRequest>>,
) -> Result<Json<ProactiveGameInviteResponse>, ApiError> {
    let _conv = require_member(&state, &conv_id, &auth.user_id).await?;
    let req = payload.map(|Json(p)| p).unwrap_or_default();
    let res = run_proactive_invite(
        &state,
        &conv_id,
        &auth.user_id,
        req.force == Some(true),
        req.game_type.as_deref(),
        false,
    )
    .await?;
    Ok(Json(res))
}

async fn load_game_for_member(
    state: &AppState,
    game_id: &str,
    user_id: &str,
) -> Result<GameSessionDoc, ApiError> {
    let game = state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .find_one(doc! { "_id": game_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบเกมนี้"))?;
    let _ = require_member(state, &game.conversation_id, user_id).await?;
    Ok(game)
}

async fn save_game(state: &AppState, game: &GameSessionDoc) -> Result<(), ApiError> {
    state
        .db
        .collection::<GameSessionDoc>("game_sessions")
        .replace_one(doc! { "_id": &game.id }, game)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(())
}

pub async fn get_game_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

pub async fn join_game_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.players.iter().any(|p| p.user_id == auth.user_id) {
        return Ok(Json(to_game_dto(&game, &auth.user_id)));
    }
    if game.status != "lobby" {
        return Err(ApiError::bad_request(
            "เกมเริ่มเล่นแล้วหรือจบไปแล้ว ไม่สามารถเข้าร่วมได้",
        ));
    }

    let user = state
        .db
        .collection::<UserDoc>("users")
        .find_one(doc! { "_id": &auth.user_id })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .ok_or_else(|| ApiError::not_found("ไม่พบข้อมูลผู้ใช้"))?;

    let now = Utc::now().to_rfc3339();
    game.players.push(GamePlayerDoc {
        user_id: user.id,
        display_name: user.display_name,
        avatar_url: user.avatar_url,
        score: 0,
        joined_at: now.clone(),
    });
    game.updated_at = now;

    save_game(&state, &game).await?;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

pub async fn start_game_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.status != "lobby" {
        return Err(ApiError::bad_request("เกมไม่ได้อยู่ในสถานะรอเริ่มเล่น"));
    }

    let min_required = if game.game_type == "undercover" { 2 } else { 1 };
    if game.players.len() < min_required {
        return Err(ApiError::bad_request(format!(
            "ต้องมีผู้เล่นเข้าร่วมอย่างน้อย {} คนก่อนเริ่มเกม",
            min_required
        )));
    }

    let now = Utc::now().to_rfc3339();
    game.status = "playing".to_string();
    game.round_index = 0;
    game.round_revealed = false;
    game.round_started_at = Some(now.clone());
    game.updated_at = now;

    match game.game_type.as_str() {
        "quiz" => {
            game.phase = "question".to_string();
        }
        "undercover" => {
            let spy_idx = (fresh_seed() as usize) % game.players.len();
            let spy_id = game.players[spy_idx].user_id.clone();
            if let Some(ref mut uc) = game.undercover {
                uc.spy_user_id = Some(spy_id);
                uc.clues.clear();
                uc.votes.clear();
                uc.winner_side = None;
            }
            game.phase = "clue".to_string();
        }
        "hint_race" => {
            game.phase = "hint".to_string();
        }
        "party_vote" => {
            game.phase = "vote".to_string();
        }
        "creative_challenge" => {
            game.phase = "submit".to_string();
        }
        _ => {
            game.phase = "question".to_string();
        }
    }

    save_game(&state, &game).await?;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

#[derive(Debug, Deserialize)]
pub struct AnswerGameRequest {
    pub choice_index: usize,
}

pub async fn answer_game_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<AnswerGameRequest>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.status != "playing" || game.round_revealed {
        return Err(ApiError::bad_request(
            "รอบนี้ปิดรับคำตอบหรือเฉลยไปแล้ว",
        ));
    }
    if !game.players.iter().any(|p| p.user_id == auth.user_id) {
        return Err(ApiError::forbidden("คุณยังไม่ได้เข้าร่วมเกมนี้"));
    }

    let now_utc = Utc::now();
    let now_iso = now_utc.to_rfc3339();

    match game.game_type.as_str() {
        "quiz" => {
            let q = game
                .questions
                .get(game.round_index)
                .ok_or_else(|| ApiError::bad_request("ไม่พบคำถามรอบปัจจุบัน"))?
                .clone();
            if payload.choice_index >= q.options.len() {
                return Err(ApiError::bad_request("ตัวเลือกไม่ถูกต้อง"));
            }

            let round_key = game.round_index.to_string();
            let round_map = game.round_answers.entry(round_key).or_default();
            if round_map.contains_key(&auth.user_id) {
                return Err(ApiError::bad_request("คุณตอบคำถามข้อนี้ไปแล้ว"));
            }

            let is_correct = payload.choice_index == q.correct_index;
            let elapsed_secs = game
                .round_started_at
                .as_deref()
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|dt| now_utc.signed_duration_since(dt.with_timezone(&Utc)).num_seconds().max(0))
                .unwrap_or(0);
            let speed_bonus = if is_correct {
                (50i64 - elapsed_secs * 2).clamp(0, 50)
            } else {
                0
            };
            let points_awarded = if is_correct { 100 + speed_bonus } else { 0 };

            round_map.insert(
                auth.user_id.clone(),
                QuizRoundAnswerDoc {
                    choice_index: payload.choice_index,
                    is_correct,
                    points_awarded,
                    answered_at: now_iso.clone(),
                },
            );

            if let Some(p) = game.players.iter_mut().find(|p| p.user_id == auth.user_id) {
                p.score += points_awarded;
            }

            let all_answered = game
                .players
                .iter()
                .all(|p| round_map.contains_key(&p.user_id));
            if all_answered {
                game.round_revealed = true;
                game.phase = "reveal".to_string();
            }
        }
        "party_vote" => {
            let round = game
                .party_rounds
                .get_mut(game.round_index)
                .ok_or_else(|| ApiError::bad_request("ไม่พบรอบโหวตปัจจุบัน"))?;
            if payload.choice_index >= round.options.len() {
                return Err(ApiError::bad_request("ตัวเลือกไม่ถูกต้อง"));
            }
            if round.votes.contains_key(&auth.user_id) {
                return Err(ApiError::bad_request("คุณโหวตรอบนี้ไปแล้ว"));
            }
            round.votes.insert(auth.user_id.clone(), payload.choice_index);

            let all_voted = game
                .players
                .iter()
                .all(|p| round.votes.contains_key(&p.user_id));
            if all_voted {
                score_party_vote_round(round, &mut game.players);
                game.round_revealed = true;
                game.phase = "reveal".to_string();
            }
        }
        _ => {
            return Err(ApiError::bad_request(
                "เกมประเภทนี้ไม่ได้ใช้การส่งตัวเลือกคำตอบ",
            ));
        }
    }

    game.updated_at = now_iso;
    save_game(&state, &game).await?;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

#[derive(Debug, Deserialize)]
pub struct GuessGameRequest {
    pub guess: String,
}

pub async fn submit_guess_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<GuessGameRequest>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.game_type != "hint_race" {
        return Err(ApiError::bad_request("เกมนี้ไม่ใช่โหมดทายคำจากคำใบ้"));
    }
    if game.status != "playing" || game.round_revealed {
        return Err(ApiError::bad_request("รอบนี้เฉลยหรือจบไปแล้ว"));
    }
    let player_name = game
        .players
        .iter()
        .find(|p| p.user_id == auth.user_id)
        .map(|p| p.display_name.clone())
        .ok_or_else(|| ApiError::forbidden("คุณยังไม่ได้เข้าร่วมเกมนี้"))?;

    let guess = payload.guess.trim().to_string();
    if guess.is_empty() || guess.chars().count() > 100 {
        return Err(ApiError::bad_request(
            "กรุณาพิมพ์คำทาย 1 ถึง 100 ตัวอักษร",
        ));
    }

    let round = game
        .hint_rounds
        .get_mut(game.round_index)
        .ok_or_else(|| ApiError::bad_request("ไม่พบโจทย์รอบปัจจุบัน"))?;
    round
        .guesses
        .entry(auth.user_id.clone())
        .or_default()
        .push(guess.clone());

    if is_hint_guess_correct(&guess, &round.answer, &round.aliases) {
        let level = round.hint_level.max(1);
        let pts = (150i64 - ((level.saturating_sub(1) as i64) * 20)).max(50);
        round.solved_by_id = Some(auth.user_id.clone());
        round.solved_by_name = Some(player_name);
        if let Some(p) = game.players.iter_mut().find(|p| p.user_id == auth.user_id) {
            p.score += pts;
        }
        game.round_revealed = true;
        game.phase = "reveal".to_string();
    }

    game.updated_at = Utc::now().to_rfc3339();
    save_game(&state, &game).await?;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

#[derive(Debug, Deserialize)]
pub struct SubmitCreativeRequest {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub image_message_id: Option<String>,
}

pub async fn submit_creative_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SubmitCreativeRequest>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.game_type != "creative_challenge" {
        return Err(ApiError::bad_request("เกมนี้ไม่ใช่โหมดภารกิจสร้างสรรค์"));
    }
    if game.status != "playing" || game.round_revealed {
        return Err(ApiError::bad_request("รอบนี้ปิดรับผลงานหรือตัดสินไปแล้ว"));
    }
    let player_name = game
        .players
        .iter()
        .find(|p| p.user_id == auth.user_id)
        .map(|p| p.display_name.clone())
        .ok_or_else(|| ApiError::forbidden("คุณยังไม่ได้เข้าร่วมเกมนี้"))?;

    let text = payload.text.trim().to_string();
    let img_msg_id = payload
        .image_message_id
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    if text.is_empty() && img_msg_id.is_none() {
        return Err(ApiError::bad_request("กรุณาพิมพ์คำตอบหรือแนบรูปภาพผลงาน"));
    }
    if text.chars().count() > 500 {
        return Err(ApiError::bad_request("ข้อความผลงานต้องไม่เกิน 500 ตัวอักษร"));
    }

    let mut image_url: Option<String> = None;
    if let Some(ref mid) = img_msg_id {
        let msg = state
            .db
            .collection::<MessageDoc>("messages")
            .find_one(doc! { "_id": mid, "conversation_id": &game.conversation_id, "is_unsent": false })
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .ok_or_else(|| ApiError::not_found("ไม่พบข้อความรูปภาพที่ระบุในห้องนี้"))?;

        if is_message_confidential_for_ai(&msg, true) {
            return Err(ApiError::forbidden(
                "ไม่สามารถนำข้อความหรือรูปภาพลับล็อก PIN มาส่งในเกมได้",
            ));
        }
        if let Some(ref att) = msg.attachment {
            if matches!(
                classify_attachment(&att.mime_type, &att.file_name),
                AttachmentKind::Image
            ) {
                image_url = Some(att.url.clone());
            }
        }
    }

    let round_idx = game.round_index;
    let conv_id = game.conversation_id.clone();
    let title = game.title.clone();
    let now = Utc::now().to_rfc3339();

    {
        let round = game
            .creative_rounds
            .get_mut(round_idx)
            .ok_or_else(|| ApiError::bad_request("ไม่พบรอบสร้างสรรค์ปัจจุบัน"))?;
        if round.entries.iter().any(|e| e.user_id == auth.user_id) {
            return Err(ApiError::bad_request("คุณส่งผลงานในรอบนี้ไปแล้ว"));
        }
        round.entries.push(CreativeEntryDoc {
            user_id: auth.user_id.clone(),
            display_name: player_name,
            text: if text.is_empty() {
                "[ส่งภาพเข้าร่วมภารกิจ]".to_string()
            } else {
                text
            },
            image_message_id: img_msg_id,
            image_url,
            score: None,
            judge_comment: None,
            submitted_at: now.clone(),
        });
    }

    let all_submitted = game.creative_rounds.get(round_idx).is_some_and(|r| {
        game.players
            .iter()
            .all(|p| r.entries.iter().any(|e| e.user_id == p.user_id))
    });

    if all_submitted {
        if let Some(round) = game.creative_rounds.get_mut(round_idx) {
            judge_creative_round(&state, &title, &conv_id, round, &mut game.players).await;
        }
        game.round_revealed = true;
        game.phase = "reveal".to_string();
    }

    game.updated_at = Utc::now().to_rfc3339();
    save_game(&state, &game).await?;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

#[derive(Debug, Deserialize)]
pub struct SubmitClueRequest {
    pub clue: String,
}

pub async fn submit_clue_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SubmitClueRequest>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.game_type != "undercover" || game.status != "playing" || game.phase != "clue" {
        return Err(ApiError::bad_request(
            "เกมไม่ได้อยู่ในช่วงใบ้คำของใครคือสายลับ",
        ));
    }
    if !game.players.iter().any(|p| p.user_id == auth.user_id) {
        return Err(ApiError::forbidden("คุณยังไม่ได้เข้าร่วมเกมนี้"));
    }

    let clue = payload.clue.trim().to_string();
    if clue.is_empty() || clue.chars().count() > 140 {
        return Err(ApiError::bad_request(
            "คำใบ้ต้องมีความยาว 1 ถึง 140 ตัวอักษร",
        ));
    }

    let Some(ref mut uc) = game.undercover else {
        return Err(ApiError::internal("ไม่พบข้อมูลรอบใครคือสายลับ"));
    };
    uc.clues.insert(auth.user_id.clone(), clue);

    let all_clued = game.players.iter().all(|p| uc.clues.contains_key(&p.user_id));
    if all_clued {
        game.phase = "vote".to_string();
    }

    game.updated_at = Utc::now().to_rfc3339();
    save_game(&state, &game).await?;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

#[derive(Debug, Deserialize)]
pub struct SubmitVoteRequest {
    pub target_user_id: String,
}

pub async fn submit_vote_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SubmitVoteRequest>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.game_type != "undercover" || game.status != "playing" || game.phase != "vote" {
        return Err(ApiError::bad_request(
            "เกมไม่ได้อยู่ในช่วงโหวตหาสายลับ",
        ));
    }
    if !game.players.iter().any(|p| p.user_id == auth.user_id) {
        return Err(ApiError::forbidden("คุณยังไม่ได้เข้าร่วมเกมนี้"));
    }

    let target = payload.target_user_id.trim();
    if target.is_empty() {
        return Err(ApiError::bad_request("กรุณาเลือกผู้เล่นที่จะโหวต"));
    }
    if target == auth.user_id {
        return Err(ApiError::bad_request("ไม่สามารถโหวตตัวเองได้"));
    }
    if !game.players.iter().any(|p| p.user_id == target) {
        return Err(ApiError::bad_request("ผู้เล่นที่เลือกไม่ได้อยู่ในเกมนี้"));
    }

    let all_voted = {
        let Some(ref mut uc) = game.undercover else {
            return Err(ApiError::internal("ไม่พบข้อมูลรอบใครคือสายลับ"));
        };
        uc.votes.insert(auth.user_id.clone(), target.to_string());
        game.players.iter().all(|p| uc.votes.contains_key(&p.user_id))
    };

    if all_voted {
        finalize_undercover_game(&state, &mut game).await;
    } else {
        game.updated_at = Utc::now().to_rfc3339();
        save_game(&state, &game).await?;
        broadcast_game_updated(&state, &game);
    }

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

pub async fn next_game_step_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.status != "playing" {
        return Err(ApiError::bad_request("เกมไม่ได้กำลังเล่นอยู่"));
    }

    let now = Utc::now().to_rfc3339();
    let mut finished_now = false;

    match game.game_type.as_str() {
        "quiz" => {
            if !game.round_revealed {
                game.round_revealed = true;
                game.phase = "reveal".to_string();
            } else if game.round_index + 1 < game.total_rounds {
                game.round_index += 1;
                game.round_revealed = false;
                game.phase = "question".to_string();
                game.round_started_at = Some(now.clone());
            } else {
                game.status = "finished".to_string();
                game.phase = "finished".to_string();
                game.winner_names = compute_top_winners(&game.players);
                finished_now = true;
            }
        }
        "undercover" => {
            if game.phase == "clue" {
                game.phase = "vote".to_string();
            } else {
                finalize_undercover_game(&state, &mut game).await;
                return Ok(Json(to_game_dto(&game, &auth.user_id)));
            }
        }
        "hint_race" => {
            if !game.round_revealed {
                if let Some(round) = game.hint_rounds.get_mut(game.round_index) {
                    if round.hint_level < round.hints.len() {
                        round.hint_level += 1;
                    } else {
                        game.round_revealed = true;
                        game.phase = "reveal".to_string();
                    }
                } else {
                    game.round_revealed = true;
                    game.phase = "reveal".to_string();
                }
            } else if game.round_index + 1 < game.total_rounds {
                game.round_index += 1;
                game.round_revealed = false;
                game.phase = "hint".to_string();
                game.round_started_at = Some(now.clone());
            } else {
                game.status = "finished".to_string();
                game.phase = "finished".to_string();
                game.winner_names = compute_top_winners(&game.players);
                finished_now = true;
            }
        }
        "party_vote" => {
            if !game.round_revealed {
                if let Some(round) = game.party_rounds.get_mut(game.round_index) {
                    score_party_vote_round(round, &mut game.players);
                }
                game.round_revealed = true;
                game.phase = "reveal".to_string();
            } else if game.round_index + 1 < game.total_rounds {
                game.round_index += 1;
                game.round_revealed = false;
                game.phase = "vote".to_string();
                game.round_started_at = Some(now.clone());
            } else {
                game.status = "finished".to_string();
                game.phase = "finished".to_string();
                game.winner_names = compute_top_winners(&game.players);
                finished_now = true;
            }
        }
        "creative_challenge" => {
            if !game.round_revealed {
                let idx = game.round_index;
                let title = game.title.clone();
                let conv_id = game.conversation_id.clone();
                if let Some(round) = game.creative_rounds.get_mut(idx) {
                    judge_creative_round(&state, &title, &conv_id, round, &mut game.players).await;
                }
                game.round_revealed = true;
                game.phase = "reveal".to_string();
            } else if game.round_index + 1 < game.total_rounds {
                game.round_index += 1;
                game.round_revealed = false;
                game.phase = "submit".to_string();
                game.round_started_at = Some(now.clone());
            } else {
                game.status = "finished".to_string();
                game.phase = "finished".to_string();
                game.winner_names = compute_top_winners(&game.players);
                finished_now = true;
            }
        }
        _ => {
            game.status = "finished".to_string();
            game.phase = "finished".to_string();
            finished_now = true;
        }
    }

    game.updated_at = now;
    save_game(&state, &game).await?;
    if finished_now {
        post_game_result_card(&state, &game).await;
    }
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

pub async fn cancel_game_handler(
    auth: AuthUser,
    Path(game_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<GameSessionDto>, ApiError> {
    let mut game = load_game_for_member(&state, &game_id, &auth.user_id).await?;
    if game.status != "lobby" && game.status != "playing" {
        return Err(ApiError::bad_request("เกมจบหรือถูกยกเลิกไปแล้ว"));
    }

    game.status = "cancelled".to_string();
    game.phase = "cancelled".to_string();
    game.updated_at = Utc::now().to_rfc3339();

    save_game(&state, &game).await?;
    broadcast_game_updated(&state, &game);

    Ok(Json(to_game_dto(&game, &auth.user_id)))
}

// =============================================================================
// Unit & Integration Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use tower::ServiceExt;

    use crate::{auth::create_jwt, config::AppConfig, create_router, seed::ensure_mongo_indexes};

    fn make_test_user(id: &str, name: &str, role: &str) -> UserDoc {
        UserDoc {
            id: id.into(),
            email: format!("{id}@test.bcaichat.local"),
            phone: String::new(),
            phone_verified: true,
            email_verified: true,
            display_name: name.into(),
            bc_id: format!("@{id}"),
            avatar_url: String::new(),
            status_message: String::new(),
            qr_token: format!("BCQR_{id}"),
            role: role.into(),
            department: "เพื่อน".into(),
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
            created_at: Utc::now().to_rfc3339(),
        }
    }

    fn make_test_conv(id: &str, conv_type: &str, members: Vec<&str>) -> ConversationDoc {
        let now = Utc::now().to_rfc3339();
        ConversationDoc {
            id: id.into(),
            conv_type: conv_type.into(),
            name: format!("ห้อง {id}"),
            avatar_url: String::new(),
            folder: if conv_type == "group" {
                "group".into()
            } else {
                "personal".into()
            },
            is_pinned: false,
            is_muted: false,
            is_archived: false,
            invite_token: String::new(),
            admin_ids: vec![members[0].into()],
            member_ids: members.into_iter().map(str::to_string).collect(),
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
            updated_at: now,
        }
    }

    async fn send_json(
        app: &axum::Router,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut req_b = Request::builder()
            .method(method)
            .uri(uri)
            .header("Authorization", format!("Bearer {token}"));
        let req = if let Some(b) = body {
            req_b = req_b.header("Content-Type", "application/json");
            req_b
                .body(Body::from(serde_json::to_vec(&b).unwrap()))
                .unwrap()
        } else {
            req_b.body(Body::empty()).unwrap()
        };
        let resp = app.clone().oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, json)
    }

    #[test]
    fn bangkok_quiet_hours_and_cooldown_and_guess_matcher() {
        // 00:30 UTC = 07:30 BKK (awake)
        let awake = DateTime::parse_from_rfc3339("2026-11-22T00:30:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert!(is_bangkok_awake_hour(awake));

        // 16:30 UTC = 23:30 BKK (quiet)
        let quiet_night = DateTime::parse_from_rfc3339("2026-11-22T16:30:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert!(!is_bangkok_awake_hour(quiet_night));

        // 23:30 UTC = 06:30 BKK (quiet)
        let quiet_morning = DateTime::parse_from_rfc3339("2026-11-22T23:30:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert!(!is_bangkok_awake_hour(quiet_morning));

        // Effective defaults on ConversationDoc
        let mut group_conv = make_test_conv("g1", "group", vec!["u1", "u2"]);
        let direct_conv = make_test_conv("d1", "direct", vec!["u1", "u2"]);
        let keep_conv = make_test_conv("k1", "keep", vec!["u1"]);
        assert!(group_conv.effective_ai_game_auto_invite());
        assert!(!direct_conv.effective_ai_game_auto_invite());
        assert!(!keep_conv.effective_ai_game_auto_invite());
        assert_eq!(group_conv.effective_ai_game_invite_cooldown_mins(), 30);

        // Cooldown anti-spam check
        assert!(is_proactive_cooldown_elapsed(&group_conv, awake));
        group_conv.last_ai_game_invite_at = Some((awake - Duration::minutes(10)).to_rfc3339());
        assert!(!is_proactive_cooldown_elapsed(&group_conv, awake));
        group_conv.last_ai_game_invite_at = Some((awake - Duration::minutes(31)).to_rfc3339());
        assert!(is_proactive_cooldown_elapsed(&group_conv, awake));

        // Guess normalizer & alias match
        assert!(is_hint_guess_correct(
            " ผัดไทย! ",
            "ผัดไทย",
            &["pad thai".to_string()]
        ));
        assert!(is_hint_guess_correct(
            "PadThai",
            "ผัดไทย",
            &["pad thai".to_string()]
        ));
        assert!(!is_hint_guess_correct("ส้มตำ", "ผัดไทย", &[]));

        // JSON extractor strips <think> and markdown fences
        let parsed = extract_json_value(
            "<think>คิดก่อน</think>\n```json\n{\"ok\":true,\"n\":3}\n```",
        )
        .expect("extract json");
        assert_eq!(parsed["ok"], json!(true));
        assert_eq!(parsed["n"], json!(3));
    }

    #[tokio::test]
    async fn full_5_engines_catalog_random_and_proactive_toggle_flow() {
        let run_short = &Uuid::new_v4().simple().to_string()[..8];
        let mut cfg = AppConfig::from_env();
        cfg.mongodb_db = format!("bcaichat_game_unit_{run_short}");
        cfg.ai_enabled = false; // offline fallback deterministic test
        cfg.ai_game_proactive_enabled = false;
        cfg.enable_test_users = false;

        let state = AppState::init(cfg).await.expect("init AppState");
        ensure_mongo_indexes(&state.db).await;
        let app = create_router(state.clone());

        let u1 = make_test_user("gu1", "ต้นน้ำ", "admin");
        let u2 = make_test_user("gu2", "แพรไหม", "user");
        let u3 = make_test_user("gu3", "ภูมิ", "user");
        state
            .db
            .collection::<UserDoc>("users")
            .insert_many(vec![u1.clone(), u2.clone(), u3.clone()])
            .await
            .unwrap();

        let grp = make_test_conv("g_room_1", "group", vec!["gu1", "gu2", "gu3"]);
        let keep = make_test_conv("k_room_1", "keep", vec!["gu1"]);
        state
            .db
            .collection::<ConversationDoc>("conversations")
            .insert_many(vec![grp, keep])
            .await
            .unwrap();

        let t1 = create_jwt("gu1", &u1.email, "admin", &state.config.jwt_secret).unwrap();
        let t2 = create_jwt("gu2", &u2.email, "user", &state.config.jwt_secret).unwrap();
        let t3 = create_jwt("gu3", &u3.email, "user", &state.config.jwt_secret).unwrap();

        let mut ws_rx = state.ws_hub.tx.subscribe();

        // 1. Catalog returns 100 unique games & filters cleanly
        let (st, cat_all) = send_json(&app, "GET", "/api/games/catalog", &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(cat_all["total"], json!(100));
        assert_eq!(cat_all["games"].as_array().unwrap().len(), 100);

        let (st, cat_solo) =
            send_json(&app, "GET", "/api/games/catalog?mode=solo", &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert!(cat_solo["games"]
            .as_array()
            .unwrap()
            .iter()
            .all(|g| g["min_players"].as_u64() == Some(1)));

        // 2. Proactive Invite + Room ON/OFF + Global ON/OFF + Anti-spam Cooldown
        let (st, inv1) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games/proactive-invite",
            &t1,
            Some(json!({})),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(inv1["invited"], json!(true));
        let inv_game_id = inv1["game"]["id"].as_str().unwrap().to_string();
        assert_eq!(inv1["game"]["proactive"], json!(true));
        assert_eq!(inv1["game"]["created_by"], json!("user_ai"));
        assert_eq!(inv1["message"]["sender_id"], json!("user_ai"));
        assert_eq!(inv1["message"]["card_payload"]["kind"], json!("game_invite"));

        // Second invite while active game exists -> invited: false (no double-invite!)
        let (st, dup_inv) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games/proactive-invite",
            &t1,
            Some(json!({ "force": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(dup_inv["invited"], json!(false));

        // Cancel proactive lobby
        let (st, _) = send_json(&app, "POST", &format!("/api/games/{inv_game_id}/cancel"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);

        // Cooldown anti-spam blocks immediate non-forced invite!
        let (st, cool_inv) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games/proactive-invite",
            &t1,
            Some(json!({})),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(cool_inv["invited"], json!(false));

        // Room toggle OFF blocks non-forced invite & broadcasts conversation_updated
        let (st, meta_off) = send_json(
            &app,
            "PUT",
            "/api/conversations/g_room_1/meta",
            &t1,
            Some(json!({ "ai_game_auto_invite": false, "ai_game_invite_cooldown_mins": 15 })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(meta_off["ai_game_auto_invite"], json!(false));
        assert_eq!(meta_off["ai_game_invite_cooldown_mins"], json!(15));

        let (st, room_off_inv) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games/proactive-invite",
            &t1,
            Some(json!({})),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(room_off_inv["invited"], json!(false));
        assert!(room_off_inv["reason"]
            .as_str()
            .unwrap_or("")
            .contains("ห้องนี้ปิด"));

        // Re-enable room toggle, then test global admin kill-switch
        let (st, _) = send_json(
            &app,
            "PUT",
            "/api/conversations/g_room_1/meta",
            &t1,
            Some(json!({ "ai_game_auto_invite": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);

        let (st, ai_off) = send_json(
            &app,
            "PUT",
            "/api/admin/ai-settings",
            &t1,
            Some(json!({ "proactive_game_invites": false })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(ai_off["proactive_game_invites"], json!(false));

        let (st, global_off_inv) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games/proactive-invite",
            &t1,
            Some(json!({ "force": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(global_off_inv["invited"], json!(false));

        // Restore global toggle ON
        let (st, _) = send_json(
            &app,
            "PUT",
            "/api/admin/ai-settings",
            &t1,
            Some(json!({ "proactive_game_invites": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);

        // 3. Quiz Engine (2 rounds, 2 players, answer secrecy before reveal, auto-reveal, finish)
        let (st, quiz) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games",
            &t1,
            Some(json!({ "game_type": "quiz", "topic": "อาหารไทย", "question_count": 2 })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let qid = quiz["id"].as_str().unwrap().to_string();
        assert_eq!(quiz["total_rounds"], json!(2));

        let (st, _) = send_json(&app, "POST", &format!("/api/games/{qid}/join"), &t2, None).await;
        assert_eq!(st, StatusCode::OK);
        let (st, started_q) =
            send_json(&app, "POST", &format!("/api/games/{qid}/start"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(started_q["status"], json!("playing"));
        assert!(
            started_q["current_question"]["correct_index"].is_null(),
            "correct_index MUST be hidden before reveal!"
        );
        assert!(started_q["current_question"]["explanation"].is_null());

        // Round 1 answers -> auto-reveal
        let (st, _) = send_json(
            &app,
            "POST",
            &format!("/api/games/{qid}/answer"),
            &t1,
            Some(json!({ "choice_index": 0 })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let (st, rev_q) = send_json(
            &app,
            "POST",
            &format!("/api/games/{qid}/answer"),
            &t2,
            Some(json!({ "choice_index": 1 })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(rev_q["round_revealed"], json!(true));
        assert!(rev_q["current_question"]["correct_index"].is_u64());

        // Advance to round 2 -> reveal -> finish
        let (st, r2) = send_json(&app, "POST", &format!("/api/games/{qid}/next"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(r2["round_index"], json!(1));
        assert_eq!(r2["round_revealed"], json!(false));
        assert!(r2["current_question"]["correct_index"].is_null());

        let (st, _) = send_json(&app, "POST", &format!("/api/games/{qid}/next"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        let (st, fin_q) =
            send_json(&app, "POST", &format!("/api/games/{qid}/next"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(fin_q["status"], json!("finished"));

        // 4. Undercover Engine (3 players, secret word isolation, self-vote 400, WS secrecy, tally)
        let (st, uc) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games",
            &t1,
            Some(json!({ "game_type": "undercover" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let ucid = uc["id"].as_str().unwrap().to_string();
        // Start with 1 player must fail (400)
        let (st, _) = send_json(&app, "POST", &format!("/api/games/{ucid}/start"), &t1, None).await;
        assert_eq!(st, StatusCode::BAD_REQUEST);

        let _ = send_json(&app, "POST", &format!("/api/games/{ucid}/join"), &t2, None).await;
        let _ = send_json(&app, "POST", &format!("/api/games/{ucid}/join"), &t3, None).await;
        let (st, _) = send_json(&app, "POST", &format!("/api/games/{ucid}/start"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);

        // Fetch personalized view for each of 3 players
        let (_, v1) = send_json(&app, "GET", &format!("/api/games/{ucid}"), &t1, None).await;
        let (_, v2) = send_json(&app, "GET", &format!("/api/games/{ucid}"), &t2, None).await;
        let (_, v3) = send_json(&app, "GET", &format!("/api/games/{ucid}"), &t3, None).await;
        let words = [
            v1["undercover"]["my_secret_word"].as_str().unwrap().to_string(),
            v2["undercover"]["my_secret_word"].as_str().unwrap().to_string(),
            v3["undercover"]["my_secret_word"].as_str().unwrap().to_string(),
        ];
        assert!(v1["undercover"]["revealed_spy_id"].is_null());
        let unique_words: HashSet<&String> = words.iter().collect();
        assert_eq!(unique_words.len(), 2, "must have exactly 1 spy word + 1 civilian word");

        // Drain WS events and ensure NO game_updated frame ever leaked secret words!
        while let Ok(frame) = ws_rx.try_recv() {
            if frame.contains("\"game_updated\"") {
                for w in &unique_words {
                    assert!(!frame.contains(w.as_str()), "WS game_updated leaked secret word!");
                }
                assert!(!frame.contains("correct_index"));
            }
        }

        // Submit clues -> auto-advance to vote
        let _ = send_json(
            &app,
            "POST",
            &format!("/api/games/{ucid}/clue"),
            &t1,
            Some(json!({ "clue": "อร่อยมาก" })),
        )
        .await;
        let _ = send_json(
            &app,
            "POST",
            &format!("/api/games/{ucid}/clue"),
            &t2,
            Some(json!({ "clue": "กินบ่อยตอนเย็น" })),
        )
        .await;
        let (st, voted_phase) = send_json(
            &app,
            "POST",
            &format!("/api/games/{ucid}/clue"),
            &t3,
            Some(json!({ "clue": "รสจัดจ้าน" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(voted_phase["phase"], json!("vote"));

        // Self-vote rejected with 400!
        let (st, _) = send_json(
            &app,
            "POST",
            &format!("/api/games/{ucid}/vote"),
            &t1,
            Some(json!({ "target_user_id": "gu1" })),
        )
        .await;
        assert_eq!(st, StatusCode::BAD_REQUEST);

        // All 3 vote -> auto-finish
        let _ = send_json(
            &app,
            "POST",
            &format!("/api/games/{ucid}/vote"),
            &t1,
            Some(json!({ "target_user_id": "gu2" })),
        )
        .await;
        let _ = send_json(
            &app,
            "POST",
            &format!("/api/games/{ucid}/vote"),
            &t2,
            Some(json!({ "target_user_id": "gu3" })),
        )
        .await;
        let (st, uc_fin) = send_json(
            &app,
            "POST",
            &format!("/api/games/{ucid}/vote"),
            &t3,
            Some(json!({ "target_user_id": "gu2" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(uc_fin["status"], json!("finished"));
        assert!(uc_fin["undercover"]["revealed_spy_id"].is_string());
        assert!(uc_fin["undercover"]["winner_side"].is_string());

        // 5. Hint Race Engine (progressive hints + hidden answer + solve scoring)
        let (st, hr) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games",
            &t1,
            Some(json!({ "game_type": "hint_race", "question_count": 1, "auto_start": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let hrid = hr["id"].as_str().unwrap().to_string();
        assert_eq!(hr["status"], json!("playing"));
        assert_eq!(hr["hint_race"]["hint_level"], json!(1));
        assert!(hr["hint_race"]["revealed_answer"].is_null());

        // Reveal hint #2 via /next
        let (st, hr2) = send_json(&app, "POST", &format!("/api/games/{hrid}/next"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(hr2["hint_race"]["hint_level"], json!(2));
        assert_eq!(hr2["hint_race"]["revealed_hints"].as_array().unwrap().len(), 2);

        // Peek true answer from DB and submit winning guess
        let db_hr = state
            .db
            .collection::<GameSessionDoc>("game_sessions")
            .find_one(doc! { "_id": &hrid })
            .await
            .unwrap()
            .unwrap();
        let true_ans = db_hr.hint_rounds[0].answer.clone();
        let (st, hr_solved) = send_json(
            &app,
            "POST",
            &format!("/api/games/{hrid}/guess"),
            &t1,
            Some(json!({ "guess": true_ans })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(hr_solved["round_revealed"], json!(true));
        assert_eq!(hr_solved["hint_race"]["revealed_answer"], json!(true_ans));
        assert_eq!(hr_solved["players"][0]["score"], json!(130)); // hint_level 2 -> 150 - 20 = 130
        let (st, hr_fin) =
            send_json(&app, "POST", &format!("/api/games/{hrid}/next"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(hr_fin["status"], json!("finished"));

        // 6. Party Vote Engine (voting + consensus bonus + commentary on reveal)
        let (st, pv) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games",
            &t1,
            Some(json!({ "game_type": "party_vote", "question_count": 1 })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let pvid = pv["id"].as_str().unwrap().to_string();
        let _ = send_json(&app, "POST", &format!("/api/games/{pvid}/join"), &t2, None).await;
        let (st, pv_s) =
            send_json(&app, "POST", &format!("/api/games/{pvid}/start"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert!(pv_s["party_vote"]["commentary"].is_null());

        let _ = send_json(
            &app,
            "POST",
            &format!("/api/games/{pvid}/answer"),
            &t1,
            Some(json!({ "choice_index": 0 })),
        )
        .await;
        let (st, pv_rev) = send_json(
            &app,
            "POST",
            &format!("/api/games/{pvid}/answer"),
            &t2,
            Some(json!({ "choice_index": 0 })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(pv_rev["round_revealed"], json!(true));
        assert!(pv_rev["party_vote"]["commentary"].is_string());
        assert_eq!(pv_rev["players"][0]["score"], json!(100)); // 50 participation + 50 consensus
        let (st, pv_fin) =
            send_json(&app, "POST", &format!("/api/games/{pvid}/next"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(pv_fin["status"], json!("finished"));

        // 7. Creative Challenge Engine (submit + fallback judge scoring 60..100 + finish)
        let (st, cc) = send_json(
            &app,
            "POST",
            "/api/conversations/g_room_1/games",
            &t1,
            Some(json!({ "game_type": "creative_challenge", "question_count": 1, "auto_start": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let ccid = cc["id"].as_str().unwrap().to_string();
        let (st, cc_sub) = send_json(
            &app,
            "POST",
            &format!("/api/games/{ccid}/submit"),
            &t1,
            Some(json!({ "text": "วันจันทร์ไม่เคยปราณีใคร แต่กาแฟเย็นปราณีเราเสมอ!" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(cc_sub["round_revealed"], json!(true));
        let judged_score = cc_sub["creative_challenge"]["entries"][0]["score"]
            .as_i64()
            .unwrap();
        assert!((60..=100).contains(&judged_score));
        assert!(cc_sub["creative_challenge"]["entries"][0]["judge_comment"].is_string());
        let (st, cc_fin) =
            send_json(&app, "POST", &format!("/api/games/{ccid}/next"), &t1, None).await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(cc_fin["status"], json!("finished"));

        // 8. Random Solo Game in Keep room auto-starts immediately!
        let (st, solo_rand) = send_json(
            &app,
            "POST",
            "/api/conversations/k_room_1/games/random",
            &t1,
            Some(json!({ "mode": "auto" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(solo_rand["status"], json!("playing"));
        assert_ne!(solo_rand["game_type"], json!("undercover"));
        assert!(!solo_rand["catalog_id"].as_str().unwrap().is_empty());

        // Cleanup test DB
        let _ = state.db.drop().await;
    }

    #[tokio::test]
    async fn mock_ai_game_generation_caching_and_confidential_image_guard() {
        use axum::{routing::post, Router};

        let mock_ai = Router::new().route(
            "/api/chat",
            post(|Json(body): Json<Value>| async move {
                let prompt = body["messages"]
                    .as_array()
                    .and_then(|a| a.last())
                    .and_then(|m| m.get("content"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let content = if prompt.contains("civilian_word") {
                    r#"<think>ลับ</think>{"category":"เครื่องดื่มไทย","civilian_word":"ชาไทยเย็น","spy_word":"ชาเขียวนม"}"#
                } else if prompt.contains("correct_index") {
                    r#"<think>ลับ</think>{"questions":[{"question":"ต้มยำกุ้งมีสมุนไพรหลักข้อใด?","options":["ตะไคร้ ใบมะกรูด ข่า","อบเชย โป๊ยกั๊ก","โรสแมรี่ ไทม์","วาซาบิ โชยุ"],"correct_index":0,"explanation":"ต้มยำกุ้งหอมเด่นจากข่า ตะไคร้ และใบมะกรูดครับ"}]}"#
                } else if prompt.contains("judgements") {
                    r#"<think>ลับ</think>{"judgements":[{"user_id":"aiu1","score":94,"comment":"คมกริบจนกรรมการต้องยกนิ้วให้เลย!"}]}"#
                } else if prompt.contains("catalog_id") {
                    r#"<think>ลับ</think>{"catalog_id":"thai_food_quiz","topic":"สตรีทฟู้ดไทย","host_message":"มาพักเบรกทายเรื่องของกินอร่อยๆ กันเถอะ!"}"#
                } else {
                    r#"{"ok":true}"#
                };
                Json(json!({
                    "model": body["model"],
                    "message": { "role": "assistant", "content": content },
                    "done": true
                }))
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ai_base = format!("http://{}", listener.local_addr().unwrap());
        let ai_srv = tokio::spawn(async move {
            let _ = axum::serve(listener, mock_ai).await;
        });

        let run_short = &Uuid::new_v4().simple().to_string()[..8];
        let mut cfg = AppConfig::from_env();
        cfg.mongodb_db = format!("bcaichat_game_ai_unit_{run_short}");
        cfg.ai_base_url = ai_base;
        cfg.ai_model = "mock-game-model".into();
        cfg.ai_api_key = String::new();
        cfg.ai_enabled = true;
        cfg.ai_game_proactive_enabled = false;
        cfg.enable_test_users = false;

        let state = AppState::init(cfg).await.expect("init AppState");
        ensure_mongo_indexes(&state.db).await;
        let app = create_router(state.clone());

        let u1 = make_test_user("aiu1", "ต้นน้ำ", "admin");
        let u2 = make_test_user("aiu2", "แพรไหม", "user");
        state
            .db
            .collection::<UserDoc>("users")
            .insert_many(vec![u1.clone(), u2.clone()])
            .await
            .unwrap();
        let grp = make_test_conv("ai_grp_1", "group", vec!["aiu1", "aiu2"]);
        state
            .db
            .collection::<ConversationDoc>("conversations")
            .insert_one(&grp)
            .await
            .unwrap();

        // Insert a confidential image message to ensure Creative Challenge blocks it with 403
        let secret_msg: MessageDoc = serde_json::from_value(json!({
            "_id": "msg_secret_photo_1",
            "conversation_id": "ai_grp_1",
            "sender_id": "aiu1",
            "sender_name": "ต้นน้ำ",
            "sender_avatar": "",
            "type": "image",
            "content": "ภาพลับ",
            "is_confidential": true,
            "confidential_pin": "1234",
            "attachment": {
                "key": "secret.png",
                "url": "/api/files/secret.png",
                "file_name": "secret.png",
                "mime_type": "image/png",
                "file_size": 128
            },
            "created_at": Utc::now().to_rfc3339()
        }))
        .unwrap();
        state
            .db
            .collection::<MessageDoc>("messages")
            .insert_one(&secret_msg)
            .await
            .unwrap();

        let t1 = create_jwt("aiu1", &u1.email, "admin", &state.config.jwt_secret).unwrap();

        // 1. Live mock AI Proactive Invite -> no <think>, uses AI host_message & topic
        let (st, inv) = send_json(
            &app,
            "POST",
            "/api/conversations/ai_grp_1/games/proactive-invite",
            &t1,
            Some(json!({})),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(inv["invited"], json!(true));
        assert_eq!(
            inv["game"]["host_message"],
            json!("มาพักเบรกทายเรื่องของกินอร่อยๆ กันเถอะ!")
        );
        assert!(!inv["game"]["host_message"]
            .as_str()
            .unwrap()
            .contains("<think>"));
        let inv_id = inv["game"]["id"].as_str().unwrap().to_string();

        // GET /active returns active_game + settings cleanly
        let (st, active) = send_json(
            &app,
            "GET",
            "/api/conversations/ai_grp_1/games/active",
            &t1,
            None,
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(active["active_game"]["id"], json!(inv_id));
        assert_eq!(active["ai_game_auto_invite"], json!(true));
        assert_eq!(active["proactive_enabled_globally"], json!(true));

        let _ = send_json(&app, "POST", &format!("/api/games/{inv_id}/cancel"), &t1, None).await;

        // 2. Live mock AI Quiz caches pack in MongoDB game_question_packs
        let (st, q) = send_json(
            &app,
            "POST",
            "/api/conversations/ai_grp_1/games",
            &t1,
            Some(json!({ "game_type": "quiz", "topic": "อาหารไทย", "question_count": 1, "auto_start": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(
            q["current_question"]["question"],
            json!("ต้มยำกุ้งมีสมุนไพรหลักข้อใด?")
        );
        let cached_count = state
            .db
            .collection::<GameQuestionPackDoc>("game_question_packs")
            .count_documents(doc! { "game_type": "quiz" })
            .await
            .unwrap();
        assert!(cached_count >= 1, "AI quiz pack must be cached in MongoDB");
        let qid = q["id"].as_str().unwrap().to_string();
        let _ = send_json(&app, "POST", &format!("/api/games/{qid}/cancel"), &t1, None).await;

        // 3. Live mock AI Undercover generates Thai pair cleanly
        let (st, uc) = send_json(
            &app,
            "POST",
            "/api/conversations/ai_grp_1/games",
            &t1,
            Some(json!({ "game_type": "undercover" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(uc["undercover"]["category"], json!("เครื่องดื่มไทย"));
        let ucid = uc["id"].as_str().unwrap().to_string();
        let _ = send_json(&app, "POST", &format!("/api/games/{ucid}/cancel"), &t1, None).await;

        // 4. Creative challenge rejects confidential PIN-locked image with 403, accepts valid text & uses AI judge
        let (st, cc) = send_json(
            &app,
            "POST",
            "/api/conversations/ai_grp_1/games",
            &t1,
            Some(json!({ "game_type": "creative_challenge", "question_count": 1, "auto_start": true })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let ccid = cc["id"].as_str().unwrap().to_string();
        let (st, _) = send_json(
            &app,
            "POST",
            &format!("/api/games/{ccid}/submit"),
            &t1,
            Some(json!({ "text": "ส่งภาพลับ", "image_message_id": "msg_secret_photo_1" })),
        )
        .await;
        assert_eq!(st, StatusCode::FORBIDDEN);

        let (st, cc_ok) = send_json(
            &app,
            "POST",
            &format!("/api/games/{ccid}/submit"),
            &t1,
            Some(json!({ "text": "กาแฟเย็นช่วยชีวิตวันจันทร์" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        assert_eq!(cc_ok["creative_challenge"]["entries"][0]["score"], json!(94));
        assert_eq!(
            cc_ok["creative_challenge"]["entries"][0]["judge_comment"],
            json!("คมกริบจนกรรมการต้องยกนิ้วให้เลย!")
        );
        let _ = send_json(&app, "POST", &format!("/api/games/{ccid}/cancel"), &t1, None).await;

        // 5. Consecutive random games avoid repeating catalog_id back-to-back
        let (st, r1) = send_json(
            &app,
            "POST",
            "/api/conversations/ai_grp_1/games/random",
            &t1,
            Some(json!({ "mode": "group" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let r1_id = r1["id"].as_str().unwrap().to_string();
        let r1_cat = r1["catalog_id"].as_str().unwrap().to_string();
        let _ = send_json(&app, "POST", &format!("/api/games/{r1_id}/cancel"), &t1, None).await;

        let (st, r2) = send_json(
            &app,
            "POST",
            "/api/conversations/ai_grp_1/games/random",
            &t1,
            Some(json!({ "mode": "group" })),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
        let r2_cat = r2["catalog_id"].as_str().unwrap().to_string();
        assert_ne!(r1_cat, r2_cat, "randomizer must avoid repeating recent catalog_id");

        let _ = state.db.drop().await;
        ai_srv.abort();
    }
}
