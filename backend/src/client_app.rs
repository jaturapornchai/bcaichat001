//! Which client a device or socket is: the personal chat app or the shop app.
//! Both sign in with the same account, so the server sends each conversation
//! event to the app the user handles it in. Clients that predate the split
//! send no app name and keep receiving everything.

pub const CHAT: &str = "chat";
pub const OA: &str = "oa";

/// Stored form of the app name a client sent: `""` for a client that sent
/// none, `None` when the name is not a known app.
pub fn parse(raw: Option<&str>) -> Option<&'static str> {
    match raw.map(str::trim).unwrap_or("") {
        "" => Some(""),
        CHAT => Some(CHAT),
        OA => Some(OA),
        _ => None,
    }
}

/// Whether `app` gets an event of a conversation for one recipient. The caller
/// has already decided the recipient may get the event at all.
///
/// A shop conversation has two sides: the customer (a member) reads it in the
/// chat app, the shop's staff (admins, never members unless they also follow
/// their own shop) handle it in the shop app. Every other conversation is
/// personal and belongs to the chat app.
pub fn receives(app: &str, is_shop_conversation: bool, is_member: bool, is_admin: bool) -> bool {
    match app {
        CHAT => !is_shop_conversation || is_member,
        OA => is_shop_conversation && (is_admin || !is_member),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_accepts_known_apps_and_treats_missing_as_legacy() {
        assert_eq!(parse(None), Some(""));
        assert_eq!(parse(Some("")), Some(""));
        assert_eq!(parse(Some(" chat ")), Some(CHAT));
        assert_eq!(parse(Some("oa")), Some(OA));
        assert_eq!(parse(Some("OA")), None);
        assert_eq!(parse(Some("shop")), None);
    }

    #[test]
    fn personal_conversations_go_to_the_chat_app_only() {
        for (is_member, is_admin) in [(true, false), (true, true)] {
            assert!(receives(CHAT, false, is_member, is_admin));
            assert!(!receives(OA, false, is_member, is_admin));
            assert!(receives("", false, is_member, is_admin));
        }
    }

    #[test]
    fn shop_conversations_split_customer_and_staff() {
        // Customer: member, not staff.
        assert!(receives(CHAT, true, true, false));
        assert!(!receives(OA, true, true, false));
        // Staff: admin, not a member.
        assert!(!receives(CHAT, true, false, true));
        assert!(receives(OA, true, false, true));
        // Staff named by the shop record before the conversation was synced.
        assert!(!receives(CHAT, true, false, false));
        assert!(receives(OA, true, false, false));
        // Staff who also follows the shop gets both sides.
        assert!(receives(CHAT, true, true, true));
        assert!(receives(OA, true, true, true));
        // Clients that predate the split keep everything.
        assert!(receives("", true, true, false));
        assert!(receives("", true, false, true));
    }
}
