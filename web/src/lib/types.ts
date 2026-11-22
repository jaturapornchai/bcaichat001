export type ThemePresetId =
  | "ban_chiang"
  | "silk_amber"
  | "indigo_kram"
  | "jade_celadon"
  | "lotus_rose"
  | "spice_cinnamon"
  | "royal_amethyst";

export type RoomToneId = "ban_chiang_cream" | "terracotta_night" | "ivory_white";

export interface UserProfile {
  id: string;
  email: string;
  phone?: string;
  phone_verified?: boolean;
  email_verified?: boolean;
  has_google_linked?: boolean;
  is_oa_bot?: boolean;
  oa_id?: string | null;
  display_name: string;
  bc_id: string;
  avatar_url: string;
  status_message: string;
  qr_token: string;
  role: string;
  department: string;
  job_title: string;
  allow_add_by_phone?: boolean;
  allow_add_by_id?: boolean;
  allow_add_by_email?: boolean;
  notify_preview?: boolean;
  notify_on_mention?: boolean;
  dnd_until?: string | null;
  has_recovery_pin?: boolean;
  recovery_codes_remaining?: number;
  last_recovered_at?: string | null;
  created_at?: string;
}

export interface FriendItem extends UserProfile {
  is_favorite: boolean;
  is_blocked: boolean;
  is_hidden: boolean;
}

export interface AttachmentInfo {
  key: string;
  url: string;
  file_name: string;
  mime_type: string;
  file_size: number;
}

export interface ReplyInfo {
  id: string;
  sender_name: string;
  content: string;
}

export interface PollOption {
  id: string;
  text: string;
  voter_ids: string[];
}

export interface PollData {
  question: string;
  options: PollOption[];
  allow_multiple: boolean;
  is_anonymous: boolean;
  is_closed: boolean;
  closed_at?: string | null;
}

export interface EventData {
  title: string;
  description: string;
  starts_at: string;
  ends_at?: string | null;
  location: string;
  going_ids: string[];
  maybe_ids: string[];
  not_going_ids: string[];
}

export interface RichCardPayload {
  kind?: string;
  app_code?: string;
  title?: string;
  color_hex?: string;
  heading?: string;
  subtitle?: string;
  highlight_value?: string;
  status?: string;
  status_label?: string;
  approved_by?: string;
  approved_at?: string;
  approval_comment?: string;
  action_url?: string;
  game_id?: string;
  game_type?: string;
  catalog_id?: string;
  emoji?: string;
  topic?: string;
  play_mode?: string;
  proactive?: boolean;
  host_message?: string;
  [key: string]: unknown;
}

export interface LocationData {
  latitude: number;
  longitude: number;
  title?: string;
  address?: string;
  map_url?: string;
}

export interface ContactCardData {
  user_id: string;
  display_name: string;
  bc_id?: string;
  avatar_url?: string;
  status_message?: string;
}

export interface LadderEntry {
  player: string;
  result: string;
}

export interface LadderGameData {
  title: string;
  entries: LadderEntry[];
}

export interface ChatMessage {
  id: string;
  conversation_id: string;
  sender_id: string;
  sender_name: string;
  sender_avatar: string;
  type: string;
  content: string;
  sticker_code?: string | null;
  attachment?: AttachmentInfo | null;
  card_payload?: RichCardPayload | null;
  reply_to?: ReplyInfo | null;
  read_by: string[];
  read_count: number;
  is_unsent: boolean;
  is_confidential: boolean;
  confidential_pin?: string | null;
  expire_at?: string | null;
  priority: string;
  task_status?: string | null;
  accepted_by?: string | null;
  accepted_at?: string | null;
  reactions: Record<string, string[]>;
  mentions: string[];
  audio_duration_sec?: number | null;
  poll?: PollData | null;
  event_data?: EventData | null;
  location_data?: LocationData | null;
  contact_data?: ContactCardData | null;
  ladder_data?: LadderGameData | null;
  edited_at?: string | null;
  forwarded_from?: string | null;
  created_at: string;
}

