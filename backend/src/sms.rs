use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::time::Duration;
use uuid::Uuid;

const SMSMKT_USER_AGENT: &str = "Mozilla/5.0 (compatible; BCAiChat/1.0)";

/// Map SMSMKT error codes/messages to clear Thai explanations.
pub fn format_smsmkt_error(code: &str, detail: &str) -> String {
    let code_t = code.trim();
    let detail_t = detail.trim();
    let detail_lower = detail_t.to_lowercase();

    if code_t == "1007-8" || detail_lower.contains("not allow api") {
        return "บัญชี SMSMKT ถูกระงับสิทธิ์ใช้งาน API ชั่วคราว (รหัส 1007-8) กรุณาติดต่อฝ่ายดูแลลูกค้า SMSMKT (LINE @smsmkt หรือ 02-298-0524) เพื่อเปิดสิทธิ์ Allow API"
            .to_string();
    }
    if code_t == "300" || detail_lower.contains("sender") {
        return "ชื่อผู้ส่ง SMS (Sender Name) ยังไม่อนุมัติในระบบ SMSMKT (รอเครือข่ายอนุมัติ 1–3 วันทำการ หรือแจ้ง @smsmkt)"
            .to_string();
    }
    if matches!(code_t, "105" | "106") || detail_lower.contains("credit") {
        return "เครดิต SMSMKT ไม่เพียงพอ".to_string();
    }
    if detail_t.is_empty() {
        format!("SMSMKT แจ้งข้อผิดพลาด (รหัส {})", code_t)
    } else if code_t.is_empty() {
        detail_t.to_string()
    } else {
        format!("{} (รหัส {})", detail_t, code_t)
    }
}

fn sha256_otp_hex(salt: &str, ref_code: &str, otp_code: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("{}:{}:{}", salt, ref_code.trim(), otp_code.trim()).as_bytes());
    hex::encode(hasher.finalize())
}

fn generate_csprng_otp_6() -> String {
    let bytes = *Uuid::new_v4().as_bytes();
    let raw = u64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]);
    let code = (raw % 900_000) + 100_000;
    format!("{:06}", code)
}

#[derive(Debug, Clone)]
pub struct OtpSendResult {
    pub token: String,
    pub ref_code: String,
}

#[derive(Debug, Clone)]
pub struct OtpValidateResult {
    pub valid: bool,
    pub message: String,
}

/// Map Thai numeral (`'๐'..='๙'`) to ASCII (`'0'..='9'`), leaving all other characters unchanged.
pub fn thai_digit_to_ascii(c: char) -> char {
    if ('๐'..='๙').contains(&c) {
        char::from_u32((c as u32) - ('๐' as u32) + ('0' as u32)).unwrap_or(c)
    } else {
        c
    }
}

/// Normalize Thai mobile numbers (`08x`, `09x`, `06x`, `+66...`, `66...`, Thai digits `'๐'..='๙'`) to 10-digit `0xxxxxxxxx`.
pub fn normalize_thai_phone(raw: &str) -> Result<String, String> {
    let digits: String = raw
        .chars()
        .map(thai_digit_to_ascii)
        .filter(|c| c.is_ascii_digit())
        .collect();
    if digits.is_empty() {
        return Err("กรุณากรอกเบอร์โทรศัพท์มือถือ".to_string());
    }
    let normalized = if let Some(rest) = digits.strip_prefix("66") {
        if rest.len() == 9 {
            format!("0{}", rest)
        } else if rest.len() == 10 && rest.starts_with('0') {
            rest.to_string()
        } else {
            digits.clone()
        }
    } else {
        digits
    };

    let bytes = normalized.as_bytes();
    let valid_prefix =
        bytes.len() == 10 && bytes[0] == b'0' && matches!(bytes[1], b'6' | b'8' | b'9');
    if !valid_prefix {
        return Err(
            "รูปแบบเบอร์มือถือไม่ถูกต้อง (กรุณากรอกเบอร์ไทย 10 หลัก เช่น 0812345678)".to_string(),
        );
    }
    Ok(normalized)
}

