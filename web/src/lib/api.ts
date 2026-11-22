import type {
  AccountRecoveryLogItem,
  ActiveGameState,
  AdminAuthSettings,
  AdminOverview,
  AiAnalyzeMessageResult,
  AiAssistResult,
  AiConnectionTestResult,
  AiSettings,
  AiSummaryResult,
  AlbumItem,
  AttachmentInfo,
  AuthConfig,
  AuthSessionResponse,
  BcIdCheckResult,
  CallJoinResponse,
  CallSession,
  ChatMessage,
  ContactCardData,
  Conversation,
  FriendItem,
  GameCatalogItem,
  GameCatalogResponse,
  GameSession,
  GameSummary,
  GooglePollResponse,
  LadderGameData,
  LocationData,
  MiniAppItem,
  NoteItem,
  OaAccount,
  OaAutoReplyRule,
  OaBroadcast,
  OaCoupon,
  OaCustomer,
  OaCustomerChat,
  OaCustomerDetail,
  OaCustomerList,
  OaCustomerTagStats,
  OaFollowerCrm,
  OaOverview,
  OaRichMenuItem,
  OaStaffMember,
  OtpChallengeResponse,
  ProactiveGameInviteResult,
  RichCardPayload,
  RoomToneId,
  ThemePresetId,
  UserProfile,
  VaultResponse,
} from "./types";
import { isLocalhostRuntime } from "./site";

const STORAGE_TOKEN_KEY = "bcaichat_tab_token";
const STORAGE_USER_KEY = "bcaichat_tab_user";
const STORAGE_ROOM_TONE_KEY = "bcaichat_room_tone";

export function getTabToken(): string {
  if (typeof window === "undefined") return "";
  return window.sessionStorage.getItem(STORAGE_TOKEN_KEY) || "";
}

export function setTabSession(token: string, user: UserProfile): void {
  if (typeof window === "undefined") return;
  window.sessionStorage.setItem(STORAGE_TOKEN_KEY, token);
  window.sessionStorage.setItem(STORAGE_USER_KEY, JSON.stringify(user));
}

export function getTabUser(): UserProfile | null {
  if (typeof window === "undefined") return null;
  const raw = window.sessionStorage.getItem(STORAGE_USER_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as UserProfile;
  } catch {
    return null;
  }
}

export function clearTabSession(): void {
  if (typeof window === "undefined") return;
  window.sessionStorage.removeItem(STORAGE_TOKEN_KEY);
  window.sessionStorage.removeItem(STORAGE_USER_KEY);
}

export function getSavedRoomTone(): RoomToneId {
  if (typeof window === "undefined") return "ban_chiang_cream";
  const raw = window.localStorage.getItem(STORAGE_ROOM_TONE_KEY);
  if (raw === "terracotta_night" || raw === "ivory_white" || raw === "ban_chiang_cream") {
    return raw;
  }
  return "ban_chiang_cream";
}

export function saveRoomTone(tone: RoomToneId): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_ROOM_TONE_KEY, tone);
}

export function getWsUrl(token: string, deviceId = "web_tab", app: "chat" | "oa" = "chat"): string {
  const configured = process.env.NEXT_PUBLIC_WS_URL?.trim();
  let base = configured || "ws://127.0.0.1:8096/ws";
  if (!configured && typeof window !== "undefined") {
    const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
    const hostname = window.location.hostname || "127.0.0.1";
    if (hostname === "localhost" || hostname === "127.0.0.1" || hostname.endsWith(".localhost")) {
      base = `${proto}//${hostname}:8096/ws`;
    } else {
      base = `${proto}//${window.location.host}/ws`;
    }
  }
  const sep = base.includes("?") ? "&" : "?";
  return `${base}${sep}token=${encodeURIComponent(token)}&device=${encodeURIComponent(deviceId)}&app=${app}`;
}

export function resolveLiveKitUrl(rawUrl?: string | null): string {
  const trimmed = (rawUrl || "").trim();
  const sameOrigin =
    typeof window !== "undefined"
      ? `${window.location.protocol === "https:" ? "wss:" : "ws:"}//${window.location.host}`
      : "ws://127.0.0.1:7880";
  if (!trimmed || trimmed === "same_origin") {
    return sameOrigin;
  }
  let clean = trimmed.replace(/\/+$/, "");
  if (clean.endsWith("/rtc")) {
    clean = clean.slice(0, -4).replace(/\/+$/, "");
  }
  return clean || sameOrigin;
}

function normalizeIdDoc<T extends { id?: string; _id?: string }>(
  raw: T & Record<string, unknown>
): T & { id: string } {
  return {
    ...raw,
    id: String(raw.id ?? raw._id ?? ""),
  };
}

function normalizeOaCustomerChat(raw: Record<string, unknown>): OaCustomerChat {
  return {
    conversation_id: String(raw.conversation_id ?? ""),
    oa_id: String(raw.oa_id ?? ""),
    follower_user_id: String(raw.follower_user_id ?? raw.customer_id ?? ""),
    follower_name: String(raw.follower_name ?? raw.customer_name ?? "ลูกค้า"),
    follower_bc_id: String(raw.follower_bc_id ?? raw.customer_bc_id ?? ""),
    follower_phone: String(raw.follower_phone ?? raw.customer_phone ?? ""),
    follower_email: String(raw.follower_email ?? raw.customer_email ?? ""),
    follower_avatar: String(raw.follower_avatar ?? raw.customer_avatar ?? ""),
    tags: Array.isArray(raw.tags) ? raw.tags.map(String) : [],
    crm_note: String(raw.crm_note ?? ""),
    ai_paused: Boolean(raw.ai_paused),
    unread_for_oa: Number(raw.unread_for_oa ?? 0),
    last_message: (raw.last_message as OaCustomerChat["last_message"]) ?? null,
    updated_at: String(raw.updated_at ?? ""),
  };
}

function normalizeOaCustomer(raw: Record<string, unknown>): OaCustomer {
  return {
    conversation_id: String(raw.conversation_id ?? ""),
    oa_id: String(raw.oa_id ?? ""),
    customer_id: String(raw.customer_id ?? raw.follower_user_id ?? ""),
    customer_name: String(raw.customer_name ?? raw.follower_name ?? "ลูกค้า"),
    customer_avatar: String(raw.customer_avatar ?? raw.follower_avatar ?? ""),
    customer_bc_id: String(raw.customer_bc_id ?? raw.follower_bc_id ?? ""),
    customer_phone: String(raw.customer_phone ?? raw.follower_phone ?? ""),
    customer_email: String(raw.customer_email ?? raw.follower_email ?? ""),
    tags: Array.isArray(raw.tags) ? raw.tags.map(String) : [],
    crm_note: String(raw.crm_note ?? ""),
    ai_paused: Boolean(raw.ai_paused),
    unread_for_oa: Number(raw.unread_for_oa ?? 0),
    last_message: (raw.last_message as OaCustomer["last_message"]) ?? null,
    updated_at: String(raw.updated_at ?? ""),
    is_following: Boolean(raw.is_following),
    followed_at: String(raw.followed_at ?? ""),
  };
}

function normalizeOaCoupon(raw: Record<string, unknown>): OaCoupon {
  const src =
    !raw.id && !raw._id && raw.coupon && typeof raw.coupon === "object"
      ? (raw.coupon as Record<string, unknown>)
      : raw;
  const claimedBy = Array.isArray(src.claimed_by) ? src.claimed_by.map(String) : [];
  const redeemedBy = Array.isArray(src.redeemed_by) ? src.redeemed_by.map(String) : [];
  return {
    id: String(src.id ?? src._id ?? ""),
    oa_id: String(src.oa_id ?? ""),
    code: String(src.code ?? ""),
    title: String(src.title ?? ""),
    description: String(src.description ?? ""),
    discount_text: String(src.discount_text ?? ""),
    expires_at: (src.expires_at as string | null | undefined) ?? null,
    max_claims: Number(src.max_claims ?? 0),
    claimed_by: claimedBy,
    redeemed_by: redeemedBy,
    claimed_count: Number(src.claimed_count ?? src.claims_count ?? claimedBy.length),
    redeemed_count: Number(src.redeemed_count ?? redeemedBy.length),
    is_claimed: Boolean(src.is_claimed ?? raw.is_claimed),
    is_redeemed: Boolean(src.is_redeemed ?? raw.is_redeemed),
    is_active: Boolean(src.is_active ?? true),
    created_at: String(src.created_at ?? ""),
  };
}

