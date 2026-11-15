use bson::{doc, Document, Regex};
use chrono::Utc;
use futures_util::TryStreamExt;
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use crate::{
    models::{
        AlbumDoc, ConversationDoc, FriendshipDoc, LastMessageSummary, MessageDoc, MiniAppDoc,
        NoteDoc, OaAccountDoc, OaAutoReplyRuleDoc, OaCouponDoc, OaFollowerDoc, OaRichMenuItem,
        UserDoc,
    },
    routes::admin_routes::DEFAULT_THEME,
    AppState,
};

pub const TEST_USER_IDS: [&str; 5] = [
    "11111111-1111-4111-8111-111111111101",
    "11111111-1111-4111-8111-111111111102",
    "11111111-1111-4111-8111-111111111103",
    "11111111-1111-4111-8111-111111111104",
    "11111111-1111-4111-8111-111111111105",
];

#[derive(Debug, Clone, Copy)]
pub struct QuickTestUserSpec {
    pub slot: u8,
    pub id: &'static str,
    pub display_name: &'static str,
    pub bc_id: &'static str,
    pub phone: &'static str,
    pub email: &'static str,
    pub role: &'static str,
    pub status_message: &'static str,
    pub badge: &'static str,
    pub qr_token: &'static str,
    pub avatar_bg: &'static str,
}

pub const QUICK_TEST_USERS: [QuickTestUserSpec; 5] = [
    QuickTestUserSpec {
        slot: 1,
        id: TEST_USER_IDS[0],
        display_name: "ต้นน้ำ",
        bc_id: "@tonnam",
        phone: "0810000001",
        email: "tonnam@test.bcaichat.app", // pragma: allowlist secret
        role: "user",
        status_message: "เจ้าของร้านชาบ้านเชียง & เพื่อนในกลุ่ม",
        badge: "เจ้าของร้านค้า • เพื่อน",
        qr_token: "BCQR_TEST_TONNAM_01", // pragma: allowlist secret
        avatar_bg: "812920",
    },
    QuickTestUserSpec {
        slot: 2,
        id: TEST_USER_IDS[1],
        display_name: "แพรไหม",
        bc_id: "@praemai",
        phone: "0810000002",
        email: "praemai@test.bcaichat.app", // pragma: allowlist secret
        role: "user",
        status_message: "เพื่อนสนิท & ทีมงานช่วยตอบแชทร้าน",
        badge: "เพื่อนสนิท • ทีมงานร้านค้า",
        qr_token: "BCQR_TEST_PRAEMAI_02", // pragma: allowlist secret
        avatar_bg: "A04035",
    },
    QuickTestUserSpec {
        slot: 3,
        id: TEST_USER_IDS[2],
        display_name: "ภูมิ",
        bc_id: "@phoom",
        phone: "0810000003",
        email: "phoom@test.bcaichat.app", // pragma: allowlist secret
        role: "user",
        status_message: "สายเที่ยว ถ่ายรูป นัดกินข้าว",
        badge: "เพื่อนในกลุ่ม",
        qr_token: "BCQR_TEST_PHOOM_03", // pragma: allowlist secret
        avatar_bg: "B45309",
    },
    QuickTestUserSpec {
        slot: 4,
        id: TEST_USER_IDS[3],
        display_name: "ใบบัว",
        bc_id: "@baibua",
        phone: "0810000004",
        email: "baibua@test.bcaichat.app", // pragma: allowlist secret
        role: "user",
        status_message: "ครอบครัว & ลูกค้าประจำร้านชา",
        badge: "ครอบครัว • ลูกค้าร้านค้า",
        qr_token: "BCQR_TEST_BAIBUA_04", // pragma: allowlist secret
        avatar_bg: "13795B",
    },
    QuickTestUserSpec {
        slot: 5,
        id: TEST_USER_IDS[4],
        display_name: "คิน",
        bc_id: "@kin",
        phone: "0810000005",
        email: "kin@test.bcaichat.app", // pragma: allowlist secret
        role: "user",
        status_message: "เพื่อนใหม่ ทดสอบค้นหาเบอร์ 0810000005",
        badge: "เพื่อนใหม่ (ลองค้นหา/เพิ่มเพื่อน)",
        qr_token: "BCQR_TEST_KIN_05", // pragma: allowlist secret
        avatar_bg: "1E40AF",
    },
];

const SEEDED_PURGE_USER_IDS: [&str; 8] = [
    "user_demo1",
    "user_demo2",
    "user_demo3",
    "user_demo4",
    "user_demo5",
    "user_jead",
    "user_somchai",
    "user_nida",
];

const SEEDED_PURGE_CONV_IDS: [&str; 3] = [
    "conv_group_office",
    "conv_group_demo5",
    "conv_group_family",
];