/// Mask mobile number for safe display (`081-xxx-5678`).
pub fn mask_phone(phone: &str) -> String {
    let chars: Vec<char> = phone.chars().collect();
    if chars.len() >= 10 {
        let head: String = chars[..3].iter().collect();
        let tail: String = chars[chars.len() - 4..].iter().collect();
        format!("{}-xxx-{}", head, tail)
    } else {
        phone.to_string()
    }
}

/// Query remaining SMS credit from SMSMKT (`GET /api/get-credit`).
pub async fn check_credit(
    http: &reqwest::Client,
    base_url: &str,
    api_key: &str,
    secret_key: &str,
) -> Result<Value, String> {
    if api_key.trim().is_empty() || secret_key.trim().is_empty() {
        return Err("ยังไม่ได้ตั้งค่า SMSMKT API Key / Secret Key".to_string());
    }
    let url = format!("{}/api/get-credit", base_url.trim_end_matches('/'));
    let resp = http
        .get(&url)
        .timeout(Duration::from_secs(12))
        .header("User-Agent", SMSMKT_USER_AGENT)
        .header("api_key", api_key.trim())
        .header("secret_key", secret_key.trim())
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("ไม่สามารถเชื่อมต่อ SMSMKT ได้: {}", e))?;

    let status = resp.status();
    let val: Value = resp
        .json()
        .await
        .map_err(|e| format!("อ่านผลลัพธ์ SMSMKT ไม่สำเร็จ: {}", e))?;
    let code = val.get("code").and_then(|c| c.as_str()).unwrap_or_default();
    if !status.is_success() || code != "000" {
        let detail = val
            .get("detail")
            .and_then(|d| d.as_str())
            .unwrap_or("ตรวจสอบเครดิตไม่สำเร็จ");
        return Err(format!("SMSMKT: {}", format_smsmkt_error(code, detail)));
    }
    Ok(val.get("result").cloned().unwrap_or(val))
}

/// Request an OTP SMS via SMSMKT (`POST /api/otp-send` when `project_key` is set,
/// otherwise plain-text OTP via `POST /api/send-message` using an approved `sender_name`).
pub async fn send_otp(
    http: &reqwest::Client,
    base_url: &str,
    api_key: &str,
    secret_key: &str,
    project_key: &str,
    sender_name: &str,
    phone: &str,
    ref_code: &str,
) -> Result<OtpSendResult, String> {
    if api_key.trim().is_empty() || secret_key.trim().is_empty() {
        return Err("ระบบยังไม่ได้ตั้งค่า SMSMKT API Key / Secret Key".to_string());
    }

    if project_key.trim().is_empty() {
        let sender = sender_name.trim();
        if sender.is_empty() {
            return Err(
                "ระบบยังไม่ได้ตั้งค่า SMSMKT Project Key หรือ Sender Name สำหรับส่ง OTP (ตั้งค่าได้ที่ .env หรือแท็บตั้งค่าผู้ดูแลระบบ)"
                    .to_string(),
            );
        }

        let otp_code = generate_csprng_otp_6();
        let salt = Uuid::new_v4().simple().to_string();
        let ref_trimmed = ref_code.trim();
        let digest_hex = sha256_otp_hex(&salt, ref_trimmed, &otp_code);

        // Plain-text Thai OTP without URLs (avoids SMSMKT anti-phishing URL suspension).
        let message = format!(
            "รหัสยืนยัน BC Ai Chat ของคุณคือ {} (Ref: {}) ใช้ได้ภายใน 5 นาที ห้ามแจ้งรหัสแก่ผู้อื่น",
            otp_code, ref_trimmed
        );
        let url = format!("{}/api/send-message", base_url.trim_end_matches('/'));
        let body = json!({
            "sender": sender,
            "phone": phone.trim(),
            "message": message,
        });

        let resp = http
            .post(&url)
            .timeout(Duration::from_secs(15))
            .header("User-Agent", SMSMKT_USER_AGENT)
            .header("api_key", api_key.trim())
            .header("secret_key", secret_key.trim())
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("ส่งคำขอ OTP ไปยัง SMSMKT ไม่สำเร็จ: {}", e))?;

        let status = resp.status();
        let val: Value = resp
            .json()
            .await
            .map_err(|e| format!("อ่านคำตอบส่ง SMS จาก SMSMKT ไม่สำเร็จ: {}", e))?;
        let code = val.get("code").and_then(|c| c.as_str()).unwrap_or_default();
        if !status.is_success() || code != "000" {
            let detail = val
                .get("detail")
                .and_then(|d| d.as_str())
                .unwrap_or("ส่งข้อความ OTP ไม่สำเร็จ");
            return Err(format!("SMSMKT ส่ง OTP ไม่สำเร็จ: {}", format_smsmkt_error(code, detail)));
        }

        return Ok(OtpSendResult {
            token: format!("local_sha256:{}:{}", salt, digest_hex),
            ref_code: ref_trimmed.to_string(),
        });
    }

    let url = format!("{}/api/otp-send", base_url.trim_end_matches('/'));
    let body = json!({
        "project_key": project_key.trim(),
        "phone": phone.trim(),
        "ref_code": ref_code.trim(),
    });

    let resp = http
        .post(&url)
        .timeout(Duration::from_secs(15))
        .header("User-Agent", SMSMKT_USER_AGENT)
        .header("api_key", api_key.trim())
        .header("secret_key", secret_key.trim())
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("ส่งคำขอ OTP ไปยัง SMSMKT ไม่สำเร็จ: {}", e))?;

    let status = resp.status();
    let val: Value = resp
        .json()
        .await
        .map_err(|e| format!("อ่านคำตอบ OTP จาก SMSMKT ไม่สำเร็จ: {}", e))?;

    let code = val.get("code").and_then(|c| c.as_str()).unwrap_or_default();
    if !status.is_success() || code != "000" {
        let detail = val
            .get("detail")
            .and_then(|d| d.as_str())
            .unwrap_or("ส่งรหัส OTP ไม่สำเร็จ");
        return Err(format!("SMSMKT ส่ง OTP ไม่สำเร็จ: {}", format_smsmkt_error(code, detail)));
    }

    let result = val.get("result").unwrap_or(&val);
    let token = result
        .get("token")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "SMSMKT ไม่ได้ส่งคืน OTP token".to_string())?
        .to_string();
    let ret_ref = result
        .get("ref_code")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(ref_code)
        .to_string();

    Ok(OtpSendResult {
        token,
        ref_code: ret_ref,
    })
}