export function resolveMediaUrl(rawUrl?: string | null): string {
  if (!rawUrl) return "";
  try {
    const u = new URL(rawUrl, "http://127.0.0.1:8096");
    if (u.pathname.startsWith("/api/files/")) {
      return u.pathname;
    }
    return rawUrl;
  } catch {
    return rawUrl;
  }
}

export function normalizeMessage(raw: Record<string, unknown>): ChatMessage {
  const rawPayload =
    (raw.card_payload as RichCardPayload | null | undefined) ??
    (raw["flex_payload"] as RichCardPayload | null | undefined) ??
    null;
  const rawType = String(raw.type ?? raw.msg_type ?? "text");
  const normalizedType = rawType === "flex_card" ? "rich_card" : rawType;

  return {
    id: String(raw.id ?? raw._id ?? ""),
    conversation_id: String(raw.conversation_id ?? ""),
    sender_id: String(raw.sender_id ?? ""),
    sender_name: String(raw.sender_name ?? "สมาชิก"),
    sender_avatar: String(raw.sender_avatar ?? ""),
    type: normalizedType,
    content: String(raw.content ?? ""),
    sticker_code: (raw.sticker_code as string | null | undefined) ?? null,
    attachment: (raw.attachment as AttachmentInfo | null | undefined) ?? null,
    card_payload: rawPayload,
    reply_to: (raw.reply_to as ChatMessage["reply_to"]) ?? null,
    read_by: Array.isArray(raw.read_by) ? raw.read_by.map(String) : [],
    read_count: Number(raw.read_count ?? 0),
    is_unsent: Boolean(raw.is_unsent),
    is_confidential: Boolean(raw.is_confidential),
    confidential_pin: (raw.confidential_pin as string | null | undefined) ?? null,
    expire_at: (raw.expire_at as string | null | undefined) ?? null,
    priority: String(raw.priority ?? "normal"),
    task_status: (raw.task_status as string | null | undefined) ?? null,
    accepted_by: (raw.accepted_by as string | null | undefined) ?? null,
    accepted_at: (raw.accepted_at as string | null | undefined) ?? null,
    reactions:
      raw.reactions && typeof raw.reactions === "object"
        ? (raw.reactions as Record<string, string[]>)
        : {},
    mentions: Array.isArray(raw.mentions) ? raw.mentions.map(String) : [],
    audio_duration_sec:
      raw.audio_duration_sec !== undefined && raw.audio_duration_sec !== null
        ? Number(raw.audio_duration_sec)
        : null,
    poll: (raw.poll as ChatMessage["poll"]) ?? null,
    event_data: (raw.event_data as ChatMessage["event_data"]) ?? null,
    location_data: (raw.location_data as LocationData | null | undefined) ?? null,
    contact_data: (raw.contact_data as ContactCardData | null | undefined) ?? null,
    ladder_data: (raw.ladder_data as LadderGameData | null | undefined) ?? null,
    edited_at: (raw.edited_at as string | null | undefined) ?? null,
    forwarded_from: (raw.forwarded_from as string | null | undefined) ?? null,
    created_at: String(raw.created_at ?? ""),
  };
}

export class ApiClient {
  private tokenOverride: string | null = null;

  constructor(tokenOverride?: string) {
    this.tokenOverride = tokenOverride ?? null;
  }

  private getToken(): string {
    return this.tokenOverride !== null ? this.tokenOverride : getTabToken();
  }

  private async request<T>(
    path: string,
    options: RequestInit = {},
    skipAuth = false
  ): Promise<T> {
    const headers = new Headers(options.headers);
    if (!headers.has("Content-Type") && !(options.body instanceof FormData)) {
      headers.set("Content-Type", "application/json");
    }
    const token = this.getToken();
    if (!skipAuth && token) {
      headers.set("Authorization", `Bearer ${token}`);
    }

    const res = await fetch(path, {
      ...options,
      headers,
      cache: "no-store",
    });

    const text = await res.text();
    let parsed: unknown = null;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch {
      parsed = text;
    }

    if (!res.ok) {
      const msg =
        parsed && typeof parsed === "object" && "error" in parsed
          ? String((parsed as { error: unknown }).error)
          : `คำขอไม่สำเร็จ (HTTP ${res.status})`;
      const err = new Error(msg) as Error & { status?: number };
      err.status = res.status;
      throw err;
    }

    return parsed as T;
  }

  async getHealth(): Promise<{ status: string; mongodb: boolean; minio: boolean }> {
    return this.request("/api/health", {}, true);
  }

  async getTheme(): Promise<{ preset: ThemePresetId }> {
    return this.request("/api/settings/theme", {}, true);
  }

  async setTheme(preset: ThemePresetId): Promise<{ preset: ThemePresetId }> {
    return this.request("/api/settings/theme", {
      method: "PUT",
      body: JSON.stringify({ preset }),
    });
  }

  async getAuthConfig(): Promise<AuthConfig> {
    return this.request<AuthConfig>("/api/auth/config", {}, true);
  }

  async bootstrapAdmin(payload: {
    code: string;
    display_name?: string;
  }): Promise<AuthSessionResponse> {
    return this.request<AuthSessionResponse>(
      "/api/auth/bootstrap-admin",
      {
        method: "POST",
        body: JSON.stringify(payload),
      },
      true
    );
  }

  async testQuickLogin(payload: {
    slot?: number;
    user_id?: string;
  }): Promise<AuthSessionResponse> {
    if (typeof window !== "undefined" && !isLocalhostRuntime()) {
      throw new Error("ปิดใช้งานบัญชีทดสอบบนเซิร์ฟเวอร์จริงแล้ว");
    }
    return this.request<AuthSessionResponse>(
      "/api/auth/test-login",
      {
        method: "POST",
        body: JSON.stringify(payload),
      },
      true
    );
  }

  async requestPhoneOtp(payload: {
    phone: string;
    purpose?: "auth" | "link" | "recover";
  }): Promise<OtpChallengeResponse> {
    return this.request<OtpChallengeResponse>(
      "/api/auth/otp/request",
      {
        method: "POST",
        body: JSON.stringify(payload),
      },
      payload.purpose !== "link"
    );
  }

  async verifyPhoneOtp(payload: {
    challenge_id: string;
    otp_code: string;
    display_name?: string;
    ref_code?: string;
  }): Promise<AuthSessionResponse> {
    return this.request<AuthSessionResponse>(
      "/api/auth/otp/verify",
      {
        method: "POST",
        body: JSON.stringify(payload),
      },
      true
    );
  }