export interface PinnedMessageSummary {
  id: string;
  sender_id: string;
  sender_name: string;
  type: string;
  content: string;
  created_at: string;
}

export interface LastMessageSummary {
  id: string;
  sender_id: string;
  sender_name: string;
  type: string;
  content: string;
  created_at: string;
  read_count: number;
}

export interface OaRichMenuItem {
  id: string;
  label: string;
  subtitle: string;
  action_type: "keyword" | "coupon" | "url" | "ai_prompt" | string;
  action_value: string;
  icon: string;
}

export interface ConversationMember {
  id: string;
  email: string;
  phone?: string;
  is_oa_bot?: boolean;
  oa_id?: string | null;
  display_name: string;
  bc_id: string;
  avatar_url: string;
  status_message: string;
  role: string;
  department: string;
  job_title: string;
}

export interface Conversation {
  id: string;
  type: "direct" | "group" | "oa" | "official" | "keep" | string;
  name: string;
  avatar_url: string;
  folder: string;
  is_pinned: boolean;
  is_muted: boolean;
  muted_until?: string | null;
  is_archived: boolean;
  is_blocked_by_me?: boolean;
  ai_game_auto_invite?: boolean;
  ai_game_invite_cooldown_mins?: number;
  invite_token: string;
  admin_ids: string[];
  member_ids?: string[];
  oa_id?: string | null;
  oa_handle?: string | null;
  rich_menu?: OaRichMenuItem[];
  pinned_message?: PinnedMessageSummary | null;
  unread_count: number;
  member_count: number;
  members: ConversationMember[];
  last_message?: LastMessageSummary | null;
  created_at: string;
  updated_at: string;
}

export interface NoteComment {
  id: string;
  user_id: string;
  user_name: string;
  content: string;
  created_at: string;
}

export interface NoteItem {
  id: string;
  conversation_id?: string | null;
  owner_id: string;
  owner_name: string;
  title: string;
  content: string;
  attachments: AttachmentInfo[];
  is_pinned: boolean;
  liked_by: string[];
  comments: NoteComment[];
  created_at: string;
  updated_at: string;
}

export interface AlbumItem {
  id: string;
  conversation_id: string;
  title: string;
  description: string;
  photos: AttachmentInfo[];
  created_by: string;
  created_by_name: string;
  created_at: string;
  updated_at: string;
}

export interface VaultFileItem {
  id: string;
  message_id: string;
  sender_id: string;
  sender_name: string;
  key: string;
  url: string;
  file_name: string;
  mime_type: string;
  file_size: number;
  is_confidential: boolean;
  created_at: string;
}

export interface VaultLinkItem {
  id: string;
  message_id: string;
  sender_id: string;
  sender_name: string;
  url: string;
  content: string;
  created_at: string;
}

export interface VaultResponse {
  images: VaultFileItem[];
  files: VaultFileItem[];
  links: VaultLinkItem[];
}

