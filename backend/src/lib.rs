pub mod auth;
pub mod client_app;
pub mod config;
pub mod minio;
pub mod models;
pub mod push;
pub mod routes;
pub mod seed;
pub mod sms;
pub mod ws;

use axum::{
    extract::DefaultBodyLimit,
    routing::{delete, get, post, put},
    Router,
};
use mongodb::{Client as MongoClient, Database};
use tower_http::cors::{Any, CorsLayer};

use crate::{
    config::AppConfig,
    minio::MinioClient,
    routes::{
        admin_routes::{
            admin_broadcast_handler, admin_create_mini_app_handler,
            admin_delete_mini_app_handler, admin_handover_handler, admin_list_mini_apps_handler,
            admin_list_users_handler, admin_overview_handler, admin_update_mini_app_handler,
            admin_update_user_role_handler, get_theme_handler, update_theme_handler,
        },
        ai_routes::{
            assist_message_handler, get_ai_settings_handler, summarize_conversation_handler,
            update_ai_settings_handler,
        },
        auth_routes::{
            add_friend_handler, admin_get_auth_settings_handler,
            admin_update_auth_settings_handler, auth_config_handler, bootstrap_admin_handler,
            check_bc_id_handler, google_auth_handler, google_oauth_callback_handler,
            google_oauth_complete_handler, google_oauth_poll_handler, google_oauth_start_handler,
            health_handler, link_google_handler, link_phone_handler, list_friends_handler,
            list_recovery_logs_handler, me_handler, otp_request_handler, otp_verify_handler,
            recover_change_google_handler, recover_change_phone_handler, remove_friend_handler,
            reset_qr_handler, search_users_handler, setup_recovery_handler, test_login_handler,
            unlink_google_handler, update_friend_handler, update_profile_handler,
        },
        call_routes::{
            accept_call_handler, decline_call_handler, get_call_token_handler,
            hangup_call_handler, list_active_calls_handler, start_call_handler,
        },
        chat_routes::{
            add_album_photos_handler, add_group_members_handler, approve_card_handler,
            clear_confidential_messages_handler, close_poll_handler, comment_note_handler,
            conversation_vault_handler, create_album_handler, create_direct_conversation_handler,
            create_event_handler, create_group_conversation_handler, create_note_handler,
            create_poll_handler, delete_album_handler, delete_message_for_me_handler,
            delete_note_handler, edit_message_handler, ensure_keep_conversation_handler,
            forward_message_handler, join_conversation_by_token_handler, like_note_handler,
            list_albums_handler, list_conversations_handler, list_events_handler,
            list_messages_handler, list_notes_handler, mark_read_handler, pin_message_handler,
            purge_message_handler, react_message_handler, remove_group_member_handler,
            rsvp_event_handler, save_message_to_keep_handler, search_messages_handler,
            send_message_handler, task_action_handler, unsend_message_handler,
            update_conversation_meta_handler, update_note_handler, vote_poll_handler,
        },
        file_routes::{get_file_handler, upload_handler},
        miniapp_routes::{list_active_mini_apps_handler, serve_miniapp_html_handler},
        oa_routes::{
            add_oa_admin_handler, claim_oa_coupon_handler, create_oa_auto_reply_handler,
            create_oa_coupon_handler, create_oa_handler, delete_oa_auto_reply_handler,
            discover_oas_handler, follow_oa_handler, get_oa_chat_messages_handler, get_oa_customer_handler, get_oa_handler,
            list_my_oas_handler, list_oa_admins_handler, list_oa_auto_replies_handler,
            list_oa_broadcasts_handler, list_oa_chats_handler, list_oa_coupons_handler,
            list_oa_customer_tags_handler, list_oa_customers_handler,
            oa_overview_handler, redeem_oa_coupon_handler, remove_oa_admin_handler,
            send_oa_broadcast_handler, send_oa_chat_message_handler, unfollow_oa_handler,
            update_oa_admin_role_handler, update_oa_follower_crm_handler, update_oa_handler,
        },
        push_routes::{push_config_handler, register_device_handler, unregister_device_handler},
    },
    ws::{ws_handler, WsHub},
};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub db: Database,
    pub minio: MinioClient,
    pub ws_hub: WsHub,
    /// None = push off (no FCM service account configured).
    pub push: Option<std::sync::Arc<push::Fcm>>,
    /// In-memory minimum token_version per user_id for O(1) zero-DB-overhead session revocation.
    pub token_versions: std::sync::Arc<std::sync::RwLock<std::collections::HashMap<String, u32>>>,
}

