use std::env;

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub port: u16,
    pub mongodb_uri: String,
    pub mongodb_db: String,
    pub minio_endpoint: String,
    pub minio_access_key: String,
    pub minio_secret_key: String,
    pub minio_bucket: String,
    pub jwt_secret: String,
    pub google_client_id: String,
    pub google_oauth_verify_base: String,
    pub super_admin_email: String,
    pub super_admin_phone: String,
    pub public_base_url: String,
    pub deepseek_api_key: String,
    pub deepseek_model: String,
    pub deepseek_base_url: String,
    pub smsmkt_base_url: String,
    pub smsmkt_api_key: String,
    pub smsmkt_secret_key: String,
    pub smsmkt_project_key: String,
    pub smsmkt_sender_name: String,
    pub smsmkt_mcp_bearer: String,
    pub admin_bootstrap_code: String,
    pub enable_test_users: bool,
    pub livekit_url: String,
    pub livekit_api_key: String,
    pub livekit_api_secret: String,
    pub call_ring_timeout_ms: u64,
    pub fcm_service_account_file: String,
    pub fcm_api_base: String,
    pub fcm_web_api_key: String,
    pub fcm_web_app_id: String,
    pub fcm_web_sender_id: String,
    pub fcm_web_vapid_key: String,
}

fn clean_secret_env(raw: String) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.starts_with("your-")
        || trimmed.starts_with("your_")
        || trimmed.starts_with("replace_")
    {
        String::new()
    } else {
        trimmed.to_string()
    }
}

pub fn is_loopback_base_url(raw_url: &str) -> bool {
    let lower = raw_url.trim().to_ascii_lowercase();
    for prefix in ["http://127.0.0.1", "http://localhost", "http://[::1]"] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            if rest.is_empty() || rest.starts_with(':') || rest.starts_with('/') {
                return true;
            }
        }
    }
    false
}

pub fn resolve_enable_test_users(
    raw_enable: Option<&str>,
    raw_public_base: Option<&str>,
) -> bool {
    if let Some(val) = raw_enable.map(str::trim).filter(|s| !s.is_empty()) {
        return val.eq_ignore_ascii_case("true") || val == "1" || val.eq_ignore_ascii_case("yes");
    }
    match raw_public_base.map(str::trim).filter(|s| !s.is_empty()) {
        Some(base) => is_loopback_base_url(base),
        None => false,
    }
}

impl AppConfig {
    pub fn from_env() -> Self {
        if dotenvy::from_path("../.env").is_err() {
            let _ = dotenvy::dotenv();
        }

        let port = env::var("PORT")
            .ok()
            .and_then(|v| v.parse::<u16>().ok())
            .unwrap_or(8096);

        let mongodb_uri = env::var("MONGODB_URI")
            .unwrap_or_else(|_| "mongodb://127.0.0.1:27030".to_string());
        let mongodb_db = env::var("MONGODB_DB").unwrap_or_else(|_| "bcaichat".to_string());

        let minio_endpoint = env::var("MINIO_ENDPOINT")
            .unwrap_or_else(|_| "http://127.0.0.1:9130".to_string())
            .trim_end_matches('/')
            .to_string();
        let minio_access_key = env::var("MINIO_ACCESS_KEY")
            .unwrap_or_else(|_| "bcaichatadmin".to_string());
        let minio_secret_key = env::var("MINIO_SECRET_KEY")
            .unwrap_or_else(|_| "bcaichat_minio_local_dev".to_string());
        let minio_bucket = env::var("MINIO_BUCKET")
            .unwrap_or_else(|_| "bcaichat-storage".to_string());

        let jwt_secret = env::var("JWT_SECRET")
            .unwrap_or_else(|_| "bcaichat_local_dev_jwt_signing_key_2026".to_string());
        let google_client_id = clean_secret_env(env::var("GOOGLE_CLIENT_ID").unwrap_or_default());
        let google_oauth_verify_base = env::var("GOOGLE_OAUTH_VERIFY_BASE")
            .unwrap_or_else(|_| "https://oauth2.googleapis.com".to_string())
            .trim()
            .trim_end_matches('/')
            .to_string();
        let super_admin_email = env::var("SUPER_ADMIN_EMAIL")
            .unwrap_or_default()
            .trim()
            .to_lowercase();
        let super_admin_phone = crate::sms::normalize_thai_phone(
            &env::var("SUPER_ADMIN_PHONE").unwrap_or_default(),
        )
        .unwrap_or_default();

        let raw_public_base = env::var("PUBLIC_BASE_URL").ok();
        let public_base_url = raw_public_base
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("http://127.0.0.1:{}", port));

        let deepseek_api_key = clean_secret_env(env::var("DEEPSEEK_API_KEY").unwrap_or_default());
        let deepseek_model = env::var("DEEPSEEK_MODEL")
            .unwrap_or_else(|_| "deepseek-chat".to_string())
            .trim()
            .to_string();
        let deepseek_base_url = env::var("DEEPSEEK_BASE_URL")
            .unwrap_or_else(|_| "https://api.deepseek.com".to_string())
            .trim_end_matches('/')
            .to_string();

