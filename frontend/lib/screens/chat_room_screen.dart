import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/map_preview.dart';
import 'call_inline_panel.dart';
import 'location_picker_screen.dart';
import 'login_screen.dart' show cleanErrorMessage;
import 'mini_app_runner_screen.dart';

class ChatRoomScreen extends StatefulWidget {
  final Conversation conversation;
  final List<Conversation> allConversations;
  final List<MiniAppItem> miniApps;
  final List<AppUser> friends;
  final bool isEmbedded;
  final VoidCallback? onConversationUpdated;
  final VoidCallback? onConversationLeft;
  final ValueChanged<ChatRoomThemeMode>? onThemeChanged;

  const ChatRoomScreen({
    super.key,
    required this.conversation,
    required this.allConversations,
    required this.miniApps,
    this.friends = const [],
    this.isEmbedded = false,
    this.onConversationUpdated,
    this.onConversationLeft,
    this.onThemeChanged,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _msgCtrl = TextEditingController();
  final TextEditingController _roomSearchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  late Conversation _conversation;
  List<ChatMessage> _messages = const [];
  bool _isLoading = true;
  bool _isUploading = false;
  String? _activeComposerTray; // null | sticker | attachment | miniapp | ai_assist
  String _aiAssistMode = 'polish';
  String? _activeRoomPanel; // null | vault | albums | events | poll | manage | ai_summary
  int _vaultInitialTab = 0;
  bool _livekitEnabled = false;
  OaAccountDto? _oaDetails;
  List<OaCoupon> _oaCoupons = const [];
  bool _loadingOaMeta = false;
  bool _showOaRichMenu = false;
  String? _claimingCouponId;
  ChatMessage? _selectedActionMessage;
  bool _selectedActionCanRecall = false;
  String? _previewImageUrl;
  String? _previewImageTitle;
  bool _showSearchBar = false;
  bool _isConfidentialMode = false;
  String _selectedPriority = 'normal'; // normal | urgent | silent
  final Set<String> _revealedMessageIds = <String>{};
  // Message ids already shown once; only first-time rows play the fade-in.
  final Set<String> _animatedMessageIds = <String>{};
  String _searchQuery = '';
  ChatMessage? _replyingTo;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<void>? _audioDoneSub;
  String? _playingAudioMsgId;
  double _audioPlaybackRate = 1.0;
  String _disappearMode = 'off'; // off | 1m | 1h | 24h | 7d
  String? _expandedReadersMsgId;
  ChatMessage? _editingMessage;
  final TextEditingController _editMsgCtrl = TextEditingController();
  bool _savingEdit = false;
  ChatMessage? _forwardingMessage;
  final Set<String> _forwardTargetIds = <String>{};
  bool _sendingForward = false;
  final Set<String> _revealedLadderIds = <String>{};
  bool _showMentionSuggestions = false;
  String _mentionQuery = '';
  final Set<String> _pendingMentionIds = <String>{};

  static const List<Map<String, String>> _thaiStickers = [
    {'code': 'ok_friend', 'emoji': '🫡✨', 'label': 'รับทราบเลยเพื่อน!'},
    {'code': 'thank_you', 'emoji': '🙏🧡', 'label': 'ขอบคุณมากๆ นะ'},
    {'code': 'arrived', 'emoji': '🏡✅', 'label': 'ถึงบ้านแล้วจ้า'},
    {'code': 'love_it', 'emoji': '👍💯', 'label': 'เห็นด้วยเต็มร้อย!'},
    {'code': 'fighting', 'emoji': '✌️🔥', 'label': 'สู้ๆ นะ เป็นกำลังใจให้'},
    {'code': 'on_the_way', 'emoji': '🚗💨', 'label': 'กำลังรีบไปเลย!'},
    {'code': 'meetup', 'emoji': '☕🍽️', 'label': 'เจอกันตามนัดนะ'},
    {'code': 'celebrate', 'emoji': '🎉🥳', 'label': 'ฉลองกันหน่อย!'},
  ];

  @override
  void initState() {
    super.initState();
    _conversation = widget.conversation;
    NotificationService.instance.openConversationId = _conversation.id;
    _msgCtrl.addListener(_onComposerTextChanged);
    _audioDoneSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingAudioMsgId = null);
    });
    _loadRoomData();
    _wsSub = ApiService.instance.wsEvents.listen(_handleWsEvent);
  }

  @override
  void didUpdateWidget(covariant ChatRoomScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id != widget.conversation.id) {
      _conversation = widget.conversation;
      NotificationService.instance.openConversationId = _conversation.id;
      _replyingTo = null;
      _activeComposerTray = null;
      _activeRoomPanel = null;
      _selectedActionMessage = null;
      _previewImageUrl = null;
      _previewImageTitle = null;
      _showSearchBar = false;
      _showMentionSuggestions = false;
      _mentionQuery = '';
      _pendingMentionIds.clear();
      _searchQuery = '';
      _roomSearchCtrl.clear();
      _oaDetails = null;
      _oaCoupons = const [];
      _showOaRichMenu = false;
      _claimingCouponId = null;
      _expandedReadersMsgId = null;
      _editingMessage = null;
      _editMsgCtrl.clear();
      _forwardingMessage = null;
      _forwardTargetIds.clear();
      _disappearMode = 'off';
      _loadRoomData();
    } else {
      _conversation = widget.conversation;
    }
  }

  @override
  void dispose() {
    _msgCtrl.removeListener(_onComposerTextChanged);
    _wsSub?.cancel();
    _audioDoneSub?.cancel();
    _audioPlayer.dispose();
    if (NotificationService.instance.openConversationId == _conversation.id) {
      NotificationService.instance.openConversationId = null;
    }
    _msgCtrl.dispose();
    _editMsgCtrl.dispose();
    _roomSearchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onComposerTextChanged() {
    final text = _msgCtrl.text;
    final cursor = _msgCtrl.selection.baseOffset;
    final upToCursor =
        (cursor >= 0 && cursor <= text.length) ? text.substring(0, cursor) : text;
    final match = RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(upToCursor);
    final nextShow = match != null;
    final nextQuery = match?.group(1) ?? '';
    if (nextShow != _showMentionSuggestions || nextQuery != _mentionQuery) {
      setState(() {
        _showMentionSuggestions = nextShow;
        _mentionQuery = nextQuery;
      });
    }
  }

  void _handleWsEvent(Map<String, dynamic> event) {
    final type = (event['type'] ?? event['event'] ?? '').toString();
    final convId =
        (event['conversation_id'] ??
                (event['message'] is Map
                    ? event['message']['conversation_id']
                    : null) ??
                '')
            .toString();

    if (convId == _conversation.id ||
        type == 'message_new' ||
        type == 'message_read' ||
        type == 'message_unsend' ||
        type == 'message_deleted' ||
        type == 'message_updated' ||
        type == 'message_edited' ||
        type == 'message_reaction' ||
        type == 'poll_voted' ||
        type == 'poll_closed' ||
        type == 'event_rsvp' ||
        type == 'note_updated' ||
        type == 'album_created' ||
        type == 'task_updated' ||
        type == 'card_approved' ||
        type == 'call_ended' ||
        type == 'conversation_updated') {
      if (type == 'message_edited' && event['message'] is Map && mounted) {
        final edited = ChatMessage.fromJson(
          Map<String, dynamic>.from(event['message'] as Map),
        );
        setState(() {
          _messages = _messages
              .map((m) => m.id == edited.id ? edited : m)
              .toList();
        });
      }
      _refreshMessagesQuietly();
      if (type == 'conversation_updated' && _conversation.isOa) {
        unawaited(_loadMetaForCallsAndOa());
      }
    }
  }

  List<OaRichMenuItem> get _oaRichMenu =>
      (_oaDetails != null && _oaDetails!.richMenu.isNotEmpty)
      ? _oaDetails!.richMenu
      : _conversation.richMenu;

  bool get _canStartCall {
    if (!_livekitEnabled) return false;
    if (_conversation.isBlockedByMe) return false;
    if (_conversation.isKeep) return false;
    if (_conversation.kind == 'official') return false;
    if (_conversation.isOa) {
      return _oaDetails?.callsEnabled ?? true;
    }
    return _conversation.kind == 'direct' || _conversation.kind == 'group';
  }

  Future<void> _loadMetaForCallsAndOa() async {
    final conv = _conversation;
    try {
      final cfg = await ApiService.instance.fetchAuthConfig();
      if (mounted && _conversation.id == conv.id) {
        setState(() => _livekitEnabled = cfg.livekitEnabled);
      }
    } catch (_) {}

    if (conv.isOa && (conv.oaId ?? '').isNotEmpty) {
      if (mounted && _conversation.id == conv.id) {
        setState(() => _loadingOaMeta = true);
      }
      try {
        final oaId = conv.oaId!;
        final oa = await ApiService.instance.getOa(oaId);
        final coupons = await ApiService.instance.fetchOaCoupons(oaId);
        if (!mounted || _conversation.id != conv.id) return;
        final menu = oa.richMenu.isNotEmpty ? oa.richMenu : conv.richMenu;
        setState(() {
          _oaDetails = oa;
          _oaCoupons = coupons;
          _showOaRichMenu = menu.isNotEmpty;
          _loadingOaMeta = false;
        });
      } catch (_) {
        if (mounted && _conversation.id == conv.id) {
          setState(() => _loadingOaMeta = false);
        }
      }
    } else if (mounted && _conversation.id == conv.id) {
      setState(() {
        _oaDetails = null;
        _oaCoupons = const [];
        _showOaRichMenu = false;
        _loadingOaMeta = false;
      });
    }
  }

  Future<void> _sendDirectQuickText(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) return;
    try {
      final sent = await ApiService.instance.sendMessage(
        _conversation.id,
        type: 'text',
        content: text,
      );
      if (!mounted) return;
      setState(() => _messages = [..._messages, sent]);
      _scrollToBottom();
      widget.onConversationUpdated?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ส่งข้อความไม่สำเร็จ: ${cleanErrorMessage(e)}')),
      );
    }
  }

  Future<void> _triggerRichMenuItem(OaRichMenuItem item) async {
    switch (item.actionType) {
      case 'url':
        final uri = Uri.tryParse(item.actionValue.trim());
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        break;
      case 'coupon':
        setState(() {
          _activeComposerTray =
              _activeComposerTray == 'oa_coupons' ? null : 'oa_coupons';
        });
        unawaited(_loadMetaForCallsAndOa());
        break;
      case 'ai_prompt':
      case 'keyword':
      default:
        final value = item.actionValue.trim().isNotEmpty
            ? item.actionValue.trim()
            : item.label.trim();
        await _sendDirectQuickText(value);
        break;
    }
  }

  Future<void> _claimCouponInRoom(OaCoupon coupon) async {
    final oaId = _conversation.oaId ?? coupon.oaId;
    if (oaId.isEmpty || _claimingCouponId != null) return;
    setState(() => _claimingCouponId = coupon.id);
    try {
      final updated = await ApiService.instance.claimOaCoupon(oaId, coupon.id);
      if (!mounted) return;
      setState(() {
        _oaCoupons = _oaCoupons
            .map((c) => c.id == updated.id ? updated : c)
            .toList();
        _claimingCouponId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.brandDeep,
          content: Text('เก็บคูปอง ${updated.code} เรียบร้อยแล้ว'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _claimingCouponId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'เก็บคูปองไม่สำเร็จ: ${e.toString().replaceFirst("Exception: ", "")}',
          ),
        ),
      );
    }
  }

  Future<void> _loadRoomData() async {
    setState(() => _isLoading = true);
    unawaited(_loadMetaForCallsAndOa());
    unawaited(
      CallInlineManager.instance.refreshActiveCalls(
        conversationId: _conversation.id,
      ),
    );
    try {
      final msgs = await ApiService.instance.fetchMessages(_conversation.id);
      await ApiService.instance.markConversationRead(_conversation.id);
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        _isLoading = false;
      });
      _scrollToBottom();
      widget.onConversationUpdated?.call();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshMessagesQuietly() async {
    try {
      final msgs = await ApiService.instance.fetchMessages(_conversation.id);
      await ApiService.instance.markConversationRead(_conversation.id);
      if (!mounted) return;
      // Follow new messages from others only if the reader is already at the end.
      final follow = msgs.length > _messages.length &&
          (!_scrollCtrl.hasClients || _scrollCtrl.position.extentAfter < 200);
      setState(() => _messages = msgs);
      if (follow) _scrollToBottom();
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // ListView.builder only measures the tail once it is laid out, so
      // maxScrollExtent grows while we scroll; chase it until it settles.
      for (var i = 0; i < 6 && mounted && _scrollCtrl.hasClients; i++) {
        final target = _scrollCtrl.position.maxScrollExtent;
        await _scrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
        if (!_scrollCtrl.hasClients ||
            _scrollCtrl.position.maxScrollExtent <= target) {
          break;
        }
      }
    });
  }

  String? _computeExpireAtIso() {
    final now = DateTime.now().toUtc();
    switch (_disappearMode) {
      case '1m':
        return now.add(const Duration(minutes: 1)).toIso8601String();
      case '1h':
        return now.add(const Duration(hours: 1)).toIso8601String();
      case '24h':
        return now.add(const Duration(hours: 24)).toIso8601String();
      case '7d':
        return now.add(const Duration(days: 7)).toIso8601String();
      default:
        return null;
    }
  }

  String get _disappearLabel {
    switch (_disappearMode) {
      case '1m':
        return 'ลบอัตโนมัติ: 1 นาที';
      case '1h':
        return 'ลบอัตโนมัติ: 1 ชม.';
      case '24h':
        return 'ลบอัตโนมัติ: 24 ชม.';
      case '7d':
        return 'ลบอัตโนมัติ: 7 วัน';
      default:
        return 'ลบอัตโนมัติ: ปิด';
    }
  }

  void _cycleDisappearMode() {
    setState(() {
      switch (_disappearMode) {
        case 'off':
          _disappearMode = '1m';
          break;
        case '1m':
          _disappearMode = '1h';
          break;
        case '1h':
          _disappearMode = '24h';
          break;
        case '24h':
          _disappearMode = '7d';
          break;
        default:
          _disappearMode = 'off';
      }
    });
  }

  String _resolveMemberName(String userId) {
    final me = ApiService.instance.currentUser;
    if (me != null && me.id == userId) {
      return me.displayName.isNotEmpty ? me.displayName : 'คุณ';
    }
    if (_conversation.peerUser != null && _conversation.peerUser!.id == userId) {
      return _conversation.peerUser!.displayName;
    }
    for (final f in widget.friends) {
      if (f.id == userId) return f.displayName;
    }
    for (final m in _messages) {
      if (m.senderId == userId && m.senderName.isNotEmpty) return m.senderName;
    }
    if (userId == 'user_ai') return 'BC AI';
    final chars = userId.characters;
    return chars.length > 10 ? chars.take(10).toString() : userId;
  }

  Future<void> _sendTextMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    final replyId = _replyingTo?.id;
    final confidential = _isConfidentialMode;
    final priority = _selectedPriority;
    final expireAt = _computeExpireAtIso();
    final mentions = <String>{..._pendingMentionIds};
    final lower = text.toLowerCase();
    if (lower.contains('@all')) mentions.add('all');
    if (lower.contains('@ai')) mentions.add('user_ai');
    _msgCtrl.clear();
    setState(() {
      _replyingTo = null;
      _showMentionSuggestions = false;
      _mentionQuery = '';
      _pendingMentionIds.clear();
    });

    try {
      final sent = await ApiService.instance.sendMessage(
        _conversation.id,
        type: 'text',
        content: text,
        replyToId: replyId,
        isConfidential: confidential,
        priority: priority,
        expireAt: expireAt,
        taskStatus: 'open',
        mentions: mentions.toList(),
      );
      if (!mounted) return;
      setState(() {
        if (confidential) _revealedMessageIds.add(sent.id);
        _messages = [..._messages, sent];
      });
      _scrollToBottom();
      widget.onConversationUpdated?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ส่งข้อความไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  Future<void> _sendRichPlusMessage({
    required String type,
    required String content,
    LocationData? locationData,
    ContactCardData? contactData,
    LadderGameData? ladderData,
  }) async {
    final replyId = _replyingTo?.id;
    final confidential = _isConfidentialMode;
    final priority = _selectedPriority;
    final expireAt = _computeExpireAtIso();
    setState(() {
      _activeComposerTray = null;
      _replyingTo = null;
    });
    try {
      final sent = await ApiService.instance.sendMessage(
        _conversation.id,
        type: type,
        content: content,
        locationData: locationData,
        contactData: contactData,
        ladderData: ladderData,
        replyToId: replyId,
        isConfidential: confidential,
        priority: priority,
        expireAt: expireAt,
      );
      if (!mounted) return;
      setState(() {
        if (confidential) _revealedMessageIds.add(sent.id);
        _messages = [..._messages, sent];
      });
      _scrollToBottom();
      widget.onConversationUpdated?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ส่งไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  void _startEditingMessage(ChatMessage msg) {
    setState(() {
      _activeComposerTray = null;
      _forwardingMessage = null;
      _editingMessage = msg;
      _editMsgCtrl.text = msg.cleanContent;
      _editMsgCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _editMsgCtrl.text.length),
      );
    });
  }

  Future<void> _saveEditedMessage() async {
    final target = _editingMessage;
    final nextText = _editMsgCtrl.text.trim();
    if (target == null || nextText.isEmpty || _savingEdit) return;
    setState(() => _savingEdit = true);
    try {
      final updated = await ApiService.instance.editMessage(
        target.id,
        nextText,
      );
      if (!mounted) return;
      setState(() {
        _messages = _messages
            .map((m) => m.id == target.id ? updated : m)
            .toList();
        _editingMessage = null;
        _editMsgCtrl.clear();
        _savingEdit = false;
      });
      widget.onConversationUpdated?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingEdit = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('แก้ไขข้อความไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  void _startForwardingMessage(ChatMessage msg) {
    setState(() {
      _activeComposerTray = null;
      _editingMessage = null;
      _forwardingMessage = msg;
      _forwardTargetIds.clear();
    });
  }

  Future<void> _submitForwardMessage() async {
    final target = _forwardingMessage;
    if (target == null || _forwardTargetIds.isEmpty || _sendingForward) return;
    setState(() => _sendingForward = true);
    final count = _forwardTargetIds.length;
    try {
      await ApiService.instance.forwardMessage(
        target.id,
        _forwardTargetIds.toList(),
      );
      if (!mounted) return;
      setState(() {
        _forwardingMessage = null;
        _forwardTargetIds.clear();
        _sendingForward = false;
      });
      widget.onConversationUpdated?.call();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ส่งต่อข้อความไปยัง $count ห้องแล้ว')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingForward = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ส่งต่อข้อความไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  Future<void> _saveMessageToKeepAction(ChatMessage msg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiService.instance.saveMessageToKeep(msg.id);
      if (!mounted) return;
      widget.onConversationUpdated?.call();
      messenger.showSnackBar(
        const SnackBar(content: Text('บันทึกเข้า Keep ส่วนตัวแล้ว 📌')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('บันทึกเข้า Keep ไม่สำเร็จ: ${cleanErrorMessage(e)}')),
      );
    }
  }

  void _cyclePriority() {
    setState(() {
      if (_selectedPriority == 'normal') {
        _selectedPriority = 'urgent';
      } else if (_selectedPriority == 'urgent') {
        _selectedPriority = 'silent';
      } else {
        _selectedPriority = 'normal';
      }
    });
  }

  Future<void> _handleTaskAction(ChatMessage msg, String action) async {
    try {
      final updated = await ApiService.instance.updateTaskAction(
        msg.id,
        action,
      );
      if (!mounted) return;
      setState(() {
        _messages = _messages.map((m) => m.id == msg.id ? updated : m).toList();
      });
      widget.onConversationUpdated?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('อัปเดตสถานะงานไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  Future<void> _handleApproveRichCard(ChatMessage msg, String status) async {
    try {
      final updated = await ApiService.instance.approveRichCard(msg.id, status);
      if (!mounted) return;
      setState(() {
        _messages = _messages.map((m) => m.id == msg.id ? updated : m).toList();
      });
      widget.onConversationUpdated?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: status == 'อนุมัติแล้ว'
              ? AppTheme.brandDeep
              : AppTheme.dangerRed,
          content: Text('ประทับตรา "$status" ลงในการ์ดเรียบร้อยแล้ว'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('อนุมัติการ์ดไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  Future<void> _sendSticker(Map<String, String> sticker) async {
    setState(() => _activeComposerTray = null);
    try {
      final sent = await ApiService.instance.sendMessage(
        _conversation.id,
        type: 'sticker',
        content: sticker['label']!,
        stickerCode: sticker['code']!,
        replyToId: _replyingTo?.id,
        isConfidential: _isConfidentialMode,
      );
      if (!mounted) return;
      setState(() {
        _replyingTo = null;
        _messages = [..._messages, sent];
      });
      _scrollToBottom();
      widget.onConversationUpdated?.call();
    } catch (_) {}
  }

  Future<void> _pickAndUploadFile() async {
    try {
      final files = await FilePicker.pickFiles();
      if (files.isEmpty) return;
      final picked = files.first;
      final bytes = await picked.readAsBytes();

      await _uploadBytesAndSend(
        fileName: picked.name,
        bytes: bytes,
        extension: picked.extension ?? '',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ไม่สามารถเลือกไฟล์ได้: ${cleanErrorMessage(e)}')));
    }
  }

  Future<void> _pickAndUploadAudio() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.audio);
      if (files.isEmpty) return;
      final picked = files.first;
      final bytes = await picked.readAsBytes();
      await _uploadBytesAndSend(
        fileName: picked.name,
        bytes: bytes,
        extension: picked.extension ?? 'mp3',
        forceAudio: true,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ไม่สามารถเลือกไฟล์เสียงได้: ${cleanErrorMessage(e)}')));
    }
  }

  Future<void> _uploadBytesAndSend({
    required String fileName,
    required List<int> bytes,
    required String extension,
    bool forceAudio = false,
    int? audioDurationSec,
  }) async {
    setState(() => _isUploading = true);
    try {
      final ext = extension.toLowerCase();
      final isAudioExt = [
        'mp3',
        'wav',
        'm4a',
        'aac',
        'ogg',
        'flac',
        'webm',
      ].contains(ext);
      String mimeType = 'application/octet-stream';
      if (['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(ext)) {
        mimeType = ext == 'jpg' ? 'image/jpeg' : 'image/$ext';
      } else if (ext == 'pdf') {
        mimeType = 'application/pdf';
      } else if (ext == 'txt' || ext == 'csv') {
        mimeType = 'text/plain; charset=utf-8';
      } else if (ext == 'mp3') {
        mimeType = 'audio/mpeg';
      } else if (ext == 'wav') {
        mimeType = 'audio/wav';
      } else if (isAudioExt) {
        mimeType = 'audio/$ext';
      }

      final b64 = base64Encode(bytes);
      final attachment = await ApiService.instance.uploadFileBase64(
        fileName: fileName,
        mimeType: mimeType,
        dataBase64: b64,
      );

      final isAudio =
          forceAudio || isAudioExt || attachment.mimeType.startsWith('audio/');
      final msgType = isAudio
          ? 'audio'
          : attachment.isImage
          ? 'image'
          : 'file';
      final sent = await ApiService.instance.sendMessage(
        _conversation.id,
        type: msgType,
        content: fileName,
        attachment: attachment,
        replyToId: _replyingTo?.id,
        isConfidential: _isConfidentialMode,
        audioDurationSec: isAudio ? (audioDurationSec ?? 15) : null,
      );

      if (!mounted) return;
      setState(() {
        _replyingTo = null;
        if (_isConfidentialMode) _revealedMessageIds.add(sent.id);
        _messages = [..._messages, sent];
      });
      _scrollToBottom();
      widget.onConversationUpdated?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.brandDeep,
          content: Text(
            'อัปโหลด "$fileName" เก็บถาวรเรียบร้อย (ส่งผิดกดลบทันที)',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.dangerRed,
          content: Text('อัปโหลดไฟล์ไม่สำเร็จ: ${cleanErrorMessage(e)}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _showAttachmentMenu() {
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray =
          _activeComposerTray == 'attachment' ? null : 'attachment';
    });
  }

  Future<void> _toggleFolderCategory() async {
    final nextFolder = _conversation.isFamily ? 'personal' : 'family';
    final updated = await ApiService.instance.updateConversationMeta(
      _conversation.id,
      folder: nextFolder,
    );
    if (!mounted) return;
    setState(() {
      if (updated != null) {
        _conversation = updated;
      } else {
        _conversation = Conversation(
          id: _conversation.id,
          kind: _conversation.kind,
          name: _conversation.name,
          avatarUrl: _conversation.avatarUrl,
          folder: nextFolder,
          isPinned: _conversation.isPinned,
          isMuted: _conversation.isMuted,
          isArchived: _conversation.isArchived,
          inviteToken: _conversation.inviteToken,
          adminIds: _conversation.adminIds,
          memberIds: _conversation.memberIds,
          memberCount: _conversation.memberCount,
          unreadCount: _conversation.unreadCount,
          pinnedMessage: _conversation.pinnedMessage,
          lastMessage: _conversation.lastMessage,
          peerUser: _conversation.peerUser,
          updatedAt: _conversation.updatedAt,
        );
      }
    });
    widget.onConversationUpdated?.call();
  }

  Future<void> _togglePinRoom() async {
    final nextPin = !_conversation.isPinned;
    final updated = await ApiService.instance.updateConversationMeta(
      _conversation.id,
      isPinned: nextPin,
    );
    if (!mounted) return;
    setState(() {
      _conversation = updated ??
          Conversation(
            id: _conversation.id,
            kind: _conversation.kind,
            name: _conversation.name,
            avatarUrl: _conversation.avatarUrl,
            folder: _conversation.folder,
            isPinned: nextPin,
            isMuted: _conversation.isMuted,
            isArchived: _conversation.isArchived,
            inviteToken: _conversation.inviteToken,
            adminIds: _conversation.adminIds,
            memberIds: _conversation.memberIds,
            memberCount: _conversation.memberCount,
            unreadCount: _conversation.unreadCount,
            pinnedMessage: _conversation.pinnedMessage,
            lastMessage: _conversation.lastMessage,
            peerUser: _conversation.peerUser,
            updatedAt: _conversation.updatedAt,
          );
    });
    widget.onConversationUpdated?.call();
  }

  String get _directPeerId {
    final p = _conversation.peerUser?.id ?? '';
    if (p.isNotEmpty) return p;
    final meId = ApiService.instance.currentUser?.id ?? '';
    return _conversation.memberIds.where((id) => id != meId).firstOrNull ?? '';
  }

  Future<void> _setRoomMuteDuration(String duration) async {
    final updated = await ApiService.instance.updateConversationMeta(
      _conversation.id,
      muteDuration: duration,
      isMuted: duration == 'forever' ? true : (duration == 'off' ? false : null),
    );
    if (!mounted) return;
    setState(() {
      _conversation = updated ??
          _conversation.copyWith(
            isMuted: duration == 'forever',
            clearMutedUntil: duration == 'off' || duration == 'forever',
          );
    });
    widget.onConversationUpdated?.call();
  }

  Future<void> _setDirectPeerBlocked(bool block) async {
    final peerId = _directPeerId;
    if (peerId.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiService.instance.updateFriendMeta(peerId, isBlocked: block);
      if (!mounted) return;
      setState(() {
        _conversation = _conversation.copyWith(isBlockedByMe: block);
      });
      widget.onConversationUpdated?.call();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            block ? 'บล็อกผู้ใช้นี้แล้ว' : 'ปลดบล็อกผู้ใช้นี้แล้ว',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('ดำเนินการไม่สำเร็จ: ${cleanErrorMessage(e)}')),
      );
    }
  }

  Future<void> _toggleArchiveRoom(bool nextArchived) async {
    final updated = await ApiService.instance.updateConversationMeta(
      _conversation.id,
      isArchived: nextArchived,
    );
    if (!mounted) return;
    setState(() {
      _conversation = updated ??
          Conversation(
            id: _conversation.id,
            kind: _conversation.kind,
            name: _conversation.name,
            avatarUrl: _conversation.avatarUrl,
            folder: _conversation.folder,
            isPinned: _conversation.isPinned,
            isMuted: _conversation.isMuted,
            isArchived: nextArchived,
            inviteToken: _conversation.inviteToken,
            adminIds: _conversation.adminIds,
            memberIds: _conversation.memberIds,
            memberCount: _conversation.memberCount,
            unreadCount: _conversation.unreadCount,
            pinnedMessage: _conversation.pinnedMessage,
            lastMessage: _conversation.lastMessage,
            peerUser: _conversation.peerUser,
            updatedAt: _conversation.updatedAt,
          );
    });
    widget.onConversationUpdated?.call();
  }

  Future<void> _pinMessageToBanner(ChatMessage? msg) async {
    await ApiService.instance.pinConversationMessage(_conversation.id, msg?.id);
    if (!mounted) return;
    setState(() {
      _conversation = Conversation(
        id: _conversation.id,
        kind: _conversation.kind,
        name: _conversation.name,
        avatarUrl: _conversation.avatarUrl,
        folder: _conversation.folder,
        isPinned: _conversation.isPinned,
        isMuted: _conversation.isMuted,
        isArchived: _conversation.isArchived,
        inviteToken: _conversation.inviteToken,
        adminIds: _conversation.adminIds,
        memberIds: _conversation.memberIds,
        memberCount: _conversation.memberCount,
        unreadCount: _conversation.unreadCount,
        pinnedMessage: msg,
        lastMessage: _conversation.lastMessage,
        peerUser: _conversation.peerUser,
        updatedAt: _conversation.updatedAt,
      );
    });
    widget.onConversationUpdated?.call();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.slateDark,
        content: Text(
          msg != null
              ? 'ปักหมุดประกาศไว้บนหัวห้องแชทเรียบร้อยแล้ว'
              : 'ยกเลิกปักหมุดประกาศบนหัวห้องแชทแล้ว',
        ),
      ),
    );
  }

  Future<void> _saveMessageToNotebook(ChatMessage msg) async {
    try {
      await ApiService.instance.createNote(
        conversationId: _conversation.id,
        title: 'จากห้อง ${_conversation.name} (${msg.senderName})',
        content: msg.cleanContent.isNotEmpty
            ? msg.cleanContent
            : msg.previewText,
        category: _conversation.isFamily ? 'ครอบครัว' : 'บันทึกสำคัญ',
        color: '#812920',
        attachment: msg.attachment,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.brandDeep,
          content: const Text(
            'บันทึกข้อความเข้าสมุดบันทึก BC & โน้ตประจำห้องเรียบร้อยแล้ว',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: Text('บันทึกเข้าสมุดบันทึก BC ไม่สำเร็จ: ${cleanErrorMessage(e)}')),
      );
    }
  }

  Future<void> _handleReactMessage(ChatMessage msg, String emoji) async {
    try {
      final updated = await ApiService.instance.reactMessage(msg.id, emoji);
      if (!mounted) return;
      if (updated != null) {
        setState(() {
          _messages = _messages.map((m) => m.id == msg.id ? updated : m).toList();
        });
      } else {
        await _refreshMessagesQuietly();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ส่งอีโมจิตอบสนองไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  Future<void> _handleDeleteForMe(ChatMessage msg) async {
    try {
      await ApiService.instance.deleteMessageForMe(msg.id);
      if (!mounted) return;
      setState(() {
        _messages = _messages.where((m) => m.id != msg.id).toList();
      });
      widget.onConversationUpdated?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ลบข้อความออกจากหน้าจอของคุณแล้ว')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ลบข้อความเฉพาะฉันไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  /// Instant Recall / Unsend & Purge MinIO File ("ส่งผิดสามารถลบได้ทันที")
  Future<void> _unsendOrHardRecall(ChatMessage msg, {bool hard = false}) async {
    try {
      await ApiService.instance.unsendMessage(msg.id, hard: hard);
      if (!mounted) return;
      if (hard) {
        setState(() {
          _messages = _messages.where((m) => m.id != msg.id).toList();
        });
      }
      await _refreshMessagesQuietly();
      widget.onConversationUpdated?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.dangerRed,
          content: Text(
            'ลบข้อความและทำลายไฟล์ออกจากเซิร์ฟเวอร์เรียบร้อยแล้ว',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ลบข้อความไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  void _openMiniAppPicker() {
    if (widget.miniApps.isEmpty) return;
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray = _activeComposerTray == 'miniapp' ? null : 'miniapp';
    });
  }

  void _openPermanentVaultDialog({int initialTab = 0}) {
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray = null;
      _vaultInitialTab = initialTab;
      _activeRoomPanel =
          (_activeRoomPanel == 'vault' && initialTab == 0) ? null : 'vault';
    });
  }

  void _openAlbumsDialog() {
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray = null;
      _activeRoomPanel = _activeRoomPanel == 'albums' ? null : 'albums';
    });
  }

  void _openEventsDialog() {
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray = null;
      _activeRoomPanel = _activeRoomPanel == 'events' ? null : 'events';
    });
  }

  void _openCreatePollDialog() {
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray = null;
      _activeRoomPanel = _activeRoomPanel == 'poll' ? null : 'poll';
    });
  }

  void _openGroupManagementSheet() {
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray = null;
      _activeRoomPanel = _activeRoomPanel == 'manage' ? null : 'manage';
    });
  }

  void _openAiSummarizeModal() {
    setState(() {
      _selectedActionMessage = null;
      _activeComposerTray = null;
      _activeRoomPanel =
          _activeRoomPanel == 'ai_summary' ? null : 'ai_summary';
    });
  }

  void _openAiAssistModal({String initialMode = 'polish'}) {
    setState(() {
      _selectedActionMessage = null;
      final closeSame =
          _activeComposerTray == 'ai_assist' && _aiAssistMode == initialMode;
      _aiAssistMode = initialMode;
      _activeComposerTray = closeSame ? null : 'ai_assist';
    });
  }

  Future<void> _sendAiSummaryToRoom(String formattedText) async {
    final sent = await ApiService.instance.sendMessage(
      _conversation.id,
      type: 'text',
      content: formattedText,
    );
    if (!mounted) return;
    setState(() => _messages = [..._messages, sent]);
    _scrollToBottom();
    widget.onConversationUpdated?.call();
  }

  void _insertAiMention() {
    final current = _msgCtrl.text;
    if (!current.startsWith('@ai ')) {
      setState(() {
        _msgCtrl.text = '@ai ${current.trimLeft()}';
        _msgCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _msgCtrl.text.length),
        );
      });
    }
  }

  List<ChatMessage> get _filteredMessages {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _messages;
    return _messages.where((m) {
      return m.content.toLowerCase().contains(q) ||
          m.senderName.toLowerCase().contains(q) ||
          (m.attachment?.fileName.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ApiService.instance.chatTheme;
    final currentUser = ApiService.instance.currentUser;
    final currentUserId = currentUser?.id ?? '';
    final isAdmin = currentUser?.isAdmin ?? false;
    final visibleMessages = _filteredMessages;

    final isCompactLayout = MediaQuery.sizeOf(context).width < 600;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: themeMode.backgroundColor,
          body: Column(
            children: [
              _buildRoomHeader(),
              if (!widget.isEmbedded)
                CallInlinePanel(conversationId: _conversation.id),
              if (_showSearchBar) _buildInRoomSearchBar(),
              if (_conversation.pinnedMessage != null)
                _buildPinnedAnnouncementBanner(_conversation.pinnedMessage!),
              Expanded(
                child: Stack(
                  children: [
                    _isLoading
                        ? const Center(
                            child: CircularProgressIndicator(color: Colors.white),
                          )
                        : visibleMessages.isEmpty
                        ? Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                              margin: const EdgeInsets.symmetric(horizontal: 24),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.30),
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusMd,
                                ),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.14),
                                ),
                              ),
                              child: const Text(
                                'เริ่มส่งข้อความ ภาพความทรงจำ หรือไฟล์ถาวรกับเพื่อนและครอบครัวได้เลย (ส่งผิดลบได้ 100%)',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  height: 1.45,
                                ),
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollCtrl,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            itemCount: visibleMessages.length,
                            itemBuilder: (ctx, index) {
                              final msg = visibleMessages[index];
                              final isMe = msg.senderId == currentUserId;
                              final row = _buildMessageRow(
                                msg,
                                isMe,
                                isAdmin,
                                themeMode,
                              );
                              // ป้ายคั่นวัน: ขึ้นก่อนข้อความแรกของแต่ละวัน
                              final dayLabel = formatThaiDay(msg.createdAt);
                              final startsNewDay =
                                  dayLabel.isNotEmpty &&
                                  (index == 0 ||
                                      !isSameLocalDay(
                                        visibleMessages[index - 1].createdAt,
                                        msg.createdAt,
                                      ));
                              if (!startsNewDay) return row;
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [_buildDaySeparator(dayLabel), row],
                              );
                            },
                          ),
                    if (_activeRoomPanel != null)
                      Positioned.fill(
                        child: _buildInlineRoomOverlayPanel(isCompactLayout),
                      ),
                  ],
                ),
              ),
              if (_selectedActionMessage != null) _buildSelectedMessageActionBar(),
              if (_editingMessage != null) _buildInlineEditMessageTray(),
              if (_forwardingMessage != null) _buildInlineForwardTray(),
              if (_activeComposerTray == 'plus')
                _InlinePlusActionPanel(
                  conversation: _conversation,
                  friends: widget.friends,
                  selectedPriority: _selectedPriority,
                  isConfidentialMode: _isConfidentialMode,
                  disappearLabel: _disappearLabel,
                  hasMiniApps: widget.miniApps.isNotEmpty,
                  onCyclePriority: _cyclePriority,
                  onToggleConfidential: () =>
                      setState(() => _isConfidentialMode = !_isConfidentialMode),
                  onCycleDisappear: _cycleDisappearMode,
                  onOpenMiniApps: _openMiniAppPicker,
                  onClose: () => setState(() => _activeComposerTray = null),
                  onSendLocation: (loc) => _sendRichPlusMessage(
                    type: 'location',
                    content: loc.title.isNotEmpty ? loc.title : 'แชร์ตำแหน่งที่ตั้ง',
                    locationData: loc,
                  ),
                  onSendContact: (contact) => _sendRichPlusMessage(
                    type: 'contact',
                    content: contact.displayName,
                    contactData: contact,
                  ),
                  onSendLadder: (game) => _sendRichPlusMessage(
                    type: 'ladder',
                    content: game.title,
                    ladderData: game,
                  ),
                ),
              if (_activeComposerTray == 'ai_menu') _buildAiMenuTray(),
              if (_activeComposerTray == 'sticker') _buildStickerPickerPanel(),
              if (_activeComposerTray == 'attachment') _buildInlineAttachmentTray(),
              if (_activeComposerTray == 'miniapp') _buildInlineMiniAppTray(),
              if (_activeComposerTray == 'ai_assist')
                _AiWritingAssistPanel(
                  key: ValueKey('assist-${_conversation.id}-$_aiAssistMode'),
                  conversation: _conversation,
                  initialDraft: _msgCtrl.text,
                  initialMode: _aiAssistMode,
                  onClose: () => setState(() => _activeComposerTray = null),
                  onApplyToComposer: (text) {
                    setState(() {
                      _activeComposerTray = null;
                      _msgCtrl.text = text;
                      _msgCtrl.selection = TextSelection.fromPosition(
                        TextPosition(offset: _msgCtrl.text.length),
                      );
                    });
                  },
                  onSendImmediately: (text) async {
                    setState(() => _activeComposerTray = null);
                    _msgCtrl.text = text;
                    await _sendTextMessage();
                  },
                ),
              if (_activeComposerTray == 'oa_coupons' && _conversation.isOa)
                _buildInlineOaCouponTray(),
              if (_conversation.isOa && _showOaRichMenu && _oaRichMenu.isNotEmpty)
                _buildOaRichMenuTray(),
              if (_replyingTo != null) _buildReplyBanner(_replyingTo!),
              _buildComposerBar(),
            ],
          ),
        ),
        if (_previewImageUrl != null)
          Positioned.fill(child: _buildInlineImagePreviewOverlay()),
      ],
    );
  }

  Widget _buildInlineRoomOverlayPanel(bool isCompact) {
    Widget child;
    switch (_activeRoomPanel) {
      case 'vault':
        child = _RoomVaultPanel(
          key: ValueKey('vault-${_conversation.id}-$_vaultInitialTab'),
          conversation: _conversation,
          initialTab: _vaultInitialTab,
          onClose: () => setState(() => _activeRoomPanel = null),
        );
        break;
      case 'albums':
        child = _RoomAlbumsPanel(
          key: ValueKey('albums-${_conversation.id}'),
          conversation: _conversation,
          onClose: () => setState(() => _activeRoomPanel = null),
        );
        break;
      case 'events':
        child = _RoomEventsPanel(
          key: ValueKey('events-${_conversation.id}'),
          conversation: _conversation,
          onClose: () => setState(() => _activeRoomPanel = null),
          onEventCreated: (_) => _refreshMessagesQuietly(),
        );
        break;
      case 'poll':
        child = _InlineCreatePollPanel(
          conversationId: _conversation.id,
          onClose: () => setState(() => _activeRoomPanel = null),
          onCreated: (sent) {
            setState(() {
              _activeRoomPanel = null;
              _messages = [..._messages, sent];
            });
            _scrollToBottom();
            widget.onConversationUpdated?.call();
          },
        );
        break;
      case 'manage':
        child = _InlineGroupManagePanel(
          conversation: _conversation,
          friends: widget.friends,
          isEmbedded: widget.isEmbedded,
          themeMode: ApiService.instance.chatTheme,
          onThemeChanged: _applyChatTheme,
          onToggleSearch: _toggleSearchBar,
          onTogglePin: _togglePinRoom,
          onToggleFolder: _toggleFolderCategory,
          onOpenVault: _openPermanentVaultDialog,
          onOpenAlbums: _openAlbumsDialog,
          onOpenNotes: () => _openPermanentVaultDialog(initialTab: 2),
          onOpenPoll: _openCreatePollDialog,
          onOpenEvents: _openEventsDialog,
          onClose: () => setState(() => _activeRoomPanel = null),
          onSetMuteDuration: _setRoomMuteDuration,
          onToggleArchive: _toggleArchiveRoom,
          onConversationChanged: (updated) {
            setState(() => _conversation = updated);
            widget.onConversationUpdated?.call();
          },
          onConversationLeft: () {
            setState(() => _activeRoomPanel = null);
            widget.onConversationLeft?.call();
            if (!widget.isEmbedded) {
              Navigator.of(context).pop();
            }
          },
        );
        break;
      case 'ai_summary':
        child = _AiSummaryPanel(
          key: ValueKey('summary-${_conversation.id}'),
          conversation: _conversation,
          onClose: () => setState(() => _activeRoomPanel = null),
          onSendToRoom: _sendAiSummaryToRoom,
          onSaveToNotebook: (formattedText) async {
            // Save to both the room notebook and personal vault.
            for (final roomId in [_conversation.id, null]) {
              await ApiService.instance.createNote(
                conversationId: roomId,
                title: '✨ AI สรุปห้อง ${_conversation.name}',
                content: formattedText,
                category: 'AI สรุปแชท',
                color: '#7C3AED',
              );
            }
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: AppTheme.brandDeep,
                content: const Text(
                  'บันทึกผลสรุป AI เข้าสมุดบันทึก BC & โน้ตห้องเรียบร้อยแล้ว!',
                ),
              ),
            );
          },
        );
        break;
      default:
        child = const SizedBox.shrink();
    }

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      padding: EdgeInsets.all(isCompact ? 6 : 14),
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 580),
        child: Material(
          color: Colors.white,
          elevation: 8,
          borderRadius: BorderRadius.circular(AppTheme.radiusXl),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }

  Widget _buildInlineImagePreviewOverlay() {
    final user = ApiService.instance.currentUser;
    return Material(
      color: Colors.black87,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      '${_previewImageTitle ?? ""} · เปิดดูโดย ${user?.displayName ?? "คุณ"}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _previewImageUrl = null;
                      _previewImageTitle = null;
                    }),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Expanded(
              child: InteractiveViewer(
                child: Image.network(_previewImageUrl!, fit: BoxFit.contain),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyChatTheme(ChatRoomThemeMode mode) async {
    await ApiService.instance.setChatTheme(mode);
    if (!mounted) return;
    setState(() {});
    widget.onThemeChanged?.call(mode);
  }

  void _toggleSearchBar() {
    setState(() {
      _showSearchBar = !_showSearchBar;
      if (!_showSearchBar) {
        _searchQuery = '';
        _roomSearchCtrl.clear();
      }
    });
  }

  /// Square 36px header icon button (tooltip carries the full Thai label).
  Widget _headerIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    required Color color,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      icon: Icon(icon, size: 19, color: color),
    );
  }

  Widget _buildRoomHeader() {
    const iconIdle = Color(0xFFE2E8F0);
    final subtitleText = _conversation.isGroup
        ? '${_conversation.memberCount} สมาชิก · ${_conversation.folderLabel}'
        : _conversation.isOa
        ? 'ร้านค้า'
        : (_conversation.peerUser?.isOnline == true
              ? 'ออนไลน์ · ${_conversation.folderLabel}'
              : _conversation.folderLabel);

    final header = LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 600;
        return Container(
          height: 48,
          padding: EdgeInsets.symmetric(horizontal: isCompact ? 4 : 10),
          decoration: const BoxDecoration(
            gradient: AppTheme.navyGradient,
            border: Border(
              bottom: BorderSide(color: Color(0x1FFFFFFF), width: 0.8),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!widget.isEmbedded)
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                  color: Colors.white,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  tooltip: 'ย้อนกลับ',
                ),
              if (isCompact && widget.isEmbedded) const SizedBox(width: 6),
              UserAvatar(
                name: _conversation.name,
                avatarUrl: _conversation.avatarUrl,
                radius: isCompact ? 15 : 16,
                showOnline: !_conversation.isGroup,
                isOfficial: _conversation.isOfficial,
                isGroup: _conversation.isGroup,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            _conversation.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: isCompact ? 15 : 16,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                          ),
                        ),
                        if (_conversation.isEffectivelyMuted) ...[
                          const SizedBox(width: 5),
                          const Tooltip(
                            message: 'ปิดเสียงแจ้งเตือนอยู่',
                            child: Icon(
                              Icons.notifications_off_outlined,
                              size: 14,
                              color: Color(0xCCFFFFFF),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      subtitleText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              _headerIconButton(
                icon: Icons.search_rounded,
                tooltip: 'ค้นหาข้อความ',
                onPressed: _toggleSearchBar,
                color: iconIdle,
              ),
              if (_canStartCall) ...[
                _headerIconButton(
                  icon: Icons.call_rounded,
                  tooltip: 'โทรด้วยเสียง',
                  onPressed: () => CallInlineManager.instance.startCall(
                    conversationId: _conversation.id,
                    callType: 'audio',
                  ),
                  color: iconIdle,
                ),
                _headerIconButton(
                  icon: Icons.videocam_rounded,
                  tooltip: 'วิดีโอคอล',
                  onPressed: () => CallInlineManager.instance.startCall(
                    conversationId: _conversation.id,
                    callType: 'video',
                  ),
                  color: iconIdle,
                ),
              ],
              _headerIconButton(
                icon: Icons.auto_awesome_rounded,
                tooltip: 'AI สรุปแชท',
                onPressed: _openAiSummarizeModal,
                color: AppTheme.goldClay,
              ),
              _headerIconButton(
                icon: Icons.menu_rounded,
                tooltip: 'เมนูห้อง',
                onPressed: _openGroupManagementSheet,
                color: Colors.white,
              ),
            ],
          ),
        );
      },
    );

    return widget.isEmbedded
        ? header
        : ColoredBox(
            color: AppTheme.slateDark,
            child: SafeArea(bottom: false, child: header),
          );
  }

  Widget _buildInRoomSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      color: AppTheme.slateNavy,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: _roomSearchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: const InputDecoration(
                hintText: 'ค้นหาข้อความ ชื่อไฟล์ หรือชื่อผู้ส่งในห้องนี้...',
                prefixIcon: Icon(Icons.search_rounded, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              setState(() {
                _showSearchBar = false;
                _searchQuery = '';
                _roomSearchCtrl.clear();
              });
            },
            child: const Text('ปิด', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedAnnouncementBanner(ChatMessage pinned) {
    return GlassPanel(
      blur: 16,
      tint: const Color(0xEBFFF7E0),
      border: Border(
        bottom: BorderSide(
          color: AppTheme.goldPin.withValues(alpha: 0.35),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              border: Border.all(
                color: AppTheme.goldPin.withValues(alpha: 0.4),
              ),
            ),
            child: const Icon(
              Icons.campaign_rounded,
              color: AppTheme.warningAmber,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      'ประกาศปักหมุดประจำห้อง',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.warningAmber,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'โดย ${pinned.senderName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.slateMuted,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  pinned.previewText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateDark,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _pinMessageToBanner(null),
            tooltip: 'เอาประกาศปักหมุดออก',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: AppTheme.slateMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDaySeparator(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Container(
          key: const Key('chat-day-separator'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageRow(
    ChatMessage msg,
    bool isMe,
    bool isAdmin,
    ChatRoomThemeMode themeMode,
  ) {
    if (msg.isUnsent) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 14,
                  color: Color(0xFFFCA5A5),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${isMe ? "คุณ" : msg.senderName} ยกเลิกข้อความและทำลายไฟล์แล้ว',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final timeStr = formatThaiTime(msg.createdAt);
    final readLabel = _conversation.isGroup && msg.readCount > 1
        ? 'อ่านแล้ว ${msg.readCount}'
        : 'อ่านแล้ว';
    final canRecall = isMe || isAdmin;

    // Pick readable meta colors for dark, mid-tone (sky) and light backgrounds.
    final bg = themeMode.backgroundColor;
    final onLight = !themeMode.isDark && bg.computeLuminance() > 0.6;
    final metaText = themeMode.isDark
        ? const Color(0xFF94A3B8)
        : onLight
        ? AppTheme.slateMuted
        : Colors.white.withValues(alpha: 0.92);
    final readColor = themeMode.isDark
        ? AppTheme.goldClay
        : onLight
        ? AppTheme.brandDeep
        : Colors.white;
    final nameColor = themeMode.isDark
        ? const Color(0xFFE2E8F0)
        : onLight
        ? AppTheme.slateDark
        : Colors.white;

    final metaColumn = Column(
      crossAxisAlignment: isMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // read_count จาก backend ไม่นับผู้ส่ง: 0 = ยังไม่มีใครอ่าน จึงยังไม่ขึ้นป้าย
        if (isMe && msg.readCount > 0)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _conversation.isGroup && msg.readBy.isNotEmpty
                ? () => setState(() {
                    _expandedReadersMsgId =
                        _expandedReadersMsgId == msg.id ? null : msg.id;
                  })
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.done_all_rounded, size: 12, color: readColor),
                  const SizedBox(width: 3),
                  Text(
                    readLabel,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: readColor,
                      height: 1.3,
                      decoration: _conversation.isGroup && msg.readBy.isNotEmpty
                          ? TextDecoration.underline
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        Text(
          msg.isEdited ? 'แก้ไขแล้ว · $timeStr' : timeStr,
          style: TextStyle(fontSize: 10.5, color: metaText, height: 1.3),
        ),
      ],
    );

    final isSelected = _selectedActionMessage?.id == msg.id;
    final hasNameHeader = !isMe ||
        msg.priority == 'urgent' ||
        msg.priority == 'silent' ||
        msg.isConfidential ||
        msg.isForwarded ||
        msg.isExpiring;
    final showTaskBar = msg.type != 'sticker' &&
        msg.type != 'rich_card' &&
        msg.type != 'poll' &&
        msg.type != 'event' &&
        msg.type != 'location' &&
        msg.type != 'contact' &&
        msg.type != 'ladder' &&
        msg.type != 'call_log' &&
        (msg.taskStatus == 'accepted' || msg.taskStatus == 'done');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Reserve room for avatar + meta column so the row never overflows.
          final reserved = (isMe ? 0 : 34) + 10 + 72;
          final bubbleMax = math.max(
            140.0,
            math.min(430.0, constraints.maxWidth - reserved),
          );
          final isNew = _animatedMessageIds.add(msg.id);

          final nameHeader = Padding(
            padding: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
              children: [
                if (!isMe)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: bubbleMax * 0.65),
                    child: Text(
                      msg.senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: nameColor,
                        height: 1.3,
                      ),
                    ),
                  ),
                if (msg.priority == 'urgent')
                  PillBadge(
                    text: '⚡ เรื่องด่วน',
                    backgroundColor: AppTheme.dangerRed.withValues(alpha: 0.92),
                    textColor: Colors.white,
                  ),
                if (msg.priority == 'silent')
                  const PillBadge(
                    text: '🌙 ส่งเงียบ',
                    backgroundColor: Color(0xFF312E81),
                    textColor: Color(0xFFE0E7FF),
                  ),
                if (msg.isConfidential)
                  const PillBadge(
                    text: '🔒 ความลับส่วนตัว',
                    backgroundColor: Color(0xFF7F1D1D),
                    textColor: Color(0xFFFECACA),
                  ),
                if (msg.isForwarded)
                  PillBadge(
                    text: '↪ ส่งต่อจาก ${msg.forwardedFrom}',
                    backgroundColor: const Color(0xFFE0F2FE),
                    textColor: const Color(0xFF0369A1),
                  ),
                if (msg.isExpiring)
                  const PillBadge(
                    text: '⏳ ลบอัตโนมัติ',
                    backgroundColor: Color(0xFFFEF3C7),
                    textColor: Color(0xFF92400E),
                  ),
              ],
            ),
          );

          // Tap or long-press a bubble to reveal the inline action bar.
          final bubbleRow = Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (isMe) ...[
                metaColumn,
                const SizedBox(width: 6),
              ],
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: bubbleMax),
                  child: GestureDetector(
                    onTap: () => _toggleMessageActionSelection(msg, canRecall),
                    onLongPress: () => _showMessageSheetActions(msg, canRecall),
                    child: Container(
                      decoration: isSelected
                          ? BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: AppTheme.brandPrimary,
                                width: 1.5,
                              ),
                            )
                          : null,
                      child: msg.isConfidential
                          ? _buildConfidentialWrapper(msg, isMe)
                          : _buildBubbleContent(msg, isMe),
                    ),
                  ),
                ),
              ),
              if (!isMe) ...[
                const SizedBox(width: 6),
                metaColumn,
              ],
            ],
          );

          final content = Row(
            mainAxisAlignment: isMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isMe) ...[
                UserAvatar(
                  name: msg.senderName,
                  avatarUrl: msg.senderAvatar,
                  radius: 14,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment: isMe
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (hasNameHeader) nameHeader,
                    bubbleRow,
                    if (_expandedReadersMsgId == msg.id && _conversation.isGroup)
                      _buildGroupReadersInlineCard(msg),
                    if (msg.reactions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: _buildReactionsRow(
                          msg,
                          ApiService.instance.currentUser?.id ?? '',
                          isMe,
                        ),
                      ),
                    if (showTaskBar)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _buildTaskClaimBar(msg),
                      ),
                  ],
                ),
              ),
            ],
          );

          // Cheap one-shot fade + slide for rows that first appear.
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: isNew ? 0.0 : 1.0, end: 1.0),
            duration: const Duration(milliseconds: 220),
            curve: AppTheme.motionCurve,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 10),
                child: child,
              ),
            ),
            child: content,
          );
        },
      ),
    );
  }

  /// Confidential Message Wrapper: hidden on screen until tapped by reader
  Widget _buildConfidentialWrapper(ChatMessage msg, bool isMe) {
    final isRevealed = _revealedMessageIds.contains(msg.id);
    final currentUser = ApiService.instance.currentUser;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDC2626), width: 1.6),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFDC2626).withValues(alpha: 0.16),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: const Color(0xFF991B1B),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(
                  Icons.lock_rounded,
                  size: 14,
                  color: Color(0xFFFDE68A),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '🔒 ความลับส่วนตัว — แตะเปิดอ่านเฉพาะบนหน้าจอนี้',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isRevealed)
                  InkWell(
                    onTap: () =>
                        setState(() => _revealedMessageIds.remove(msg.id)),
                    child: const Text(
                      'ซ่อนข้อมูล',
                      style: TextStyle(
                        color: Color(0xFFFDE68A),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!isRevealed)
            InkWell(
              onTap: () => setState(() => _revealedMessageIds.add(msg.id)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.visibility_off_rounded,
                      color: Color(0xFF991B1B),
                      size: 28,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'เนื้อหาความลับถูกซ่อนไว้เพื่อความปลอดภัย',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'แตะเพื่อเปิดดูข้อมูลความลับ (บันทึกชื่อผู้เปิดอ่าน: ${currentUser?.displayName ?? "คุณ"})',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.dangerRed,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: _buildBubbleContent(msg, isMe),
                ),
                Positioned(
                  right: 10,
                  bottom: 6,
                  child: IgnorePointer(
                    child: Text(
                      'เปิดอ่านโดย ${currentUser?.email ?? ""}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.dangerRed.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  void _toggleMessageActionSelection(ChatMessage msg, bool canRecall) {
    setState(() {
      _activeComposerTray = null;
      if (_selectedActionMessage?.id == msg.id) {
        _selectedActionMessage = null;
      } else {
        _selectedActionMessage = msg;
        _selectedActionCanRecall = canRecall;
      }
    });
  }

  void _showMessageSheetActions(ChatMessage msg, bool canRecall) {
    setState(() {
      _activeComposerTray = null;
      _selectedActionMessage = msg;
      _selectedActionCanRecall = canRecall;
    });
  }

  Widget _buildSelectedMessageActionBar() {
    final msg = _selectedActionMessage;
    if (msg == null) return const SizedBox.shrink();
    final canRecall = _selectedActionCanRecall;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFFDF8F6),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'จัดการข้อความ:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 2,
                  children: ['❤️', '👍', '😂', '😮', '😢', '🙏'].map((emoji) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        setState(() => _selectedActionMessage = null);
                        _handleReactMessage(msg, emoji);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Text(emoji, style: const TextStyle(fontSize: 19)),
                      ),
                    );
                  }).toList(),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _selectedActionMessage = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 0,
            children: [
              ActionChip(
                avatar: const Icon(Icons.reply_rounded, size: 15),
                label: const Text('ตอบกลับ', style: TextStyle(fontSize: 12)),
                onPressed: () => setState(() {
                  _replyingTo = msg;
                  _selectedActionMessage = null;
                }),
              ),
              if (msg.type == 'text' &&
                  !msg.isUnsent &&
                  msg.content.trim().isNotEmpty &&
                  (!msg.isConfidential ||
                      _revealedMessageIds.contains(msg.id))) ...[
                ActionChip(
                  key: Key('copy-msg-btn-${msg.id}'),
                  avatar: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('คัดลอก', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() => _selectedActionMessage = null);
                    Clipboard.setData(ClipboardData(text: msg.content));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('คัดลอกข้อความแล้ว')),
                    );
                  },
                ),
              ],
              if (msg.senderId == (ApiService.instance.currentUser?.id ?? '') &&
                  msg.type == 'text' &&
                  !msg.isUnsent) ...[
                ActionChip(
                  avatar: const Icon(
                    Icons.edit_rounded,
                    size: 15,
                    color: AppTheme.workBlue,
                  ),
                  label: const Text('แก้ไข', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() => _selectedActionMessage = null);
                    _startEditingMessage(msg);
                  },
                ),
              ],
              if (!msg.isUnsent &&
                  msg.type != 'system' &&
                  msg.type != 'call_log') ...[
                ActionChip(
                  avatar: Icon(
                    Icons.shortcut_rounded,
                    size: 15,
                    color: AppTheme.brandDeep,
                  ),
                  label: const Text('ส่งต่อ', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() => _selectedActionMessage = null);
                    _startForwardingMessage(msg);
                  },
                ),
              ],
              if (!msg.isUnsent && msg.type != 'system') ...[
                ActionChip(
                  avatar: Icon(
                    Icons.bookmark_rounded,
                    size: 15,
                    color: AppTheme.brandPrimary,
                  ),
                  label: const Text('Keep', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() => _selectedActionMessage = null);
                    _saveMessageToKeepAction(msg);
                  },
                ),
              ],
              ActionChip(
                avatar: const Icon(
                  Icons.push_pin_rounded,
                  size: 15,
                  color: AppTheme.warningAmber,
                ),
                label: const Text('ปักหมุดหัวห้อง', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() => _selectedActionMessage = null);
                  _pinMessageToBanner(msg);
                },
              ),
              ActionChip(
                avatar: Icon(
                  Icons.bookmark_add_rounded,
                  size: 15,
                  color: AppTheme.brandPrimary,
                ),
                label: const Text('บันทึกโน้ต', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() => _selectedActionMessage = null);
                  _saveMessageToNotebook(msg);
                },
              ),
              if (msg.type == 'text' &&
                  !msg.isUnsent &&
                  (msg.taskStatus ?? 'open') == 'open') ...[
                ActionChip(
                  avatar: const Icon(
                    Icons.pan_tool_alt_rounded,
                    size: 15,
                    color: AppTheme.workBlue,
                  ),
                  label: const Text('อาสาช่วย', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() => _selectedActionMessage = null);
                    _handleTaskAction(msg, 'accept');
                  },
                ),
              ],
              ActionChip(
                avatar: const Icon(Icons.delete_outline_rounded, size: 15),
                tooltip: 'ลบเฉพาะฝั่งฉัน',
                label: const Text('ลบ', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() => _selectedActionMessage = null);
                  _handleDeleteForMe(msg);
                },
              ),
              if (canRecall) ...[
                ActionChip(
                  avatar: const Icon(
                    Icons.undo_rounded,
                    size: 15,
                    color: AppTheme.dangerRed,
                  ),
                  label: const Text(
                    'ยกเลิกการส่ง',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.dangerRed,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () {
                    setState(() => _selectedActionMessage = null);
                    _unsendOrHardRecall(msg, hard: false);
                  },
                ),
                ActionChip(
                  avatar: const Icon(
                    Icons.delete_forever_rounded,
                    size: 15,
                    color: Color(0xFF991B1B),
                  ),
                  label: const Text(
                    'ลบไร้ร่องรอย',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF991B1B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () {
                    setState(() => _selectedActionMessage = null);
                    _unsendOrHardRecall(msg, hard: true);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBubbleContent(ChatMessage msg, bool isMe) {
    switch (msg.type) {
      case 'sticker':
        return _buildStickerBubble(msg);
      case 'image':
        return _buildImageBubble(msg, isMe);
      case 'file':
        return _buildFileBubble(msg, isMe);
      case 'audio':
        return _buildAudioBubble(msg, isMe);
      case 'rich_card':
        return _buildRichCardBubble(msg);
      case 'poll':
        return _buildPollBubble(msg);
      case 'event':
        return _buildEventBubble(msg);
      case 'location':
        return _buildLocationBubble(msg, isMe);
      case 'contact':
        return _buildContactBubble(msg, isMe);
      case 'ladder':
        return _buildLadderBubble(msg, isMe);
      case 'call_log':
        return _buildCallLogBubble(msg, isMe);
      default:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isMe ? null : AppTheme.receivedBubble,
            gradient: isMe
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [const Color(0xFFFEECE8), AppTheme.sentBubble],
                  )
                : null,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isMe ? 14 : 5),
              topRight: Radius.circular(isMe ? 5 : 14),
              bottomLeft: const Radius.circular(14),
              bottomRight: const Radius.circular(14),
            ),
            boxShadow: AppTheme.shadowSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (msg.replyTo != null)
                _buildReplyQuoteInsideBubble(msg.replyTo!),
              SelectableText(
                msg.cleanContent,
                style: const TextStyle(
                  fontSize: 14.5,
                  color: AppTheme.slateDark,
                  height: 1.45,
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildReplyQuoteInsideBubble(ReplySummary reply) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: AppTheme.brandDeep, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ตอบกลับ ${reply.senderName}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppTheme.brandDeep,
            ),
          ),
          Text(
            reply.content,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppTheme.slateBody),
          ),
        ],
      ),
    );
  }

  Widget _buildStickerBubble(ChatMessage msg) {
    final matched = _thaiStickers.firstWhere(
      (s) => s['code'] == msg.stickerCode,
      orElse: () => {'emoji': '🧡✨', 'label': msg.cleanContent},
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(matched['emoji'] ?? '🧡', style: const TextStyle(fontSize: 38)),
          const SizedBox(height: 4),
          Text(
            msg.cleanContent.isNotEmpty
                ? msg.cleanContent
                : (matched['label'] ?? ''),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.slateDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageBubble(ChatMessage msg, bool isMe) {
    final url = msg.attachment?.url ?? '';
    final fileName = msg.attachment?.fileName ?? msg.cleanContent;

    return Container(
      decoration: BoxDecoration(
        color: isMe ? AppTheme.sentBubble : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (url.isNotEmpty)
            InkWell(
              onTap: () => _showImagePreviewDialog(url, fileName),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 220,
                  minWidth: 180,
                ),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 120,
                    color: AppTheme.surfaceBg,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.image_outlined,
                      size: 40,
                      color: AppTheme.slateMuted,
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.cloud_done_rounded,
                  size: 14,
                  color: AppTheme.brandDeep,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    '$fileName · เก็บถาวร (ไม่หมดอายุ)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.brandDeep,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showImagePreviewDialog(String url, String title) {
    setState(() {
      _previewImageUrl = url;
      _previewImageTitle = title;
    });
  }

  Widget _buildFileBubble(ChatMessage msg, bool isMe) {
    final att = msg.attachment;
    final fileName = att?.fileName ?? msg.cleanContent;
    final sizeText = formatFileSize(att?.fileSize ?? 0);
    final url = att?.url ?? '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isMe ? AppTheme.sentBubble : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.workBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.insert_drive_file_rounded,
                  color: AppTheme.workBlue,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          sizeText,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        PillBadge(
                          text: 'เก็บถาวร ไม่หมดอายุ',
                          backgroundColor: AppTheme.brandSoft,
                          textColor: AppTheme.brandDeep,
                          icon: Icons.verified_rounded,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (url.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    final uri = Uri.tryParse(url);
                    if (uri != null) {
                      launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                  tooltip: 'ดาวน์โหลด / เปิดไฟล์',
                  icon: Icon(Icons.download_rounded, color: AppTheme.brandDeep),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTaskClaimBar(ChatMessage msg) {
    final status = msg.taskStatus ?? 'open';
    final actor = (msg.acceptedBy != null && msg.acceptedBy!.trim().isNotEmpty)
        ? msg.acceptedBy!
        : 'เพื่อน';

    Widget chip({
      required IconData icon,
      required String label,
      required Color fg,
      required Color bg,
      required Color border,
      VoidCallback? onTap,
    }) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border),
              boxShadow: AppTheme.shadowSm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (status == 'done') {
      return chip(
        icon: Icons.task_alt_rounded,
        label: 'เรียบร้อยแล้วโดย: $actor',
        fg: Colors.white,
        bg: const Color(0xFF13795B),
        border: const Color(0xFF6EE7B7),
      );
    }

    if (status == 'accepted') {
      return chip(
        icon: Icons.check_circle_rounded,
        label: 'รับช่วยโดย: $actor • กดเมื่อเสร็จ',
        fg: AppTheme.brandDeep,
        bg: AppTheme.brandSoft,
        border: AppTheme.brandPrimary,
        onTap: () => _handleTaskAction(msg, 'done'),
      );
    }

    return chip(
      icon: Icons.pan_tool_alt_rounded,
      label: 'อาสาช่วยเรื่องนี้',
      fg: AppTheme.workBlue,
      bg: Colors.white.withValues(alpha: 0.95),
      border: AppTheme.borderSubtle,
      onTap: () => _handleTaskAction(msg, 'accept'),
    );
  }

  Widget _buildReactionsRow(ChatMessage msg, String currentUserId, bool isMe) {
    final entries = msg.reactions.entries
        .where((e) => e.value.isNotEmpty)
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
      children: entries.map((e) {
        final reacted = e.value.contains(currentUserId);
        return InkWell(
          onTap: () => _handleReactMessage(msg, e.key),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: reacted
                  ? AppTheme.brandSoft
                  : Colors.white.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: reacted ? AppTheme.brandPrimary : AppTheme.borderSubtle,
              ),
              boxShadow: AppTheme.shadowSm,
            ),
            child: Text(
              '${e.key} ${e.value.length}',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: reacted ? AppTheme.brandDeep : AppTheme.slateDark,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _cycleAudioPlaybackRate() async {
    final next = _audioPlaybackRate == 1.0
        ? 1.5
        : (_audioPlaybackRate == 1.5 ? 2.0 : 1.0);
    setState(() => _audioPlaybackRate = next);
    if (_playingAudioMsgId != null) {
      try {
        await _audioPlayer.setPlaybackRate(next);
      } catch (_) {}
    }
  }

  Future<void> _toggleAudioPlayback(ChatMessage msg) async {
    final url = msg.attachment?.url ?? '';
    if (url.isEmpty) return;
    if (_playingAudioMsgId == msg.id) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _playingAudioMsgId = null);
      return;
    }
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(UrlSource(url));
      try {
        await _audioPlayer.setPlaybackRate(_audioPlaybackRate);
      } catch (_) {}
      if (mounted) setState(() => _playingAudioMsgId = msg.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('เล่นเสียงไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  Widget _buildAudioBubble(ChatMessage msg, bool isMe) {
    final playing = _playingAudioMsgId == msg.id;
    final dur = msg.audioDurationSec ?? 0;
    final durLabel = dur > 0
        ? '${(dur ~/ 60).toString().padLeft(2, '0')}:${(dur % 60).toString().padLeft(2, '0')}'
        : 'ข้อความเสียง';
    final fileName = msg.attachment?.fileName ?? msg.cleanContent;
    final rateText = _audioPlaybackRate == 1.0
        ? '1x'
        : (_audioPlaybackRate == 1.5 ? '1.5x' : '2x');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isMe ? AppTheme.sentBubble : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          InkWell(
            onTap: () => _toggleAudioPlayback(msg),
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.brandPrimary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName.isNotEmpty ? fileName : 'บันทึกเสียงสนทนา',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  playing ? 'กำลังเล่นเสียง... ($durLabel)' : 'ความยาว $durLabel',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.slateMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: _cycleAudioPlaybackRate,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _audioPlaybackRate == 1.0
                    ? AppTheme.surfaceBg
                    : AppTheme.brandSoft,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: _audioPlaybackRate == 1.0
                      ? AppTheme.borderSubtle
                      : AppTheme.brandPrimary,
                ),
              ),
              child: Text(
                rateText,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: _audioPlaybackRate == 1.0
                      ? AppTheme.slateDark
                      : AppTheme.brandDeep,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupReadersInlineCard(ChatMessage msg) {
    final readers = msg.readBy
        .where((id) => id != msg.senderId)
        .map(_resolveMemberName)
        .where((name) => name.isNotEmpty)
        .toList();
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.visibility_rounded, size: 13, color: AppTheme.brandPrimary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              readers.isEmpty
                  ? 'ยังไม่มีสมาชิกคนอื่นอ่าน'
                  : 'อ่านแล้ว (${readers.length}): ${readers.join(", ")}',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.slateDark,
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => setState(() => _expandedReadersMsgId = null),
            child: const Icon(
              Icons.close_rounded,
              size: 14,
              color: AppTheme.slateMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationBubble(ChatMessage msg, bool isMe) {
    final loc = msg.locationData;
    final title = (loc?.title ?? '').trim().isNotEmpty
        ? loc!.title.trim()
        : (msg.cleanContent.isNotEmpty ? msg.cleanContent : 'ตำแหน่งที่ปักหมุด');
    final address = (loc?.address ?? '').trim();
    final lat = loc?.latitude ?? 0.0;
    final lng = loc?.longitude ?? 0.0;
    final mapUrl =
        loc?.resolvedMapUrl ??
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng';

    return Container(
      width: 270,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFFFFF5F3) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.brandSoft,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.location_on_rounded,
                  color: AppTheme.brandPrimary,
                  size: 19,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.slateDark,
                      ),
                    ),
                    Text(
                      'พิกัด: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (address.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.slateBody,
                height: 1.35,
              ),
            ),
          ],
          if (BcMapPreview.isValidLatLng(loc?.latitude, loc?.longitude)) ...[
            const SizedBox(height: 6),
            BcMapPreview(lat: lat, lng: lng, height: 130),
          ],
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    final uri = Uri.tryParse(mapUrl);
                    if (uri != null) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  icon: const Icon(Icons.directions_rounded, size: 15),
                  label: const Text('นำทาง Maps', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.brandPrimary,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '$lat, $lng'));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('คัดลอกพิกัดแล้ว')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('คัดลอก', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContactBubble(ChatMessage msg, bool isMe) {
    final c = msg.contactData;
    final name = (c?.displayName ?? '').trim().isNotEmpty
        ? c!.displayName.trim()
        : (msg.cleanContent.isNotEmpty ? msg.cleanContent : 'เพื่อน BC');
    final bcId = (c?.bcId ?? '').trim();
    final userId = (c?.userId ?? '').trim();
    final meId = ApiService.instance.currentUser?.id ?? '';
    final isSelf = userId.isNotEmpty && userId == meId;
    final alreadyFriend = widget.friends.any(
      (f) => f.id == userId || (bcId.isNotEmpty && f.bcId == bcId),
    );

    return Container(
      width: 256,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFFFFF5F3) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              UserAvatar(
                name: name,
                avatarUrl: c?.avatarUrl ?? '',
                radius: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.slateDark,
                      ),
                    ),
                    if (bcId.isNotEmpty)
                      Text(
                        bcId.startsWith('@') ? bcId : '@$bcId',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.brandDeep,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if ((c?.statusMessage ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              c!.statusMessage.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
            ),
          ],
          const SizedBox(height: 8),
          if (isSelf)
            PillBadge(
              text: 'นามบัตรของคุณ',
              backgroundColor: AppTheme.brandSoft,
              textColor: AppTheme.brandDeep,
            )
          else if (userId.isNotEmpty || bcId.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    if (!alreadyFriend) {
                      try {
                        await ApiService.instance.addFriend(
                          query: bcId.isNotEmpty ? bcId : userId,
                        );
                      } catch (_) {}
                    }
                    if (userId.isNotEmpty) {
                      final conv = await ApiService.instance
                          .openDirectConversation(userId);
                      if (!mounted) return;
                      widget.onConversationUpdated?.call();
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatRoomScreen(
                            conversation: conv,
                            allConversations: widget.allConversations,
                            miniApps: widget.miniApps,
                            friends: widget.friends,
                            onConversationUpdated: widget.onConversationUpdated,
                          ),
                        ),
                      );
                    } else {
                      widget.onConversationUpdated?.call();
                      messenger.showSnackBar(
                        SnackBar(content: Text('เพิ่มเพื่อน $name แล้ว')),
                      );
                    }
                  } catch (e) {
                    if (!mounted) return;
                    messenger.showSnackBar(
                      SnackBar(content: Text('ดำเนินการไม่สำเร็จ: ${cleanErrorMessage(e)}')),
                    );
                  }
                },
                icon: Icon(
                  alreadyFriend
                      ? Icons.chat_bubble_outline_rounded
                      : Icons.person_add_alt_1_rounded,
                  size: 15,
                ),
                label: Text(
                  alreadyFriend ? 'ทักแชทเลย' : 'เพิ่มเพื่อน / ทักแชท',
                  style: const TextStyle(fontSize: 12),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brandPrimary,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLadderBubble(ChatMessage msg, bool isMe) {
    final game = msg.ladderData;
    final title = (game?.title ?? '').trim().isNotEmpty
        ? game!.title.trim()
        : (msg.cleanContent.isNotEmpty ? msg.cleanContent : 'เกมสุ่มบันได');
    final entries = game?.entries ?? const <LadderEntry>[];
    final collapsed = _revealedLadderIds.contains(msg.id);

    return Container(
      width: 274,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFFFFF5F3) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text('🎲', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              InkWell(
                onTap: () => setState(() {
                  if (collapsed) {
                    _revealedLadderIds.remove(msg.id);
                  } else {
                    _revealedLadderIds.add(msg.id);
                  }
                }),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  child: Text(
                    collapsed ? 'ดูผล (${entries.length})' : 'ซ่อนผล',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brandPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (!collapsed && entries.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderSubtle),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          entry.player,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateDark,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          size: 13,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.brandSoft,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            entry.result,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.brandDeep,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCallLogBubble(ChatMessage msg, bool isMe) {
    final payload = msg.cardPayload ?? const <String, dynamic>{};
    final callType = (payload['call_type'] ?? 'audio').toString();
    final isVideo = callType == 'video';
    final status = (payload['status'] ?? 'ended').toString();
    final rawDur = payload['duration_sec'];
    final durSec = rawDur is int
        ? rawDur
        : int.tryParse((rawDur ?? '').toString()) ?? 0;

    final isMissed =
        status == 'missed' || status == 'declined' || status == 'cancelled';
    final statusLabel = switch (status) {
      'missed' => 'ไม่ได้รับสาย',
      'declined' => 'ปฏิเสธสาย',
      'cancelled' => 'ยกเลิกสาย',
      _ when durSec > 0 =>
        'จบสาย · ${(durSec ~/ 60).toString().padLeft(2, "0")}:${(durSec % 60).toString().padLeft(2, "0")}',
      _ => msg.cleanContent.isNotEmpty ? msg.cleanContent : 'สิ้นสุดการสนทนา',
    };

    final icon = isMissed
        ? Icons.call_missed_rounded
        : (isVideo ? Icons.videocam_rounded : Icons.call_rounded);
    final accent = isMissed ? AppTheme.dangerRed : AppTheme.brandPrimary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: isMe
                ? Colors.white.withValues(alpha: 0.72)
                : accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: accent),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isVideo ? 'วิดีโอคอล' : 'โทรด้วยเสียง',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
              ),
              Text(
                statusLabel,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: isMissed ? AppTheme.dangerRed : AppTheme.slateMuted,
                ),
              ),
            ],
          ),
        ),
        if (_canStartCall) ...[
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => CallInlineManager.instance.startCall(
              conversationId: _conversation.id,
              callType: isVideo ? 'video' : 'audio',
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.brandSoft,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.borderSubtle),
              ),
              child: Text(
                'โทรกลับ',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.brandDeep,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  IconData _oaMenuIcon(String name) {
    switch (name.trim()) {
      case 'coupon':
      case 'tag':
        return Icons.local_offer_rounded;
      case 'link':
      case 'url':
        return Icons.open_in_new_rounded;
      case 'ai':
      case 'sparkles':
        return Icons.auto_awesome_rounded;
      case 'menu':
      case 'shop':
        return Icons.storefront_rounded;
      case 'support':
      case 'chat':
        return Icons.support_agent_rounded;
      default:
        return Icons.touch_app_rounded;
    }
  }

  Widget _buildOaRichMenuTray() {
    final menu = _oaRichMenu.take(6).toList();
    if (menu.isEmpty) return const SizedBox.shrink();
    final cols = menu.length <= 2 ? menu.length : (menu.length <= 4 ? 2 : 3);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFFAF6F5),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.grid_view_rounded,
                size: 16,
                color: AppTheme.brandPrimary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'เมนู ${_oaDetails?.displayName ?? _conversation.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showOaRichMenu = false),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        'ซ่อนเมนู',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                      SizedBox(width: 2),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: AppTheme.slateMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 6.0;
              final itemW = (constraints.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: menu.map((item) {
                  return SizedBox(
                    width: itemW,
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _triggerRichMenuItem(item),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.borderSubtle),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Icon(
                                _oaMenuIcon(item.icon),
                                size: 15,
                                color: AppTheme.brandPrimary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      item.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.slateDark,
                                      ),
                                    ),
                                    if (item.subtitle.trim().isNotEmpty)
                                      Text(
                                        item.subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.slateMuted,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInlineOaCouponTray() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xF5FFFFFF),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.local_offer_rounded,
                size: 17,
                color: AppTheme.brandPrimary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'คูปองจากร้าน (${_oaCoupons.length})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _activeComposerTray = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_loadingOaMeta && _oaCoupons.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_oaCoupons.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'ยังไม่มีคูปองโปรโมชันจากร้านนี้ในขณะนี้',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              ),
            )
          else
            SizedBox(
              height: 82,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _oaCoupons.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final coupon = _oaCoupons[i];
                  final busy = _claimingCouponId == coupon.id;
                  return Container(
                    width: 210,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderSubtle),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                coupon.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.slateDark,
                                ),
                              ),
                              if (coupon.discountText.isNotEmpty)
                                Text(
                                  coupon.discountText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.brandPrimary,
                                  ),
                                ),
                              Text(
                                'โค้ด ${coupon.code}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: AppTheme.slateMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (coupon.isRedeemed)
                          const PillBadge(
                            text: 'ใช้แล้ว',
                            backgroundColor: Color(0xFFE2E8F0),
                            textColor: AppTheme.slateBody,
                          )
                        else if (coupon.isClaimed)
                          const PillBadge(
                            text: 'เก็บแล้ว',
                            backgroundColor: Color(0xFFDCFCE7),
                            textColor: Color(0xFF166534),
                          )
                        else
                          FilledButton(
                            onPressed:
                                busy ? null : () => _claimCouponInRoom(coupon),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.brandPrimary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              busy ? '...' : 'เก็บคูปอง',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPollBubble(ChatMessage msg) {
    final poll = msg.poll;
    if (poll == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(msg.cleanContent),
      );
    }
    final currentUser = ApiService.instance.currentUser;
    final myId = currentUser?.id ?? '';
    final canClose =
        !poll.isClosed && (msg.senderId == myId || (currentUser?.isAdmin ?? false));
    final total = poll.totalVotes;
    final cardWidth = math.min(310.0, MediaQuery.of(context).size.width * 0.68);

    return Container(
      width: cardWidth,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.poll_rounded, size: 18, color: AppTheme.brandPrimary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  poll.isClosed ? 'โพล (ปิดโหวตแล้ว)' : 'โพลสำรวจความคิดเห็น',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.brandDeep,
                  ),
                ),
              ),
              Text(
                '${poll.uniqueVotersCount} คนโหวต',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.slateMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            poll.question,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              color: AppTheme.slateDark,
            ),
          ),
          const SizedBox(height: 10),
          ...poll.options.map((opt) {
            final voted = opt.voterIds.contains(myId);
            final ratio = total > 0 ? opt.voterIds.length / total : 0.0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: poll.isClosed
                    ? null
                    : () async {
                        final selected = <String>{};
                        for (final o in poll.options) {
                          if (o.voterIds.contains(myId)) selected.add(o.id);
                        }
                        if (poll.allowMultiple) {
                          if (voted) {
                            selected.remove(opt.id);
                          } else {
                            selected.add(opt.id);
                          }
                        } else {
                          selected
                            ..clear()
                            ..add(opt.id);
                        }
                        try {
                          final updated = await ApiService.instance.votePoll(
                            msg.id,
                            selected.toList(),
                          );
                          if (!mounted) return;
                          setState(() {
                            _messages = _messages
                                .map((m) => m.id == msg.id ? updated : m)
                                .toList();
                          });
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('โหวตไม่สำเร็จ: ${cleanErrorMessage(e)}')),
                          );
                        }
                      },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: voted ? AppTheme.brandSoft : AppTheme.surfaceBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: voted ? AppTheme.brandPrimary : AppTheme.borderSubtle,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            voted
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 16,
                            color: voted ? AppTheme.brandPrimary : AppTheme.slateMuted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              opt.text,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: voted ? FontWeight.w700 : FontWeight.w500,
                                color: AppTheme.slateDark,
                              ),
                            ),
                          ),
                          Text(
                            '${opt.voterIds.length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.brandDeep,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      LinearProgressIndicator(
                        value: ratio,
                        minHeight: 4,
                        backgroundColor: Colors.white,
                        color: AppTheme.brandPrimary,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          if (canClose)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  try {
                    final updated = await ApiService.instance.closePoll(msg.id);
                    if (!mounted) return;
                    setState(() {
                      _messages = _messages
                          .map((m) => m.id == msg.id ? updated : m)
                          .toList();
                    });
                  } catch (_) {}
                },
                child: const Text('ปิดโพลนี้'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEventBubble(ChatMessage msg) {
    final ev = msg.eventData;
    if (ev == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(msg.cleanContent),
      );
    }
    final myId = ApiService.instance.currentUser?.id ?? '';
    final isGoing = ev.goingIds.contains(myId);
    final isMaybe = ev.maybeIds.contains(myId);
    final isNo = ev.notGoingIds.contains(myId);
    final cardWidth = math.min(310.0, MediaQuery.of(context).size.width * 0.68);

    Widget rsvpBtn(String status, String label, bool active, int count) {
      return Expanded(
        child: OutlinedButton(
          onPressed: () async {
            try {
              final updated = await ApiService.instance.rsvpEvent(msg.id, status);
              if (!mounted) return;
              setState(() {
                _messages = _messages
                    .map((m) => m.id == msg.id ? updated : m)
                    .toList();
              });
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('ตอบรับนัดหมายไม่สำเร็จ: ${cleanErrorMessage(e)}')),
              );
            }
          },
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            backgroundColor: active ? AppTheme.brandSoft : Colors.white,
            foregroundColor: active ? AppTheme.brandDeep : AppTheme.slateBody,
            side: BorderSide(
              color: active ? AppTheme.brandPrimary : AppTheme.borderSubtle,
            ),
          ),
          child: Text(
            '$label ($count)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
      );
    }

    return Container(
      width: cardWidth,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_rounded, size: 18, color: AppTheme.brandPrimary),
              const SizedBox(width: 6),
              Text(
                'นัดหมาย / กิจกรรม',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.brandDeep,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            ev.title,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              color: AppTheme.slateDark,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '🕒 ${formatThaiTime(ev.startsAt)}',
            style: const TextStyle(fontSize: 12, color: AppTheme.slateBody),
          ),
          if (ev.location.isNotEmpty)
            Text(
              '📍 ${ev.location}',
              style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            ),
          if (ev.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              ev.description,
              style: const TextStyle(fontSize: 12, color: AppTheme.slateBody),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              rsvpBtn('going', 'ไป', isGoing, ev.goingIds.length),
              const SizedBox(width: 6),
              rsvpBtn('maybe', 'อาจจะ', isMaybe, ev.maybeIds.length),
              const SizedBox(width: 6),
              rsvpBtn('not_going', 'ไม่ไป', isNo, ev.notGoingIds.length),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRichCardBubble(ChatMessage msg) {
    final card = msg.cardPayload ?? const <String, dynamic>{};
    final appTitle = (card['app_title'] ?? 'BC Ai Chat Mini-App').toString();
    final title = (card['title'] ?? msg.cleanContent).toString();
    final subtitle = (card['subtitle'] ?? '').toString();
    final highlight = (card['highlight'] ?? '').toString();
    final badge = (card['badge'] ?? 'การ์ดโต้ตอบ').toString();
    final note = (card['note'] ?? '').toString();
    final colorHex = (card['color'] ?? '#812920').toString();
    final iconName = (card['icon'] ?? 'widgets').toString();
    final accent = AppTheme.parseHexColor(colorHex);

    final approvalStatus = (card['approval_status'] ?? card['status'] ?? '')
        .toString();
    final approvedBy = (card['approved_by'] ?? '').toString();
    final isApproved =
        approvalStatus == 'อนุมัติแล้ว' ||
        (approvedBy.isNotEmpty && !approvalStatus.contains('ไม่อนุมัติ'));
    final isRejected = approvalStatus == 'ไม่อนุมัติ';
    final cardWidth = math.min(290.0, MediaQuery.of(context).size.width * 0.64);

    return Container(
      width: cardWidth,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.shadowMd,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accent, Color.lerp(accent, Colors.black, 0.2)!],
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  AppTheme.resolveMiniAppIcon(iconName),
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    appTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.slateDark,
                    height: 1.4,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.slateBody,
                      height: 1.4,
                    ),
                  ),
                ],
                if (highlight.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceBg,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      border: Border.all(color: AppTheme.borderSubtle),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'รายละเอียด',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            highlight,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    note,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.slateMuted,
                      height: 1.4,
                    ),
                  ),
                ],
                const SizedBox(height: 12),

                // Digital Approval Stamp or In-Chat Live Approval Buttons
                if (isApproved || isRejected)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isRejected
                          ? const Color(0xFFFEF2F2)
                          : AppTheme.brandSoft,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      border: Border.all(
                        color: isRejected
                            ? AppTheme.dangerRed
                            : AppTheme.brandPrimary,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          isRejected
                              ? Icons.cancel_rounded
                              : Icons.verified_rounded,
                          size: 16,
                          color: isRejected
                              ? AppTheme.dangerRed
                              : AppTheme.brandDeep,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            isRejected
                                ? 'ไม่สะดวกโดย ${approvedBy.isNotEmpty ? approvedBy : "ผู้รับ"}'
                                : 'ตกลงโดย ${approvedBy.isNotEmpty ? approvedBy : "ผู้รับ"}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: isRejected
                                  ? AppTheme.dangerRed
                                  : AppTheme.brandDeep,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 38,
                          child: ElevatedButton.icon(
                            onPressed: () =>
                                _handleApproveRichCard(msg, 'อนุมัติแล้ว'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.brandPrimary,
                              foregroundColor: Colors.white,
                              minimumSize: Size.zero,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusSm,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.check_rounded, size: 16),
                            label: const Text(
                              'อนุมัติทันที',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: SizedBox(
                          height: 38,
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                _handleApproveRichCard(msg, 'ไม่อนุมัติ'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.dangerRed,
                              minimumSize: Size.zero,
                              side: const BorderSide(
                                color: AppTheme.dangerRed,
                                width: 1.2,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusSm,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.close_rounded, size: 16),
                            label: const Text(
                              'ไม่อนุมัติ',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      final appCode = (card['app_code'] ?? '').toString();
                      final targetApp = widget.miniApps.isNotEmpty
                          ? widget.miniApps.firstWhere(
                              (a) => a.code == appCode,
                              orElse: () => widget.miniApps.first,
                            )
                          : MiniAppItem(
                              id: 'custom',
                              code: appCode.isEmpty ? 'leave' : appCode,
                              title: appTitle,
                              subtitle: subtitle,
                              category: 'บริการเสริม',
                              icon: iconName,
                              color: colorHex,
                              url: '/miniapp/$appCode',
                              enabled: true,
                            );
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MiniAppRunnerScreen(
                            miniApp: targetApp,
                            conversations: widget.allConversations,
                            initialConversationId: _conversation.id,
                            onCardSent: (_) {
                              _refreshMessagesQuietly();
                              widget.onConversationUpdated?.call();
                            },
                          ),
                        ),
                      );
                    },
                    icon: Icon(
                      Icons.open_in_new_rounded,
                      size: 13,
                      color: accent,
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: Size.zero,
                      side: BorderSide(color: accent.withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      ),
                    ),
                    label: Text(
                      'เปิดระบบเสริม ($appTitle)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStickerPickerPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xF5FFFFFF),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'สติกเกอร์ "อารมณ์ดีดินเผาไทย" (คลิกเพื่อส่งทันที)',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _activeComposerTray = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _thaiStickers.map((stk) {
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _sendSticker(stk),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.borderSubtle),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(stk['emoji']!, style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 6),
                      Text(
                        stk['label']!,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.slateDark,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineAttachmentTray() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xF5FFFFFF),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_upload_rounded,
                color: AppTheme.brandPrimary,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'แนบรูป ไฟล์เก็บถาวร & กิจกรรมในห้อง',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _activeComposerTray = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 0,
            children: [
              ActionChip(
                avatar: Icon(
                  Icons.folder_open_rounded,
                  size: 16,
                  color: AppTheme.brandPrimary,
                ),
                label: const Text('เลือกรูป/ไฟล์จากเครื่อง'),
                onPressed: () {
                  setState(() => _activeComposerTray = null);
                  _pickAndUploadFile();
                },
              ),
              ActionChip(
                avatar: const Icon(
                  Icons.map_rounded,
                  size: 16,
                  color: AppTheme.workBlue,
                ),
                label: const Text('ส่งไฟล์แพลนเที่ยวตัวอย่าง'),
                onPressed: () {
                  setState(() => _activeComposerTray = null);
                  final sampleContent = utf8.encode(
                    'บันทึกแพลนเที่ยว & ของฝาก BC Ai Chat\n'
                    'ทริป: เชียงใหม่ - บ้านเชียง 3 วัน 2 คืน\n'
                    'จุดแวะ: คาเฟ่ริมน้ำ, ตลาดเช้า, บ้านญาติ\n'
                    'จัดเก็บไฟล์ถาวร (ส่งผิดกดลบทันที)\n',
                  );
                  _uploadBytesAndSend(
                    fileName:
                        'trip-plan-${DateTime.now().millisecondsSinceEpoch % 10000}.txt',
                    bytes: sampleContent,
                    extension: 'txt',
                  );
                },
              ),
              ActionChip(
                avatar: Icon(
                  Icons.mic_rounded,
                  size: 16,
                  color: AppTheme.brandPrimary,
                ),
                label: const Text('ส่งไฟล์เสียง'),
                onPressed: () {
                  setState(() => _activeComposerTray = null);
                  _pickAndUploadAudio();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.poll_outlined, size: 16),
                label: const Text('สร้างโพลโหวต'),
                onPressed: () {
                  setState(() => _activeComposerTray = null);
                  _openCreatePollDialog();
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.event_available_outlined, size: 16),
                label: const Text('นัดเจอ / กิจกรรม'),
                onPressed: () {
                  setState(() => _activeComposerTray = null);
                  _openEventsDialog();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInlineEditMessageTray() {
    final target = _editingMessage;
    if (target == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFFDF8F6),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.edit_rounded, size: 16, color: AppTheme.workBlue),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'แก้ไขข้อความของคุณ',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _editingMessage = null;
                  _editMsgCtrl.clear();
                }),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _editMsgCtrl,
                  onSubmitted: (_) => _saveEditedMessage(),
                  decoration: const InputDecoration(
                    hintText: 'พิมพ์ข้อความใหม่...',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _savingEdit ? null : _saveEditedMessage,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brandPrimary,
                  visualDensity: VisualDensity.compact,
                ),
                child: _savingEdit
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('บันทึก'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInlineForwardTray() {
    final target = _forwardingMessage;
    if (target == null) return const SizedBox.shrink();
    final rooms = widget.allConversations
        .where((c) => c.id != _conversation.id && !c.isBlockedByMe)
        .toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFFDF8F6),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.shortcut_rounded, size: 17, color: AppTheme.brandPrimary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'ส่งต่อไปยังห้องอื่น (สูงสุด 10 ห้อง): ${target.previewText}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              FilledButton(
                onPressed: (_forwardTargetIds.isEmpty || _sendingForward)
                    ? null
                    : _submitForwardMessage,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brandPrimary,
                  visualDensity: VisualDensity.compact,
                ),
                child: _sendingForward
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text('ส่งต่อ (${_forwardTargetIds.length})'),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _forwardingMessage = null;
                  _forwardTargetIds.clear();
                }),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (rooms.isEmpty)
            const Text(
              'ยังไม่มีห้องอื่นสำหรับส่งต่อ',
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 132),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  children: List.generate(rooms.length, (i) {
                    final r = rooms[i];
                    final selected = _forwardTargetIds.contains(r.id);
                    return FilterChip(
                      selected: selected,
                      selectedColor: AppTheme.brandSoft,
                      label: Text(
                        r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onSelected: (v) {
                        setState(() {
                          if (v) {
                            if (_forwardTargetIds.length < 10) {
                              _forwardTargetIds.add(r.id);
                            }
                          } else {
                            _forwardTargetIds.remove(r.id);
                          }
                        });
                      },
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInlineMiniAppTray() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xF5FFFFFF),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.widgets_rounded,
                color: AppTheme.brandPrimary,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'เลือกผู้ช่วยส่วนตัวเพื่อส่งการ์ดเข้าห้องแชท',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _activeComposerTray = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(widget.miniApps.length, (i) {
                final app = widget.miniApps[i];
                final color = AppTheme.parseHexColor(app.color);
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    setState(() => _activeComposerTray = null);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MiniAppRunnerScreen(
                          miniApp: app,
                          conversations: widget.allConversations,
                          initialConversationId: _conversation.id,
                          onCardSent: (_) {
                            _refreshMessagesQuietly();
                            widget.onConversationUpdated?.call();
                          },
                        ),
                      ),
                    );
                  },
                  child: Container(
                    width: 168,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.borderSubtle),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            AppTheme.resolveMiniAppIcon(app.icon),
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            app.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateDark,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyBanner(ChatMessage replyMsg) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
      decoration: const BoxDecoration(
        color: Color(0xF5F8FAFC),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.reply_rounded, size: 18, color: AppTheme.brandDeep),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ตอบกลับ ${replyMsg.senderName}: ${replyMsg.previewText}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.slateDark,
              ),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _replyingTo = null),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  /// Compact pill used by the composer mode row (priority, confidential, AI shortcuts).
  Widget _modeChip({
    required VoidCallback onTap,
    required IconData icon,
    required String label,
    required Color fg,
    Color? bg,
    Gradient? gradient,
    Color? borderColor,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppTheme.motionFast,
          curve: AppTheme.motionCurve,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            gradient: gradient,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor ?? Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveModeStatusRow() {
    final isUrgent = _selectedPriority == 'urgent';
    final isSilent = _selectedPriority == 'silent';
    final isDisappearOn = _disappearMode != 'off';
    if (!isUrgent && !isSilent && !_isConfidentialMode && !isDisappearOn) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          if (isUrgent)
            _modeChip(
              onTap: () => setState(() => _selectedPriority = 'normal'),
              icon: Icons.notifications_active_rounded,
              label: 'เรื่องด่วน ✕',
              fg: Colors.white,
              bg: AppTheme.dangerRed,
            ),
          if (isSilent)
            _modeChip(
              onTap: () => setState(() => _selectedPriority = 'normal'),
              icon: Icons.nights_stay_rounded,
              label: 'ส่งแบบไร้เสียง ✕',
              fg: Colors.white,
              bg: const Color(0xFF312E81),
            ),
          if (_isConfidentialMode)
            _modeChip(
              onTap: () => setState(() => _isConfidentialMode = false),
              icon: Icons.lock_rounded,
              label: 'โหมดความลับ ✕',
              fg: Colors.white,
              bg: const Color(0xFF991B1B),
            ),
          if (isDisappearOn)
            _modeChip(
              onTap: () => setState(() => _disappearMode = 'off'),
              icon: Icons.timer_rounded,
              label: '$_disappearLabel ✕',
              fg: Colors.white,
              bg: const Color(0xFF92400E),
            ),
        ],
      ),
    );
  }

  Widget _buildAiMenuTray() {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xF5FFFFFF),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                color: AppTheme.personalPurple,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'ผู้ช่วย AI & คำสั่งด่วน',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'ปิด',
                onPressed: () => setState(() => _activeComposerTray = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _modeChip(
                onTap: () {
                  setState(() => _activeComposerTray = null);
                  _insertAiMention();
                },
                icon: Icons.psychology_rounded,
                label: '@ai ถาม AI ในห้อง',
                fg: Colors.white,
                gradient: AppTheme.aiGradient,
              ),
              _modeChip(
                onTap: () => _openAiAssistModal(initialMode: 'polish'),
                icon: Icons.auto_fix_high_rounded,
                label: 'ช่วยเกลาคำพูด',
                fg: AppTheme.personalPurple,
                bg: const Color(0xFFF3E8FF),
                borderColor: AppTheme.personalPurple.withValues(alpha: 0.3),
              ),
              _modeChip(
                onTap: () => _openAiAssistModal(initialMode: 'suggest_reply'),
                icon: Icons.tips_and_updates_rounded,
                label: 'คิดคำตอบไวจากแชทล่าสุด',
                fg: AppTheme.brandDeep,
                bg: AppTheme.brandSoft,
              ),
              _modeChip(
                onTap: _openAiSummarizeModal,
                icon: Icons.summarize_rounded,
                label: 'AI สรุปแชทสำคัญ',
                fg: AppTheme.workBlue,
                bg: const Color(0xFFE0E7FF),
              ),
              if (_conversation.isOa && _oaRichMenu.isNotEmpty)
                _modeChip(
                  onTap: () => setState(() {
                    _activeComposerTray = null;
                    _showOaRichMenu = !_showOaRichMenu;
                  }),
                  icon: Icons.grid_view_rounded,
                  label: _showOaRichMenu ? 'ซ่อนเมนูลัดร้านค้า' : 'เมนูลัดร้านค้า',
                  fg: _showOaRichMenu ? Colors.white : AppTheme.brandPrimary,
                  bg: _showOaRichMenu ? AppTheme.brandPrimary : AppTheme.brandSoft,
                ),
              if (_conversation.isOa)
                _modeChip(
                  onTap: () {
                    setState(() {
                      _activeComposerTray =
                          _activeComposerTray == 'oa_coupons'
                              ? null
                              : 'oa_coupons';
                    });
                    unawaited(_loadMetaForCallsAndOa());
                  },
                  icon: Icons.local_offer_rounded,
                  label: 'คูปองร้าน',
                  fg: AppTheme.brandDeep,
                  bg: const Color(0xFFFEF3C7),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMentionSuggestionStrip() {
    final q = _mentionQuery.trim().toLowerCase();
    final candidates = <(String id, String tag, String label)>[
      ('all', '@all', '@all (ทุกคนในห้อง)'),
      ('user_ai', '@ai', '@ai (BC AI สมองกล)'),
      ...widget.friends
          .where((f) =>
              _conversation.memberIds.isEmpty ||
              _conversation.memberIds.contains(f.id))
          .map((f) => (f.id, '@${f.displayName}', '@${f.displayName}')),
    ].where((item) {
      if (q.isEmpty) return true;
      return item.$2.toLowerCase().contains(q) ||
          item.$3.toLowerCase().contains(q);
    }).take(6).toList();

    if (candidates.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        children: List.generate(candidates.length, (i) {
          final c = candidates[i];
          return ActionChip(
            backgroundColor: AppTheme.brandSoft,
            label: Text(
              c.$3,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.brandDeep,
              ),
            ),
            onPressed: () {
              final text = _msgCtrl.text;
              final replaced = text.replaceFirst(
                RegExp(r'@(?:[^\s@]*)$'),
                '${c.$2} ',
              );
              setState(() {
                _pendingMentionIds.add(c.$1);
                _showMentionSuggestions = false;
                _mentionQuery = '';
                _msgCtrl.text = replaced;
                _msgCtrl.selection = TextSelection.fromPosition(
                  TextPosition(offset: replaced.length),
                );
              });
            },
          );
        }),
      ),
    );
  }

  Widget _buildComposerBar() {
    if (_conversation.isBlockedByMe) {
      return GlassPanel(
        blur: 16,
        tint: const Color(0xF5FEF2F2),
        border: const Border(
          top: BorderSide(color: Color(0xFFFECACA), width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(
                Icons.block_rounded,
                size: 18,
                color: AppTheme.dangerRed,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'คุณได้บล็อกผู้ใช้นี้ กรุณาปลดบล็อกก่อนส่งข้อความหรือโทร',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.dangerRed,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _setDirectPeerBlocked(false),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brandPrimary,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                ),
                child: const Text('ปลดบล็อก', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ),
      );
    }

    final accent = _isConfidentialMode
        ? const Color(0xFF991B1B)
        : _selectedPriority == 'urgent'
        ? AppTheme.dangerRed
        : AppTheme.brandPrimary;

    return GlassPanel(
      blur: 20,
      tint: _isConfidentialMode
          ? const Color(0xF2FFFBEB)
          : const Color(0xE6FFFFFF),
      border: Border(
        top: BorderSide(
          color: _isConfidentialMode
              ? AppTheme.dangerRed
              : AppTheme.borderSubtle,
          width: _isConfidentialMode ? 1.5 : 0.8,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selectedPriority != 'normal' ||
                _isConfidentialMode ||
                _disappearMode != 'off')
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _buildActiveModeStatusRow(),
              ),
            if (_showMentionSuggestions) _buildMentionSuggestionStrip(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => setState(() {
                    _selectedActionMessage = null;
                    _activeComposerTray =
                        _activeComposerTray == 'plus' ? null : 'plus';
                  }),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  tooltip: 'ส่งตำแหน่ง / แนะนำเพื่อน / เกม / ตัวเลือกส่ง',
                  icon: Icon(
                    _activeComposerTray == 'plus'
                        ? Icons.add_circle_rounded
                        : Icons.add_circle_outline_rounded,
                    color: _activeComposerTray == 'plus'
                        ? AppTheme.brandPrimary
                        : AppTheme.slateBody,
                  ),
                ),
                IconButton(
                  onPressed: _isUploading ? null : _showAttachmentMenu,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  tooltip: 'แนบรูป/ไฟล์',
                  icon: _isUploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.attach_file_rounded,
                          color: _activeComposerTray == 'attachment'
                              ? AppTheme.brandPrimary
                              : AppTheme.slateBody,
                        ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _msgCtrl,
                    onSubmitted: (_) => _sendTextMessage(),
                    textInputAction: TextInputAction.send,
                    style: const TextStyle(fontSize: 13.5, height: 1.35),
                    decoration: InputDecoration(
                      hintText: _isConfidentialMode
                          ? 'พิมพ์ข้อความลับ...'
                          : _selectedPriority == 'urgent'
                          ? 'พิมพ์ข้อความเรื่องด่วน...'
                          : 'พิมพ์ข้อความ...',
                      hintMaxLines: 1,
                      isDense: true,
                      filled: true,
                      fillColor: _isConfidentialMode
                          ? Colors.white
                          : AppTheme.surfaceBg,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      // ปุ่มสติกเกอร์ฝังที่ขอบขวาของช่องพิมพ์ — ตำแหน่งที่ผู้ใช้แอปแชทคุ้นมือ
                      suffixIconConstraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
                      ),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() {
                          _selectedActionMessage = null;
                          _activeComposerTray =
                              _activeComposerTray == 'sticker' ? null : 'sticker';
                        }),
                        padding: EdgeInsets.zero,
                        tooltip: 'สติกเกอร์',
                        icon: Icon(
                          Icons.emoji_emotions_outlined,
                          size: 20,
                          color: _activeComposerTray == 'sticker'
                              ? AppTheme.brandPrimary
                              : AppTheme.slateBody,
                        ),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(
                          color: accent.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => setState(() {
                    _selectedActionMessage = null;
                    _activeComposerTray =
                        _activeComposerTray == 'ai_menu' ? null : 'ai_menu';
                  }),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  tooltip: 'ผู้ช่วย AI',
                  icon: Icon(
                    Icons.auto_awesome_rounded,
                    size: 20,
                    color: _activeComposerTray == 'ai_menu'
                        ? AppTheme.personalPurple
                        : AppTheme.slateBody,
                  ),
                ),
                const SizedBox(width: 4),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _msgCtrl,
                  builder: (context, value, _) {
                    final ready = value.text.trim().isNotEmpty;
                    if (!ready) {
                      return Tooltip(
                        message: 'ส่งไฟล์เสียง',
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            color: AppTheme.surfaceBg,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            onPressed: _isUploading ? null : _pickAndUploadAudio,
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.mic_rounded,
                              size: 20,
                              color: AppTheme.slateBody,
                            ),
                          ),
                        ),
                      );
                    }
                    return Tooltip(
                      message: 'ส่งข้อความ',
                      child: AnimatedScale(
                        scale: 1.0,
                        duration: AppTheme.motionFast,
                        curve: AppTheme.motionCurve,
                        child: AnimatedContainer(
                          duration: AppTheme.motionMed,
                          curve: AppTheme.motionCurve,
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                            boxShadow: AppTheme.glow(accent),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _sendTextMessage,
                              child: const Center(
                                child: Icon(
                                  Icons.send_rounded,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline Panel showing Permanent MinIO Vault (Images, Files) & Group Notes
class _RoomVaultPanel extends StatefulWidget {
  final Conversation conversation;
  final int initialTab;
  final VoidCallback onClose;

  const _RoomVaultPanel({
    super.key,
    required this.conversation,
    this.initialTab = 0,
    required this.onClose,
  });

  @override
  State<_RoomVaultPanel> createState() => _RoomVaultPanelState();
}

class _RoomVaultPanelState extends State<_RoomVaultPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  VaultData _vault = const VaultData(images: [], files: [], links: []);
  List<NoteItem> _roomNotes = const [];
  bool _loading = true;
  bool _showAddNoteForm = false;
  final TextEditingController _noteTitleCtrl = TextEditingController();
  final TextEditingController _noteContentCtrl = TextEditingController();
  String? _commentingNoteId;
  final TextEditingController _commentCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    );
    _loadVault();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _noteTitleCtrl.dispose();
    _noteContentCtrl.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadVault() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ApiService.instance.fetchVault(widget.conversation.id),
        ApiService.instance.fetchNotes(conversationId: widget.conversation.id),
      ]);
      if (!mounted) return;
      setState(() {
        _vault = results[0] as VaultData;
        _roomNotes = results[1] as List<NoteItem>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitNewRoomNote() async {
    final title = _noteTitleCtrl.text.trim();
    if (title.isEmpty) return;
    await ApiService.instance.createNote(
      conversationId: widget.conversation.id,
      title: title,
      content: _noteContentCtrl.text.trim(),
      category: 'โน้ตประจำห้อง',
    );
    if (!mounted) return;
    _noteTitleCtrl.clear();
    _noteContentCtrl.clear();
    setState(() => _showAddNoteForm = false);
    _loadVault();
  }

  Future<void> _submitNoteComment(String noteId) async {
    final txt = _commentCtrl.text.trim();
    if (txt.isEmpty) return;
    await ApiService.instance.addNoteComment(noteId, txt);
    if (!mounted) return;
    _commentCtrl.clear();
    setState(() => _commentingNoteId = null);
    _loadVault();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 10, 6),
          decoration: const BoxDecoration(gradient: AppTheme.navyGradient),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.cloud_done_rounded,
                    color: AppTheme.brandPrimary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'คลังรูปภาพ ไฟล์ถาวร & โน้ต — ${widget.conversation.name}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: PillBadge(
                  text:
                      'เก็บไฟล์ถาวร · ส่งผิดกดลบทำลายไฟล์ได้ทันที',
                  backgroundColor: Color(0xFF3E1914),
                  textColor: AppTheme.goldClay,
                  icon: Icons.verified_rounded,
                ),
              ),
              const SizedBox(height: 8),
              TabBar(
                controller: _tabCtrl,
                dividerColor: Colors.transparent,
                labelStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
                indicatorColor: AppTheme.brandPrimary,
                labelColor: Colors.white,
                unselectedLabelColor: const Color(0xFF94A3B8),
                tabs: [
                  Tab(text: 'รูปภาพ (${_vault.images.length})'),
                  Tab(text: 'ไฟล์เก็บไว้ (${_vault.files.length})'),
                  Tab(text: 'โน้ตประจำห้อง (${_roomNotes.length})'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabCtrl,
                  children: [
                    _buildImagesGrid(),
                    _buildFilesList(),
                    _buildRoomNotesList(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildImagesGrid() {
    if (_vault.images.isEmpty) {
      return const Center(
        child: Text(
          'ยังไม่มีรูปภาพในคลังของห้องแชทนี้',
          style: TextStyle(color: AppTheme.slateMuted),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _vault.images.length,
      itemBuilder: (ctx, i) {
        final msg = _vault.images[i];
        final url = msg.attachment?.url ?? '';
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.borderSubtle),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url.isNotEmpty)
                Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.image),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  color: Colors.black54,
                  child: Text(
                    msg.attachment?.fileName ?? msg.cleanContent,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilesList() {
    if (_vault.files.isEmpty) {
      return const Center(
        child: Text(
          'ยังไม่มีไฟล์ในคลังถาวรของห้องนี้',
          style: TextStyle(color: AppTheme.slateMuted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _vault.files.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final msg = _vault.files[i];
        final att = msg.attachment;
        return ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.borderSubtle),
          ),
          leading: const Icon(
            Icons.description_rounded,
            color: AppTheme.workBlue,
          ),
          title: Text(
            att?.fileName ?? msg.cleanContent,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
          ),
          subtitle: Text(
            'ส่งโดย ${msg.senderName} · ${formatFileSize(att?.fileSize ?? 0)}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () {
                  final url = att?.url ?? '';
                  final uri = Uri.tryParse(url);
                  if (uri != null) {
                    launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                tooltip: 'ดาวน์โหลดไฟล์',
                icon: Icon(Icons.download_rounded, color: AppTheme.brandDeep),
              ),
              IconButton(
                onPressed: () async {
                  await ApiService.instance.unsendMessage(msg.id, hard: true);
                  await _loadVault();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      backgroundColor: AppTheme.dangerRed,
                      content: Text(
                        'ลบข้อความและทำลายไฟล์ออกจากเซิร์ฟเวอร์เรียบร้อยแล้ว',
                      ),
                    ),
                  );
                },
                tooltip: 'สั่งลบและทำลายไฟล์ถาวร',
                icon: const Icon(
                  Icons.delete_forever_rounded,
                  color: AppTheme.dangerRed,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRoomNotesList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'สมุดโน้ตและเรื่องที่คุยกันไว้ในห้อง',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () =>
                    setState(() => _showAddNoteForm = !_showAddNoteForm),
                icon: Icon(
                  _showAddNoteForm ? Icons.close_rounded : Icons.add_rounded,
                  size: 16,
                ),
                label: Text(_showAddNoteForm ? 'ปิด' : 'เพิ่มโน้ตห้อง'),
              ),
            ],
          ),
        ),
        if (_showAddNoteForm)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _noteTitleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'หัวข้อโน้ต',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _noteContentCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'รายละเอียด / สิ่งที่ตกลงกัน',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _showAddNoteForm = false),
                      child: const Text('ยกเลิก'),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(
                      onPressed: _submitNewRoomNote,
                      child: const Text('บันทึกโน้ต'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: _roomNotes.isEmpty
              ? const Center(
                  child: Text(
                    'ยังไม่มีโน้ตประจำห้องแชทนี้',
                    style: TextStyle(color: AppTheme.slateMuted),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _roomNotes.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final note = _roomNotes[i];
                    final myId = ApiService.instance.currentUser?.id ?? '';
                    final liked = note.likedBy.contains(myId);
                    final isCommenting = _commentingNoteId == note.id;
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (note.isPinned) ...[
                                const Icon(
                                  Icons.push_pin_rounded,
                                  size: 15,
                                  color: AppTheme.goldPin,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  note.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: note.isPinned
                                    ? 'เลิกปักหมุด'
                                    : 'ปักหมุดโน้ต',
                                iconSize: 18,
                                onPressed: () async {
                                  await ApiService.instance.updateNote(
                                    note.id,
                                    isPinned: !note.isPinned,
                                  );
                                  _loadVault();
                                },
                                icon: Icon(
                                  note.isPinned
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                  color: AppTheme.goldPin,
                                ),
                              ),
                              IconButton(
                                tooltip: 'ลบโน้ต',
                                iconSize: 18,
                                onPressed: () async {
                                  await ApiService.instance.deleteNote(note.id);
                                  _loadVault();
                                },
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: AppTheme.dangerRed,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            note.content,
                            style: const TextStyle(fontSize: 13),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () async {
                                  await ApiService.instance.toggleNoteLike(
                                    note.id,
                                  );
                                  _loadVault();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        liked
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        size: 16,
                                        color: liked
                                            ? AppTheme.brandPrimary
                                            : AppTheme.slateMuted,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${note.likedBy.length}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 14,
                                color: AppTheme.slateMuted,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${note.comments.length} ความคิดเห็น',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.slateMuted,
                                ),
                              ),
                              const Spacer(),
                              TextButton(
                                onPressed: () => setState(() {
                                  _commentCtrl.clear();
                                  _commentingNoteId =
                                      isCommenting ? null : note.id;
                                }),
                                child: Text(isCommenting ? 'ยกเลิก' : 'คอมเมนต์'),
                              ),
                            ],
                          ),
                          if (isCommenting)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _commentCtrl,
                                      onSubmitted: (_) =>
                                          _submitNoteComment(note.id),
                                      decoration: const InputDecoration(
                                        hintText: 'พิมพ์ความคิดเห็น...',
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  ElevatedButton(
                                    onPressed: () =>
                                        _submitNoteComment(note.id),
                                    child: const Text('ส่ง'),
                                  ),
                                ],
                              ),
                            ),
                          if (note.comments.isNotEmpty) ...[
                            const Divider(height: 12),
                            ...note.comments.map(
                              (c) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  '${c.userName}: ${c.content}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.slateBody,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// DeepSeek AI Room Summary Inline Panel
class _AiSummaryPanel extends StatefulWidget {
  final Conversation conversation;
  final VoidCallback onClose;
  final Future<void> Function(String formattedText) onSendToRoom;
  final Future<void> Function(String formattedText) onSaveToNotebook;

  const _AiSummaryPanel({
    super.key,
    required this.conversation,
    required this.onClose,
    required this.onSendToRoom,
    required this.onSaveToNotebook,
  });

  @override
  State<_AiSummaryPanel> createState() => _AiSummaryPanelState();
}

class _AiSummaryPanelState extends State<_AiSummaryPanel> {
  AiSummaryResult? _result;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _runSummarize();
  }

  Future<void> _runSummarize() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiService.instance.summarizeConversation(
        widget.conversation.id,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF4C1D95), Color(0xFF1E3A8A)],
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xFFFDE68A),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '✨ BC AI สรุปแชทให้เข้าใจไว',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'ห้อง: ${widget.conversation.name} · โมเดล: ${res?.model ?? "deepseek-chat"}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFDDD6FE),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        Flexible(
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.all(36),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        color: AppTheme.personalPurple,
                      ),
                      SizedBox(height: 16),
                      Text(
                        'BC AI กำลังอ่านแชทและสรุปประเด็นสำคัญ...',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.slateBody,
                        ),
                      ),
                    ],
                  ),
                )
              : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: AppTheme.dangerRed,
                        size: 36,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.dangerRed),
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        onPressed: _runSummarize,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('ลองใหม่อีกครั้ง'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F3FF),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFDDD6FE),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.push_pin_rounded,
                                  size: 17,
                                  color: AppTheme.personalPurple,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  '📌 สรุปประเด็นสำคัญในห้องแชท',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.personalPurple,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              res?.summary ?? '-',
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: AppTheme.slateDark,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (res != null && res.actionItems.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppTheme.brandSoft,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: AppTheme.brandPrimary.withValues(
                                alpha: 0.35,
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.task_alt_rounded,
                                    size: 17,
                                    color: AppTheme.brandDeep,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '✅ สิ่งที่ต้องทำต่อ:',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.brandDeep,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              ...res.actionItems.map(
                                (item) => Padding(
                                  padding: const EdgeInsets.only(bottom: 5),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '• ',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: AppTheme.brandDeep,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          item,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.slateDark,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (res != null && res.decisions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: const Color(0xFFBFDBFE),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.lightbulb_rounded,
                                    size: 17,
                                    color: AppTheme.workBlue,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    '💡 ข้อสรุปที่คุยกันไว้',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.workBlue,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              ...res.decisions.map(
                                (d) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    '• $d',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.slateDark,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        if (!_loading && res != null)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final text = res.toFormattedNote();
                    widget.onClose();
                    await widget.onSaveToNotebook(text);
                  },
                  icon: Icon(
                    Icons.bookmark_add_rounded,
                    size: 17,
                    color: AppTheme.brandDeep,
                  ),
                  label: const Text('บันทึกเข้าสมุดบันทึก BC'),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    final text = res.toFormattedNote();
                    widget.onClose();
                    await widget.onSendToRoom(text);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.personalPurple,
                  ),
                  icon: const Icon(Icons.send_rounded, size: 17),
                  label: const Text('ส่งสรุปนี้เข้าห้องแชท'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// DeepSeek AI Writing Assistant & Smart Reply Inline Panel
class _AiWritingAssistPanel extends StatefulWidget {
  final Conversation conversation;
  final String initialDraft;
  final String initialMode;
  final VoidCallback onClose;
  final ValueChanged<String> onApplyToComposer;
  final Future<void> Function(String text) onSendImmediately;

  const _AiWritingAssistPanel({
    super.key,
    required this.conversation,
    required this.initialDraft,
    required this.initialMode,
    required this.onClose,
    required this.onApplyToComposer,
    required this.onSendImmediately,
  });

  @override
  State<_AiWritingAssistPanel> createState() => _AiWritingAssistPanelState();
}

class _AiWritingAssistPanelState extends State<_AiWritingAssistPanel> {
  late TextEditingController _draftCtrl;
  late String _mode;
  AiAssistResult? _result;
  bool _loading = false;

  static const List<(String, String, IconData)> _modes = [
    ('polish', 'เกลาให้น่ารัก/สุภาพ', Icons.auto_fix_high_rounded),
    ('suggest_reply', 'แนะนำคำตอบจากแชทล่าสุด', Icons.tips_and_updates_rounded),
    ('action_plan', 'จัดเป็นลิสต์ขั้นตอน', Icons.checklist_rounded),
    ('translate_en', 'แปลเป็นภาษาอังกฤษ', Icons.translate_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _draftCtrl = TextEditingController(text: widget.initialDraft);
    _mode = widget.initialMode;
    _runAssist();
  }

  @override
  void dispose() {
    _draftCtrl.dispose();
    super.dispose();
  }

  // Each mode chip re-runs the AI; a slower earlier reply must not overwrite the
  // answer for the mode the user picked last.
  int _runSeq = 0;

  Future<void> _runAssist() async {
    final seq = ++_runSeq;
    setState(() => _loading = true);
    try {
      final res = await ApiService.instance.requestAiAssist(
        conversationId: widget.conversation.id,
        mode: _mode,
        text: _draftCtrl.text,
      );
      if (!mounted || seq != _runSeq) return;
      setState(() {
        _result = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _runSeq) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('เรียก AI ไม่สำเร็จ: ${cleanErrorMessage(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;

    return Container(
      constraints: const BoxConstraints(maxHeight: 350),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3E8FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.psychology_rounded,
                    color: AppTheme.personalPurple,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '🪄 ผู้ช่วย BC AI เกลาคำพูด & คิดคำตอบ',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.slateDark,
                        ),
                      ),
                      Text(
                        'ช่วยเกลาข้อความ คิดคำตอบให้เพื่อน สรุปลิสต์ หรือแปลภาษาในคลิกเดียว',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 0,
              children: _modes.map((m) {
                final active = _mode == m.$1;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    selected: active,
                    selectedColor: const Color(0xFFEDE9FE),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          m.$3,
                          size: 14,
                          color: active
                              ? AppTheme.personalPurple
                              : AppTheme.slateBody,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          m.$2,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: active
                                ? AppTheme.personalPurple
                                : AppTheme.slateBody,
                          ),
                        ),
                      ],
                    ),
                    onSelected: (_) {
                      setState(() => _mode = m.$1);
                      _runAssist();
                    },
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _draftCtrl,
                    onSubmitted: (_) => _runAssist(),
                    decoration: const InputDecoration(
                      labelText:
                          'ข้อความร่างของคุณ (เว้นว่างเพื่อให้ AI อ่านจากแชทล่าสุด)',
                      isDense: true,
                      prefixIcon: Icon(Icons.edit_note_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _loading ? null : _runAssist,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.personalPurple,
                  ),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: const Text('ให้ AI ช่วยคิด'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(18),
                child: Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.personalPurple,
                  ),
                ),
              )
            else if (res != null && res.suggestion.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F3FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFDDD6FE)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '✨ ข้อความที่ BC AI แนะนำ:',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.personalPurple,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      res.suggestion,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              widget.onApplyToComposer(res.suggestion),
                          icon: const Icon(Icons.input_rounded, size: 15),
                          label: const Text('ใส่ช่องพิมพ์'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () =>
                              widget.onSendImmediately(res.suggestion),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.brandPrimary,
                          ),
                          icon: const Icon(Icons.send_rounded, size: 15),
                          label: const Text('ส่งทันที'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (res.alternatives.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...res.alternatives
                    .take(2)
                    .map(
                      (alt) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => widget.onApplyToComposer(alt),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppTheme.borderSubtle,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    alt,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const Icon(
                                  Icons.north_west_rounded,
                                  size: 14,
                                  color: AppTheme.personalPurple,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _RoomAlbumsPanel extends StatefulWidget {
  final Conversation conversation;
  final VoidCallback onClose;

  const _RoomAlbumsPanel({
    super.key,
    required this.conversation,
    required this.onClose,
  });

  @override
  State<_RoomAlbumsPanel> createState() => _RoomAlbumsPanelState();
}

class _RoomAlbumsPanelState extends State<_RoomAlbumsPanel> {
  List<AlbumItem> _albums = const [];
  bool _loading = true;
  bool _showCreateForm = false;
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ApiService.instance.fetchAlbums(
        widget.conversation.id,
      );
      if (!mounted) return;
      setState(() {
        _albums = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<AttachmentInfo>> _pickPhotos() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty) return const [];
    final out = <AttachmentInfo>[];
    for (final picked in files) {
      final bytes = await picked.readAsBytes();
      final ext = (picked.extension ?? 'png').toLowerCase();
      final mime = ext == 'jpg' ? 'image/jpeg' : 'image/$ext';
      final att = await ApiService.instance.uploadFileBase64(
        fileName: picked.name,
        mimeType: mime,
        dataBase64: base64Encode(bytes),
      );
      out.add(att);
    }
    return out;
  }

  Future<void> _submitCreateAlbum() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    try {
      final photos = await _pickPhotos();
      await ApiService.instance.createAlbum(
        widget.conversation.id,
        title: title,
        description: _descCtrl.text.trim(),
        photos: photos,
      );
      if (!mounted) return;
      _titleCtrl.clear();
      _descCtrl.clear();
      setState(() => _showCreateForm = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('สร้างอัลบั้มไม่สำเร็จ: ${cleanErrorMessage(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: const BoxDecoration(gradient: AppTheme.navyGradient),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.photo_library_rounded, color: AppTheme.goldClay),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'อัลบั้มรูปภาพ — ${widget.conversation.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () =>
                    setState(() => _showCreateForm = !_showCreateForm),
                icon: Icon(
                  _showCreateForm
                      ? Icons.close_rounded
                      : Icons.add_photo_alternate_rounded,
                  size: 15,
                ),
                label: Text(_showCreateForm ? 'ปิด' : 'สร้างอัลบั้ม'),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        if (_showCreateForm)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ชื่ออัลบั้ม (เช่น ทริปเชียงใหม่)',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(
                    labelText: 'คำอธิบาย (ไม่บังคับ)',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _showCreateForm = false),
                      child: const Text('ยกเลิก'),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(
                      onPressed: _submitCreateAlbum,
                      child: const Text('เลือกรูป & สร้าง'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _albums.isEmpty
              ? const Center(
                  child: Text(
                    'ยังไม่มีอัลบั้มรูปภาพ กดปุ่ม "สร้างอัลบั้ม" ด้านบนเพื่อเก็บรูปถาวร',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.slateMuted),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _albums.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (ctx, i) {
                    final alb = _albums[i];
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${alb.title} (${alb.photos.length} รูป)',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14.5,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () async {
                                  try {
                                    final photos = await _pickPhotos();
                                    if (photos.isEmpty) return;
                                    await ApiService.instance.addAlbumPhotos(
                                      alb.id,
                                      photos,
                                    );
                                    await _load();
                                  } catch (_) {}
                                },
                                icon: const Icon(Icons.add_rounded, size: 16),
                                label: const Text('เพิ่มรูป'),
                              ),
                              IconButton(
                                onPressed: () async {
                                  await ApiService.instance.deleteAlbum(alb.id);
                                  await _load();
                                },
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: AppTheme.dangerRed,
                                ),
                              ),
                            ],
                          ),
                          if (alb.description.isNotEmpty)
                            Text(
                              alb.description,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.slateMuted,
                              ),
                            ),
                          if (alb.photos.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 92,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: alb.photos.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, pIdx) {
                                  final photo = alb.photos[pIdx];
                                  return ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Image.network(
                                      photo.url,
                                      width: 92,
                                      height: 92,
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stack) =>
                                          Container(
                                            width: 92,
                                            height: 92,
                                            color: AppTheme.borderSubtle,
                                            child: const Icon(Icons.image),
                                          ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RoomEventsPanel extends StatefulWidget {
  final Conversation conversation;
  final VoidCallback onClose;
  final ValueChanged<ChatMessage> onEventCreated;

  const _RoomEventsPanel({
    super.key,
    required this.conversation,
    required this.onClose,
    required this.onEventCreated,
  });

  @override
  State<_RoomEventsPanel> createState() => _RoomEventsPanelState();
}

class _RoomEventsPanelState extends State<_RoomEventsPanel> {
  List<ChatMessage> _events = const [];
  bool _loading = true;
  bool _showCreateForm = false;
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _locCtrl =
      TextEditingController(text: 'คาเฟ่ / ออนไลน์');
  final TextEditingController _descCtrl = TextEditingController();
  DateTime _pickedDate = DateTime.now().add(const Duration(days: 1));
  TimeOfDay _pickedTime = const TimeOfDay(hour: 10, minute: 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ApiService.instance.fetchEvents(
        widget.conversation.id,
      );
      if (!mounted) return;
      setState(() {
        _events = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitCreateEvent() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return;
    final startsAt = DateTime(
      _pickedDate.year,
      _pickedDate.month,
      _pickedDate.day,
      _pickedTime.hour,
      _pickedTime.minute,
    ).toUtc().toIso8601String();
    try {
      final created = await ApiService.instance.createEvent(
        widget.conversation.id,
        title: title,
        description: _descCtrl.text.trim(),
        startsAt: startsAt,
        location: _locCtrl.text.trim(),
      );
      if (!mounted) return;
      _titleCtrl.clear();
      _descCtrl.clear();
      setState(() => _showCreateForm = false);
      widget.onEventCreated(created);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('สร้างนัดหมายไม่สำเร็จ: ${cleanErrorMessage(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = ApiService.instance.currentUser?.id ?? '';
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: const BoxDecoration(gradient: AppTheme.navyGradient),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.event_available_rounded, color: AppTheme.goldClay),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'นัดหมาย & กิจกรรม — ${widget.conversation.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () =>
                    setState(() => _showCreateForm = !_showCreateForm),
                icon: Icon(
                  _showCreateForm ? Icons.close_rounded : Icons.add_rounded,
                  size: 15,
                ),
                label: Text(_showCreateForm ? 'ปิด' : 'สร้างนัดหมาย'),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        if (_showCreateForm)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'หัวข้อนัดหมาย (เช่น นัดทานข้าวเย็นวันเสาร์)',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _locCtrl,
                  decoration: const InputDecoration(
                    labelText: 'สถานที่ / ลิงก์วิดีโอคอล',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(
                    labelText: 'รายละเอียดเพิ่มเติม',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: context,
                            initialDate: _pickedDate,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365),
                            ),
                          );
                          if (d != null && mounted) {
                            setState(() => _pickedDate = d);
                          }
                        },
                        icon: const Icon(Icons.calendar_today_rounded, size: 15),
                        label: Text(
                          '${_pickedDate.day}/${_pickedDate.month}/${_pickedDate.year}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final t = await showTimePicker(
                            context: context,
                            initialTime: _pickedTime,
                          );
                          if (t != null && mounted) {
                            setState(() => _pickedTime = t);
                          }
                        },
                        icon: const Icon(Icons.access_time_rounded, size: 15),
                        label: Text(
                          '${_pickedTime.hour.toString().padLeft(2, '0')}:${_pickedTime.minute.toString().padLeft(2, '0')}',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _showCreateForm = false),
                      child: const Text('ยกเลิก'),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(
                      onPressed: _submitCreateEvent,
                      child: const Text('ส่งนัดหมายเข้าห้อง'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _events.isEmpty
              ? const Center(
                  child: Text(
                    'ยังไม่มีนัดหมายในห้องนี้ กดปุ่ม "สร้างนัดหมาย" ด้านบนเพื่อส่งเชิญเพื่อน',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.slateMuted),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _events.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (ctx, i) {
                    final msg = _events[i];
                    final ev = msg.eventData;
                    if (ev == null) return const SizedBox.shrink();
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ev.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '🕒 ${formatThaiTime(ev.startsAt)}  📍 ${ev.location}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.slateBody,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: Text('ไป (${ev.goingIds.length})'),
                                selected: ev.goingIds.contains(myId),
                                onSelected: (_) async {
                                  await ApiService.instance.rsvpEvent(
                                    msg.id,
                                    'going',
                                  );
                                  _load();
                                },
                              ),
                              ChoiceChip(
                                label: Text('อาจจะ (${ev.maybeIds.length})'),
                                selected: ev.maybeIds.contains(myId),
                                onSelected: (_) async {
                                  await ApiService.instance.rsvpEvent(
                                    msg.id,
                                    'maybe',
                                  );
                                  _load();
                                },
                              ),
                              ChoiceChip(
                                label: Text(
                                  'ไม่ไป (${ev.notGoingIds.length})',
                                ),
                                selected: ev.notGoingIds.contains(myId),
                                onSelected: (_) async {
                                  await ApiService.instance.rsvpEvent(
                                    msg.id,
                                    'not_going',
                                  );
                                  _load();
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _InlineCreatePollPanel extends StatefulWidget {
  final String conversationId;
  final VoidCallback onClose;
  final ValueChanged<ChatMessage> onCreated;

  const _InlineCreatePollPanel({
    required this.conversationId,
    required this.onClose,
    required this.onCreated,
  });

  @override
  State<_InlineCreatePollPanel> createState() => _InlineCreatePollPanelState();
}

class _InlineCreatePollPanelState extends State<_InlineCreatePollPanel> {
  final TextEditingController _questionCtrl = TextEditingController();
  final List<TextEditingController> _optCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _allowMultiple = false;
  bool _isAnonymous = false;
  bool _submitting = false;

  @override
  void dispose() {
    _questionCtrl.dispose();
    for (final c in _optCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final q = _questionCtrl.text.trim();
    final opts = _optCtrls
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (q.isEmpty || opts.length < 2 || _submitting) return;
    setState(() => _submitting = true);
    try {
      final sent = await ApiService.instance.createPoll(
        widget.conversationId,
        question: q,
        options: opts,
        allowMultiple: _allowMultiple,
        isAnonymous: _isAnonymous,
      );
      if (!mounted) return;
      widget.onCreated(sent);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('สร้างโพลไม่สำเร็จ: ${cleanErrorMessage(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 8, 12),
          decoration: const BoxDecoration(gradient: AppTheme.navyGradient),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.poll_rounded, color: AppTheme.goldClay),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'สร้างโพลโหวตในห้องแชท',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _questionCtrl,
                  decoration: const InputDecoration(
                    labelText: 'หัวข้อ / คำถามโพล (เช่น เย็นนี้กินอะไรดี?)',
                    prefixIcon: Icon(Icons.poll_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                ...List.generate(_optCtrls.length, (idx) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _optCtrls[idx],
                            decoration: InputDecoration(
                              labelText: 'ตัวเลือกที่ ${idx + 1}',
                              isDense: true,
                            ),
                          ),
                        ),
                        if (_optCtrls.length > 2)
                          IconButton(
                            onPressed: () {
                              final removed = _optCtrls.removeAt(idx);
                              removed.dispose();
                              setState(() {});
                            },
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                      ],
                    ),
                  );
                }),
                if (_optCtrls.length < 6)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(
                        () => _optCtrls.add(TextEditingController()),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('เพิ่มตัวเลือก'),
                    ),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowMultiple,
                  onChanged: (v) =>
                      setState(() => _allowMultiple = v ?? false),
                  title: const Text('อนุญาตให้เลือกหลายข้อ'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _isAnonymous,
                  onChanged: (v) => setState(() => _isAnonymous = v ?? false),
                  title: const Text('โหวตแบบไม่ระบุชื่อ'),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: widget.onClose,
                      child: const Text('ยกเลิก'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _submitting ? null : _submit,
                      child: const Text('ส่งโพลเข้าห้อง'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InlineGroupManagePanel extends StatefulWidget {
  final Conversation conversation;
  final List<AppUser> friends;
  final bool isEmbedded;
  final ChatRoomThemeMode themeMode;
  final ValueChanged<ChatRoomThemeMode> onThemeChanged;
  final VoidCallback onToggleSearch;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleFolder;
  final VoidCallback onOpenVault;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenNotes;
  final VoidCallback onOpenPoll;
  final VoidCallback onOpenEvents;
  final VoidCallback onClose;
  final Future<void> Function(String duration) onSetMuteDuration;
  final Future<void> Function(bool archived) onToggleArchive;
  final ValueChanged<Conversation> onConversationChanged;
  final VoidCallback onConversationLeft;

  const _InlineGroupManagePanel({
    required this.conversation,
    required this.friends,
    required this.isEmbedded,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onToggleSearch,
    required this.onTogglePin,
    required this.onToggleFolder,
    required this.onOpenVault,
    required this.onOpenAlbums,
    required this.onOpenNotes,
    required this.onOpenPoll,
    required this.onOpenEvents,
    required this.onClose,
    required this.onSetMuteDuration,
    required this.onToggleArchive,
    required this.onConversationChanged,
    required this.onConversationLeft,
  });

  @override
  State<_InlineGroupManagePanel> createState() =>
      _InlineGroupManagePanelState();
}

class _InlineGroupManagePanelState extends State<_InlineGroupManagePanel> {
  final Set<String> _selectedToAdd = <String>{};
  late bool _archived;
  bool _savingMute = false;
  bool _savingPeerAction = false;

  @override
  void initState() {
    super.initState();
    _archived = widget.conversation.isArchived;
  }

  String _formatMutedTime(DateTime? dt) {
    if (dt == null) return '';
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm น.';
  }

  String _muteStatusLabel(Conversation conv) {
    if (conv.isMuted) return 'ปิดแจ้งเตือนถาวร';
    final until = conv.mutedUntilDate;
    if (until != null && conv.isEffectivelyMuted) {
      return 'ปิดแจ้งเตือนจนถึง ${_formatMutedTime(until)}';
    }
    return 'เปิดแจ้งเตือนปกติ';
  }

  Future<void> _pickMuteDuration(String duration) async {
    setState(() => _savingMute = true);
    try {
      await widget.onSetMuteDuration(duration);
    } finally {
      if (mounted) setState(() => _savingMute = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ApiService.instance.currentUser;
    final meId = currentUser?.id ?? '';
    final conv = widget.conversation;
    final hasAi = conv.memberIds.contains('user_ai');
    final candidateFriends = widget.friends
        .where((f) => !conv.memberIds.contains(f.id) && f.id != meId)
        .toList();
    final directPeerId = conv.peerUser?.id ??
        conv.memberIds.where((id) => id != meId).firstOrNull ??
        '';
    final matchedFriend = widget.friends
        .where((f) => f.id == directPeerId)
        .firstOrNull;
    final isDirectUser =
        !conv.isGroup && !conv.isOa && !conv.isOfficial && directPeerId.isNotEmpty;
    final isBlocked = conv.isBlockedByMe || (matchedFriend?.isBlocked ?? false);
    final isHidden = matchedFriend?.isHidden ?? false;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 8, 12),
          decoration: const BoxDecoration(gradient: AppTheme.navyGradient),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.tune_rounded, color: AppTheme.goldClay),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  conv.isGroup
                      ? 'จัดการกลุ่ม & ตั้งค่าห้องแชท'
                      : 'ตั้งค่าห้องแชท',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'เครื่องมือในห้องแชท',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.search_rounded, size: 16),
                      label: const Text('ค้นหาข้อความ', style: TextStyle(fontSize: 12)),
                      onPressed: () {
                        widget.onClose();
                        widget.onToggleSearch();
                      },
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        conv.isPinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 16,
                        color: conv.isPinned ? AppTheme.goldPin : null,
                      ),
                      label: Text(
                        conv.isPinned ? 'เลิกปักหมุดห้อง' : 'ปักหมุดห้อง',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: widget.onTogglePin,
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.folder_copy_outlined, size: 16),
                      label: const Text('คลังรูป & ไฟล์', style: TextStyle(fontSize: 12)),
                      onPressed: widget.onOpenVault,
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.photo_library_outlined, size: 16),
                      label: const Text('อัลบั้มรูปภาพ', style: TextStyle(fontSize: 12)),
                      onPressed: widget.onOpenAlbums,
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.sticky_note_2_outlined, size: 16),
                      label: const Text('โน้ตห้อง', style: TextStyle(fontSize: 12)),
                      onPressed: widget.onOpenNotes,
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.poll_outlined, size: 16),
                      label: const Text('สร้างโพลโหวต', style: TextStyle(fontSize: 12)),
                      onPressed: widget.onOpenPoll,
                    ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.event_available_outlined, size: 16),
                      label: const Text('นัดหมาย & กิจกรรม', style: TextStyle(fontSize: 12)),
                      onPressed: widget.onOpenEvents,
                    ),
                    if (!conv.isOa && !conv.isOfficial)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.label_outline_rounded, size: 16),
                        label: Text(
                          'หมวด: ${conv.folderLabel}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: widget.onToggleFolder,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'สีพื้นหลังห้องแชท',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: ChatRoomThemeMode.values.map((m) {
                    final selected = widget.themeMode == m;
                    return ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      selected: selected,
                      selectedColor: AppTheme.brandSoft,
                      avatar: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: m.backgroundColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppTheme.borderSubtle),
                        ),
                      ),
                      label: Text(
                        m.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      onSelected: (_) => widget.onThemeChanged(m),
                    );
                  }).toList(),
                ),
                const Divider(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      conv.isEffectivelyMuted
                          ? Icons.notifications_off_outlined
                          : Icons.notifications_active_outlined,
                      size: 18,
                      color: conv.isEffectivelyMuted
                          ? AppTheme.brandPrimary
                          : AppTheme.slateBody,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'การแจ้งเตือนห้องนี้',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _muteStatusLabel(conv),
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final opt in const [
                      (code: 'off', label: 'เปิดเสียง'),
                      (code: '1h', label: '1 ชม.'),
                      (code: '8h', label: '8 ชม.'),
                      (code: 'until_8am', label: 'ถึง 08:00 น.'),
                      (code: 'forever', label: 'ปิดถาวร'),
                    ])
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: ((opt.code == 'off' &&
                                    !conv.isEffectivelyMuted) ||
                                (opt.code == 'forever' && conv.isMuted))
                            ? AppTheme.brandSoft
                            : AppTheme.surfaceBg,
                        label: Text(
                          opt.label,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: _savingMute
                            ? null
                            : () => _pickMuteDuration(opt.code),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.inventory_2_outlined),
                  title: const Text('เก็บห้องแชทเข้าถาวร'),
                  value: _archived,
                  onChanged: (v) async {
                    setState(() => _archived = v);
                    await widget.onToggleArchive(v);
                  },
                ),
                if (isDirectUser) ...[
                  const Divider(),
                  const Text(
                    'จัดการเพื่อนในห้อง 1-1',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateDark,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _savingPeerAction
                            ? null
                            : () async {
                                setState(() => _savingPeerAction = true);
                                try {
                                  await ApiService.instance.updateFriendMeta(
                                    directPeerId,
                                    isHidden: !isHidden,
                                  );
                                  widget.onConversationChanged(conv);
                                } finally {
                                  if (mounted) {
                                    setState(() => _savingPeerAction = false);
                                  }
                                }
                              },
                        icon: Icon(
                          isHidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 16,
                        ),
                        label: Text(isHidden ? 'เลิกซ่อน' : 'ซ่อนเพื่อน'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _savingPeerAction
                            ? null
                            : () async {
                                setState(() => _savingPeerAction = true);
                                try {
                                  final nextBlock = !isBlocked;
                                  await ApiService.instance.updateFriendMeta(
                                    directPeerId,
                                    isBlocked: nextBlock,
                                  );
                                  widget.onConversationChanged(
                                    conv.copyWith(isBlockedByMe: nextBlock),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() => _savingPeerAction = false);
                                  }
                                }
                              },
                        icon: Icon(
                          Icons.block_rounded,
                          size: 16,
                          color: isBlocked
                              ? AppTheme.brandPrimary
                              : AppTheme.dangerRed,
                        ),
                        label: Text(
                          isBlocked ? 'ปลดบล็อก' : 'บล็อกเพื่อน',
                          style: TextStyle(
                            color: isBlocked
                                ? AppTheme.brandPrimary
                                : AppTheme.dangerRed,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _savingPeerAction
                            ? null
                            : () async {
                                setState(() => _savingPeerAction = true);
                                try {
                                  await ApiService.instance.deleteFriend(
                                    directPeerId,
                                  );
                                  widget.onConversationLeft();
                                } finally {
                                  if (mounted) {
                                    setState(() => _savingPeerAction = false);
                                  }
                                }
                              },
                        icon: const Icon(
                          Icons.person_remove_outlined,
                          size: 16,
                          color: AppTheme.dangerRed,
                        ),
                        label: const Text(
                          'ลบเพื่อน',
                          style: TextStyle(color: AppTheme.dangerRed),
                        ),
                      ),
                    ],
                  ),
                ],
                if (conv.isGroup) ...[
                  const Divider(),
                  if (conv.inviteToken.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.brandSoft,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.borderSubtle),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'รหัสเชิญเข้ากลุ่ม',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.slateMuted,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                SelectableText(
                                  conv.inviteToken,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.brandDeep,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: conv.inviteToken),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('คัดลอกรหัสเชิญเข้ากลุ่มแล้ว'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 15),
                            label: const Text('คัดลอก'),
                          ),
                        ],
                      ),
                    ),
                  if (!hasAi)
                    ElevatedButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final updated = await ApiService.instance
                              .addConversationMembers(conv.id, ['user_ai']);
                          if (!mounted) return;
                          widget.onConversationChanged(updated);
                          widget.onClose();
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'เชิญ 🤖 BC AI เข้ากลุ่มเรียบร้อยแล้ว!',
                              ),
                            ),
                          );
                        } catch (e) {
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(content: Text('เชิญ AI ไม่สำเร็จ: ${cleanErrorMessage(e)}')),
                          );
                        }
                      },
                      icon: const Icon(Icons.psychology_rounded),
                      label: const Text('เชิญ 🤖 BC AI เข้ากลุ่ม'),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3E8FF),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.psychology_rounded,
                            color: AppTheme.personalPurple,
                            size: 18,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '🤖 BC AI อยู่ในกลุ่มนี้แล้ว (พิมพ์ @ai ถามได้ทันที)',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.personalPurple,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'สมาชิกในกลุ่ม (${conv.memberCount} คน)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateDark,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: conv.memberIds.map((mid) {
                      if (mid == 'user_ai') {
                        return const Chip(label: Text('🤖 BC AI'));
                      }
                      if (mid == meId && currentUser != null) {
                        return Chip(
                          label: Text('${currentUser.displayName} (คุณ)'),
                        );
                      }
                      final matched = widget.friends
                          .where((f) => f.id == mid)
                          .toList();
                      final label = matched.isNotEmpty
                          ? matched.first.displayName
                          : mid;
                      return Chip(label: Text(label));
                    }).toList(),
                  ),
                  if (candidateFriends.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'เชิญเพื่อนเข้ากลุ่มเพิ่ม:',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: candidateFriends.map((f) {
                        final picked = _selectedToAdd.contains(f.id);
                        return FilterChip(
                          label: Text(f.displayName),
                          selected: picked,
                          onSelected: (v) => setState(() {
                            if (v) {
                              _selectedToAdd.add(f.id);
                            } else {
                              _selectedToAdd.remove(f.id);
                            }
                          }),
                        );
                      }).toList(),
                    ),
                    if (_selectedToAdd.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            final updated = await ApiService.instance
                                .addConversationMembers(
                                  conv.id,
                                  _selectedToAdd.toList(),
                                );
                            if (!mounted) return;
                            widget.onConversationChanged(updated);
                            widget.onClose();
                          } catch (e) {
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('เชิญสมาชิกไม่สำเร็จ: ${cleanErrorMessage(e)}'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.person_add_rounded, size: 18),
                        label: Text(
                          'เชิญเพื่อนที่เลือก (${_selectedToAdd.length} คน)',
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.dangerRed,
                      side: const BorderSide(color: AppTheme.dangerRed),
                    ),
                    onPressed: () async {
                      if (meId.isEmpty) return;
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await ApiService.instance.removeConversationMember(
                          conv.id,
                          meId,
                        );
                        if (!mounted) return;
                        widget.onConversationLeft();
                      } catch (e) {
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('ออกจากกลุ่มไม่สำเร็จ: ${cleanErrorMessage(e)}'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.exit_to_app_rounded),
                    label: const Text('ออกจากกลุ่มนี้'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InlinePlusActionPanel extends StatefulWidget {
  final Conversation conversation;
  final List<AppUser> friends;
  final String selectedPriority;
  final bool isConfidentialMode;
  final String disappearLabel;
  final bool hasMiniApps;
  final VoidCallback onCyclePriority;
  final VoidCallback onToggleConfidential;
  final VoidCallback onCycleDisappear;
  final VoidCallback onOpenMiniApps;
  final VoidCallback onClose;
  final ValueChanged<LocationData> onSendLocation;
  final ValueChanged<ContactCardData> onSendContact;
  final ValueChanged<LadderGameData> onSendLadder;

  const _InlinePlusActionPanel({
    required this.conversation,
    required this.friends,
    required this.selectedPriority,
    required this.isConfidentialMode,
    required this.disappearLabel,
    required this.hasMiniApps,
    required this.onCyclePriority,
    required this.onToggleConfidential,
    required this.onCycleDisappear,
    required this.onOpenMiniApps,
    required this.onClose,
    required this.onSendLocation,
    required this.onSendContact,
    required this.onSendLadder,
  });

  @override
  State<_InlinePlusActionPanel> createState() => _InlinePlusActionPanelState();
}

class _InlinePlusActionPanelState extends State<_InlinePlusActionPanel> {
  // null = เพิ่งกด + เห็นแค่เมนู เลือกหัวข้อแล้วจึงเปิดรายละเอียดของหัวข้อนั้น
  String? _tab; // null = เห็นแค่เมนู | contact | ladder | options (ตำแหน่ง/การ์ดโต้ตอบ เปิดหน้าของตัวเองทันที)

  // Contact filter
  final TextEditingController _friendFilterCtrl = TextEditingController();

  // Ladder fields
  final TextEditingController _ladderTitleCtrl = TextEditingController(
    text: 'เกมสุ่มบันไดลุ้นโชค',
  );
  late final TextEditingController _ladderPlayersCtrl;
  final TextEditingController _ladderResultsCtrl = TextEditingController(
    text: 'เลี้ยงกาแฟ, จ่ายค่าข้าว, ล้างจาน, รอดตัว!, ลดให้ 50%, รางวัลพิเศษ',
  );

  @override
  void initState() {
    super.initState();
    final meName = ApiService.instance.currentUser?.displayName.trim() ?? '';
    final names = <String>[];
    if (meName.isNotEmpty) names.add(meName);
    for (final f in widget.friends) {
      if (widget.conversation.memberIds.isEmpty ||
          widget.conversation.memberIds.contains(f.id)) {
        if (!names.contains(f.displayName)) names.add(f.displayName);
      }
      if (names.length >= 6) break;
    }
    if (names.length < 2) {
      names
        ..clear()
        ..addAll(const ['ก้อง', 'แพร', 'บอส']);
    }
    _ladderPlayersCtrl = TextEditingController(text: names.join(', '));
  }

  @override
  void dispose() {
    _friendFilterCtrl.dispose();
    _ladderTitleCtrl.dispose();
    _ladderPlayersCtrl.dispose();
    _ladderResultsCtrl.dispose();
    super.dispose();
  }

  /// เปิดแผนที่เต็มจอ เลือกตำแหน่งแล้วส่งเข้าห้องแชททันที
  Future<void> _openFullMapPicker() async {
    final picked = await Navigator.of(context).push<({double lat, double lng})>(
      MaterialPageRoute(builder: (_) => const LocationPickerScreen()),
    );
    if (picked == null || !mounted) return;
    final lat = double.parse(picked.lat.toStringAsFixed(6));
    final lng = double.parse(picked.lng.toStringAsFixed(6));
    widget.onSendLocation(
      LocationData(
        latitude: lat,
        longitude: lng,
        title: 'ตำแหน่งที่ปักหมุด',
        address: '',
        mapUrl: 'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
      ),
    );
  }

  void _submitLadder() {
    final players = _ladderPlayersCtrl.text
        .split(RegExp(r'[,\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (players.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาใส่ชื่อผู้เล่นอย่างน้อย 2 คน')),
      );
      return;
    }
    final pool = _ladderResultsCtrl.text
        .split(RegExp(r'[,\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (pool.isEmpty) pool.addAll(const ['ผู้โชคดี!', 'รอดตัว!']);
    while (pool.length < players.length) {
      pool.add(pool[pool.length % pool.length]);
    }
    final shuffled = List<String>.from(pool)..shuffle(math.Random());
    final entries = <LadderEntry>[
      for (var i = 0; i < players.length; i++)
        LadderEntry(player: players[i], result: shuffled[i]),
    ];
    final title = _ladderTitleCtrl.text.trim().isNotEmpty
        ? _ladderTitleCtrl.text.trim()
        : 'เกมสุ่มบันไดลุ้นโชค';
    widget.onSendLadder(LadderGameData(title: title, entries: entries));
  }

  // ปุ่มเมนูแบบไอคอนบน-ข้อความล่าง (เมนูปุ่ม + เห็นเป็นตารางไอคอนก่อน เลือกแล้วจึงเข้าหัวข้อ)
  Widget _menuButton(
    String code,
    IconData icon,
    String label,
    double width, {
    VoidCallback? onTap,
  }) {
    final active = _tab == code;
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap ?? () => setState(() => _tab = code),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          decoration: BoxDecoration(
            color: active ? AppTheme.brandPrimary : AppTheme.surfaceBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? AppTheme.brandPrimary : AppTheme.borderSubtle,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: active ? Colors.white : AppTheme.slateBody,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.white : AppTheme.slateDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final friendQ = _friendFilterCtrl.text.trim().toLowerCase();
    final filteredFriends = widget.friends.where((f) {
      if (friendQ.isEmpty) return true;
      return f.displayName.toLowerCase().contains(friendQ) ||
          f.bcId.toLowerCase().contains(friendQ);
    }).toList();

    final isUrgent = widget.selectedPriority == 'urgent';
    final isSilent = widget.selectedPriority == 'silent';
    final isDisappearOn = !widget.disappearLabel.endsWith('ปิด');

    return Container(
      constraints: const BoxConstraints(maxHeight: 335),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xF8FFFFFF),
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = 6.0;
                    final columns = constraints.maxWidth >= 420 ? 5 : 3;
                    final itemWidth =
                        ((constraints.maxWidth - gap * (columns - 1)) / columns)
                            .floorToDouble();
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        _menuButton(
                          'location',
                          Icons.location_on_rounded,
                          'ตำแหน่ง',
                          itemWidth,
                          onTap: _openFullMapPicker,
                        ),
                        _menuButton(
                          'contact',
                          Icons.contact_page_rounded,
                          'แนะนำเพื่อน',
                          itemWidth,
                        ),
                        _menuButton(
                          'ladder',
                          Icons.casino_rounded,
                          'สุ่มบันได',
                          itemWidth,
                        ),
                        if (widget.hasMiniApps)
                          _menuButton(
                            'miniapps',
                            Icons.widgets_outlined,
                            'การ์ดโต้ตอบ',
                            itemWidth,
                            onTap: widget.onOpenMiniApps,
                          ),
                        _menuButton(
                          'options',
                          Icons.tune_rounded,
                          'ตัวเลือกการส่ง',
                          itemWidth,
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'ปิด',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          if (_tab == 'options') const SizedBox(height: 6),
          if (_tab == 'options')
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 0,
                children: [
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: isUrgent
                        ? AppTheme.dangerRed
                        : isSilent
                        ? const Color(0xFF312E81)
                        : AppTheme.surfaceBg,
                    avatar: Icon(
                      isUrgent
                          ? Icons.notifications_active_rounded
                          : isSilent
                          ? Icons.nights_stay_rounded
                          : Icons.chat_bubble_outline_rounded,
                      size: 14,
                      color: (isUrgent || isSilent)
                          ? Colors.white
                          : AppTheme.slateBody,
                    ),
                    label: Text(
                      isUrgent
                          ? 'เรื่องด่วน'
                          : isSilent
                          ? 'ส่งแบบไร้เสียง'
                          : 'โหมดส่ง: ปกติ',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: (isUrgent || isSilent)
                            ? Colors.white
                            : AppTheme.slateDark,
                      ),
                    ),
                    onPressed: widget.onCyclePriority,
                  ),
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: widget.isConfidentialMode
                        ? const Color(0xFF991B1B)
                        : AppTheme.surfaceBg,
                    avatar: Icon(
                      widget.isConfidentialMode
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      size: 14,
                      color: widget.isConfidentialMode
                          ? Colors.white
                          : AppTheme.slateBody,
                    ),
                    label: Text(
                      'โหมดความลับ',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: widget.isConfidentialMode
                            ? Colors.white
                            : AppTheme.slateDark,
                      ),
                    ),
                    onPressed: widget.onToggleConfidential,
                  ),
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: isDisappearOn
                        ? const Color(0xFF92400E)
                        : AppTheme.surfaceBg,
                    avatar: Icon(
                      isDisappearOn
                          ? Icons.timer_rounded
                          : Icons.timer_off_outlined,
                      size: 14,
                      color: isDisappearOn ? Colors.white : AppTheme.slateBody,
                    ),
                    label: Text(
                      widget.disappearLabel,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: isDisappearOn ? Colors.white : AppTheme.slateDark,
                      ),
                    ),
                    onPressed: widget.onCycleDisappear,
                  ),
                ],
              ),
            ),
          if (_tab == 'contact' || _tab == 'ladder') const SizedBox(height: 8),
          if (_tab == 'contact' || _tab == 'ladder')
          Flexible(
            child: SingleChildScrollView(
              child: switch (_tab) {
                'contact' => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _friendFilterCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'ค้นหาชื่อหรือ BC ID เพื่อแนะนำให้เพื่อน...',
                        prefixIcon: Icon(Icons.search_rounded, size: 18),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (filteredFriends.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(10),
                        child: Text(
                          'ไม่พบรายชื่อเพื่อน',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      )
                    else
                      ...filteredFriends.take(12).map(
                        (f) => ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 0,
                          ),
                          leading: UserAvatar(
                            name: f.displayName,
                            avatarUrl: f.avatarUrl,
                            radius: 15,
                          ),
                          title: Text(
                            f.displayName,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            f.bcId.isNotEmpty ? '@${f.bcId}' : f.statusMessage,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: FilledButton(
                            onPressed: () => widget.onSendContact(
                              ContactCardData(
                                userId: f.id,
                                displayName: f.displayName,
                                bcId: f.bcId,
                                avatarUrl: f.avatarUrl,
                                statusMessage: f.statusMessage,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.brandPrimary,
                              visualDensity: VisualDensity.compact,
                            ),
                            child: const Text(
                              'ส่งนามบัตร',
                              style: TextStyle(fontSize: 11.5),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                _ => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _ladderTitleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'ชื่อเกม / กิจกรรม',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _ladderPlayersCtrl,
                      decoration: const InputDecoration(
                        labelText: 'ผู้เล่น (คั่นด้วย , )',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _ladderResultsCtrl,
                      decoration: const InputDecoration(
                        labelText: 'รางวัล / บทลงโทษ (คั่นด้วย , )',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _submitLadder,
                      icon: const Icon(Icons.shuffle_rounded, size: 16),
                      label: const Text('สุ่มบันได & ส่งลงแชทเลย'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.brandPrimary,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}