pub async fn ensure_mongo_indexes(db: &mongodb::Database) {
    use mongodb::{options::IndexOptions, IndexModel};
    let users_coll = db.collection::<UserDoc>("users");
    let _ = users_coll
        .create_indexes(vec![
            IndexModel::builder().keys(doc! { "email": 1 }).build(),
            IndexModel::builder().keys(doc! { "phone": 1 }).build(),
            IndexModel::builder().keys(doc! { "qr_token": 1 }).build(),
            IndexModel::builder().keys(doc! { "google_id": 1 }).build(),
        ])
        .await;
    let unique_bc_id = IndexModel::builder()
        .keys(doc! { "bc_id": 1 })
        .options(IndexOptions::builder().unique(true).build())
        .build();
    if users_coll.create_index(unique_bc_id.clone()).await.is_err() {
        let _ = users_coll.drop_index("bc_id_1").await;
        let _ = users_coll.create_index(unique_bc_id).await;
    }
    let _ = db
        .collection::<ConversationDoc>("conversations")
        .create_indexes(vec![
            IndexModel::builder()
                .keys(doc! { "member_ids": 1, "is_pinned": -1, "updated_at": -1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "invite_token": 1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "oa_id": 1 })
                .build(),
        ])
        .await;
    let _ = db
        .collection::<MessageDoc>("messages")
        .create_indexes(vec![
            IndexModel::builder()
                .keys(doc! { "conversation_id": 1, "created_at": 1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "conversation_id": 1, "is_unsent": 1, "sender_id": 1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "conversation_id": 1, "is_confidential": 1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "conversation_id": 1, "type": 1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "conversation_id": 1, "is_unsent": 1, "read_by": 1 })
                .build(),
        ])
        .await;
    let _ = db
        .collection::<Document>("device_tokens")
        .create_index(IndexModel::builder().keys(doc! { "user_id": 1 }).build())
        .await;
    let _ = db
        .collection::<FriendshipDoc>("friendships")
        .create_indexes(vec![
            IndexModel::builder()
                .keys(doc! { "user_id": 1, "friend_id": 1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "user_id": 1, "is_blocked": 1, "friend_id": 1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "friend_id": 1, "is_blocked": 1, "user_id": 1 })
                .build(),
        ])
        .await;
    let _ = db
        .collection::<NoteDoc>("notes")
        .create_index(
            IndexModel::builder()
                .keys(doc! { "owner_id": 1, "conversation_id": 1, "is_pinned": -1 })
                .build(),
        )
        .await;
    let _ = db
        .collection::<AlbumDoc>("albums")
        .create_index(
            IndexModel::builder()
                .keys(doc! { "conversation_id": 1, "updated_at": -1 })
                .build(),
        )
        .await;
    let _ = db
        .collection::<Document>("otp_sessions")
        .create_indexes(vec![
            IndexModel::builder().keys(doc! { "phone": 1, "created_at": -1 }).build(),
            IndexModel::builder().keys(doc! { "expires_at": 1 }).build(),
        ])
        .await;
    let _ = db
        .collection::<Document>("google_oauth_states")
        .create_index(IndexModel::builder().keys(doc! { "expires_at": 1 }).build())
        .await;
    let _ = db
        .collection::<Document>("oa_accounts")
        .create_indexes(vec![
            IndexModel::builder().keys(doc! { "handle": 1 }).build(),
            IndexModel::builder().keys(doc! { "owner_id": 1 }).build(),
            IndexModel::builder().keys(doc! { "admin_ids": 1 }).build(),
        ])
        .await;
    let _ = db
        .collection::<Document>("oa_followers")
        .create_indexes(vec![
            IndexModel::builder().keys(doc! { "oa_id": 1, "user_id": 1 }).build(),
            IndexModel::builder().keys(doc! { "user_id": 1 }).build(),
        ])
        .await;
    let _ = db
        .collection::<Document>("oa_auto_replies")
        .create_index(IndexModel::builder().keys(doc! { "oa_id": 1 }).build())
        .await;
    let _ = db
        .collection::<Document>("oa_coupons")
        .create_index(IndexModel::builder().keys(doc! { "oa_id": 1 }).build())
        .await;
    let _ = db
        .collection::<Document>("oa_broadcasts")
        .create_index(IndexModel::builder().keys(doc! { "oa_id": 1, "created_at": -1 }).build())
        .await;
    let _ = db
        .collection::<Document>("call_sessions")
        .create_indexes(vec![
            IndexModel::builder()
                .keys(doc! { "conversation_id": 1, "status": 1, "started_at": -1 })
                .build(),
            IndexModel::builder()
                .keys(doc! { "target_user_ids": 1, "status": 1 })
                .build(),
        ])
        .await;
    let _ = db
        .collection::<Document>("account_recovery_logs")
        .create_index(
            IndexModel::builder()
                .keys(doc! { "user_id": 1, "created_at": -1 })
                .build(),
        )
        .await;
}