impl AppState {
    pub async fn init(config: AppConfig) -> Result<Self, String> {
        let mongo_client = MongoClient::with_uri_str(&config.mongodb_uri)
            .await
            .map_err(|e| format!("MongoDB connection error: {}", e))?;
        let db = mongo_client.database(&config.mongodb_db);

        let minio = MinioClient::new(
            &config.minio_endpoint,
            &config.minio_access_key,
            &config.minio_secret_key,
            &config.minio_bucket,
        );

        let ws_hub = WsHub::new();
        let push = push::Fcm::from_config(&config);

        let mut tv_map = std::collections::HashMap::new();
        if let Ok(mut cursor) = db
            .collection::<bson::Document>("users")
            .find(bson::doc! { "token_version": { "$gt": 0 } })
            .await
        {
            use futures_util::TryStreamExt;
            while let Ok(Some(d)) = cursor.try_next().await {
                if let Ok(uid) = d.get_str("_id") {
                    let tv_opt = d
                        .get_i32("token_version")
                        .map(|v| v as i64)
                        .or_else(|_| d.get_i64("token_version"));
                    if let Ok(tv) = tv_opt {
                        if tv > 0 {
                            tv_map.insert(uid.to_string(), tv as u32);
                        }
                    }
                }
            }
        }
        let token_versions = std::sync::Arc::new(std::sync::RwLock::new(tv_map));

        Ok(Self {
            config,
            db,
            minio,
            ws_hub,
            push,
            token_versions,
        })
    }

    pub fn set_token_version(&self, user_id: &str, tv: u32) {
        if let Ok(mut guard) = self.token_versions.write() {
            guard.insert(user_id.to_string(), tv);
        }
    }
}