/// Validate a user's OTP code with SMSMKT (`POST /api/otp-validate`).
pub async fn validate_otp(
    http: &reqwest::Client,
    base_url: &str,
    api_key: &str,
    secret_key: &str,
    token: &str,
    otp_code: &str,
    ref_code: &str,
) -> Result<OtpValidateResult, String> {
    if let Some(rest) = token.trim().strip_prefix("local_sha256:") {
        let parts: Vec<&str> = rest.splitn(2, ':').collect();
        if parts.len() != 2 {
            return Err("OTP token ไม่ถูกต้อง".to_string());
        }
        let salt = parts[0];
        let expected_hash = parts[1];
        let computed = sha256_otp_hex(salt, ref_code, otp_code);
        let valid = computed.len() == expected_hash.len()
            && computed
                .bytes()
                .zip(expected_hash.bytes())
                .fold(0u8, |acc, (a, b)| acc | (a ^ b))
                == 0;
        return Ok(OtpValidateResult {
            valid,
            message: if valid {
                "OK".to_string()
            } else {
                "รหัส OTP ไม่ถูกต้องหรือหมดอายุ".to_string()
            },
        });
    }

    if api_key.trim().is_empty() || secret_key.trim().is_empty() {
        return Err("ระบบยังไม่ได้ตั้งค่า SMSMKT API Key / Secret Key".to_string());
    }

    let url = format!("{}/api/otp-validate", base_url.trim_end_matches('/'));
    let mut body = json!({
        "token": token.trim(),
        "otp_code": otp_code.trim(),
    });
    if !ref_code.trim().is_empty() {
        body["ref_code"] = json!(ref_code.trim());
    }

    let resp = http
        .post(&url)
        .timeout(Duration::from_secs(15))
        .header("User-Agent", SMSMKT_USER_AGENT)
        .header("api_key", api_key.trim())
        .header("secret_key", secret_key.trim())
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("ตรวจสอบรหัส OTP กับ SMSMKT ไม่สำเร็จ: {}", e))?;

    let status = resp.status();
    let val: Value = resp
        .json()
        .await
        .map_err(|e| format!("อ่านผลตรวจ OTP จาก SMSMKT ไม่สำเร็จ: {}", e))?;

    let code = val.get("code").and_then(|c| c.as_str()).unwrap_or_default();
    let result = val.get("result");
    let result_status = result
        .and_then(|r| r.get("status"))
        .and_then(|b| b.as_bool())
        .unwrap_or(false);
    let detail = val
        .get("detail")
        .and_then(|d| d.as_str())
        .or_else(|| result.and_then(|r| r.get("message")).and_then(|m| m.as_str()))
        .unwrap_or("รหัส OTP ไม่ถูกต้องหรือหมดอายุ")
        .to_string();

    let message = if status.is_success() && code == "000" {
        detail
    } else {
        format_smsmkt_error(code, &detail)
    };

    Ok(OtpValidateResult {
        valid: status.is_success() && code == "000" && result_status,
        message,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_thai_mobile_variants() {
        assert_eq!(normalize_thai_phone("081-234-5678").unwrap(), "0812345678");
        assert_eq!(normalize_thai_phone("+66812345678").unwrap(), "0812345678");
        assert_eq!(normalize_thai_phone("66912345678").unwrap(), "0912345678");
        assert_eq!(normalize_thai_phone("0612345678").unwrap(), "0612345678");
        assert_eq!(normalize_thai_phone("๐๘๙๙๒๒๓๑๓๑").unwrap(), "0899223131");
        assert_eq!(normalize_thai_phone("๐๘๑-๒๓๔-๕๖๗๘").unwrap(), "0812345678");
        assert_eq!(normalize_thai_phone("+๖๖ ๘๙-๙๒๒-๓๑๓๑").unwrap(), "0899223131");
        assert!(normalize_thai_phone("021234567").is_err());
        assert!(normalize_thai_phone("abc").is_err());
    }

    #[test]
    fn mask_phone_hides_middle_digits() {
        assert_eq!(mask_phone("0812345678"), "081-xxx-5678");
    }

    #[test]
    fn format_smsmkt_error_maps_known_codes() {
        let api_err = format_smsmkt_error(
            "1007-8",
            "Permission denied : User authentication is not allow API.",
        );
        assert!(api_err.contains("1007-8") && api_err.contains("@smsmkt"));

        let sender_err = format_smsmkt_error("300", "Not found this sender name.");
        assert!(sender_err.contains("Sender Name"));
    }

    #[tokio::test]
    async fn send_message_otp_fallback_and_local_validate() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;
        use tokio::sync::oneshot;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = oneshot::channel::<String>();

        tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = vec![0u8; 4096];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req_text = String::from_utf8_lossy(&buf[..n]).to_string();
                let _ = tx.send(req_text);
                let body = r#"{"code":"000","detail":"OK.","result":{"message_id":"msg_1"}}"#;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes()).await;
            }
        });

        let client = reqwest::Client::new();
        let base_url = format!("http://{}", addr);
        let sent = send_otp(
            &client,
            &base_url,
            "k_test",
            "s_test",
            "",
            "bcaccount",
            "0812345678",
            "REF999",
        )
        .await
        .expect("send_message fallback should succeed");
        assert!(sent.token.starts_with("local_sha256:"));

        let req_text = rx.await.unwrap();
        assert!(req_text.contains("/api/send-message"));
        assert!(req_text.contains("\"sender\":\"bcaccount\""));
        assert!(!req_text.contains("http://") && !req_text.contains("https://"));

        // Extract 6-digit OTP from Thai message in captured body
        let digits: String = req_text
            .split("คือ ")
            .nth(1)
            .unwrap()
            .chars()
            .take(6)
            .collect();
        assert_eq!(digits.len(), 6);

        let wrong = validate_otp(&client, &base_url, "k_test", "s_test", &sent.token, "000000", "REF999")
            .await
            .unwrap();
        assert!(!wrong.valid);

        let right = validate_otp(&client, &base_url, "k_test", "s_test", &sent.token, &digits, "REF999")
            .await
            .unwrap();
        assert!(right.valid);
    }
}
