use axum::{
    extract::{Path, Query, State},
    response::Html,
    Json,
};
use bson::doc;
use futures_util::TryStreamExt;
use serde::Deserialize;

use crate::{
    auth::{verify_jwt, ApiError},
    models::{MiniAppDoc, MiniAppDto, UserDoc},
    AppState,
};

pub async fn list_active_mini_apps_handler(
    State(state): State<AppState>,
) -> Result<Json<Vec<MiniAppDto>>, ApiError> {
    let coll = state.db.collection::<MiniAppDoc>("mini_apps");
    let cursor = coll
        .find(doc! { "is_active": true })
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let mut docs: Vec<MiniAppDoc> = cursor
        .try_collect()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    docs.sort_by_key(|a| a.sort_order);
    Ok(Json(docs.into_iter().map(MiniAppDto::from).collect()))
}

#[derive(Debug, Deserialize)]
pub struct MiniAppPageQuery {
    pub token: Option<String>,
    pub conv_id: Option<String>,
}

pub async fn serve_miniapp_html_handler(
    Path(code): Path<String>,
    Query(query): Query<MiniAppPageQuery>,
    State(state): State<AppState>,
) -> Html<String> {
    let token = query.token.unwrap_or_default();
    let conv_id = query.conv_id.unwrap_or_default();

    let mut user_display = "ผู้ใช้งาน BC Ai Chat".to_string();
    let mut user_email = "".to_string();

    if !token.is_empty() {
        if let Ok(claims) = verify_jwt(&token, &state.config.jwt_secret) {
            user_email = claims.email.clone();
            let users_coll = state.db.collection::<UserDoc>("users");
            if let Ok(Some(u)) = users_coll.find_one(doc! { "_id": &claims.sub }).await {
                user_display = format!("{} ({})", u.display_name, u.bc_id);
            }
        }
    }

    let (title, badge_color, subtitle, field1_label, field1_default, field2_label, field2_default, amount_label, amount_default) =
        match code.as_str() {
            "ai" | "ai_companion" | "ai_copilot" => (
                "ผู้ช่วย AI ส่วนตัว",
                "#812920",
                "ช่วยสรุปแชทเพื่อน จัดแผนเที่ยว แนะนำร้านอร่อย และส่งการ์ดโต้ตอบเข้าห้องแชท",
                "หัวข้อที่ให้ AI ช่วยสรุป / วางแผน",
                "สรุปนัดกินข้าวและทริปวันหยุดเสาร์-อาทิตย์นี้",
                "รายละเอียดสำหรับเพื่อนในห้อง",
                "นัดเจอกันคาเฟ่บ่ายสาม • ต่อหมูกระทะริมน้ำตอนเย็น",
                "สถานะจากผู้ช่วย AI",
                "สรุปเรียบร้อยโดย BC AI ส่วนตัว",
            ),
            "split" | "split_bill" | "expense" | "expense_claim" => (
                "หารค่าข้าวกับเพื่อน",
                "#A04035",
                "คำนวณหารมื้ออร่อยกับแก๊งเพื่อน แล้วส่งการ์ดสรุปยอดเข้าห้องแชททันที",
                "ชื่อร้าน / มื้ออาหาร",
                "ร้านหมูกระทะริมน้ำ & ของหวาน",
                "สมาชิกที่ร่วมหาร / หมายเหตุ",
                "แก๊งเพื่อน 5 คน (โอนพร้อมเพย์แพรได้เลย)",
                "ยอดหารต่อคน",
                "คนละ 320 บาท (รวม 1,600 บาท)",
            ),
            "trip" | "trip_planner" | "leave" | "leave_approval" => (
                "จัดทริปเที่ยว",
                "#B45309",
                "วางแผนจุดแวะเที่ยว ที่พัก และงบประมาณทริปแชร์ให้เพื่อนและครอบครัว",
                "จุดหมายปลายทาง / ชื่อทริป",
                "ทริปเขาใหญ่ 2 วัน 1 คืน กางเต็นท์ดูดาว",
                "วันเดินทาง & ไฮไลต์กิจกรรม",
                "เสาร์-อาทิตย์หน้า • แวะคาเฟ่ จุดชมวิว และปิ้งย่างยามเย็น",
                "งบประมาณต่อคนโดยประมาณ",
                "คนละ 1,250 บาท",
            ),
            "wishlist" | "gift_wishlist" | "quotation" | "quick_quotation" => (
                "ลิสต์ของฝาก / ช้อปปิ้ง",
                "#13795B",
                "จดรายการของฝาก ของขวัญ และของใช้เข้าบ้านแชร์ในห้องแชท",
                "รายการของฝาก / ของที่จะซื้อ",
                "ขนมเปี๊ยะลาวา & เมล็ดกาแฟคั่วกลาง",
                "พิกัดร้านหรือฝากใครซื้อ",
                "แวะซื้อขากลับก่อนเข้าบ้าน 2 กล่อง",
                "งบประมาณ / จำนวน",
                "2 กล่อง (ประมาณ 450 บาท)",
            ),
            "hangout" | "hangout_invite" | "booking" | "crm_queue" => (
                "การ์ดชวนนัดเจอ",
                "#1E40AF",
                "ส่งการ์ดชวนกินข้าว ดูหนัง วิ่งสวน หรือสังสรรค์วันหยุดให้เพื่อนกดตอบรับ",
                "กิจกรรมที่ชวนนัดเจอ",
                "นัดดูหนังรอบค่ำ & กินไอศกรีมโฮมเมด",
                "วัน-เวลานัดพบ & สถานที่",
                "เสาร์นี้ เวลา 18:00 น. (ลานน้ำพุชั้น 1)",
                "สถานะนัดหมาย",
                "ว่างเจอกัน! กดตอบรับได้เลย",
            ),
            _ => (
                "เครื่องมือไลฟ์สไตล์ส่วนตัว BC Ai Chat",
                "#812920",
                "สร้างการ์ดโต้ตอบสำหรับแชร์ในห้องแชทครอบครัวและเพื่อนสนิท",
                "หัวข้อรายการ",
                "แชร์เรื่องราวดีๆ ในกลุ่ม",
                "รายละเอียด",
                "ส่งการ์ดโต้ตอบเข้าห้องแชทส่วนตัว",
                "ข้อมูลเพิ่มเติม",
                "พร้อมแชร์ 100%",
            ),
        };

    let html = format!(
        r##"<!DOCTYPE html>
<html lang="th">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>{title} - BC Ai Chat</title>
  <style>
    * {{ box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Prompt", "Noto Sans Thai", sans-serif; }}
    body {{ margin: 0; padding: 16px; background: #FBF9F8; color: #1B1C1C; }}
    .card {{ max-width: 520px; margin: 0 auto; background: #FFFFFF; border: 1px solid #DCC0BC; border-radius: 16px; box-shadow: 0 4px 20px rgba(129, 41, 32, 0.08); overflow: hidden; }}
    .header {{ background: {badge_color}; color: #FFFFFF; padding: 18px 20px; }}
    .header h1 {{ margin: 0; font-size: 19px; font-weight: 700; }}
    .header p {{ margin: 6px 0 0; font-size: 13px; opacity: 0.92; }}
    .sso-bar {{ background: #F6F3F2; padding: 10px 20px; border-bottom: 1px solid #DCC0BC; font-size: 13px; color: #2B1410; display: flex; justify-content: space-between; align-items: center; }}
    .sso-badge {{ background: #FFDAD5; color: #812920; padding: 3px 8px; border-radius: 999px; font-weight: 600; font-size: 11px; }}
    .body {{ padding: 20px; }}
    .form-group {{ margin-bottom: 14px; }}
    label {{ display: block; font-size: 13px; font-weight: 600; color: #2B1410; margin-bottom: 6px; }}
    input, select, textarea {{ width: 100%; padding: 10px 12px; border: 1px solid #DCC0BC; border-radius: 10px; font-size: 14px; color: #1B1C1C; background: #FFFFFF; outline: none; }}
    input:focus, select:focus, textarea:focus {{ border-color: {badge_color}; box-shadow: 0 0 0 3px rgba(129, 41, 32, 0.15); }}
    .btn {{ width: 100%; padding: 13px 16px; border: none; border-radius: 12px; background: {badge_color}; color: #FFFFFF; font-size: 15px; font-weight: 700; cursor: pointer; display: flex; align-items: center; justify-content: center; gap: 8px; }}
    .btn:hover {{ opacity: 0.94; }}
    .status-box {{ margin-top: 14px; padding: 12px; border-radius: 10px; font-size: 13px; display: none; }}
    .status-ok {{ background: #F5EFEA; color: #681F18; border: 1px solid #DCC0BC; display: block; }}
    .status-err {{ background: #FEE2E2; color: #991B1B; border: 1px solid #FCA5A5; display: block; }}
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <h1>{title}</h1>
      <p>{subtitle}</p>
    </div>
    <div class="sso-bar">
      <span>ผู้ใช้งาน: <strong>{user_display}</strong> {user_email}</span>
      <span class="sso-badge">เชื่อมต่อ BC Ai Chat แล้ว</span>
    </div>
    <div class="body">
      <div class="form-group">
        <label>เลือกห้องแชทปลายทางที่จะส่งการ์ดโต้ตอบ</label>
        <select id="convSelect">
          <option value="{conv_id}">ห้องแชทปัจจุบัน ({conv_id})</option>
        </select>
      </div>
      <div class="form-group">
        <label>{field1_label}</label>
        <input id="field1" type="text" value="{field1_default}" />
      </div>
      <div class="form-group">
        <label>{field2_label}</label>
        <input id="field2" type="text" value="{field2_default}" />
      </div>
      <div class="form-group">
        <label>{amount_label}</label>
        <input id="amount" type="text" value="{amount_default}" />
      </div>
      <button class="btn" onclick="sendRichCard()">
        <span>ส่งการ์ดโต้ตอบเข้าห้องแชททันที</span>
      </button>
      <div id="statusBox" class="status-box"></div>
    </div>
  </div>

  <script>
    const TOKEN = {token_json};
    const DEFAULT_CONV_ID = {conv_id_json};
    const APP_CODE = {code_json};
    const APP_TITLE = {title_json};
    const BADGE_COLOR = {color_json};

    async function loadRooms() {{
      if (!TOKEN) return;
      try {{
        const res = await fetch('/api/conversations?folder=all', {{
          headers: {{ 'Authorization': 'Bearer ' + TOKEN }}
        }});
        if (!res.ok) return;
        const rooms = await res.json();
        const sel = document.getElementById('convSelect');
        sel.innerHTML = '';
        rooms.forEach(r => {{
          const opt = document.createElement('option');
          opt.value = r.id;
          opt.textContent = (r.type === 'group' ? '👥 ' : '💬 ') + r.name;
          if (r.id === DEFAULT_CONV_ID) opt.selected = true;
          sel.appendChild(opt);
        }});
      }} catch (e) {{
        console.warn(e);
      }}
    }}

    async function sendRichCard() {{
      const convId = document.getElementById('convSelect').value || DEFAULT_CONV_ID;
      const f1 = document.getElementById('field1').value;
      const f2 = document.getElementById('field2').value;
      const amt = document.getElementById('amount').value;
      const statusBox = document.getElementById('statusBox');

      const cardPayload = {{
        app_code: APP_CODE,
        title: APP_TITLE,
        color_hex: BADGE_COLOR,
        heading: f1,
        subtitle: f2,
        highlight_value: amt,
        status: "แชร์แล้ว",
        status_label: "แชร์ในห้องแชท",
        action_url: window.location.href
      }};

      try {{
        const res = await fetch('/api/conversations/' + encodeURIComponent(convId) + '/messages', {{
          method: 'POST',
          headers: {{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + TOKEN
          }},
          body: JSON.stringify({{
            type: 'rich_card',
            content: '[' + APP_TITLE + '] ' + f1 + ' — ' + amt,
            card_payload: cardPayload
          }})
        }});

        if (!res.ok) throw new Error('HTTP ' + res.status);
        const msg = await res.json();
        statusBox.className = 'status-box status-ok';
        statusBox.textContent = '✅ ส่งการ์ดโต้ตอบเข้าห้องแชทเรียบร้อยแล้ว! (รหัสข้อความ: ' + msg.id.slice(0, 8) + ')';

        if (window.parent && window.parent !== window) {{
          window.parent.postMessage({{
            event: 'miniapp_card_sent',
            conversation_id: convId,
            message: msg
          }}, '*');
        }}
      }} catch (err) {{
        statusBox.className = 'status-box status-err';
        statusBox.textContent = '❌ ไม่สามารถส่งการ์ดโต้ตอบได้: ' + err.message;
      }}
    }}

    loadRooms();
  </script>
</body>
</html>"##,
        title = title,
        badge_color = badge_color,
        subtitle = subtitle,
        user_display = user_display,
        user_email = if user_email.is_empty() {
            "".to_string()
        } else {
            format!("• {}", user_email)
        },
        conv_id = conv_id,
        field1_label = field1_label,
        field1_default = field1_default,
        field2_label = field2_label,
        field2_default = field2_default,
        amount_label = amount_label,
        amount_default = amount_default,
        token_json = serde_json::to_string(&token).unwrap_or_else(|_| "\"\"".to_string()),
        conv_id_json = serde_json::to_string(&conv_id).unwrap_or_else(|_| "\"\"".to_string()),
        code_json = serde_json::to_string(&code).unwrap_or_else(|_| "\"\"".to_string()),
        title_json = serde_json::to_string(&title).unwrap_or_else(|_| "\"\"".to_string()),
        color_json = serde_json::to_string(&badge_color).unwrap_or_else(|_| "\"#812920\"".to_string()),
    );

    Html(html)
}