        let smsmkt_base_url = env::var("SMSMKT_BASE_URL")
            .unwrap_or_else(|_| "https://portal-otp.smsmkt.com".to_string())
            .trim()
            .trim_end_matches('/')
            .to_string();
        let smsmkt_api_key = clean_secret_env(env::var("SMSMKT_API_KEY").unwrap_or_default());
        let smsmkt_secret_key = clean_secret_env(env::var("SMSMKT_SECRET_KEY").unwrap_or_default());
        let smsmkt_project_key = clean_secret_env(env::var("SMSMKT_PROJECT_KEY").unwrap_or_default());
        let smsmkt_sender_name = clean_secret_env(env::var("SMSMKT_SENDER_NAME").unwrap_or_default());
        let smsmkt_mcp_bearer = clean_secret_env(env::var("SMSMKT_MCP_BEARER").unwrap_or_default());
        let admin_bootstrap_code =
            clean_secret_env(env::var("ADMIN_BOOTSTRAP_CODE").unwrap_or_default());
        let enable_test_users = resolve_enable_test_users(
            env::var("ENABLE_TEST_USERS").ok().as_deref(),
            raw_public_base.as_deref(),
        );

        let raw_lk_url = env::var("LIVEKIT_URL").unwrap_or_default();
        let cleaned_lk_url = raw_lk_url
            .trim()
            .trim_end_matches('/')
            .trim_end_matches("/rtc")
            .trim_end_matches('/')
            .to_string();
        let livekit_url = if cleaned_lk_url.is_empty() {
            "ws://127.0.0.1:7880".to_string()
        } else {
            cleaned_lk_url
        };
        let livekit_api_key = clean_secret_env(env::var("LIVEKIT_API_KEY").unwrap_or_default());
        let livekit_api_secret =
            clean_secret_env(env::var("LIVEKIT_API_SECRET").unwrap_or_default());
        let call_ring_timeout_ms = env::var("CALL_RING_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|&v| v > 0)
            .unwrap_or(45_000);

        let env_trim = |k: &str| env::var(k).unwrap_or_default().trim().to_string();
        let fcm_api_base = env::var("FCM_API_BASE")
            .unwrap_or_else(|_| "https://fcm.googleapis.com".to_string())
            .trim_end_matches('/')
            .to_string();

        Self {
            port,
            mongodb_uri,
            mongodb_db,
            minio_endpoint,
            minio_access_key,
            minio_secret_key,
            minio_bucket,
            jwt_secret,
            google_client_id,
            google_oauth_verify_base,
            super_admin_email,
            super_admin_phone,
            public_base_url,
            deepseek_api_key,
            deepseek_model,
            deepseek_base_url,
            smsmkt_base_url,
            smsmkt_api_key,
            smsmkt_secret_key,
            smsmkt_project_key,
            smsmkt_sender_name,
            smsmkt_mcp_bearer,
            admin_bootstrap_code,
            enable_test_users,
            livekit_url,
            livekit_api_key,
            livekit_api_secret,
            call_ring_timeout_ms,
            fcm_service_account_file: env_trim("FCM_SERVICE_ACCOUNT_FILE"),
            fcm_api_base,
            fcm_web_api_key: env_trim("FCM_WEB_API_KEY"),
            fcm_web_app_id: env_trim("FCM_WEB_APP_ID"),
            fcm_web_sender_id: env_trim("FCM_WEB_SENDER_ID"),
            fcm_web_vapid_key: env_trim("FCM_WEB_VAPID_KEY"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{is_loopback_base_url, resolve_enable_test_users};

    #[test]
    fn resolve_enable_test_users_enforces_fail_closed_outside_explicit_loopback() {
        // Neither env var set -> fail-closed false!
        assert!(!resolve_enable_test_users(None, None));
        assert!(!resolve_enable_test_users(Some(""), Some("")));

        // Explicit loopback PUBLIC_BASE_URL when ENABLE_TEST_USERS is unset -> true
        assert!(resolve_enable_test_users(None, Some("http://127.0.0.1:8096")));
        assert!(resolve_enable_test_users(None, Some("http://localhost:3096")));
        assert!(resolve_enable_test_users(None, Some("http://[::1]:8096")));

        // External / HTTPS / spoofed domains when ENABLE_TEST_USERS is unset -> fail-closed false
        assert!(!resolve_enable_test_users(
            None,
            Some("https://www.bcaichat.com")
        ));
        assert!(!resolve_enable_test_users(
            None,
            Some("http://localhost.evil.com")
        ));
        assert!(!is_loopback_base_url("http://127.0.0.1.evil.com"));

        // Explicit ENABLE_TEST_USERS overrides in both directions
        assert!(resolve_enable_test_users(
            Some("true"),
            Some("https://www.bcaichat.com")
        ));
        assert!(resolve_enable_test_users(Some("1"), None));
        assert!(resolve_enable_test_users(Some("YES"), None));
        assert!(!resolve_enable_test_users(
            Some("false"),
            Some("http://127.0.0.1:8096")
        ));
        assert!(!resolve_enable_test_users(
            Some("0"),
            Some("http://localhost:8096")
        ));
        assert!(!resolve_enable_test_users(
            Some("no"),
            Some("http://localhost:8096")
        ));
    }
}