  async linkPhone(payload: {
    challenge_id: string;
    otp_code: string;
    ref_code?: string;
    recovery_pin?: string;
  }): Promise<{ user: UserProfile }> {
    return this.request<{ user: UserProfile }>("/api/auth/link/phone", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async loginWithGoogle(payload: {
    id_token?: string;
    access_token?: string;
    display_name?: string;
    avatar_url?: string;
  }): Promise<AuthSessionResponse> {
    return this.request<AuthSessionResponse>(
      "/api/auth/google",
      {
        method: "POST",
        body: JSON.stringify(payload),
      },
      true
    );
  }

  async linkGoogle(payload: {
    id_token?: string;
    access_token?: string;
    display_name?: string;
    avatar_url?: string;
    recovery_pin?: string;
  }): Promise<{ user: UserProfile }> {
    return this.request<{ user: UserProfile }>("/api/auth/link/google", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async unlinkGoogle(): Promise<{ user: UserProfile }> {
    return this.request<{ user: UserProfile }>("/api/auth/link/google", {
      method: "DELETE",
    });
  }

  async setupRecoveryPin(payload: {
    recovery_pin: string;
    current_pin?: string;
    regenerate_codes?: boolean;
  }): Promise<{ user: UserProfile; backup_codes: string[] }> {
    return this.request<{ user: UserProfile; backup_codes: string[] }>(
      "/api/auth/recovery/setup",
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
  }

  async getRecoveryLogs(): Promise<AccountRecoveryLogItem[]> {
    const res = await this.request<{ logs: AccountRecoveryLogItem[] }>(
      "/api/auth/recovery/logs"
    );
    return Array.isArray(res.logs) ? res.logs : [];
  }

  async recoverChangePhone(payload: {
    method: "google" | "pin_or_code";
    google_id_token?: string;
    google_access_token?: string;
    google_oauth_state?: string;
    identifier?: string;
    recovery_secret?: string;
    new_phone_challenge_id: string;
    new_phone_otp_code: string;
    new_phone_ref_code?: string;
    revoke_other_sessions?: boolean;
  }): Promise<AuthSessionResponse & { recovered?: boolean }> {
    return this.request<AuthSessionResponse & { recovered?: boolean }>(
      "/api/auth/recover/change-phone",
      {
        method: "POST",
        body: JSON.stringify(payload),
      },
      true
    );
  }

  async recoverChangeGoogle(payload: {
    method: "phone_otp" | "pin_or_code";
    phone_challenge_id?: string;
    phone_otp_code?: string;
    phone_ref_code?: string;
    identifier?: string;
    recovery_secret?: string;
    new_google_id_token?: string;
    new_google_access_token?: string;
    new_google_oauth_state?: string;
    revoke_other_sessions?: boolean;
  }): Promise<AuthSessionResponse & { recovered?: boolean }> {
    return this.request<AuthSessionResponse & { recovered?: boolean }>(
      "/api/auth/recover/change-google",
      {
        method: "POST",
        body: JSON.stringify(payload),
      },
      true
    );
  }

  async pollGoogleOAuth(state: string): Promise<GooglePollResponse> {
    return this.request<GooglePollResponse>(
      `/api/auth/google/poll?state=${encodeURIComponent(state)}`,
      {},
      true
    );
  }

  getGoogleStartUrl(mode: "login" | "link" | "recover", state: string): string {
    const token = this.getToken();
    const tokenPart =
      mode === "link" && token ? `&token=${encodeURIComponent(token)}` : "";
    return `/api/auth/google/start?mode=${encodeURIComponent(mode)}&state=${encodeURIComponent(state)}${tokenPart}`;
  }

  async getMe(): Promise<UserProfile> {
    return this.request<UserProfile>("/api/auth/me");
  }

  async checkBcId(bcId: string): Promise<BcIdCheckResult> {
    return this.request<BcIdCheckResult>(
      `/api/auth/bc-id/check?bc_id=${encodeURIComponent(bcId)}`
    );
  }

  async updateProfile(payload: {
    display_name?: string;
    bc_id?: string;
    status_message?: string;
    department?: string;
    job_title?: string;
    allow_add_by_phone?: boolean;
    allow_add_by_id?: boolean;
    allow_add_by_email?: boolean;
    notify_preview?: boolean;
    notify_on_mention?: boolean;
    dnd_mode?: "off" | "1h" | "8h" | "until_8am";
    dnd_until?: string | null;
  }): Promise<UserProfile> {
    return this.request<UserProfile>("/api/users/me", {
      method: "PUT",
      body: JSON.stringify(payload),
    });
  }

  async updateMeSettings(payload: {
    display_name?: string;
    bc_id?: string;
    status_message?: string;
    department?: string;
    job_title?: string;
    allow_add_by_phone?: boolean;
    allow_add_by_id?: boolean;
    allow_add_by_email?: boolean;
    notify_preview?: boolean;
    notify_on_mention?: boolean;
    dnd_mode?: "off" | "1h" | "8h" | "until_8am";
    dnd_until?: string | null;
  }): Promise<UserProfile> {
    return this.updateProfile(payload);
  }

  async resetMyQr(): Promise<{ qr_token: string; user: UserProfile }> {
    return this.request<{ qr_token: string; user: UserProfile }>(
      "/api/users/me/reset-qr",
      { method: "POST" }
    );
  }

  async listFriends(): Promise<FriendItem[]> {
    return this.request<FriendItem[]>("/api/friends");
  }

  async updateFriendStatus(
    friendId: string,
    payload: { is_favorite?: boolean; is_blocked?: boolean; is_hidden?: boolean }
  ): Promise<FriendItem> {
    return this.request<FriendItem>(`/api/friends/${encodeURIComponent(friendId)}`, {
      method: "PUT",
      body: JSON.stringify(payload),
    });
  }

  async deleteFriend(friendId: string): Promise<{ ok: boolean }> {
    return this.request<{ ok: boolean }>(`/api/friends/${encodeURIComponent(friendId)}`, {
      method: "DELETE",
    });
  }

  async searchUsers(
    q: string,
    by?: "phone" | "email" | "id" | "qr"
  ): Promise<UserProfile[]> {
    const byPart = by ? `&by=${encodeURIComponent(by)}` : "";
    return this.request<UserProfile[]>(
      `/api/users/search?q=${encodeURIComponent(q)}${byPart}`
    );
  }

  async addFriend(payload: {
    query?: string;
    target_id?: string;
    phone?: string;
    bc_id?: string;
    email?: string;
    qr_token?: string;
  }): Promise<{ friend: FriendItem; conversation_id: string; conversation: Conversation }> {
    return this.request("/api/friends/add", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async listConversations(folder = "all"): Promise<Conversation[]> {
    return this.request<Conversation[]>(
      `/api/conversations?folder=${encodeURIComponent(folder)}`
    );
  }

  async openDirectConversation(friendId: string): Promise<Conversation> {
    return this.request<Conversation>("/api/conversations/direct", {
      method: "POST",
      body: JSON.stringify({ friend_id: friendId }),
    });
  }

  async createGroupConversation(payload: {
    name: string;
    folder?: string;
    member_ids: string[];
    avatar_url?: string;
  }): Promise<Conversation> {
    return this.request<Conversation>("/api/conversations/group", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async joinGroupByToken(inviteToken: string): Promise<Conversation> {
    return this.request<Conversation>("/api/conversations/join", {
      method: "POST",
      body: JSON.stringify({ invite_token: inviteToken }),
    });
  }

  async updateConversationMeta(
    convId: string,
    payload: {
      folder?: string;
      is_pinned?: boolean;
      is_muted?: boolean;
      mute_duration?: "off" | "1h" | "8h" | "until_8am" | "forever";
      muted_until?: string | null;
      is_archived?: boolean;
      name?: string;
      avatar_url?: string;
      ai_game_auto_invite?: boolean;
      ai_game_invite_cooldown_mins?: number;
    }
  ): Promise<Conversation> {
    return this.request<Conversation>(
      `/api/conversations/${encodeURIComponent(convId)}/meta`,
      {
        method: "PUT",
        body: JSON.stringify(payload),
      }
    );
  }

  async inviteGroupMembers(convId: string, memberIds: string[]): Promise<Conversation> {
    return this.request<Conversation>(
      `/api/conversations/${encodeURIComponent(convId)}/members`,
      {
        method: "POST",
        body: JSON.stringify({ member_ids: memberIds }),
      }
    );
  }

  async removeGroupMember(convId: string, memberId: string): Promise<Conversation> {
    return this.request<Conversation>(
      `/api/conversations/${encodeURIComponent(convId)}/members/${encodeURIComponent(memberId)}`,
      {
        method: "DELETE",
      }
    );
  }

  async pinMessage(convId: string, messageId: string | null): Promise<Conversation> {
    return this.request<Conversation>(
      `/api/conversations/${encodeURIComponent(convId)}/pin-message`,
      {
        method: "PUT",
        body: JSON.stringify({ message_id: messageId }),
      }
    );
  }

  async listMessages(convId: string): Promise<ChatMessage[]> {
    const raw = await this.request<Record<string, unknown>[]>(
      `/api/conversations/${encodeURIComponent(convId)}/messages`
    );
    return raw.map(normalizeMessage);
  }

  async sendMessage(
    convId: string,
    payload: {
      type?: string;
      content?: string;
      sticker_code?: string;
      attachment?: AttachmentInfo;
      card_payload?: RichCardPayload;
      location_data?: LocationData;
      contact_data?: ContactCardData;
      ladder_data?: LadderGameData;
      forwarded_from?: string;
      reply_to_id?: string;
      is_confidential?: boolean;
      confidential_pin?: string;
      expire_at?: string;
      priority?: string;
      task_status?: string;
      mentions?: string[];
      audio_duration_sec?: number;
    }
  ): Promise<ChatMessage> {
    const bodyPayload: Record<string, unknown> = {
      type: payload.type || "text",
      content: payload.content,
      sticker_code: payload.sticker_code,
      attachment: payload.attachment,
      reply_to_id: payload.reply_to_id,
      is_confidential: payload.is_confidential ?? false,
      confidential_pin: payload.confidential_pin,
      expire_at: payload.expire_at,
      priority: payload.priority,
      task_status: payload.task_status,
      mentions: payload.mentions,
      audio_duration_sec: payload.audio_duration_sec,
    };
    if (payload.card_payload) {
      bodyPayload.card_payload = payload.card_payload;
    }
    if (payload.location_data) {
      bodyPayload.location_data = payload.location_data;
    }
    if (payload.contact_data) {
      bodyPayload.contact_data = payload.contact_data;
    }
    if (payload.ladder_data) {
      bodyPayload.ladder_data = payload.ladder_data;
    }
    if (payload.forwarded_from) {
      bodyPayload.forwarded_from = payload.forwarded_from;
    }
    const raw = await this.request<Record<string, unknown>>(
      `/api/conversations/${encodeURIComponent(convId)}/messages`,
      {
        method: "POST",
        body: JSON.stringify(bodyPayload),
      }
    );
    return normalizeMessage(raw);
  }

  async markRead(convId: string): Promise<void> {
    await this.request(`/api/conversations/${encodeURIComponent(convId)}/read`, {
      method: "POST",
    });
  }

  async reactMessage(msgId: string, emoji: string): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}/react`,
      {
        method: "POST",
        body: JSON.stringify({ emoji }),
      }
    );
    return normalizeMessage(raw);
  }

  async deleteMessageForMe(msgId: string): Promise<void> {
    await this.request(`/api/messages/${encodeURIComponent(msgId)}/delete-for-me`, {
      method: "POST",
    });
  }

  async unsendMessage(msgId: string, hard = false): Promise<void> {
    await this.request(
      `/api/messages/${encodeURIComponent(msgId)}/unsend?hard=${hard ? "true" : "false"}`,
      {
        method: "DELETE",
      }
    );
  }

  async editMessage(msgId: string, content: string): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}`,
      {
        method: "PUT",
        body: JSON.stringify({ content }),
      }
    );
    return normalizeMessage(raw);
  }

  async forwardMessage(
    msgId: string,
    targetConversationIds: string[]
  ): Promise<{ forwarded_count: number; messages: ChatMessage[] }> {
    const raw = await this.request<{
      forwarded_count?: number;
      messages?: Record<string, unknown>[];
    }>(`/api/messages/${encodeURIComponent(msgId)}/forward`, {
      method: "POST",
      body: JSON.stringify({ target_conversation_ids: targetConversationIds }),
    });
    return {
      forwarded_count: Number(raw.forwarded_count ?? 0),
      messages: Array.isArray(raw.messages) ? raw.messages.map(normalizeMessage) : [],
    };
  }

  async ensureKeepConversation(): Promise<Conversation> {
    return this.request<Conversation>("/api/conversations/keep", {
      method: "POST",
    });
  }

  async saveMessageToKeep(msgId: string): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}/save-to-keep`,
      {
        method: "POST",
      }
    );
    return normalizeMessage(raw);
  }

  async clearConfidential(convId: string): Promise<{ purged_messages: number; purged_files: number }> {
    return this.request(`/api/conversations/${encodeURIComponent(convId)}/clear-confidential`, {
      method: "POST",
    });
  }

  async taskAction(msgId: string, action: "accept" | "done" | "reopen"): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}/task-action`,
      {
        method: "POST",
        body: JSON.stringify({ action }),
      }
    );
    return normalizeMessage(raw);
  }

  async approveCard(msgId: string, status: string, comment?: string): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}/approve-card`,
      {
        method: "POST",
        body: JSON.stringify({ status, comment }),
      }
    );
    return normalizeMessage(raw);
  }

  async createPoll(
    convId: string,
    payload: {
      question: string;
      options: string[];
      allow_multiple?: boolean;
      is_anonymous?: boolean;
    }
  ): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/conversations/${encodeURIComponent(convId)}/polls`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return normalizeMessage(raw);
  }

  async votePoll(msgId: string, optionIds: string[]): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}/vote`,
      {
        method: "POST",
        body: JSON.stringify({ option_ids: optionIds }),
      }
    );
    return normalizeMessage(raw);
  }

  async closePoll(msgId: string): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}/close-poll`,
      {
        method: "POST",
      }
    );
    return normalizeMessage(raw);
  }

  async listEvents(convId: string): Promise<ChatMessage[]> {
    const raw = await this.request<Record<string, unknown>[]>(
      `/api/conversations/${encodeURIComponent(convId)}/events`
    );
    return raw.map(normalizeMessage);
  }

  async createEvent(
    convId: string,
    payload: {
      title: string;
      description?: string;
      starts_at: string;
      ends_at?: string;
      location?: string;
    }
  ): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/conversations/${encodeURIComponent(convId)}/events`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return normalizeMessage(raw);
  }

  async rsvpEvent(
    msgId: string,
    status: "going" | "maybe" | "not_going"
  ): Promise<ChatMessage> {
    const raw = await this.request<Record<string, unknown>>(
      `/api/messages/${encodeURIComponent(msgId)}/rsvp`,
      {
        method: "POST",
        body: JSON.stringify({ status }),
      }
    );
    return normalizeMessage(raw);
  }

  async listAlbums(convId: string): Promise<AlbumItem[]> {
    return this.request<AlbumItem[]>(
      `/api/conversations/${encodeURIComponent(convId)}/albums`
    );
  }

  async createAlbum(
    convId: string,
    payload: { title: string; description?: string; photos?: AttachmentInfo[] }
  ): Promise<AlbumItem> {
    return this.request<AlbumItem>(
      `/api/conversations/${encodeURIComponent(convId)}/albums`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
  }

  async addAlbumPhotos(albumId: string, photos: AttachmentInfo[]): Promise<AlbumItem> {
    return this.request<AlbumItem>(
      `/api/albums/${encodeURIComponent(albumId)}/photos`,
      {
        method: "POST",
        body: JSON.stringify({ photos }),
      }
    );
  }

  async deleteAlbum(albumId: string): Promise<void> {
    await this.request(`/api/albums/${encodeURIComponent(albumId)}`, {
      method: "DELETE",
    });
  }

  async getVault(convId: string): Promise<VaultResponse> {
    return this.request<VaultResponse>(
      `/api/conversations/${encodeURIComponent(convId)}/vault`
    );
  }

  async searchMessages(q: string, conversationId?: string): Promise<ChatMessage[]> {
    const params = new URLSearchParams({ q });
    if (conversationId) params.set("conversation_id", conversationId);
    const raw = await this.request<Record<string, unknown>[]>(
      `/api/messages/search?${params.toString()}`
    );
    return raw.map(normalizeMessage);
  }

  async listNotes(conversationId?: string): Promise<NoteItem[]> {
    const q = conversationId
      ? `?conversation_id=${encodeURIComponent(conversationId)}`
      : "";
    return this.request<NoteItem[]>(`/api/notes${q}`);
  }

  async createNote(payload: {
    conversation_id?: string;
    title: string;
    content: string;
    attachments?: AttachmentInfo[];
    is_pinned?: boolean;
  }): Promise<NoteItem> {
    return this.request<NoteItem>("/api/notes", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async updateNote(
    noteId: string,
    payload: { title?: string; content?: string; is_pinned?: boolean }
  ): Promise<NoteItem> {
    return this.request<NoteItem>(`/api/notes/${encodeURIComponent(noteId)}`, {
      method: "PUT",
      body: JSON.stringify(payload),
    });
  }

  async deleteNote(noteId: string): Promise<void> {
    await this.request(`/api/notes/${encodeURIComponent(noteId)}`, {
      method: "DELETE",
    });
  }

  async likeNote(noteId: string): Promise<NoteItem> {
    return this.request<NoteItem>(`/api/notes/${encodeURIComponent(noteId)}/like`, {
      method: "POST",
    });
  }

  async commentNote(noteId: string, content: string): Promise<NoteItem> {
    return this.request<NoteItem>(`/api/notes/${encodeURIComponent(noteId)}/comments`, {
      method: "POST",
      body: JSON.stringify({ content }),
    });
  }

  async uploadFile(file: File | Blob, fileName?: string, conversationId?: string): Promise<AttachmentInfo> {
    const form = new FormData();
    form.append("file", file, fileName || (file instanceof File ? file.name : "recording.webm"));
    if (fileName) form.append("file_name", fileName);
    if (conversationId) form.append("conversation_id", conversationId);
    const res = await this.request<AttachmentInfo & { id: string }>("/api/upload", {
      method: "POST",
      body: form,
    });
    return {
      key: res.key,
      url: res.url,
      file_name: res.file_name,
      mime_type: res.mime_type,
      file_size: res.file_size,
    };
  }

  async summarizeChat(conversationId: string, postToChat = false): Promise<AiSummaryResult> {
    return this.request<AiSummaryResult>("/api/ai/summarize", {
      method: "POST",
      body: JSON.stringify({
        conversation_id: conversationId,
        post_to_chat: postToChat,
      }),
    });
  }

  async assistAi(payload: {
    conversation_id?: string;
    prompt?: string;
    mode: "polish" | "formal" | "suggest_reply" | "translate_en" | "action_plan";
  }): Promise<AiAssistResult> {
    return this.request<AiAssistResult>("/api/ai/assist", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async analyzeMessageWithAi(payload: {
    message_id: string;
    prompt?: string;
    post_to_chat?: boolean;
  }): Promise<AiAnalyzeMessageResult> {
    return this.request<AiAnalyzeMessageResult>("/api/ai/analyze-message", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async listMiniApps(): Promise<MiniAppItem[]> {
    return this.request<MiniAppItem[]>("/api/mini-apps");
  }

  async adminOverview(): Promise<AdminOverview> {
    return this.request<AdminOverview>("/api/admin/overview");
  }

  async adminUsers(): Promise<UserProfile[]> {
    return this.request<UserProfile[]>("/api/admin/users");
  }

  async adminUpdateUserRole(userId: string, role: "admin" | "user"): Promise<UserProfile> {
    return this.request<UserProfile>(
      `/api/admin/users/${encodeURIComponent(userId)}/role`,
      {
        method: "PUT",
        body: JSON.stringify({ role }),
      }
    );
  }

  async adminMiniApps(): Promise<MiniAppItem[]> {
    return this.request<MiniAppItem[]>("/api/admin/mini-apps");
  }

  async adminCreateMiniApp(payload: Partial<MiniAppItem> & { title: string }): Promise<MiniAppItem> {
    return this.request<MiniAppItem>("/api/admin/mini-apps", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  async adminUpdateMiniApp(appId: string, payload: Partial<MiniAppItem>): Promise<MiniAppItem> {
    return this.request<MiniAppItem>(`/api/admin/mini-apps/${encodeURIComponent(appId)}`, {
      method: "PUT",
      body: JSON.stringify(payload),
    });
  }

  async adminDeleteMiniApp(appId: string): Promise<void> {
    await this.request(`/api/admin/mini-apps/${encodeURIComponent(appId)}`, {
      method: "DELETE",
    });
  }

  async adminGetAiSettings(): Promise<AiSettings> {
    return this.request<AiSettings>("/api/admin/ai-settings");
  }

  async adminUpdateAiSettings(payload: {
    enabled?: boolean;
    system_prompt?: string;
    auto_reply_in_groups?: boolean;
    redact_confidential?: boolean;
    proactive_game_invites?: boolean;
  }): Promise<AiSettings> {
    return this.request<AiSettings>("/api/admin/ai-settings", {
      method: "PUT",
      body: JSON.stringify(payload),
    });
  }

  async adminTestAiConnection(): Promise<AiConnectionTestResult> {
    return this.request<AiConnectionTestResult>("/api/admin/ai-test", {
      method: "POST",
    });
  }

  async adminGetAuthSettings(): Promise<AdminAuthSettings> {
    return this.request<AdminAuthSettings>("/api/admin/auth-settings");
  }

  async adminUpdateAuthSettings(payload: {
    smsmkt_api_key?: string;
    smsmkt_secret_key?: string;
    smsmkt_project_key?: string;
    smsmkt_sender_name?: string;
    google_client_id?: string;
  }): Promise<AdminAuthSettings> {
    return this.request<AdminAuthSettings>("/api/admin/auth-settings", {
      method: "PUT",
      body: JSON.stringify(payload),
    });
  }

  async adminBroadcast(title: string, content: string): Promise<{ sent_count: number }> {
    return this.request("/api/admin/broadcast", {
      method: "POST",
      body: JSON.stringify({ title, content }),
    });
  }

  // ---- BCAiChatOA ----

  async discoverOas(q = "", category = ""): Promise<OaAccount[]> {
    const params = new URLSearchParams();
    if (q.trim()) params.set("q", q.trim());
    if (category.trim()) params.set("category", category.trim());
    const qs = params.toString();
    const list = await this.request<Array<OaAccount & Record<string, unknown>>>(
      `/api/oa/discover${qs ? `?${qs}` : ""}`
    );
    return list.map((o) => normalizeIdDoc(o));
  }

  async listMyOas(): Promise<OaAccount[]> {
    const list = await this.request<Array<OaAccount & Record<string, unknown>>>("/api/oa/mine");
    return list.map((o) => normalizeIdDoc(o));
  }

  async createOa(payload: {
    handle: string;
    display_name: string;
    category?: string;
    bio?: string;
    avatar_url?: string;
    theme_color?: string;
    greeting_message?: string;
    business_hours?: string;
    ai_enabled?: boolean;
    calls_enabled?: boolean;
    ai_knowledge_prompt?: string;
    rich_menu?: OaRichMenuItem[];
  }): Promise<OaAccount> {
    const res = await this.request<OaAccount & Record<string, unknown>>("/api/oa", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    return normalizeIdDoc(res);
  }

  async getOa(oaId: string): Promise<OaAccount> {
    const res = await this.request<OaAccount & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}`
    );
    return normalizeIdDoc(res);
  }

  async updateOa(
    oaId: string,
    payload: Partial<{
      display_name: string;
      category: string;
      bio: string;
      avatar_url: string;
      theme_color: string;
      greeting_message: string;
      business_hours: string;
      is_active: boolean;
      ai_enabled: boolean;
      calls_enabled: boolean;
      ai_knowledge_prompt: string;
      rich_menu: OaRichMenuItem[];
    }>
  ): Promise<OaAccount> {
    const res = await this.request<OaAccount & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}`,
      {
        method: "PUT",
        body: JSON.stringify(payload),
      }
    );
    return normalizeIdDoc(res);
  }

  async listOaAdmins(oaId: string): Promise<OaStaffMember[]> {
    return this.request<OaStaffMember[]>(`/api/oa/${encodeURIComponent(oaId)}/admins`);
  }

  async addOaAdmin(
    oaId: string,
    payload: {
      query?: string;
      user_id?: string;
      phone?: string;
      bc_id?: string;
      email?: string;
      role?: string;
    }
  ): Promise<OaAccount> {
    const res = await this.request<OaAccount & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/admins`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return normalizeIdDoc(res);
  }

  async updateOaAdminRole(
    oaId: string,
    userId: string,
    role: string
  ): Promise<OaAccount> {
    const res = await this.request<OaAccount & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/admins/${encodeURIComponent(userId)}`,
      {
        method: "PUT",
        body: JSON.stringify({ role }),
      }
    );
    return normalizeIdDoc(res);
  }

  async removeOaAdmin(oaId: string, userId: string): Promise<OaAccount> {
    const res = await this.request<OaAccount & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/admins/${encodeURIComponent(userId)}`,
      { method: "DELETE" }
    );
    return normalizeIdDoc(res);
  }

  async followOa(
    oaId: string
  ): Promise<{ oa: OaAccount; conversation: Conversation; conversation_id: string }> {
    const res = await this.request<{
      oa: OaAccount & Record<string, unknown>;
      conversation: Conversation;
      conversation_id: string;
    }>(`/api/oa/${encodeURIComponent(oaId)}/follow`, { method: "POST" });
    return {
      ...res,
      oa: normalizeIdDoc(res.oa),
    };
  }

  async unfollowOa(oaId: string): Promise<OaAccount> {
    const res = await this.request<OaAccount & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/unfollow`,
      { method: "POST" }
    );
    return normalizeIdDoc(res);
  }

  async getOaOverview(oaId: string): Promise<OaOverview> {
    return this.request<OaOverview>(`/api/oa/${encodeURIComponent(oaId)}/overview`);
  }

  async listOaChats(oaId: string, q = "", tag = ""): Promise<OaCustomerChat[]> {
    const params = new URLSearchParams();
    if (q.trim()) params.set("q", q.trim());
    if (tag.trim()) params.set("tag", tag.trim());
    const qs = params.toString();
    const rows = await this.request<Array<Record<string, unknown>>>(
      `/api/oa/${encodeURIComponent(oaId)}/chats${qs ? `?${qs}` : ""}`
    );
    return rows.map(normalizeOaCustomerChat);
  }

  async listOaChatMessages(oaId: string, convId: string): Promise<ChatMessage[]> {
    const rows = await this.request<Array<Record<string, unknown>>>(
      `/api/oa/${encodeURIComponent(oaId)}/chats/${encodeURIComponent(convId)}/messages`
    );
    return rows.map(normalizeMessage);
  }

  async sendOaChatMessage(
    oaId: string,
    convId: string,
    payload: {
      msg_type?: string;
      content?: string;
      sticker_code?: string;
      card_payload?: RichCardPayload;
      coupon_id?: string;
    }
  ): Promise<ChatMessage> {
    const row = await this.request<Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/chats/${encodeURIComponent(convId)}/messages`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return normalizeMessage(row);
  }

  async updateOaFollowerCrm(
    oaId: string,
    userId: string,
    payload: { tags?: string[]; crm_note?: string; ai_paused?: boolean }
  ): Promise<OaFollowerCrm> {
    const res = await this.request<OaFollowerCrm & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/followers/${encodeURIComponent(userId)}/crm`,
      {
        method: "PUT",
        body: JSON.stringify(payload),
      }
    );
    return normalizeIdDoc(res);
  }

  async listOaAutoReplies(oaId: string): Promise<OaAutoReplyRule[]> {
    const list = await this.request<Array<OaAutoReplyRule & Record<string, unknown>>>(
      `/api/oa/${encodeURIComponent(oaId)}/auto-replies`
    );
    return list.map((r) => normalizeIdDoc(r));
  }

  async createOaAutoReply(
    oaId: string,
    payload: {
      keyword: string;
      match_mode?: string;
      reply_text: string;
      card_payload?: RichCardPayload;
      is_active?: boolean;
    }
  ): Promise<OaAutoReplyRule> {
    const res = await this.request<OaAutoReplyRule & Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/auto-replies`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return normalizeIdDoc(res);
  }

  async deleteOaAutoReply(oaId: string, ruleId: string): Promise<void> {
    await this.request(
      `/api/oa/${encodeURIComponent(oaId)}/auto-replies/${encodeURIComponent(ruleId)}`,
      { method: "DELETE" }
    );
  }

  async listOaCoupons(oaId: string): Promise<OaCoupon[]> {
    const list = await this.request<Array<Record<string, unknown>>>(
      `/api/oa/${encodeURIComponent(oaId)}/coupons`
    );
    return list.map(normalizeOaCoupon);
  }

  async createOaCoupon(
    oaId: string,
    payload: {
      code: string;
      title: string;
      description?: string;
      discount_text?: string;
      expires_at?: string;
      max_claims?: number;
    }
  ): Promise<OaCoupon> {
    const res = await this.request<Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/coupons`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return normalizeOaCoupon(res);
  }

  async claimOaCoupon(oaId: string, couponId: string): Promise<OaCoupon> {
    const res = await this.request<Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/coupons/${encodeURIComponent(couponId)}/claim`,
      { method: "POST" }
    );
    return normalizeOaCoupon(res);
  }

  async redeemOaCoupon(
    oaId: string,
    couponId: string,
    userId?: string
  ): Promise<OaCoupon> {
    const res = await this.request<Record<string, unknown>>(
      `/api/oa/${encodeURIComponent(oaId)}/coupons/${encodeURIComponent(couponId)}/redeem`,
      {
        method: "POST",
        body: JSON.stringify(userId ? { user_id: userId } : {}),
      }
    );
    return normalizeOaCoupon(res);
  }

  async listOaBroadcasts(oaId: string): Promise<OaBroadcast[]> {
    const list = await this.request<Array<OaBroadcast & Record<string, unknown>>>(
      `/api/oa/${encodeURIComponent(oaId)}/broadcasts`
    );
    return list.map((b) => normalizeIdDoc(b));
  }

  async listOaCustomers(
    oaId: string,
    params: {
      q?: string;
      tags?: string[];
      following?: boolean;
      sort?: "recent" | "name" | "followed";
      page?: number;
      limit?: number;
    }
  ): Promise<OaCustomerList> {
    const qs = new URLSearchParams();
    if (params.q?.trim()) qs.set("q", params.q.trim());
    if (params.tags?.length) qs.set("tags", params.tags.join(","));
    if (params.following !== undefined) qs.set("following", String(params.following));
    if (params.sort) qs.set("sort", params.sort);
    qs.set("page", String(params.page ?? 1));
    qs.set("limit", String(params.limit ?? 30));
    const res = await this.request<{
      items?: Array<Record<string, unknown>>;
      total?: number;
      page?: number;
      limit?: number;
    }>(`/api/oa/${encodeURIComponent(oaId)}/customers?${qs.toString()}`);
    return {
      items: (res.items ?? []).map(normalizeOaCustomer),
      total: Number(res.total ?? 0),
      page: Number(res.page ?? 1),
      limit: Number(res.limit ?? 30),
    };
  }

  async getOaCustomer(oaId: string, userId: string): Promise<OaCustomerDetail> {
    const res = await this.request<Record<string, unknown> & OaCustomerDetail>(
      `/api/oa/${encodeURIComponent(oaId)}/customers/${encodeURIComponent(userId)}`
    );
    return {
      customer: normalizeOaCustomer((res.customer ?? {}) as unknown as Record<string, unknown>),
      coupons: res.coupons ?? [],
      broadcasts: (res.broadcasts ?? []).map((b) => ({
        ...b,
        target_tags: Array.isArray(b.target_tags) ? b.target_tags : [],
      })),
      stats: {
        coupons_claimed: Number(res.stats?.coupons_claimed ?? 0),
        coupons_redeemed: Number(res.stats?.coupons_redeemed ?? 0),
        broadcasts_received: Number(res.stats?.broadcasts_received ?? 0),
      },
    };
  }

  async getOaCustomerTags(oaId: string, tags: string[] = []): Promise<OaCustomerTagStats> {
    const qs = tags.length ? `?tags=${encodeURIComponent(tags.join(","))}` : "";
    const res = await this.request<Partial<OaCustomerTagStats>>(
      `/api/oa/${encodeURIComponent(oaId)}/customer-tags${qs}`
    );
    return {
      tags: res.tags ?? [],
      total_following: Number(res.total_following ?? 0),
      match_count: Number(res.match_count ?? 0),
    };
  }

  async createOaBroadcast(
    oaId: string,
    payload: {
      target_tags?: string[];
      msg_type?: string;
      content?: string;
      card_payload?: RichCardPayload;
      coupon_id?: string;
    }
  ): Promise<{ broadcast: OaBroadcast; recipient_count: number }> {
    const res = await this.request<{
      broadcast: OaBroadcast & Record<string, unknown>;
      recipient_count: number;
    }>(`/api/oa/${encodeURIComponent(oaId)}/broadcasts`, {
      method: "POST",
      body: JSON.stringify(payload),
    });
    return {
      ...res,
      broadcast: normalizeIdDoc(res.broadcast),
    };
  }

  // ---- Voice & Video Calls ----

  async startCall(
    conversationId: string,
    callType: "audio" | "video"
  ): Promise<CallJoinResponse> {
    return this.request<CallJoinResponse>("/api/calls/start", {
      method: "POST",
      body: JSON.stringify({ conversation_id: conversationId, call_type: callType }),
    });
  }

  async listActiveCalls(conversationId?: string): Promise<CallSession[]> {
    const qs = conversationId
      ? `?conversation_id=${encodeURIComponent(conversationId)}`
      : "";
    const res = await this.request<{ calls: CallSession[] }>(`/api/calls/active${qs}`);
    return res.calls || [];
  }

  async acceptCall(callId: string): Promise<CallJoinResponse> {
    return this.request<CallJoinResponse>(
      `/api/calls/${encodeURIComponent(callId)}/accept`,
      { method: "POST" }
    );
  }

  async getCallToken(callId: string): Promise<CallJoinResponse> {
    return this.request<CallJoinResponse>(
      `/api/calls/${encodeURIComponent(callId)}/token`
    );
  }

  async declineCall(callId: string): Promise<CallSession> {
    const res = await this.request<{ call: CallSession }>(
      `/api/calls/${encodeURIComponent(callId)}/decline`,
      { method: "POST" }
    );
    return res.call;
  }

  async hangupCall(callId: string): Promise<CallSession> {
    const res = await this.request<{ call: CallSession }>(
      `/api/calls/${encodeURIComponent(callId)}/hangup`,
      { method: "POST" }
    );
    return res.call;
  }

  // ---- BC Game Center (100-Game Solo/Group Catalog & 5 Engines) ----

  private normalizeGameSession(raw: GameSession & Record<string, unknown>): GameSession {
    const base = normalizeIdDoc(raw);
    return {
      ...base,
      players: Array.isArray(base.players) ? base.players : [],
      winner_names: Array.isArray(base.winner_names) ? base.winner_names : [],
      round_index: Number(base.round_index ?? 0),
      total_rounds: Number(base.total_rounds ?? 1),
      round_revealed: Boolean(base.round_revealed),
      proactive: Boolean(base.proactive),
      host_message: String(base.host_message ?? ""),
      current_question: base.current_question
        ? {
            ...base.current_question,
            options: Array.isArray(base.current_question.options)
              ? base.current_question.options
              : [],
            choice_counts: Array.isArray(base.current_question.choice_counts)
              ? base.current_question.choice_counts
              : [],
          }
        : null,
      undercover: base.undercover
        ? {
            ...base.undercover,
            clues: Array.isArray(base.undercover.clues) ? base.undercover.clues : [],
            vote_counts:
              base.undercover.vote_counts && typeof base.undercover.vote_counts === "object"
                ? base.undercover.vote_counts
                : {},
          }
        : null,
      hint_race: base.hint_race
        ? {
            ...base.hint_race,
            revealed_hints: Array.isArray(base.hint_race.revealed_hints)
              ? base.hint_race.revealed_hints
              : [],
            my_guesses: Array.isArray(base.hint_race.my_guesses)
              ? base.hint_race.my_guesses
              : [],
            total_hints: Number(base.hint_race.total_hints ?? 5),
            hint_level: Number(base.hint_race.hint_level ?? 1),
          }
        : null,
      party_vote: base.party_vote
        ? {
            ...base.party_vote,
            options: Array.isArray(base.party_vote.options) ? base.party_vote.options : [],
            choice_counts: Array.isArray(base.party_vote.choice_counts)
              ? base.party_vote.choice_counts
              : [],
          }
        : null,
      creative_challenge: base.creative_challenge
        ? {
            ...base.creative_challenge,
            entries: Array.isArray(base.creative_challenge.entries)
              ? base.creative_challenge.entries
              : [],
            requires_image: Boolean(base.creative_challenge.requires_image),
            my_submitted: Boolean(base.creative_challenge.my_submitted),
          }
        : null,
    };
  }

  async listGameCatalog(params?: {
    mode?: "all" | "solo" | "group";
    category?: string;
    q?: string;
  }): Promise<GameCatalogResponse> {
    const qs = new URLSearchParams();
    if (params?.mode && params.mode !== "all") qs.set("mode", params.mode);
    if (params?.category?.trim()) qs.set("category", params.category.trim());
    if (params?.q?.trim()) qs.set("q", params.q.trim());
    const query = qs.toString();
    const res = await this.request<{
      total?: number;
      categories?: string[];
      games?: GameCatalogItem[];
    }>(`/api/games/catalog${query ? `?${query}` : ""}`);
    const games = Array.isArray(res.games) ? res.games : [];
    return {
      total: Number(res.total ?? games.length),
      categories: Array.isArray(res.categories) ? res.categories : [],
      games,
    };
  }

  async getActiveGame(convId: string): Promise<ActiveGameState> {
    const res = await this.request<{
      active_game?: (GameSession & Record<string, unknown>) | null;
      recent_games?: Array<GameSummary & Record<string, unknown>>;
      ai_game_auto_invite?: boolean;
      ai_game_invite_cooldown_mins?: number;
      proactive_enabled_globally?: boolean;
    }>(`/api/conversations/${encodeURIComponent(convId)}/games/active`);
    return {
      active_game: res.active_game ? this.normalizeGameSession(res.active_game) : null,
      recent_games: Array.isArray(res.recent_games)
        ? res.recent_games.map((g) => ({
            ...normalizeIdDoc(g),
            winner_names: Array.isArray(g.winner_names) ? g.winner_names : [],
            player_count: Number(g.player_count ?? 0),
          }))
        : [],
      ai_game_auto_invite: Boolean(res.ai_game_auto_invite),
      ai_game_invite_cooldown_mins: Number(res.ai_game_invite_cooldown_mins ?? 30),
      proactive_enabled_globally: res.proactive_enabled_globally !== false,
    };
  }

  async createGame(
    convId: string,
    payload: {
      game_type?: string;
      game_id?: string;
      topic?: string;
      question_count?: number;
      auto_start?: boolean;
    }
  ): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/conversations/${encodeURIComponent(convId)}/games`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return this.normalizeGameSession(res);
  }

  async startRandomGame(
    convId: string,
    payload: {
      mode?: "auto" | "solo" | "group";
      category?: string;
      auto_start?: boolean;
    } = {}
  ): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/conversations/${encodeURIComponent(convId)}/games/random`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return this.normalizeGameSession(res);
  }

  async triggerProactiveGameInvite(
    convId: string,
    payload: { force?: boolean; game_type?: string } = {}
  ): Promise<ProactiveGameInviteResult> {
    const res = await this.request<{
      invited?: boolean;
      reason?: string | null;
      game?: (GameSession & Record<string, unknown>) | null;
      message?: Record<string, unknown> | null;
    }>(`/api/conversations/${encodeURIComponent(convId)}/games/proactive-invite`, {
      method: "POST",
      body: JSON.stringify(payload),
    });
    return {
      invited: Boolean(res.invited),
      reason: res.reason ?? null,
      game: res.game ? this.normalizeGameSession(res.game) : null,
      message: res.message ? normalizeMessage(res.message) : null,
    };
  }

  async getGame(gameId: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}`
    );
    return this.normalizeGameSession(res);
  }

  async joinGame(gameId: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/join`,
      { method: "POST" }
    );
    return this.normalizeGameSession(res);
  }

  async startGame(gameId: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/start`,
      { method: "POST" }
    );
    return this.normalizeGameSession(res);
  }

  async submitQuizAnswer(gameId: string, choiceIndex: number): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/answer`,
      {
        method: "POST",
        body: JSON.stringify({ choice_index: choiceIndex }),
      }
    );
    return this.normalizeGameSession(res);
  }

  async submitUndercoverClue(gameId: string, clue: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/clue`,
      {
        method: "POST",
        body: JSON.stringify({ clue }),
      }
    );
    return this.normalizeGameSession(res);
  }

  async submitUndercoverVote(gameId: string, targetUserId: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/vote`,
      {
        method: "POST",
        body: JSON.stringify({ target_user_id: targetUserId }),
      }
    );
    return this.normalizeGameSession(res);
  }

  async submitHintGuess(gameId: string, guess: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/guess`,
      {
        method: "POST",
        body: JSON.stringify({ guess }),
      }
    );
    return this.normalizeGameSession(res);
  }

  async submitCreativeEntry(
    gameId: string,
    payload: { text: string; image_message_id?: string }
  ): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/submit`,
      {
        method: "POST",
        body: JSON.stringify(payload),
      }
    );
    return this.normalizeGameSession(res);
  }

  async advanceGame(gameId: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/next`,
      { method: "POST" }
    );
    return this.normalizeGameSession(res);
  }

  async cancelGame(gameId: string): Promise<GameSession> {
    const res = await this.request<GameSession & Record<string, unknown>>(
      `/api/games/${encodeURIComponent(gameId)}/cancel`,
      { method: "POST" }
    );
    return this.normalizeGameSession(res);
  }
}

export const api = new ApiClient();

export function formatCallDuration(sec?: number | null): string {
  const s = Math.max(0, Math.floor(Number(sec || 0)));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const rem = s % 60;
  const mm = String(m).padStart(2, "0");
  const ss = String(rem).padStart(2, "0");
  if (h > 0) return `${h}:${mm}:${ss}`;
  return `${mm}:${ss}`;
}

export function formatThaiTime(iso?: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  if (sameDay) return `${hh}:${mm} น.`;
  const dd = String(d.getDate()).padStart(2, "0");
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  return `${dd}/${mo} ${hh}:${mm}`;
}

const THAI_WEEKDAYS_SHORT = ["อา.", "จ.", "อ.", "พ.", "พฤ.", "ศ.", "ส."];
const THAI_MONTHS_SHORT = [
  "ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.",
  "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค.",
];

/** คีย์วันตามเวลาเครื่อง ใช้เทียบว่าข้อความสองอันอยู่คนละวันหรือไม่ ("" = วันที่อ่านไม่ได้) */
export function localDayKey(iso?: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

/** ป้ายคั่นวันในห้องแชท: วันนี้ / เมื่อวาน / ส. 14 พ.ย. (ต่างปีต่อท้ายด้วย พ.ศ.) */
export function formatThaiDay(iso?: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const now = new Date();
  const startOfDay = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diffDays = Math.round((startOfDay(now) - startOfDay(d)) / 86_400_000);
  if (diffDays === 0) return "วันนี้";
  if (diffDays === 1) return "เมื่อวาน";
  const label = `${THAI_WEEKDAYS_SHORT[d.getDay()]} ${d.getDate()} ${THAI_MONTHS_SHORT[d.getMonth()]}`;
  return d.getFullYear() === now.getFullYear() ? label : `${label} ${d.getFullYear() + 543}`;
}

export function formatFileSize(bytes: number): string {
  if (!bytes || bytes <= 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  return `${(kb / 1024).toFixed(2)} MB`;
}

export function isTimestampFuture(iso?: string | null): boolean {
  if (!iso) return false;
  const ts = Date.parse(iso);
  return Number.isFinite(ts) && ts > Date.now();
}

export function isConversationMutedNow(
  conv?: Pick<Conversation, "is_muted" | "muted_until"> | null
): boolean {
  if (!conv) return false;
  if (conv.muted_until) {
    return isTimestampFuture(conv.muted_until);
  }
  return Boolean(conv.is_muted);
}

export function isDndActiveNow(user?: Pick<UserProfile, "dnd_until"> | null): boolean {
  return isTimestampFuture(user?.dnd_until);
}

export function formatThaiUntil(iso?: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  if (sameDay) return `ถึง ${hh}:${mm} น.`;
  const dd = String(d.getDate()).padStart(2, "0");
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  return `ถึง ${dd}/${mo} ${hh}:${mm} น.`;
}

export function makeOAuthState(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `st_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

export interface GoogleOAuthPopupResult {
  status?: string;
  token?: string;
  user?: UserProfile;
  oauth_state?: string;
  email?: string;
  error?: string;
}

export function openGoogleOAuthPopup(opts: {
  mode: "login" | "link" | "recover";
  windowName?: string;
  onResult: (data: GoogleOAuthPopupResult, state: string) => void;
  onError: (message: string) => void;
  onCancel?: () => void;
}): (() => void) | null {
  const state = makeOAuthState();
  const startUrl = api.getGoogleStartUrl(opts.mode, state);
  const popup = window.open(
    startUrl,
    opts.windowName || `bcaichat_google_${opts.mode}`,
    "width=500,height=640,menubar=no,toolbar=no"
  );
  if (!popup) {
    opts.onError("เบราว์เซอร์บล็อกหน้าต่างป๊อปอัป กรุณาอนุญาตป๊อปอัปแล้วลองอีกครั้ง");
    return null;
  }

  let settled = false;
  const cleanup = (notifyCancel = false) => {
    if (settled) return;
    settled = true;
    window.removeEventListener("message", onMessage);
    clearInterval(pollTimer);
    try {
      if (!popup.closed) popup.close();
    } catch {
      // Ignore cross-origin close error
    }
    if (notifyCancel) opts.onCancel?.();
  };

  const handleData = (data: GoogleOAuthPopupResult) => {
    if (settled) return;
    if (data.error) {
      cleanup(false);
      opts.onError(data.error);
      return;
    }
    if (
      data.token ||
      data.user ||
      data.status === "verified_for_recovery"
    ) {
      cleanup(false);
      opts.onResult({ ...data, oauth_state: data.oauth_state || state }, state);
    }
  };

  const onMessage = (ev: MessageEvent) => {
    const payload = ev.data as
      | { type?: string; state?: string; data?: GoogleOAuthPopupResult }
      | undefined;
    if (!payload || payload.type !== "bc_google_oauth_done") return;
    if (payload.state && payload.state !== state) return;
    if (payload.data) handleData(payload.data);
  };

  window.addEventListener("message", onMessage);

  const checkPoll = async (): Promise<boolean> => {
    const res = await api.pollGoogleOAuth(state);
    if (settled) return true;
    if (res.status === "completed" || res.status === "verified_for_recovery") {
      handleData({
        status: res.status,
        token: res.token,
        user: res.user,
        oauth_state: res.oauth_state || state,
        email: res.email,
      });
      return true;
    }
    if (res.status === "error") {
      handleData({ error: res.error || "ดำเนินการผ่าน Gmail ไม่สำเร็จ" });
      return true;
    }
    return false;
  };

  const pollTimer = setInterval(async () => {
    if (settled) return;
    try {
      if (await checkPoll()) return;
    } catch {
      // Continue polling while OAuth completes
    }
    if (popup.closed && !settled) {
      setTimeout(async () => {
        if (settled) return;
        try {
          if (await checkPoll()) return;
        } catch {
          // Ignore
        }
        cleanup(true);
      }, 400);
    }
  }, 1500);

  return () => cleanup(true);
}