pub fn create_router(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    Router::new()
        .route("/api/health", get(health_handler))
        // Auth & Profile
        .route("/api/auth/config", get(auth_config_handler))
        .route("/api/auth/test-login", post(test_login_handler))
        .route("/api/auth/bootstrap-admin", post(bootstrap_admin_handler))
        .route("/api/auth/otp/request", post(otp_request_handler))
        .route("/api/auth/otp/verify", post(otp_verify_handler))
        .route("/api/auth/link/phone", post(link_phone_handler))
        .route("/api/auth/google", post(google_auth_handler))
        .route(
            "/api/auth/link/google",
            post(link_google_handler).delete(unlink_google_handler),
        )
        .route("/api/auth/google/start", get(google_oauth_start_handler))
        .route("/api/auth/google/callback", get(google_oauth_callback_handler))
        .route("/api/auth/google/complete", post(google_oauth_complete_handler))
        .route("/api/auth/google/poll", get(google_oauth_poll_handler))
        .route("/api/auth/recovery/setup", post(setup_recovery_handler))
        .route("/api/auth/recovery/logs", get(list_recovery_logs_handler))
        .route(
            "/api/auth/recover/change-phone",
            post(recover_change_phone_handler),
        )
        .route(
            "/api/auth/recover/change-google",
            post(recover_change_google_handler),
        )
        .route("/api/auth/me", get(me_handler).put(update_profile_handler))
        .route("/api/auth/profile", put(update_profile_handler))
        .route("/api/auth/bc-id/check", get(check_bc_id_handler))
        .route("/api/auth/reset-qr", post(reset_qr_handler))
        .route("/api/users/me", get(me_handler).put(update_profile_handler))
        .route("/api/users/bc-id/check", get(check_bc_id_handler))
        .route("/api/users/me/reset-qr", post(reset_qr_handler))
        .route(
            "/api/admin/auth-settings",
            get(admin_get_auth_settings_handler).put(admin_update_auth_settings_handler),
        )
        // Friends & User Search
        .route("/api/friends", get(list_friends_handler))
        .route("/api/friends/add", post(add_friend_handler))
        .route(
            "/api/friends/:friend_id",
            put(update_friend_handler).delete(remove_friend_handler),
        )
        .route("/api/users/search", get(search_users_handler))
        // Conversations & Group Management
        .route("/api/conversations", get(list_conversations_handler))
        .route(
            "/api/conversations/direct",
            post(create_direct_conversation_handler),
        )
        .route(
            "/api/conversations/group",
            post(create_group_conversation_handler),
        )
        .route(
            "/api/conversations/join",
            post(join_conversation_by_token_handler),
        )
        .route(
            "/api/conversations/keep",
            get(ensure_keep_conversation_handler).post(ensure_keep_conversation_handler),
        )
        .route(
            "/api/conversations/:id",
            put(update_conversation_meta_handler),
        )
        .route(
            "/api/conversations/:id/meta",
            put(update_conversation_meta_handler),
        )
        .route(
            "/api/conversations/:id/members",
            post(add_group_members_handler),
        )
        .route(
            "/api/conversations/:id/members/:member_id",
            delete(remove_group_member_handler),
        )
        .route(
            "/api/conversations/:id/pin-message",
            put(pin_message_handler),
        )
        .route(
            "/api/conversations/:id/messages",
            get(list_messages_handler).post(send_message_handler),
        )
        .route("/api/conversations/:id/read", post(mark_read_handler))
        .route(
            "/api/conversations/:id/clear-confidential",
            post(clear_confidential_messages_handler),
        )
        // Polls & Events & Albums
        .route("/api/conversations/:id/polls", post(create_poll_handler))
        .route(
            "/api/conversations/:id/events",
            get(list_events_handler).post(create_event_handler),
        )
        .route(
            "/api/conversations/:id/albums",
            get(list_albums_handler).post(create_album_handler),
        )
        .route("/api/albums/:id/photos", post(add_album_photos_handler))
        .route("/api/albums/:id", delete(delete_album_handler))
        // Message Actions
        .route("/api/messages/:id", put(edit_message_handler))
        .route("/api/messages/:id/forward", post(forward_message_handler))
        .route(
            "/api/messages/:id/save-to-keep",
            post(save_message_to_keep_handler),
        )
        .route("/api/messages/:id/react", post(react_message_handler))
        .route(
            "/api/messages/:id/delete-for-me",
            post(delete_message_for_me_handler),
        )
        .route("/api/messages/:id/vote", post(vote_poll_handler))
        .route("/api/messages/:id/close-poll", post(close_poll_handler))
        .route("/api/messages/:id/rsvp", post(rsvp_event_handler))
        .route(
            "/api/messages/:id/unsend",
            delete(unsend_message_handler).post(unsend_message_handler),
        )
        .route(
            "/api/messages/:id/purge",
            delete(purge_message_handler).post(purge_message_handler),
        )
        .route("/api/messages/:id/task-action", post(task_action_handler))
        .route("/api/messages/:id/approve-card", post(approve_card_handler))
        .route(
            "/api/conversations/:id/vault",
            get(conversation_vault_handler),
        )
        .route("/api/messages/search", get(search_messages_handler))
        // สมุดบันทึก BC & โน้ตกลุ่ม
        .route(
            "/api/notes",
            get(list_notes_handler).post(create_note_handler),
        )
        .route(
            "/api/notes/:id",
            put(update_note_handler).delete(delete_note_handler),
        )
        .route("/api/notes/:id/like", post(like_note_handler))
        .route("/api/notes/:id/comments", post(comment_note_handler))
        // MinIO File Storage
        .route("/api/upload", post(upload_handler))
        .route("/api/files/:key", get(get_file_handler))
        // บริการเสริม Mini-Apps
        .route("/api/mini-apps", get(list_active_mini_apps_handler))
        .route("/miniapp/:code", get(serve_miniapp_html_handler))
        // DeepSeek AI Assistant Endpoints
        .route("/api/ai/summarize", post(summarize_conversation_handler))
        .route("/api/ai/assist", post(assist_message_handler))
        .route(
            "/api/admin/ai-settings",
            get(get_ai_settings_handler).put(update_ai_settings_handler),
        )
        .route(
            "/api/settings/theme",
            get(get_theme_handler).put(update_theme_handler),
        )
        // Admin Backoffice
        .route("/api/admin/overview", get(admin_overview_handler))
        .route("/api/admin/users", get(admin_list_users_handler))
        .route(
            "/api/admin/users/:id/role",
            put(admin_update_user_role_handler),
        )
        .route(
            "/api/admin/mini-apps",
            get(admin_list_mini_apps_handler).post(admin_create_mini_app_handler),
        )
        .route(
            "/api/admin/mini-apps/:id",
            put(admin_update_mini_app_handler).delete(admin_delete_mini_app_handler),
        )
        .route("/api/admin/broadcast", post(admin_broadcast_handler))
        .route("/api/admin/handover", post(admin_handover_handler))
        // BCAiChatOA Storefront & Multi-Role Shop Team
        .route("/api/oa/discover", get(discover_oas_handler))
        .route("/api/oa/mine", get(list_my_oas_handler))
        .route("/api/oa", post(create_oa_handler))
        .route("/api/oa/:id", get(get_oa_handler).put(update_oa_handler))
        .route(
            "/api/oa/:id/admins",
            get(list_oa_admins_handler).post(add_oa_admin_handler),
        )
        .route(
            "/api/oa/:id/admins/:uid",
            put(update_oa_admin_role_handler).delete(remove_oa_admin_handler),
        )
        .route("/api/oa/:id/follow", post(follow_oa_handler))
        .route("/api/oa/:id/unfollow", post(unfollow_oa_handler))
        .route("/api/oa/:id/overview", get(oa_overview_handler))
        .route("/api/oa/:id/chats", get(list_oa_chats_handler))
        .route("/api/oa/:id/customers", get(list_oa_customers_handler))
        .route("/api/oa/:id/customers/:uid", get(get_oa_customer_handler))
        .route("/api/oa/:id/customer-tags", get(list_oa_customer_tags_handler))
        .route(
            "/api/oa/:id/chats/:conv_id/messages",
            get(get_oa_chat_messages_handler).post(send_oa_chat_message_handler),
        )
        .route(
            "/api/oa/:id/followers/:uid/crm",
            put(update_oa_follower_crm_handler),
        )
        .route(
            "/api/oa/:id/auto-replies",
            get(list_oa_auto_replies_handler).post(create_oa_auto_reply_handler),
        )
        .route(
            "/api/oa/:id/auto-replies/:rule_id",
            delete(delete_oa_auto_reply_handler),
        )
        .route(
            "/api/oa/:id/coupons",
            get(list_oa_coupons_handler).post(create_oa_coupon_handler),
        )
        .route(
            "/api/oa/:id/coupons/:coupon_id/claim",
            post(claim_oa_coupon_handler),
        )
        .route(
            "/api/oa/:id/coupons/:coupon_id/redeem",
            post(redeem_oa_coupon_handler),
        )
        .route(
            "/api/oa/:id/broadcasts",
            get(list_oa_broadcasts_handler).post(send_oa_broadcast_handler),
        )
        // LiveKit SFU Voice & Video Calls
        .route("/api/calls/start", post(start_call_handler))
        .route("/api/calls/active", get(list_active_calls_handler))
        .route("/api/calls/:id/accept", post(accept_call_handler))
        .route("/api/calls/:id/token", get(get_call_token_handler))
        .route("/api/calls/:id/decline", post(decline_call_handler))
        .route("/api/calls/:id/hangup", post(hangup_call_handler))
        // Push alerts (FCM)
        .route("/api/devices", post(register_device_handler))
        .route("/api/devices/:id", delete(unregister_device_handler))
        .route("/api/push/config", get(push_config_handler))
        // WebSocket
        .route("/ws", get(ws_handler))
        .layer(DefaultBodyLimit::max(50 * 1024 * 1024))
        .layer(cors)
        .with_state(state)
}