async fn upsert_seeded_user(
    users_coll: &mongodb::Collection<UserDoc>,
    user: &UserDoc,
) -> Result<(), String> {
    let existing = users_coll
        .find_one(doc! { "_id": &user.id })
        .await
        .map_err(|e| e.to_string())?;
    if existing.is_none() {
        users_coll
            .insert_one(user)
            .await
            .map_err(|e| e.to_string())?;
    } else {
        users_coll
            .update_one(
                doc! { "_id": &user.id },
                doc! {
                    "$set": {
                        "email": &user.email,
                        "phone": &user.phone,
                        "phone_verified": user.phone_verified,
                        "email_verified": user.email_verified,
                        "display_name": &user.display_name,
                        "bc_id": &user.bc_id,
                        "avatar_url": &user.avatar_url,
                        "status_message": &user.status_message,
                        "role": &user.role,
                        "department": &user.department,
                        "job_title": &user.job_title,
                        "is_oa_bot": user.is_oa_bot,
                        "oa_id": &user.oa_id,
                    }
                },
            )
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Removes all legacy Demo/test seed users, demo rooms, and sample files from MongoDB & MinIO.
/// Keeps ONLY `user_ai`, `user_official`, real registered users, and OA bots (`user_oa_*`).
async fn migrate_legacy_seed_data(state: &AppState) {
    let legacy_file_keys = [
        "seed_tax_invoice_preview.svg",
        "seed_quotation_QT2026_0089.txt",
        "seed_trip_postcard.svg",
        "seed_weekend_trip.txt",
    ];
    for key in legacy_file_keys {
        let _ = state.minio.delete_object(key).await;
    }

    let seed_conv_ids: Vec<&str> = SEEDED_PURGE_CONV_IDS.to_vec();
    let _ = state
        .db
        .collection::<Document>("files")
        .delete_many(doc! {
            "$or": [
                { "_id": { "$in": ["file_seed_invoice_img", "file_seed_quotation_doc", "file_seed_trip_img", "file_seed_trip_doc"] } },
                { "key": { "$in": legacy_file_keys.as_slice() } },
                { "conversation_id": { "$in": &seed_conv_ids } }
            ]
        })
        .await;

    // Identify demo / old seeded users to purge
    let users_doc_coll = state.db.collection::<Document>("users");
    let demo_email_rx = Regex {
        pattern: r"^(demo[0-9]+|jead|somchai|nida)@(bcaichat|bcapp)\.local$".to_string(),
        options: "i".to_string(),
    };
    let fixed_purge_ids: Vec<&str> = SEEDED_PURGE_USER_IDS.to_vec();
    let mut purged_ids: HashSet<String> = SEEDED_PURGE_USER_IDS
        .iter()
        .map(|s| (*s).to_string())
        .collect();

    if let Ok(cursor) = users_doc_coll
        .find(doc! {
            "_id": { "$nin": ["user_ai", "user_official"] },
            "$or": [
                { "_id": { "$in": &fixed_purge_ids } },
                { "email": demo_email_rx.clone() },
            ]
        })
        .await
    {
        if let Ok(docs) = cursor.try_collect::<Vec<Document>>().await {
            for d in docs {
                if let Ok(id) = d.get_str("_id") {
                    if !id.starts_with("user_oa_") && !TEST_USER_IDS.contains(&id) {
                        purged_ids.insert(id.to_string());
                    }
                }
            }
        }
    }

    let purged_list: Vec<String> = purged_ids.into_iter().collect();
    if !purged_list.is_empty() {
        let _ = users_doc_coll
            .delete_many(doc! { "_id": { "$in": &purged_list } })
            .await;
        let _ = state
            .db
            .collection::<Document>("friendships")
            .delete_many(doc! {
                "$or": [
                    { "user_id": { "$in": &purged_list } },
                    { "friend_id": { "$in": &purged_list } },
                ]
            })
            .await;
        let _ = state
            .db
            .collection::<Document>("device_tokens")
            .delete_many(doc! { "user_id": { "$in": &purged_list } })
            .await;
        let personal_note_ids: Vec<String> = purged_list
            .iter()
            .map(|id| format!("note_personal_seed_{id}"))
            .collect();
        let _ = state
            .db
            .collection::<Document>("notes")
            .delete_many(doc! {
                "$or": [
                    { "_id": { "$in": &personal_note_ids } },
                    { "owner_id": { "$in": &purged_list } },
                ]
            })
            .await;
    }

    // Collect direct conversations involving purged demo users + fixed seed rooms
    let conv_docs_coll = state.db.collection::<Document>("conversations");
    let mut deleted_conv_ids: HashSet<String> = SEEDED_PURGE_CONV_IDS
        .iter()
        .map(|s| (*s).to_string())
        .collect();

    if !purged_list.is_empty() {
        if let Ok(cursor) = conv_docs_coll
            .find(doc! {
                "$or": [
                    { "_id": { "$in": &seed_conv_ids } },
                    { "type": { "$in": ["direct", "official"] }, "member_ids": { "$in": &purged_list } },
                ]
            })
            .await
        {
            if let Ok(convs) = cursor.try_collect::<Vec<Document>>().await {
                for c in convs {
                    if let Ok(id) = c.get_str("_id") {
                        if !matches!(
                            id,
                            "conv_dm_test_1_2"
                                | "conv_group_test_friends"
                                | "conv_oa_test_chabanchiang"
                        ) {
                            deleted_conv_ids.insert(id.to_string());
                        }
                    }
                }
            }
        }
        // Pull deleted demo users from any remaining group conversations
        let _ = conv_docs_coll
            .update_many(
                doc! {},
                doc! {
                    "$pullAll": {
                        "member_ids": &purged_list,
                        "admin_ids": &purged_list,
                    }
                },
            )
            .await;
    }

    let deleted_conv_list: Vec<String> = deleted_conv_ids.into_iter().collect();
    if !deleted_conv_list.is_empty() {
        let _ = conv_docs_coll
            .delete_many(doc! { "_id": { "$in": &deleted_conv_list } })
            .await;
        let _ = state
            .db
            .collection::<Document>("messages")
            .delete_many(doc! { "conversation_id": { "$in": &deleted_conv_list } })
            .await;
    }

    let _ = state
        .db
        .collection::<Document>("notes")
        .delete_many(doc! {
            "$or": [
                { "conversation_id": { "$in": &deleted_conv_list } },
                { "_id": { "$in": ["note_group_office_1", "note_group_family_1", "note_demo5_seed_1"] } }
            ]
        })
        .await;

    let _ = state
        .db
        .collection::<Document>("albums")
        .delete_many(doc! {
            "$or": [
                { "conversation_id": { "$in": &deleted_conv_list } },
                { "_id": { "$in": ["album_office_seed_1", "album_demo5_seed_1", "album_family_seed_1"] } }
            ]
        })
        .await;

    let _ = state
        .db
        .collection::<Document>("mini_apps")
        .delete_many(doc! {
            "$or": [
                { "app_code": { "$in": ["ai_copilot", "leave_approval", "quick_quotation", "expense_claim", "crm_queue"] } },
                { "_id": { "$in": ["mini_ai_copilot", "mini_leave", "mini_quotation", "mini_expense", "mini_booking"] } }
            ]
        })
        .await;

    let legacy_rx = Regex {
        pattern: concat!(
            "0105566099887|INV-2026-08914|QT-2026-0089|",
            "\u{0e1d}\u{0e48}\u{0e32}\u{0e22}\u{0e02}\u{0e32}\u{0e22}|",
            "\u{0e1a}\u{0e31}\u{0e0d}\u{0e0a}\u{0e35}\u{0e01}\u{0e32}\u{0e23}\u{0e40}\u{0e07}\u{0e34}\u{0e19}|",
            "\u{0e1a}\u{0e31}\u{0e0d}\u{0e0a}\u{0e35}\u{0e41}\u{0e25}\u{0e30}\u{0e01}\u{0e32}\u{0e23}\u{0e40}\u{0e07}\u{0e34}\u{0e19}|",
            "\u{0e04}\u{0e25}\u{0e31}\u{0e07}\u{0e2a}\u{0e34}\u{0e19}\u{0e04}\u{0e49}\u{0e32}|",
            "\u{0e14}\u{0e39}\u{0e41}\u{0e25}\u{0e25}\u{0e39}\u{0e01}\u{0e04}\u{0e49}\u{0e32}|",
            "\u{0e1a}\u{0e23}\u{0e34}\u{0e01}\u{0e32}\u{0e23}\u{0e25}\u{0e39}\u{0e01}\u{0e04}\u{0e49}\u{0e32}|",
            "\u{0e08}\u{0e31}\u{0e14}\u{0e0b}\u{0e37}\u{0e49}\u{0e2d}|",
            "\u{0e43}\u{0e1a}\u{0e40}\u{0e2a}\u{0e19}\u{0e2d}\u{0e23}\u{0e32}\u{0e04}\u{0e32}|",
            "\u{0e43}\u{0e1a}\u{0e01}\u{0e33}\u{0e01}\u{0e31}\u{0e1a}\u{0e20}\u{0e32}\u{0e29}\u{0e35}|",
            "\u{0e2d}\u{0e19}\u{0e38}\u{0e21}\u{0e31}\u{0e15}\u{0e34}\u{0e43}\u{0e1a}\u{0e25}\u{0e32}|",
            "\u{0e42}\u{0e2d}\u{0e19}\u{0e22}\u{0e49}\u{0e32}\u{0e22}\u{0e07}\u{0e32}\u{0e19}|",
            "\u{0e2d}\u{0e07}\u{0e04}\u{0e4c}\u{0e01}\u{0e23}|",
            "\u{0e40}\u{0e23}\u{0e37}\u{0e48}\u{0e2d}\u{0e07}\u{0e07}\u{0e32}\u{0e19}|",
            "\u{0e07}\u{0e32}\u{0e19}\u{0e14}\u{0e48}\u{0e27}\u{0e19}|",
            "\u{0e1b}\u{0e23}\u{0e30}\u{0e01}\u{0e32}\u{0e28}\u{0e17}\u{0e32}\u{0e07}\u{0e01}\u{0e32}\u{0e23}|",
            "\u{0e1c}\u{0e39}\u{0e49}\u{0e14}\u{0e39}\u{0e41}\u{0e25}\u{0e2a}\u{0e39}\u{0e07}\u{0e2a}\u{0e38}\u{0e14}|",
            "\u{0e1c}\u{0e39}\u{0e49}\u{0e0a}\u{0e48}\u{0e27}\u{0e22}\u{0e2d}\u{0e31}\u{0e08}\u{0e09}\u{0e23}\u{0e34}\u{0e22}\u{0e30}|",
            "\u{0e1e}\u{0e19}\u{0e31}\u{0e01}\u{0e07}\u{0e32}\u{0e19}"
        )
        .to_string(),
        options: "i".to_string(),
    };

    let files_doc_coll = state.db.collection::<Document>("files");
    if let Ok(f_cursor) = files_doc_coll
        .find(doc! {
            "$or": [
                { "uploader_name": legacy_rx.clone() },
                { "file_name": legacy_rx.clone() }
            ]
        })
        .await
    {
        if let Ok(stale_files) = f_cursor.try_collect::<Vec<Document>>().await {
            for fd in &stale_files {
                if let Ok(k) = fd.get_str("key") {
                    let _ = state.minio.delete_object(k).await;
                }
            }
        }
    }
    let _ = files_doc_coll
        .delete_many(doc! {
            "$or": [
                { "uploader_name": legacy_rx.clone() },
                { "file_name": legacy_rx.clone() }
            ]
        })
        .await;

    let _ = state
        .db
        .collection::<Document>("messages")
        .delete_many(doc! {
            "$or": [
                { "content": legacy_rx.clone() },
                { "sender_name": legacy_rx.clone() },
                { "accepted_by": legacy_rx.clone() },
            ]
        })
        .await;

    // Ensure AI & auth settings documents initialize cleanly
    let _ = crate::routes::ai_routes::get_effective_ai_settings(state).await;
}

pub async fn seed_initial_data(state: &AppState) -> Result<(), String> {
    ensure_mongo_indexes(&state.db).await;

    if let Err(e) = state.minio.ensure_bucket().await {
        tracing::warn!("MinIO bucket ensure warning: {}", e);
    }

    migrate_legacy_seed_data(state).await;

    let now = Utc::now().to_rfc3339();

    let settings_coll = state.db.collection::<Document>("app_settings");
    if settings_coll
        .find_one(doc! { "_id": "theme" })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let _ = settings_coll
            .insert_one(doc! {
                "_id": "theme",
                "preset": DEFAULT_THEME,
                "updated_by": "system",
                "updated_at": &now,
            })
            .await;
    }

    let users_coll = state.db.collection::<UserDoc>("users");
    ensure_system_accounts(&users_coll, &now).await?;

    // Seed 5 Personal Mini-Apps (Ban Chiang palette)
    let mini_coll = state.db.collection::<MiniAppDoc>("mini_apps");
    let base_url = &state.config.public_base_url;
    let initial_mini_apps = vec![
        MiniAppDoc {
            id: "mini_ai_companion".to_string(),
            app_code: "ai_companion".to_string(),
            title: "ผู้ช่วย AI ส่วนตัว".to_string(),
            subtitle: "ช่วยคิดแผนเที่ยว สรุปแชทกลุ่ม เกลาข้อความ และตั้งเตือนนัดหมาย".to_string(),
            category: "ai".to_string(),
            icon_name: "auto_awesome".to_string(),
            color_hex: "#812920".to_string(),
            entry_url: format!("{}/miniapp/ai", base_url),
            is_active: true,
            sort_order: 0,
            created_at: now.clone(),
            updated_at: now.clone(),
        },
        MiniAppDoc {
            id: "mini_split_bill".to_string(),
            app_code: "split_bill".to_string(),
            title: "หารค่าข้าวกับเพื่อน".to_string(),
            subtitle: "คำนวณหารมื้ออร่อยกับแก๊งเพื่อน แล้วส่งการ์ดสรุปยอดเข้าแชททันที".to_string(),
            category: "lifestyle".to_string(),
            icon_name: "payments".to_string(),
            color_hex: "#A04035".to_string(),
            entry_url: format!("{}/miniapp/split", base_url),
            is_active: true,
            sort_order: 1,
            created_at: now.clone(),
            updated_at: now.clone(),
        },
        MiniAppDoc {
            id: "mini_trip_planner".to_string(),
            app_code: "trip_planner".to_string(),
            title: "จัดทริปเที่ยว".to_string(),
            subtitle: "วางแผนจุดแวะเที่ยว ที่พัก และงบทริปแชร์ให้ทุกคนในกลุ่ม".to_string(),
            category: "travel".to_string(),
            icon_name: "explore".to_string(),
            color_hex: "#B45309".to_string(),
            entry_url: format!("{}/miniapp/trip", base_url),
            is_active: true,
            sort_order: 2,
            created_at: now.clone(),
            updated_at: now.clone(),
        },
        MiniAppDoc {
            id: "mini_gift_wishlist".to_string(),
            app_code: "gift_wishlist".to_string(),
            title: "ลิสต์ของฝาก / ช้อปปิ้ง".to_string(),
            subtitle: "จดรายการของฝากและของเข้าบ้าน แชร์ให้ครอบครัวช่วยกันเช็ก".to_string(),
            category: "lifestyle".to_string(),
            icon_name: "redeem".to_string(),
            color_hex: "#13795B".to_string(),
            entry_url: format!("{}/miniapp/wishlist", base_url),
            is_active: true,
            sort_order: 3,
            created_at: now.clone(),
            updated_at: now.clone(),
        },
        MiniAppDoc {
            id: "mini_hangout_invite".to_string(),
            app_code: "hangout_invite".to_string(),
            title: "การ์ดชวนนัดเจอ".to_string(),
            subtitle: "ส่งการ์ดชวนกินข้าว ดูหนัง หรือสังสรรค์วันหยุดให้เพื่อนกดตอบรับ".to_string(),
            category: "social".to_string(),
            icon_name: "celebration".to_string(),
            color_hex: "#1E40AF".to_string(),
            entry_url: format!("{}/miniapp/hangout", base_url),
            is_active: true,
            sort_order: 4,
            created_at: now.clone(),
            updated_at: now.clone(),
        },
    ];

    for app in initial_mini_apps {
        mini_coll
            .replace_one(doc! { "_id": &app.id }, &app)
            .upsert(true)
            .await
            .map_err(|e| e.to_string())?;
    }

    if state.config.enable_test_users {
        ensure_quick_test_users(state).await?;
    }

    Ok(())
}

async fn ensure_system_accounts(
    users_coll: &mongodb::Collection<UserDoc>,
    now: &str,
) -> Result<(), String> {
    let system_accounts = [
        UserDoc {
            id: "user_official".to_string(),
            email: "official@bcaichat.local".to_string(),
            phone: String::new(),
            phone_verified: false,
            email_verified: false,
            display_name: "ข่าวสาร BC Ai Chat".to_string(),
            bc_id: "@bc.official".to_string(),
            avatar_url: "https://ui-avatars.com/api/?name=BC+News&background=A04035&color=fff&bold=true".to_string(),
            status_message: "อัปเดตฟีเจอร์ใหม่ แนะนำการใช้งานแชทส่วนตัว และร้านค้า".to_string(),
            qr_token: "BCQR_OFFICIAL_BC".to_string(),
            role: "admin".to_string(),
            department: "ข่าวสารแอป".to_string(),
            job_title: "บัญชีทางการ".to_string(),
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
            created_at: now.to_string(),
        },
        UserDoc {
            id: "user_ai".to_string(),
            email: "ai@bcaichat.local".to_string(),
            phone: String::new(),
            phone_verified: false,
            email_verified: false,
            display_name: "🤖 BC AI ผู้ช่วยส่วนตัว".to_string(),
            bc_id: "@bc.ai".to_string(),
            avatar_url: "https://ui-avatars.com/api/?name=BC+AI&background=812920&color=fff&bold=true".to_string(),
            status_message: "ผู้ช่วย AI ส่วนตัวสำหรับทุกคนและทุกกลุ่ม (เรียก @ai ได้ทุกห้อง)".to_string(),
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
            created_at: now.to_string(),
        },
    ];

    for u in &system_accounts {
        upsert_seeded_user(users_coll, u).await?;
    }
    Ok(())
}

pub async fn ensure_quick_test_users(state: &AppState) -> Result<(), String> {
    let now = Utc::now().to_rfc3339();
    let users_coll = state.db.collection::<UserDoc>("users");
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    ensure_system_accounts(&users_coll, &now).await?;

    let mut test_docs = Vec::with_capacity(QUICK_TEST_USERS.len());
    for spec in &QUICK_TEST_USERS {
        let avatar_url = format!(
            "https://ui-avatars.com/api/?name={}&background={}&color=fff&bold=true",
            urlencoding::encode(spec.display_name),
            spec.avatar_bg
        );
        let user_doc = UserDoc {
            id: spec.id.to_string(),
            email: spec.email.to_string(),
            phone: spec.phone.to_string(),
            phone_verified: true,
            email_verified: true,
            display_name: spec.display_name.to_string(),
            bc_id: spec.bc_id.to_string(),
            avatar_url,
            status_message: spec.status_message.to_string(),
            qr_token: spec.qr_token.to_string(),
            role: spec.role.to_string(),
            department: "เพื่อน".to_string(),
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
        };
        upsert_seeded_user(&users_coll, &user_doc).await?;
        let stored = users_coll
            .find_one(doc! { "_id": spec.id })
            .await
            .map_err(|e| e.to_string())?
            .unwrap_or(user_doc);
        ensure_user_onboarding(state, &stored).await?;
        test_docs.push(stored);
    }

    // Slots 1..4 are friends with each other (all is_favorite: false).
    // Slot 5 (คิน, 0810000005, @kin) stays un-friended for live search/add-friend testing!
    for i in 0..4 {
        for j in (i + 1)..4 {
            ensure_friendship_pair(state, TEST_USER_IDS[i], TEST_USER_IDS[j], false).await?;
        }
    }

    // 1-on-1 DM between Slot 1 (ต้นน้ำ) and Slot 2 (แพรไหม): conv_dm_test_1_2 (is_pinned: false)
    let u1 = &test_docs[0];
    let u2 = &test_docs[1];
    let u4 = &test_docs[3];
    let dm_exists = conv_coll
        .find_one(doc! {
            "$or": [
                { "_id": "conv_dm_test_1_2" },
                { "type": "direct", "member_ids": { "$all": [&u1.id, &u2.id], "$size": 2 } }
            ]
        })
        .await
        .map_err(|e| e.to_string())?
        .is_some();

    if !dm_exists {
        let dm_msg_id = "msg_dm_test_1_2_seed".to_string();
        let dm_text =
            "สวัสดีต้นน้ำ! วันนี้ที่ร้านชาบ้านเชียงมีเมนูชามัทฉะตัวใหม่เข้าแล้วนะ".to_string();
        let dm_conv = ConversationDoc {
            id: "conv_dm_test_1_2".to_string(),
            conv_type: "direct".to_string(),
            name: u2.display_name.clone(),
            avatar_url: u2.avatar_url.clone(),
            folder: "personal".to_string(),
            is_pinned: false,
            is_muted: false,
            is_archived: false,
            invite_token: String::new(),
            admin_ids: Vec::new(),
            member_ids: vec![u1.id.clone(), u2.id.clone()],
            oa_id: None,
            oa_handle: None,
            user_meta: HashMap::new(),
            pinned_message: None,
            last_message: Some(LastMessageSummary {
                id: dm_msg_id.clone(),
                sender_id: u2.id.clone(),
                sender_name: u2.display_name.clone(),
                msg_type: "text".to_string(),
                content: dm_text.clone(),
                created_at: now.clone(),
                read_count: 1,
            }),
            created_at: now.clone(),
            updated_at: now.clone(),
        };
        conv_coll
            .insert_one(&dm_conv)
            .await
            .map_err(|e| e.to_string())?;
        if msg_coll
            .find_one(doc! { "_id": &dm_msg_id })
            .await
            .map_err(|e| e.to_string())?
            .is_none()
        {
            let _ = msg_coll
                .insert_one(MessageDoc {
                    id: dm_msg_id,
                    conversation_id: "conv_dm_test_1_2".to_string(),
                    sender_id: u2.id.clone(),
                    sender_name: u2.display_name.clone(),
                    sender_avatar: u2.avatar_url.clone(),
                    msg_type: "text".to_string(),
                    content: dm_text,
                    sticker_code: None,
                    attachment: None,
                    card_payload: None,
                    flex_payload: None,
                    reply_to: None,
                    read_by: vec![u2.id.clone(), u1.id.clone()],
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
                })
                .await;
        }
    }

    // Group room: conv_group_test_friends ("แก๊งเพื่อนวันหยุด", Slots 1..4 + user_ai, is_pinned: false)
    if conv_coll
        .find_one(doc! { "_id": "conv_group_test_friends" })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let grp_msg_id = "msg_group_test_friends_seed".to_string();
        let grp_text =
            "สวัสดีทุกคน! เสาร์อาทิตย์นี้ไปจิบชาถ่ายรูปเล่นกันไหม พิมพ์ @ai ให้ช่วยจัดทริปได้เลยนะ"
                .to_string();
        let grp_avatar = format!(
            "https://ui-avatars.com/api/?name={}&background=A04035&color=fff&bold=true",
            urlencoding::encode("แก๊งเพื่อนวันหยุด")
        );
        let grp_conv = ConversationDoc {
            id: "conv_group_test_friends".to_string(),
            conv_type: "group".to_string(),
            name: "แก๊งเพื่อนวันหยุด".to_string(),
            avatar_url: grp_avatar,
            folder: "group".to_string(),
            is_pinned: false,
            is_muted: false,
            is_archived: false,
            invite_token: "BCINV-TESTFRND".to_string(),
            admin_ids: vec![u1.id.clone()],
            member_ids: vec![
                TEST_USER_IDS[0].to_string(),
                TEST_USER_IDS[1].to_string(),
                TEST_USER_IDS[2].to_string(),
                TEST_USER_IDS[3].to_string(),
                "user_ai".to_string(),
            ],
            oa_id: None,
            oa_handle: None,
            user_meta: HashMap::new(),
            pinned_message: None,
            last_message: Some(LastMessageSummary {
                id: grp_msg_id.clone(),
                sender_id: u1.id.clone(),
                sender_name: u1.display_name.clone(),
                msg_type: "text".to_string(),
                content: grp_text.clone(),
                created_at: now.clone(),
                read_count: 3,
            }),
            created_at: now.clone(),
            updated_at: now.clone(),
        };
        conv_coll
            .insert_one(&grp_conv)
            .await
            .map_err(|e| e.to_string())?;
        if msg_coll
            .find_one(doc! { "_id": &grp_msg_id })
            .await
            .map_err(|e| e.to_string())?
            .is_none()
        {
            let _ = msg_coll
                .insert_one(MessageDoc {
                    id: grp_msg_id,
                    conversation_id: "conv_group_test_friends".to_string(),
                    sender_id: u1.id.clone(),
                    sender_name: u1.display_name.clone(),
                    sender_avatar: u1.avatar_url.clone(),
                    msg_type: "text".to_string(),
                    content: grp_text,
                    sticker_code: None,
                    attachment: None,
                    card_payload: None,
                    flex_payload: None,
                    reply_to: None,
                    read_by: vec![
                        TEST_USER_IDS[0].to_string(),
                        TEST_USER_IDS[1].to_string(),
                        TEST_USER_IDS[2].to_string(),
                        TEST_USER_IDS[3].to_string(),
                    ],
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
                })
                .await;
        }
    }

    // Sample Shop: oa_test_chabanchiang ("ชาบ้านเชียง", owner = Slot 1, agent = Slot 2, customer = Slot 4)
    let oa_id = "oa_test_chabanchiang";
    let bot_id = "user_oa_test_chabanchiang";
    let oa_avatar = format!(
        "https://ui-avatars.com/api/?name={}&background=812920&color=fff&bold=true",
        urlencoding::encode("ชาบ้านเชียง")
    );
    let oa_bio = "ชงสดหอมกรุ่นจากใบชาคัดพิเศษ พร้อมขนมโฮมเมดทุกวัน";
    let oa_greeting =
        "สวัสดีค่ะ ยินดีต้อนรับสู่ร้านชาบ้านเชียง พิมพ์คำว่า เมนู เพื่อดูรายการเครื่องดื่มยอดนิยมได้เลยนะคะ";

    let bot_doc = UserDoc {
        id: bot_id.to_string(),
        email: "oa+cha_banchiang@bcaichat.local".to_string(),
        phone: String::new(),
        phone_verified: false,
        email_verified: false,
        display_name: "ชาบ้านเชียง".to_string(),
        bc_id: "@cha_banchiang".to_string(),
        avatar_url: oa_avatar.clone(),
        status_message: oa_bio.to_string(),
        qr_token: "BCOA_oa_test_chabanchiang".to_string(),
        role: "user".to_string(),
        department: "เครื่องดื่ม & คาเฟ่".to_string(),
        job_title: "ร้านค้า".to_string(),
        google_id: None,
        is_oa_bot: true,
        oa_id: Some(oa_id.to_string()),
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
    };
    upsert_seeded_user(&users_coll, &bot_doc).await?;

    let oa_coll = state.db.collection::<OaAccountDoc>("oa_accounts");
    if oa_coll
        .find_one(doc! { "_id": oa_id })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let mut staff_roles = HashMap::new();
        staff_roles.insert(u2.id.clone(), "agent".to_string());
        let oa_doc = OaAccountDoc {
            id: oa_id.to_string(),
            handle: "cha_banchiang".to_string(),
            display_name: "ชาบ้านเชียง".to_string(),
            category: "เครื่องดื่ม & คาเฟ่".to_string(),
            bio: oa_bio.to_string(),
            avatar_url: oa_avatar.clone(),
            theme_color: "#812920".to_string(),
            greeting_message: oa_greeting.to_string(),
            business_hours: "ทุกวัน 08:30–19:30 น.".to_string(),
            owner_id: u1.id.clone(),
            admin_ids: vec![u2.id.clone()],
            staff_roles,
            bot_user_id: bot_id.to_string(),
            is_verified: true,
            is_active: true,
            calls_enabled: true,
            ai_enabled: true,
            ai_knowledge_prompt:
                "ร้านชาบ้านเชียง จำหน่ายชาไทย มัทฉะลาเต้ ชาพีชโซดา และขนมปังปิ้งเตาถ่าน เปิดบริการทุกวัน 08:30–19:30 น."
                    .to_string(),
            rich_menu: vec![
                OaRichMenuItem {
                    id: "rm_menu".to_string(),
                    label: "ดูเมนูเครื่องดื่ม".to_string(),
                    subtitle: "รายการชายอดนิยม".to_string(),
                    action_type: "keyword".to_string(),
                    action_value: "เมนู".to_string(),
                    icon: "storefront".to_string(),
                },
                OaRichMenuItem {
                    id: "rm_coupon".to_string(),
                    label: "คูปองส่วนลด".to_string(),
                    subtitle: "รับส่วนลด 20 บาท".to_string(),
                    action_type: "coupon".to_string(),
                    action_value: "CHABC20".to_string(),
                    icon: "local_offer".to_string(),
                },
                OaRichMenuItem {
                    id: "rm_hours".to_string(),
                    label: "เวลาเปิด-ปิดร้าน".to_string(),
                    subtitle: "เปิดทุกวัน 08:30–19:30 น.".to_string(),
                    action_type: "keyword".to_string(),
                    action_value: "เวลาเปิด-ปิด".to_string(),
                    icon: "schedule".to_string(),
                },
            ],
            follower_count: 1,
            created_at: now.clone(),
            updated_at: now.clone(),
        };
        oa_coll
            .insert_one(&oa_doc)
            .await
            .map_err(|e| e.to_string())?;
    }

    let oa_conv_id = "conv_oa_test_chabanchiang";
    if conv_coll
        .find_one(doc! { "_id": oa_conv_id })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let oa_msg_id = "msg_oa_test_chabanchiang_seed".to_string();
        let oa_conv = ConversationDoc {
            id: oa_conv_id.to_string(),
            conv_type: "oa".to_string(),
            name: "ชาบ้านเชียง".to_string(),
            avatar_url: oa_avatar.clone(),
            folder: "personal".to_string(),
            is_pinned: false,
            is_muted: false,
            is_archived: false,
            invite_token: String::new(),
            admin_ids: vec![u1.id.clone(), u2.id.clone()],
            member_ids: vec![u4.id.clone(), bot_id.to_string()],
            oa_id: Some(oa_id.to_string()),
            oa_handle: Some("cha_banchiang".to_string()),
            user_meta: HashMap::new(),
            pinned_message: None,
            last_message: Some(LastMessageSummary {
                id: oa_msg_id.clone(),
                sender_id: bot_id.to_string(),
                sender_name: "ชาบ้านเชียง".to_string(),
                msg_type: "text".to_string(),
                content: oa_greeting.to_string(),
                created_at: now.clone(),
                read_count: 1,
            }),
            created_at: now.clone(),
            updated_at: now.clone(),
        };
        conv_coll
            .insert_one(&oa_conv)
            .await
            .map_err(|e| e.to_string())?;
        if msg_coll
            .find_one(doc! { "_id": &oa_msg_id })
            .await
            .map_err(|e| e.to_string())?
            .is_none()
        {
            let _ = msg_coll
                .insert_one(MessageDoc {
                    id: oa_msg_id,
                    conversation_id: oa_conv_id.to_string(),
                    sender_id: bot_id.to_string(),
                    sender_name: "ชาบ้านเชียง".to_string(),
                    sender_avatar: oa_avatar,
                    msg_type: "text".to_string(),
                    content: oa_greeting.to_string(),
                    sticker_code: None,
                    attachment: None,
                    card_payload: None,
                    flex_payload: None,
                    reply_to: None,
                    read_by: vec![bot_id.to_string(), u4.id.clone()],
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
                })
                .await;
        }
    }

    let fol_coll = state.db.collection::<OaFollowerDoc>("oa_followers");
    if fol_coll
        .find_one(doc! { "oa_id": oa_id, "user_id": &u4.id })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let fol = OaFollowerDoc {
            id: "fol_oa_test_chabanchiang_4".to_string(),
            oa_id: oa_id.to_string(),
            user_id: u4.id.clone(),
            conversation_id: oa_conv_id.to_string(),
            tags: vec!["ลูกค้าประจำ".to_string()],
            crm_note: "ชอบชาไทยหวานน้อย".to_string(),
            ai_paused: false,
            is_following: true,
            followed_at: now.clone(),
            updated_at: now.clone(),
        };
        fol_coll
            .insert_one(&fol)
            .await
            .map_err(|e| e.to_string())?;
    }

    let ar_coll = state.db.collection::<OaAutoReplyRuleDoc>("oa_auto_replies");
    if ar_coll
        .find_one(doc! { "_id": "ar_oa_test_chabanchiang_menu" })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let rule = OaAutoReplyRuleDoc {
            id: "ar_oa_test_chabanchiang_menu".to_string(),
            oa_id: oa_id.to_string(),
            keyword: "เมนู".to_string(),
            match_mode: "contains".to_string(),
            reply_text:
                "เมนูแนะนำร้านชาบ้านเชียง: ชาไทยต้นตำรับ 55.-, มัทฉะลาเต้ 65.-, ชาพีชโซดา 60.- สั่งผ่านแชทนี้ได้เลยค่ะ!"
                    .to_string(),
            card_payload: None,
            is_active: true,
            hit_count: 0,
            created_at: now.clone(),
        };
        ar_coll
            .insert_one(&rule)
            .await
            .map_err(|e| e.to_string())?;
    }

    let cp_coll = state.db.collection::<OaCouponDoc>("oa_coupons");
    if cp_coll
        .find_one(doc! { "_id": "cp_oa_test_chabanchiang_20" })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let cp = OaCouponDoc {
            id: "cp_oa_test_chabanchiang_20".to_string(),
            oa_id: oa_id.to_string(),
            code: "CHABC20".to_string(),
            title: "ส่วนลด 20 บาท ชาบ้านเชียง".to_string(),
            description: "เมื่อสั่งเครื่องดื่มครบ 100 บาทขึ้นไปที่ร้านชาบ้านเชียง".to_string(),
            discount_text: "ลด 20 บาท".to_string(),
            expires_at: None,
            max_claims: 100,
            claimed_by: Vec::new(),
            redeemed_by: Vec::new(),
            is_active: true,
            created_at: now,
        };
        cp_coll
            .insert_one(&cp)
            .await
            .map_err(|e| e.to_string())?;
    }

    Ok(())
}