export interface MiniAppItem {
  id: string;
  app_code: string;
  title: string;
  subtitle: string;
  category: string;
  icon_name: string;
  color_hex: string;
  entry_url: string;
  is_active: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export interface AdminOverview {
  total_users: number;
  total_conversations: number;
  total_messages: number;
  total_files: number;
  total_storage_bytes: number;
  total_mini_apps: number;
  recent_files: Array<{
    id: string;
    key: string;
    url: string;
    file_name: string;
    mime_type: string;
    file_size: number;
    uploader_name: string;
    created_at: string;
  }>;
}

export interface AiSettings {
  enabled: boolean;
  managed_by_system: boolean;
  system_ready: boolean;
  system_prompt: string;
  auto_reply_in_groups: boolean;
  redact_confidential: boolean;
  proactive_game_invites?: boolean;
  updated_at: string;
}

export interface AiConnectionTestResult {
  ok: boolean;
  latency_ms: number;
  reply?: string | null;
  error?: string | null;
}

export interface AiAnalyzeMessageResult {
  message_id: string;
  conversation_id: string;
  file_name: string;
  mime_type: string;
  media_kind: "image" | "document" | string;
  analysis: string;
  extracted_preview?: string | null;
  model: string;
  live_api: boolean;
  posted_message_id?: string | null;
}

export interface AiSummaryResult {
  conversation_id: string;
  conversation_name: string;
  summary: string;
  action_items: string[];
  decisions: string[];
  participants: string[];
  message_count: number;
  model: string;
  live_api: boolean;
}

export interface AiAssistResult {
  mode: string;
  result: string;
  suggestions: string[];
  model: string;
  live_api: boolean;
}

export interface QuickTestUserItem {
  slot: number;
  id: string;
  display_name: string;
  bc_id: string;
  phone: string;
  role: string;
  badge: string;
}

export interface AuthConfig {
  phone_otp_enabled: boolean;
  phone_otp_ready: boolean;
  google_enabled: boolean;
  google_client_id: string;
  admin_bootstrap_enabled: boolean;
  livekit_enabled: boolean;
  demo_enabled: boolean;
  test_users_enabled?: boolean;
  test_users?: QuickTestUserItem[];
}

export interface OtpChallengeResponse {
  challenge_id: string;
  ref_code: string;
  masked_phone: string;
  expires_in_sec: number;
}

export interface AuthSessionResponse {
  token: string;
  user: UserProfile;
  is_new_user?: boolean;
}

export interface GooglePollResponse {
  status:
    | "pending"
    | "completed"
    | "verified_for_recovery"
    | "error"
    | "not_found"
    | string;
  mode?: string;
  token?: string;
  user?: UserProfile;
  is_new_user?: boolean;
  oauth_state?: string;
  email?: string;
  error?: string;
}

export interface AccountRecoveryLogItem {
  id: string;
  user_id: string;
  action: string;
  method: string;
  detail_masked: string;
  created_at: string;
}

export interface BcIdCheckResult {
  valid: boolean;
  available: boolean;
  is_current?: boolean;
  normalized_bc_id: string;
  message: string;
}

export interface AdminAuthSettings {
  smsmkt_has_keys: boolean;
  smsmkt_masked_api_key: string;
  smsmkt_masked_secret_key: string;
  smsmkt_project_key: string;
  smsmkt_sender_name?: string;
  phone_otp_ready: boolean;
  google_client_id: string;
  google_enabled: boolean;
  credit_info?: unknown;
  credit_error?: string | null;
  updated_at: string;
}

export interface OaStaffMember {
  user_id: string;
  display_name: string;
  bc_id: string;
  phone: string;
  email: string;
  avatar_url: string;
  role: "owner" | "admin" | "agent" | "marketer" | string;
}

export interface OaAccount {
  id: string;
  handle: string;
  display_name: string;
  category: string;
  bio: string;
  avatar_url: string;
  theme_color: string;
  greeting_message: string;
  business_hours: string;
  owner_id: string;
  admin_ids: string[];
  my_role?: "owner" | "admin" | "agent" | "marketer" | string | null;
  staff_roles?: Record<string, string>;
  bot_user_id: string;
  is_active: boolean;
  is_verified: boolean;
  ai_enabled: boolean;
  calls_enabled: boolean;
  ai_knowledge_prompt: string;
  rich_menu: OaRichMenuItem[];
  follower_count: number;
  is_following: boolean;
  conversation_id?: string | null;
  created_at: string;
  updated_at: string;
}

export interface OaOverview {
  oa: OaAccount;
  stats: {
    follower_count: number;
    active_chats_count: number;
    auto_reply_count: number;
    active_coupon_count: number;
    total_coupon_claims: number;
    broadcast_count: number;
    tags: Array<{ tag: string; count: number }>;
  };
}

export interface OaCustomerChat {
  conversation_id: string;
  oa_id: string;
  follower_user_id: string;
  follower_name: string;
  follower_bc_id: string;
  follower_phone: string;
  follower_email?: string;
  follower_avatar: string;
  tags: string[];
  crm_note: string;
  ai_paused: boolean;
  unread_for_oa?: number;
  last_message?: LastMessageSummary | null;
  updated_at: string;
}

export interface OaFollowerCrm {
  id: string;
  oa_id: string;
  user_id: string;
  conversation_id: string;
  tags: string[];
  crm_note: string;
  ai_paused: boolean;
  followed_at: string;
  updated_at: string;
}

export interface OaAutoReplyRule {
  id: string;
  oa_id: string;
  keyword: string;
  match_mode: "contains" | "exact" | "starts_with" | string;
  reply_text: string;
  card_payload?: RichCardPayload | null;
  is_active: boolean;
  hit_count: number;
  created_at: string;
}

export interface OaCoupon {
  id: string;
  oa_id: string;
  code: string;
  title: string;
  description: string;
  discount_text: string;
  expires_at?: string | null;
  max_claims: number;
  claimed_by: string[];
  redeemed_by: string[];
  claimed_count: number;
  redeemed_count: number;
  is_claimed: boolean;
  is_redeemed: boolean;
  is_active: boolean;
  created_at: string;
}

export interface OaCustomer {
  conversation_id: string;
  oa_id: string;
  customer_id: string;
  customer_name: string;
  customer_avatar: string;
  customer_bc_id: string;
  customer_phone: string;
  customer_email: string;
  tags: string[];
  crm_note: string;
  ai_paused: boolean;
  unread_for_oa: number;
  last_message?: LastMessageSummary | null;
  updated_at: string;
  is_following: boolean;
  followed_at: string;
}

export interface OaCustomerList {
  items: OaCustomer[];
  total: number;
  page: number;
  limit: number;
}

export interface OaCustomerDetail {
  customer: OaCustomer;
  coupons: Array<{
    id: string;
    code: string;
    title: string;
    discount_text: string;
    expires_at?: string | null;
    is_redeemed: boolean;
    is_active: boolean;
  }>;
  broadcasts: Array<{
    id: string;
    msg_type: string;
    content: string;
    target_tags: string[];
    coupon_id?: string | null;
    created_at: string;
  }>;
  stats: {
    coupons_claimed: number;
    coupons_redeemed: number;
    broadcasts_received: number;
  };
}

export interface OaCustomerTagStats {
  tags: Array<{ tag: string; count: number }>;
  total_following: number;
  match_count: number;
}

export interface OaBroadcast {
  id: string;
  oa_id: string;
  target_tag: string;
  target_tags?: string[];
  msg_type: string;
  content: string;
  recipient_count: number;
  created_by: string;
  created_at: string;
}

export interface CallParticipantState {
  user_id: string;
  display_name: string;
  avatar_url: string;
  state: string;
  muted_audio: boolean;
  video_enabled: boolean;
  updated_at: string;
}

export interface CallSession {
  id: string;
  conversation_id: string;
  room_name: string;
  call_type: "audio" | "video" | string;
  status: "ringing" | "active" | "ended" | "missed" | "declined" | string;
  initiator_id: string;
  initiator_name: string;
  initiator_avatar: string;
  oa_id?: string | null;
  target_user_ids: string[];
  participants: CallParticipantState[];
  started_at: string;
  answered_at?: string | null;
  ended_at?: string | null;
  duration_sec: number;
  end_reason?: string | null;
}

export interface CallJoinResponse {
  call: CallSession;
  livekit_url: string;
  token: string;
}

export type GameEngineType =
  | "quiz"
  | "undercover"
  | "hint_race"
  | "party_vote"
  | "creative_challenge"
  | string;

export type GamePlayMode = "solo" | "group" | "both" | string;
export type GameStatus = "lobby" | "playing" | "finished" | "cancelled" | string;

export interface GameCatalogItem {
  number: number;
  id: string;
  name: string;
  tagline: string;
  emoji: string;
  category: string;
  play_mode: GamePlayMode;
  min_players: number;
  engine: GameEngineType;
  ai_topic_hint?: string;
  default_rounds: number;
}

export interface GameCatalogResponse {
  total: number;
  categories: string[];
  games: GameCatalogItem[];
}

export interface GamePlayer {
  user_id: string;
  display_name: string;
  avatar_url: string;
  score: number;
  answered: boolean;
  voted: boolean;
  clue?: string | null;
}

export interface QuizQuestionView {
  question: string;
  options: string[];
  correct_index?: number | null;
  explanation?: string | null;
  my_choice?: number | null;
  choice_counts: number[];
}

export interface UndercoverClue {
  user_id: string;
  display_name: string;
  clue: string;
}

export interface UndercoverView {
  category: string;
  my_secret_word?: string | null;
  my_clue?: string | null;
  my_vote?: string | null;
  clues: UndercoverClue[];
  vote_counts: Record<string, number>;
  revealed_spy_id?: string | null;
  revealed_spy_name?: string | null;
  revealed_civilian_word?: string | null;
  revealed_spy_word?: string | null;
  winner_side?: "civilians" | "spy" | string | null;
}

export interface HintRaceView {
  revealed_hints: string[];
  total_hints: number;
  hint_level: number;
  solved_by_name?: string | null;
  revealed_answer?: string | null;
  my_guesses: string[];
}

export interface PartyVoteView {
  prompt: string;
  options: string[];
  my_choice?: number | null;
  choice_counts: number[];
  commentary?: string | null;
}

export interface CreativeEntry {
  user_id: string;
  display_name: string;
  text: string;
  image_url?: string | null;
  score?: number | null;
  judge_comment?: string | null;
}

export interface CreativeChallengeView {
  prompt: string;
  tip: string;
  requires_image: boolean;
  my_submitted: boolean;
  entries: CreativeEntry[];
}

export interface GameSession {
  id: string;
  conversation_id: string;
  game_type: GameEngineType;
  catalog_id?: string;
  emoji?: string;
  category?: string;
  play_mode?: GamePlayMode;
  tagline?: string;
  title: string;
  topic: string;
  status: GameStatus;
  phase: string;
  proactive: boolean;
  host_message: string;
  created_by: string;
  created_by_name: string;
  players: GamePlayer[];
  round_index: number;
  total_rounds: number;
  round_revealed: boolean;
  current_question?: QuizQuestionView | null;
  undercover?: UndercoverView | null;
  hint_race?: HintRaceView | null;
  party_vote?: PartyVoteView | null;
  creative_challenge?: CreativeChallengeView | null;
  winner_names: string[];
  created_at: string;
  updated_at: string;
}

export interface GameSummary {
  id: string;
  game_type: GameEngineType;
  catalog_id?: string;
  emoji?: string;
  title: string;
  topic: string;
  status: GameStatus;
  winner_names: string[];
  player_count: number;
  created_at: string;
}

export interface ActiveGameState {
  active_game: GameSession | null;
  recent_games: GameSummary[];
  ai_game_auto_invite: boolean;
  ai_game_invite_cooldown_mins: number;
  proactive_enabled_globally: boolean;
}

export interface ProactiveGameInviteResult {
  invited: boolean;
  reason?: string | null;
  game?: GameSession | null;
  message?: ChatMessage | null;
}

export interface GameWsSignal {
  seq: number;
  eventName: string;
  conversationId: string;
  gameId?: string;
  status?: string;
  phase?: string;
  aiGameAutoInvite?: boolean;
  aiGameInviteCooldownMins?: number;
}

export interface WsEvent {
  event?: string;
  type?: string;
  conversation_id?: string;
  message_id?: string;
  user_id?: string;
  preset?: string;
  call_id?: string;
  oa_id?: string;
  game_id?: string;
  status?: string;
  phase?: string;
  ai_game_auto_invite?: boolean;
  ai_game_invite_cooldown_mins?: number;
  call?: CallSession;
  message?: Record<string, unknown>;
  [key: string]: unknown;
}