pub async fn ensure_friendship_pair(
    state: &AppState,
    uid_a: &str,
    uid_b: &str,
    fav_a: bool,
) -> Result<(), String> {
    let friends_coll = state.db.collection::<FriendshipDoc>("friendships");
    let now = Utc::now().to_rfc3339();

    for (u, f, fav) in [(uid_a, uid_b, fav_a), (uid_b, uid_a, false)] {
        if u == f {
            continue;
        }
        let exists = friends_coll
            .find_one(doc! { "user_id": u, "friend_id": f })
            .await
            .map_err(|e| e.to_string())?;
        if exists.is_none() {
            let doc_item = FriendshipDoc {
                id: Uuid::new_v4().to_string(),
                user_id: u.to_string(),
                friend_id: f.to_string(),
                is_favorite: fav,
                is_blocked: false,
                is_hidden: false,
                created_at: now.clone(),
            };
            friends_coll
                .insert_one(doc_item)
                .await
                .map_err(|e| e.to_string())?;
        }
    }

    Ok(())
}

pub async fn ensure_direct_conversation(
    state: &AppState,
    user: &UserDoc,
    partner: &UserDoc,
    conv_type: &str,
    folder: &str,
    is_pinned: bool,
    welcome_text: &str,
) -> Result<ConversationDoc, String> {
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");

    if let Some(existing) = conv_coll
        .find_one(doc! {
            "type": { "$in": ["direct", "official"] },
            "member_ids": { "$all": [&user.id, &partner.id], "$size": 2 }
        })
        .await
        .map_err(|e| e.to_string())?
    {
        return Ok(existing);
    }

    let now = Utc::now().to_rfc3339();
    let conv_id = Uuid::new_v4().to_string();
    let msg_id = Uuid::new_v4().to_string();

    let last_msg = LastMessageSummary {
        id: msg_id.clone(),
        sender_id: partner.id.clone(),
        sender_name: partner.display_name.clone(),
        msg_type: "text".to_string(),
        content: welcome_text.to_string(),
        created_at: now.clone(),
        read_count: 0,
    };

    let conv = ConversationDoc {
        id: conv_id.clone(),
        conv_type: conv_type.to_string(),
        name: partner.display_name.clone(),
        avatar_url: partner.avatar_url.clone(),
        folder: folder.to_string(),
        is_pinned,
        is_muted: false,
        is_archived: false,
        invite_token: String::new(),
        admin_ids: Vec::new(),
        member_ids: vec![user.id.clone(), partner.id.clone()],
        user_meta: HashMap::new(),
        pinned_message: None,
        last_message: Some(last_msg),
        oa_id: None,
        oa_handle: None,
        created_at: now.clone(),
        updated_at: now.clone(),
    };

    conv_coll
        .insert_one(&conv)
        .await
        .map_err(|e| e.to_string())?;

    let msg = MessageDoc {
        id: msg_id,
        conversation_id: conv_id,
        sender_id: partner.id.clone(),
        sender_name: partner.display_name.clone(),
        sender_avatar: partner.avatar_url.clone(),
        msg_type: "text".to_string(),
        content: welcome_text.to_string(),
        sticker_code: None,
        attachment: None,
        card_payload: None,
        flex_payload: None,
        reply_to: None,
        read_by: vec![partner.id.clone()],
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

    msg_coll
        .insert_one(msg)
        .await
        .map_err(|e| e.to_string())?;

    Ok(conv)
}

pub async fn ensure_keep_conversation_for_user(
    state: &AppState,
    user: &UserDoc,
) -> Result<ConversationDoc, String> {
    let conv_coll = state.db.collection::<ConversationDoc>("conversations");
    let msg_coll = state.db.collection::<MessageDoc>("messages");
    let keep_id = format!("conv_keep_{}", user.id);

    if let Some(existing) = conv_coll
        .find_one(doc! { "_id": &keep_id })
        .await
        .map_err(|e| e.to_string())?
    {
        return Ok(existing);
    }

    let now = Utc::now().to_rfc3339();
    let msg_id = format!("msg_keep_seed_{}", user.id);
    let welcome_text = "📌 พื้นที่บันทึกช่วยจำส่วนตัว (Keep) — เก็บข้อความ รูปภาพ ไฟล์ พิกัด และลิงก์สำคัญไว้ดูคนเดียวได้ทุกอุปกรณ์";
    let avatar_url = format!(
        "https://ui-avatars.com/api/?name={}&background=812920&color=fff&bold=true",
        urlencoding::encode("Keep")
    );

    let conv = ConversationDoc {
        id: keep_id.clone(),
        conv_type: "keep".to_string(),
        name: "บันทึกช่วยจำส่วนตัว (Keep)".to_string(),
        avatar_url,
        folder: "personal".to_string(),
        is_pinned: false,
        is_muted: true,
        is_archived: false,
        invite_token: String::new(),
        admin_ids: vec![user.id.clone()],
        member_ids: vec![user.id.clone()],
        user_meta: HashMap::new(),
        pinned_message: None,
        last_message: Some(LastMessageSummary {
            id: msg_id.clone(),
            sender_id: user.id.clone(),
            sender_name: user.display_name.clone(),
            msg_type: "text".to_string(),
            content: welcome_text.to_string(),
            created_at: now.clone(),
            read_count: 0,
        }),
        oa_id: None,
        oa_handle: None,
        created_at: now.clone(),
        updated_at: now.clone(),
    };

    let _ = conv_coll
        .replace_one(doc! { "_id": &keep_id }, &conv)
        .upsert(true)
        .await
        .map_err(|e| e.to_string())?;

    if msg_coll
        .find_one(doc! { "_id": &msg_id })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let welcome_msg = MessageDoc {
            id: msg_id,
            conversation_id: keep_id,
            sender_id: user.id.clone(),
            sender_name: user.display_name.clone(),
            sender_avatar: user.avatar_url.clone(),
            msg_type: "text".to_string(),
            content: welcome_text.to_string(),
            sticker_code: None,
            attachment: None,
            card_payload: None,
            flex_payload: None,
            reply_to: None,
            read_by: vec![user.id.clone()],
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
        let _ = msg_coll.insert_one(welcome_msg).await;
    }

    Ok(conv)
}

pub async fn ensure_user_onboarding(state: &AppState, user: &UserDoc) -> Result<(), String> {
    if user.is_oa_bot {
        return Ok(());
    }
    if user.id != "user_ai" && user.id != "user_official" {
        let _ = ensure_keep_conversation_for_user(state, user).await;
    }
    let users_coll = state.db.collection::<UserDoc>("users");
    let notes_coll = state.db.collection::<NoteDoc>("notes");

    let starter_contacts = vec![
        (
            "user_ai",
            "official",
            "personal",
            false,
            false,
            "สวัสดีครับ! ผมคือ 🤖 BC AI ผู้ช่วยส่วนตัวของคุณ พิมพ์คุยปรึกษาได้ทุกเรื่องในห้องนี้ หรือพิมพ์ @ai ในกลุ่มเพื่อนและครอบครัวให้ช่วยจัดทริป แนะนำร้านอร่อย หารค่าข้าว หรือสรุปนัดหมายได้เลยครับ!",
        ),
        (
            "user_official",
            "official",
            "personal",
            false,
            false,
            "ยินดีต้อนรับสู่ BC Ai Chat! สมัครด้วยเบอร์มือถือ เชื่อมต่อยืนยัน Gmail ได้อย่างปลอดภัย ซิงค์แชทข้ามอุปกรณ์ เก็บรูปถาวรบน MinIO พร้อมระบบร้านค้าสำหรับเจ้าของกิจการ",
        ),
    ];

    for (contact_id, conv_type, folder, is_pinned, is_fav, welcome) in starter_contacts {
        if contact_id == user.id {
            continue;
        }
        ensure_friendship_pair(state, &user.id, contact_id, is_fav).await?;
        if let Some(partner) = users_coll
            .find_one(doc! { "_id": contact_id })
            .await
            .map_err(|e| e.to_string())?
        {
            ensure_direct_conversation(
                state,
                user,
                &partner,
                conv_type,
                folder,
                is_pinned,
                welcome,
            )
            .await?;
        }
    }

    let now = Utc::now().to_rfc3339();
    let personal_seed_id = format!("note_personal_seed_{}", user.id);
    if notes_coll
        .find_one(doc! { "_id": &personal_seed_id })
        .await
        .map_err(|e| e.to_string())?
        .is_none()
    {
        let personal_note = NoteDoc {
            id: personal_seed_id.clone(),
            conversation_id: None,
            owner_id: user.id.clone(),
            owner_name: user.display_name.clone(),
            title: "บันทึกส่วนตัวของฉัน — ลิสต์ไอเดีย & เตือนความจำ".to_string(),
            content: "จดบันทึกส่วนตัว ลิสต์ของฝาก หรือนัดหมายสำคัญในสมุดบันทึก BC ได้เลย ซิงค์อัตโนมัติทุกอุปกรณ์ ไม่มีวันหมดอายุ".to_string(),
            attachments: vec![],
            is_pinned: false,
            liked_by: vec![],
            comments: vec![],
            created_at: now.clone(),
            updated_at: now,
        };
        let _ = notes_coll
            .replace_one(doc! { "_id": &personal_seed_id }, personal_note)
            .upsert(true)
            .await;
    }

    Ok(())
}
