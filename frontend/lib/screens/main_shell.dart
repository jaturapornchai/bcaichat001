import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../services/push_service.dart';
import '../theme/app_theme.dart';
import 'call_inline_panel.dart';
import 'chat_room_screen.dart';
import 'login_screen.dart' show cleanErrorMessage;
import 'mini_app_runner_screen.dart';
import 'oa_workspace_panel.dart';
import 'qr_friend_screen.dart';

class MainShell extends StatefulWidget {
  final AppUser currentUser;
  final VoidCallback onLoggedOut;
  final ValueChanged<AppUser> onUserChanged;
  final ValueChanged<AppUser>? onSwitchUser;
  final AuthConfig? initialAuthConfig;

  const MainShell({
    super.key,
    required this.currentUser,
    required this.onLoggedOut,
    required this.onUserChanged,
    this.onSwitchUser,
    this.initialAuthConfig,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 1; // Mobile-first: land directly on Chats tab
  String _selectedChatFolder = 'all';

  late AppUser _user;
  List<AppUser> _friends = const [];
  List<Conversation> _conversations = const [];
  List<MiniAppItem> _miniApps = const [];
  List<NoteItem> _notebookNotes = const [];
  AdminOverview? _adminOverview;
  List<AppUser> _adminUsers = const [];
  bool _showHiddenFriends = false;

  // Inline collapsible panels (avoid modal popups)
  String? _homeInlinePanel; // 'qr' | 'profile' | 'add_friend' | 'join_group' | 'create_group' | 'oa'
  String? _chatInlinePanel; // 'notif' | 'join_group' | 'create_group' | 'oa'
  bool _showCreateNoteInline = false;
  bool _showMiniAppFormInline = false;
  MiniAppItem? _editingMiniApp;
  AuthConfig _authConfig = const AuthConfig();
  AuthSettingsDto? _authSettings;
  bool _showSwitchUserBar = false;
  bool _switchingTestUser = false;

  // Progressive disclosure state
  String? _expandedFriendActionId;
  String? _pendingDeleteFriendId;
  bool _showSecondaryChatFolders = false;
  String? _openSettingsSection; // 'notifications' | 'privacy' | 'security' | 'theme_tools' | 'admin'

  // Unified smart search + add friend in Home tab
  final TextEditingController _homeSmartSearchCtrl = TextEditingController();
  String _homeSmartQuery = '';
  String _homeSmartMode = 'id';
  bool _homeSmartSearching = false;
  bool _homeSmartHasSearched = false;
  List<AppUser> _homeSmartResults = const [];
  String? _homeSmartError;

  AiAdminSettings _aiSettings = const AiAdminSettings(
    model: 'deepseek-chat',
    maskedKey: 'ตั้งค่าบนเซิร์ฟเวอร์แล้ว',
    hasKey: true,
    systemPrompt:
        'คุณคือ BC AI ผู้ช่วยส่วนตัวประจำทุกห้องแชทของ BC Ai Chat ช่วยคิดคำตอบ เกลาข้อความ สรุปนัดหมาย และช่วยวางแผนกับครอบครัวและเพื่อนๆ อย่างเป็นกันเอง',
    enabled: true,
  );

  Conversation? _activeConversation;

  /// จอกว้างตั้งแต่ค่านี้ขึ้นไป (Windows/แท็บเล็ตแนวนอน) ใช้ layout สองฝั่ง
  static const double _wideBreakpoint = 840;
  static const double _listPaneWidth = 380;
  bool _isWideLayout = false;

  /// ห้องฝั่งขวาเปิดเมื่อผู้ใช้เลือกเองเท่านั้น — _activeConversation ถูกตั้งค่าเริ่มต้น
  /// ตอนโหลดข้อมูล ถ้าเปิดห้องตามนั้นเลยจะทำให้ข้อความถูกนับว่าอ่านแล้วโดยไม่ได้เปิดดู
  bool _roomPaneOpened = false;
  bool _isLoadingInitial = true;

  // Global search in Chats tab
  final TextEditingController _chatSearchCtrl = TextEditingController();
  String _chatSearchQuery = '';
  List<ChatMessage> _globalSearchResults = const [];
  bool _isSearchingGlobal = false;

  StreamSubscription<Map<String, dynamic>>? _wsSub;

  @override
  void initState() {
    super.initState();
    _user = widget.currentUser;
    if (widget.initialAuthConfig != null) {
      _authConfig = widget.initialAuthConfig!;
    }
    _loadAllData().then(
      (_) => PushService.instance.listenForOpens(_openConversationById),
    );
    _wsSub = ApiService.instance.wsEvents.listen((event) {
      final evType = (event['type'] ?? event['event'] ?? '').toString();
      if (evType.startsWith('call_')) {
        CallInlineManager.instance.handleWsEvent(evType, event);
        if (evType == 'call_ended' || evType == 'call_declined') {
          _refreshConversationsAndFriends();
        }
        return;
      }
      _refreshConversationsAndFriends();
      final convId = event['conversation_id']?.toString();
      NotificationService.instance.handleWsEvent(
        event,
        myUserId: _user.id,
        room: _conversations.where((c) => c.id == convId).firstOrNull,
        currentUser: _user,
      );
    });
    NotificationService.instance.onOpenConversation = _openConversationById;
    NotificationService.instance.init();
    PushService.instance.start();
  }

  /// Tap on a message pop-up: bring that room on screen.
  void _openConversationById(String conversationId) {
    if (!mounted) return;
    final conv = _conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    if (conv == null) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _selectConversation(conv, isWide: _isWideLayout);
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.id != widget.currentUser.id) {
      _user = widget.currentUser;
      _activeConversation = null;
      _loadAllData();
      PushService.instance.start();
    }
    if (oldWidget.initialAuthConfig != widget.initialAuthConfig &&
        widget.initialAuthConfig != null) {
      _authConfig = widget.initialAuthConfig!;
    }
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    if (NotificationService.instance.onOpenConversation ==
        _openConversationById) {
      NotificationService.instance.onOpenConversation = null;
    }
    _chatSearchCtrl.dispose();
    _homeSmartSearchCtrl.dispose();
    super.dispose();
  }

  String _friendlyUiError(Object e, String fallback) {
    final msg = e.toString().replaceFirst('Exception: ', '').trim();
    if (msg.isEmpty ||
        msg.contains('Exception') ||
        msg.contains('Socket') ||
        msg.contains('ClientException') ||
        msg.contains('http://') ||
        msg.contains('https://')) {
      return '$fallback ลองใหม่อีกครั้ง';
    }
    return msg;
  }

  String _detectSmartSearchMode(String raw) {
    final t = raw.trim();
    if (t.startsWith('BCQR_') || t.startsWith('bcaichat://')) {
      return 'qr';
    }
    if (t.contains('@') && t.contains('.')) {
      return 'email';
    }
    if (RegExp(r'^[\d๐-๙\s\-+().]{3,}$').hasMatch(t)) {
      return 'phone';
    }
    return 'id';
  }

  Future<void> _runHomeSmartSearch() async {
    final raw = _homeSmartSearchCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _homeSmartQuery = '';
        _homeSmartHasSearched = false;
        _homeSmartResults = const [];
        _homeSmartError = null;
      });
      return;
    }
    final mode = _detectSmartSearchMode(raw);
    final normalized = normalizeFriendSearchQuery(raw, mode: mode);
    setState(() {
      _homeSmartQuery = raw;
      _homeSmartMode = mode;
      _homeSmartSearching = true;
      _homeSmartHasSearched = true;
      _homeSmartError = null;
    });
    try {
      final found = await ApiService.instance.searchUsers(normalized, by: mode);
      if (!mounted) return;
      setState(() {
        _homeSmartResults = found;
        _homeSmartSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _homeSmartSearching = false;
        _homeSmartResults = const [];
        _homeSmartError = _friendlyUiError(e, 'ค้นหาไม่สำเร็จ');
      });
    }
  }

  Future<void> _loadAllData() async {
    setState(() => _isLoadingInitial = true);
    try {
      final results = await Future.wait([
        ApiService.instance.fetchFriends(),
        ApiService.instance.fetchConversations(folder: 'all'),
        ApiService.instance.fetchMiniApps(),
        ApiService.instance.fetchNotes(),
      ]);

      final friends = results[0] as List<AppUser>;
      final convs = results[1] as List<Conversation>;
      final apps = results[2] as List<MiniAppItem>;
      final notes = results[3] as List<NoteItem>;

      if (!mounted) return;
      setState(() {
        _friends = friends;
        _conversations = convs;
        _miniApps = apps;
        _notebookNotes = notes;
        if (_activeConversation != null) {
          final updatedActive = convs
              .where((c) => c.id == _activeConversation!.id)
              .toList();
          if (updatedActive.isNotEmpty) {
            _activeConversation = updatedActive.first;
          }
        } else if (convs.isNotEmpty) {
          _activeConversation = convs.first;
        }
        _isLoadingInitial = false;
      });

      _loadAdminDataQuietly();
      _loadAuthAndCallsQuietly();
    } catch (_) {
      if (mounted) setState(() => _isLoadingInitial = false);
    }
  }

  Future<void> _refreshConversationsAndFriends() async {
    try {
      final results = await Future.wait([
        ApiService.instance.fetchConversations(folder: 'all'),
        ApiService.instance.fetchFriends(),
        ApiService.instance.fetchMiniApps(),
      ]);
      if (!mounted) return;
      final convs = results[0] as List<Conversation>;
      setState(() {
        _conversations = convs;
        _friends = results[1] as List<AppUser>;
        _miniApps = results[2] as List<MiniAppItem>;
        if (_activeConversation != null) {
          final match = convs
              .where((c) => c.id == _activeConversation!.id)
              .toList();
          if (match.isNotEmpty) {
            _activeConversation = match.first;
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _loadAdminDataQuietly() async {
    try {
      final results = await Future.wait([
        ApiService.instance.fetchAdminOverview(),
        ApiService.instance.fetchAdminUsers(),
        ApiService.instance.fetchAdminMiniApps(),
        ApiService.instance.fetchAdminAiSettings(),
      ]);
      if (!mounted) return;
      setState(() {
        _adminOverview = results[0] as AdminOverview?;
        _adminUsers = results[1] as List<AppUser>;
        final adminApps = results[2] as List<MiniAppItem>;
        if (adminApps.isNotEmpty) {
          _miniApps = adminApps;
        }
        _aiSettings = results[3] as AiAdminSettings;
      });
      if (_user.isAdmin) {
        try {
          final authSet = await ApiService.instance.getAuthSettings();
          if (mounted) setState(() => _authSettings = authSet);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _loadAuthAndCallsQuietly() async {
    try {
      final cfg = await ApiService.instance.fetchAuthConfig();
      if (mounted) setState(() => _authConfig = cfg);
    } catch (_) {}
    await CallInlineManager.instance.refreshActiveCalls();
  }

  bool _isOpeningKeep = false;

  Future<void> _openKeepConversation({required bool isWide}) async {
    if (_isOpeningKeep) return;
    setState(() => _isOpeningKeep = true);
    try {
      final keepConv = await ApiService.instance.ensureKeepConversation();
      await _refreshConversationsAndFriends();
      if (!mounted) return;
      final refreshed =
          _conversations.where((c) => c.id == keepConv.id).firstOrNull ??
          keepConv;
      _selectConversation(refreshed, isWide: isWide);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyUiError(e, 'เปิด Keep ส่วนตัวไม่สำเร็จ')),
        ),
      );
    } finally {
      if (mounted) setState(() => _isOpeningKeep = false);
    }
  }

  Future<void> _performGlobalSearch(String query) async {
    setState(() => _chatSearchQuery = query);
    if (query.trim().length < 2) {
      setState(() {
        _globalSearchResults = const [];
        _isSearchingGlobal = false;
      });
      return;
    }
    setState(() => _isSearchingGlobal = true);
    try {
      final found = await ApiService.instance.searchMessages(query);
      if (!mounted) return;
      setState(() {
        _globalSearchResults = found;
        _isSearchingGlobal = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isSearchingGlobal = false);
    }
  }

  int get _totalUnreadCount {
    return _conversations.fold<int>(0, (sum, c) => sum + c.unreadCount);
  }

  List<Conversation> get _filteredConversations {
    final q = _chatSearchQuery.trim().toLowerCase();
    return _conversations.where((c) {
      final archived = c.isArchived || c.folder == 'archived';
      if (_selectedChatFolder == 'archived') {
        if (!archived) return false;
      } else {
        if (archived) return false;
      }
      if (_selectedChatFolder == 'personal' && c.folder != 'personal') {
        return false;
      }
      if (_selectedChatFolder == 'family' && !c.isFamily) {
        return false;
      }
      if (_selectedChatFolder == 'group' && !c.isGroup) {
        return false;
      }
      if (_selectedChatFolder == 'oa' && !c.isOa) {
        return false;
      }
      if (_selectedChatFolder == 'pinned' && !c.isPinned) {
        return false;
      }
      if (_selectedChatFolder == 'unread' && c.unreadCount <= 0) {
        return false;
      }
      if (q.isNotEmpty) {
        final matchName = c.name.toLowerCase().contains(q);
        final matchLast =
            c.lastMessage?.previewText.toLowerCase().contains(q) ?? false;
        return matchName || matchLast;
      }
      return true;
    }).toList();
  }

  void _selectConversation(Conversation conv, {required bool isWide}) {
    setState(() {
      _activeConversation = conv;
      _roomPaneOpened = true;
      if (isWide && _selectedIndex != 0 && _selectedIndex != 1) {
        _selectedIndex = 1;
      }
    });
    if (!isWide) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(
            conversation: conv,
            allConversations: _conversations,
            friends: _friends,
            miniApps: _miniApps.where((m) => m.enabled).toList(),
            isEmbedded: false,
            onConversationUpdated: _refreshConversationsAndFriends,
            onConversationLeft: () {
              if (mounted && _activeConversation?.id == conv.id) {
                setState(() => _activeConversation = null);
              }
              _refreshConversationsAndFriends();
            },
          ),
        ),
      );
    }
  }

  Future<void> _openChatWithFriend(
    AppUser friend, {
    required bool isWide,
  }) async {
    try {
      final conv = await ApiService.instance.openDirectConversation(friend.id);
      await _refreshConversationsAndFriends();
      if (!mounted) return;
      _selectConversation(conv, isWide: isWide);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyUiError(e, 'ไม่สามารถเปิดห้องสนทนาได้')),
        ),
      );
    }
  }

  void _openMiniApp(MiniAppItem app) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MiniAppRunnerScreen(
          miniApp: app,
          conversations: _conversations,
          initialConversationId: _activeConversation?.id,
          onCardSent: (_) => _refreshConversationsAndFriends(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Inline Collapsible Panels: My QR Code, Edit Profile, Add Friend, Groups
  // ---------------------------------------------------------------------------
  void _toggleHomePanel(String panel) {
    setState(() {
      _homeInlinePanel = _homeInlinePanel == panel ? null : panel;
    });
  }

  void _toggleChatPanel(String panel) {
    setState(() {
      _chatInlinePanel = _chatInlinePanel == panel ? null : panel;
    });
  }

  Widget _buildInlinePanelWrapper({
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: AppTheme.brandPrimary.withValues(alpha: 0.35),
        ),
        boxShadow: AppTheme.shadowMd,
      ),
      child: child,
    );
  }

  Widget _buildInlineQrCard() {
    final qrData = _user.qrToken.isNotEmpty
        ? _user.qrToken
        : 'bcaichat://add/${_user.bcId.isNotEmpty ? _user.bcId : _user.email}';

    return _buildInlinePanelWrapper(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  'QR ของฉัน',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _homeInlinePanel = null),
                tooltip: 'ปิด',
                icon: const Icon(Icons.close_rounded, size: 20),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: BcQrBox(
                data: qrData,
                size: 168,
                quietZonePadding: 8,
                outerPadding: 12,
                borderRadius: 16,
                borderColor: AppTheme.brandPrimary.withValues(alpha: 0.35),
                borderWidth: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: qrData));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('คัดลอกรหัส QR เรียบร้อยแล้ว'),
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text(
                  'คัดลอกรหัส QR',
                  style: TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final updated = await ApiService.instance.resetMyQr();
                    if (!mounted) return;
                    setState(() => _user = updated);
                    widget.onUserChanged(updated);
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('สร้าง QR ใหม่เรียบร้อยแล้ว'),
                      ),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          _friendlyUiError(e, 'สร้าง QR ใหม่ไม่สำเร็จ'),
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text(
                  'สร้าง QR ใหม่',
                  style: TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _homeInlinePanel = null),
                child: const Text('ปิด'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActiveInlinePanel(
    String? active, {
    required bool isWide,
    required VoidCallback onClose,
  }) {
    switch (active) {
      case 'qr':
        return _buildInlineQrCard();
      case 'profile':
        return _buildInlinePanelWrapper(
          child: _InlineEditProfilePanel(
            user: _user,
            onCancel: onClose,
            onSaved: (updated) {
              setState(() {
                _user = updated;
                _homeInlinePanel = null;
              });
              widget.onUserChanged(updated);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: AppTheme.brandDeep,
                  content: const Text('บันทึกโปรไฟล์และ BC ID เรียบร้อยแล้ว'),
                ),
              );
            },
          ),
        );
      case 'add_friend':
        return _buildInlinePanelWrapper(
          child: AddFriendInlinePanel(
            currentUser: _user,
            friends: _friends,
            onUserUpdated: (updated) {
              setState(() => _user = updated);
              widget.onUserChanged(updated);
            },
            onCancel: onClose,
            onOpenChatWithFriend: (u) async {
              onClose();
              await _openChatWithFriend(u, isWide: isWide);
            },
            onAddedFriend: (u) async {
              onClose();
              await _refreshConversationsAndFriends();
              if (u != null && mounted) {
                await _openChatWithFriend(u, isWide: isWide);
              }
            },
          ),
        );
      case 'join_group':
        return _buildInlinePanelWrapper(
          child: _InlineJoinGroupPanel(
            onCancel: onClose,
            onJoined: (conv) async {
              onClose();
              await _refreshConversationsAndFriends();
              if (mounted) {
                _selectConversation(conv, isWide: isWide);
              }
            },
          ),
        );
      case 'create_group':
        return _buildInlinePanelWrapper(
          child: _InlineCreateGroupPanel(
            friends: _friends,
            onCancel: onClose,
            onCreated: (conv) async {
              onClose();
              await _refreshConversationsAndFriends();
              if (mounted) {
                _selectConversation(conv, isWide: isWide);
              }
            },
          ),
        );
      case 'notif':
        return _buildInlinePanelWrapper(
          child: _InlineNotificationPanel(
            user: _user,
            onUserUpdated: (updated) {
              setState(() => _user = updated);
              widget.onUserChanged(updated);
            },
            onClose: onClose,
          ),
        );
      case 'oa':
        return OaWorkspacePanel(
          currentUser: _user,
          onOpenConversationId: (convId) async {
            onClose();
            await _refreshConversationsAndFriends();
            if (mounted) _openConversationById(convId);
          },
          onClose: onClose,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------------------------------------------------------------------
  // Quick Test Account Switcher (Inline, Zero-Popup)
  // ---------------------------------------------------------------------------
  Future<void> _switchToTestUser(QuickTestUser u) async {
    if (_switchingTestUser || u.id == _user.id) return;
    setState(() => _switchingTestUser = true);
    try {
      final res = await ApiService.instance.testQuickLogin(slot: u.slot);
      if (!mounted) return;
      setState(() {
        _switchingTestUser = false;
        _showSwitchUserBar = false;
      });
      if (widget.onSwitchUser != null) {
        widget.onSwitchUser!(res.user);
      } else {
        setState(() {
          _user = res.user;
          _activeConversation = null;
        });
        widget.onUserChanged(res.user);
        await _loadAllData();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _switchingTestUser = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(cleanErrorMessage(e))),
      );
    }
  }

  Widget _buildQuickTestSwitchBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: const BoxDecoration(
        color: Color(0xFFFBF7F5),
        border: Border(bottom: BorderSide(color: AppTheme.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.swap_horiz_rounded,
                size: 16,
                color: AppTheme.brandPrimary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'บัญชีทดสอบ: ${_user.displayName}${_user.bcId.isNotEmpty ? " (@${_user.bcId})" : ""}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              if (_switchingTestUser) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              const SizedBox(width: 8),
              InkWell(
                key: const Key('toggle-quick-switch-bar'),
                borderRadius: BorderRadius.circular(999),
                onTap: _switchingTestUser
                    ? null
                    : () => setState(
                        () => _showSwitchUserBar = !_showSwitchUserBar,
                      ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _showSwitchUserBar ? AppTheme.brandSoft : Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _showSwitchUserBar
                          ? AppTheme.brandPrimary
                          : AppTheme.borderSubtle,
                    ),
                  ),
                  child: Text(
                    _showSwitchUserBar ? 'สลับบัญชี ▴' : 'สลับบัญชี ▾',
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
          if (_showSwitchUserBar) ...[
            const SizedBox(height: 6),
            Wrap(
              key: const Key('quick-switch-users-panel'),
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: _authConfig.testUsers.map((u) {
                final isCurrent =
                    u.id == _user.id ||
                    (u.bcId.isNotEmpty && u.bcId == _user.bcId);
                return _buildQuickSwitchChip(u, isCurrent: isCurrent);
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickSwitchChip(QuickTestUser u, {required bool isCurrent}) {
    final label = u.badge.isNotEmpty
        ? '${u.displayName} (${u.badge})'
        : u.displayName;
    return Material(
      color: isCurrent ? AppTheme.brandSoft : Colors.white,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        key: Key('quick-switch-user-${u.slot}'),
        borderRadius: BorderRadius.circular(999),
        onTap: (isCurrent || _switchingTestUser)
            ? null
            : () => _switchToTestUser(u),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color:
                  isCurrent ? AppTheme.brandPrimary : AppTheme.borderSubtle,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                UserAvatar(
                  name: u.displayName,
                  radius: 10,
                  isOfficial: u.role == 'admin',
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                      color:
                          isCurrent ? AppTheme.brandDeep : AppTheme.slateDark,
                    ),
                  ),
                ),
                if (isCurrent) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.check_circle_rounded,
                    size: 13,
                    color: AppTheme.brandPrimary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build Adaptive Shell — จอแคบ: แท็บล่างแบบมือถือ · จอกว้าง: แถบเมนูซ้าย + สองฝั่ง
  // ---------------------------------------------------------------------------
  static const _navItems = <({IconData icon, IconData selected, String label})>[
    (
      icon: Icons.home_outlined,
      selected: Icons.home_rounded,
      label: 'หน้าหลัก',
    ),
    (
      icon: Icons.chat_bubble_outline_rounded,
      selected: Icons.chat_bubble_rounded,
      label: 'แชท',
    ),
    (
      icon: Icons.bookmark_border_rounded,
      selected: Icons.bookmark_rounded,
      label: 'สมุดบันทึก',
    ),
    (
      icon: Icons.settings_outlined,
      selected: Icons.settings_rounded,
      label: 'ตั้งค่า',
    ),
  ];

  /// ลำดับปุ่มที่แสดง (ค่า = เลขแท็บ): แชทอยู่อันแรก — เลขแท็บภายในคงเดิม
  static const _navOrder = <int>[1, 0, 2, 3];

  void _onNavSelected(int idx) {
    setState(() => _selectedIndex = idx);
    if (idx == 2) _reloadNotebookNotes();
    if (idx == 3 && _user.isAdmin) _loadAdminDataQuietly();
  }

  Widget _navIcon(int idx, {required bool selected}) {
    final item = _navItems[idx];
    final icon = Icon(
      selected ? item.selected : item.icon,
      color: selected ? AppTheme.brandDeep : null,
    );
    if (idx != 1) return icon;
    return Badge(
      isLabelVisible: _totalUnreadCount > 0,
      backgroundColor: AppTheme.brandPrimary,
      label: Text('$_totalUnreadCount'),
      child: icon,
    );
  }

  /// ให้ลูกเห็นความกว้างของ "ช่องตัวเอง" แทนความกว้างทั้งหน้าต่าง
  /// (จอย่อยที่เช็ก MediaQuery < 600 จะจัดแบบกะทัดรัดได้ถูกต้อง)
  Widget _paneScope(Widget child) {
    return LayoutBuilder(
      builder: (context, box) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(size: Size(box.maxWidth, mq.size.height)),
          child: child,
        );
      },
    );
  }

  Widget _buildWideRoomPane() {
    final conv = _roomPaneOpened ? _activeConversation : null;
    if (conv == null) {
      return ColoredBox(
        color: AppTheme.surfaceBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 44,
                color: AppTheme.slateMuted,
              ),
              const SizedBox(height: 8),
              Text(
                'เลือกห้องแชทเพื่อเริ่มสนทนา',
                style: TextStyle(color: AppTheme.slateMuted),
              ),
            ],
          ),
        ),
      );
    }
    return _paneScope(
      ChatRoomScreen(
        key: ValueKey('embedded-room-${conv.id}'),
        conversation: conv,
        allConversations: _conversations,
        friends: _friends,
        miniApps: _miniApps.where((m) => m.enabled).toList(),
        isEmbedded: true,
        onConversationUpdated: _refreshConversationsAndFriends,
        onConversationLeft: () {
          if (mounted && _activeConversation?.id == conv.id) {
            setState(() => _activeConversation = null);
          }
          _refreshConversationsAndFriends();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    _isWideLayout = isWide;
    final selected = _selectedIndex.clamp(0, 3);
    // หน้าหลัก/แชท บนจอกว้าง = รายการซ้าย + ห้องแชทขวา; แท็บอื่นใช้เต็มความกว้าง
    final splitRoom = isWide && selected <= 1;

    final tabBody = AnimatedSwitcher(
      duration: AppTheme.motionMed,
      transitionBuilder: AppTheme.fadeSlideTransition,
      child: KeyedSubtree(
        key: ValueKey('tab-$_selectedIndex'),
        child: _buildSelectedTabBody(isWide: isWide),
      ),
    );

    Widget content = splitRoom
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: _listPaneWidth, child: _paneScope(tabBody)),
              const VerticalDivider(width: 1, color: AppTheme.borderSubtle),
              Expanded(child: _buildWideRoomPane()),
            ],
          )
        : tabBody;

    if (isWide) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NavigationRail(
            selectedIndex: _navOrder.indexOf(selected),
            onDestinationSelected: (pos) => _onNavSelected(_navOrder[pos]),
            backgroundColor: Colors.white,
            indicatorColor: AppTheme.brandSoft,
            labelType: NavigationRailLabelType.all,
            minWidth: 72,
            destinations: [
              for (final i in _navOrder)
                NavigationRailDestination(
                  icon: _navIcon(i, selected: false),
                  selectedIcon: _navIcon(i, selected: true),
                  label: Text(_navItems[i].label),
                ),
            ],
          ),
          const VerticalDivider(width: 1, color: AppTheme.borderSubtle),
          Expanded(child: content),
        ],
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            CallInlinePanel(
              conversationId: _activeConversation?.id,
              onOpenConversation: _openConversationById,
            ),
            if (_authConfig.testUsersEnabled &&
                _authConfig.testUsers.isNotEmpty)
              _buildQuickTestSwitchBar(),
            Expanded(child: content),
          ],
        ),
      ),
      bottomNavigationBar: isWide
          ? null
          : DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x140F172A),
                    blurRadius: 18,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              child: NavigationBar(
                selectedIndex: _navOrder.indexOf(selected),
                onDestinationSelected: (pos) => _onNavSelected(_navOrder[pos]),
                backgroundColor: Colors.white,
                indicatorColor: AppTheme.brandSoft,
                destinations: [
                  for (final i in _navOrder)
                    NavigationDestination(
                      icon: _navIcon(i, selected: false),
                      selectedIcon: _navIcon(i, selected: true),
                      label: _navItems[i].label,
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildSelectedTabBody({required bool isWide}) {
    switch (_selectedIndex) {
      case 0:
        return _buildHomeTab(isWide: isWide);
      case 1:
        return _buildChatsTab(isWide: isWide);
      case 2:
        return _buildNotebookVaultTab();
      case 3:
        return _buildSettingsAndToolsTab();
      default:
        return _buildChatsTab(isWide: isWide);
    }
  }

  // ---------------------------------------------------------------------------
  // TAB 0: หน้าหลัก (HOME — โปรไฟล์, QR, เพิ่มเพื่อน, บริการเสริม, กลุ่ม & เพื่อน)
  // ---------------------------------------------------------------------------
  /// หัวข้อส่วน (titleMedium w700 + คำอธิบายจาง ๆ) ใช้ร่วมทุกแท็บ
  Widget _sectionHeader(
    String title, {
    String? subtitle,
    Widget? trailing,
    EdgeInsetsGeometry padding = const EdgeInsets.only(bottom: 12),
  }) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppTheme.slateMuted,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _buildHomeTab({required bool isWide}) {
    final groups = _conversations.where((c) => c.isGroup).toList();
    final officials = _conversations.where((c) => c.isOfficial).toList();
    final smartQ = normalizeThaiDigits(_homeSmartCtrlQuery()).trim().toLowerCase();
    final smartDigits = smartQ.replaceAll(RegExp(r'[\s\-+().]'), '');

    return Column(
      children: [
        // Clean Top Header (zero corporate / cloud badges)
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppTheme.borderSubtle)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipOval(
                child: Image.asset(
                  'assets/images/bc_logo.png',
                  width: 30,
                  height: 30,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'BC Ai Chat',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    height: 1.3,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _toggleHomePanel('add_friend'),
                tooltip: 'เพิ่มเพื่อน 4 ช่องทาง',
                icon: Icon(
                  Icons.person_add_alt_1_rounded,
                  color: _homeInlinePanel == 'add_friend'
                      ? AppTheme.brandPrimary
                      : AppTheme.slateDark,
                ),
              ),
              IconButton(
                onPressed: () => _toggleHomePanel('create_group'),
                tooltip: 'สร้างกลุ่มแชทใหม่',
                icon: Icon(
                  Icons.group_add_rounded,
                  color: _homeInlinePanel == 'create_group'
                      ? AppTheme.brandPrimary
                      : AppTheme.slateDark,
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(10),
            children: [
              // Clean My Profile Card (BCQR hidden until user taps QR ของฉัน)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: AppTheme.navyGradient,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  boxShadow: AppTheme.shadowMd,
                ),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        UserAvatar(
                          name: _user.displayName,
                          avatarUrl: _user.avatarUrl,
                          radius: 20,
                          showOnline: true,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _user.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  height: 1.35,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _user.bcId.isNotEmpty
                                    ? '@${_user.bcId}'
                                    : _user.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.goldClay,
                                  fontSize: 12,
                                  height: 1.4,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_user.statusMessage.isNotEmpty)
                                Text(
                                  _user.statusMessage,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFCBD5E1),
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 38,
                            child: ElevatedButton.icon(
                              onPressed: () => _toggleHomePanel('qr'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.brandPrimary,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                              ),
                              icon: const Icon(Icons.qr_code_rounded, size: 16),
                              label: const Text(
                                'QR ของฉัน',
                                style: TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 38,
                            child: OutlinedButton.icon(
                              onPressed: () => _toggleHomePanel('profile'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.28),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                              ),
                              icon: const Icon(Icons.edit_rounded, size: 15),
                              label: const Text(
                                'แก้ไขโปรไฟล์',
                                style: TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Unified Smart Search & Add Friend Bar
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _homeSmartSearchCtrl,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => setState(() {
                        if (_homeSmartSearchCtrl.text.trim().isEmpty) {
                          _homeSmartQuery = '';
                          _homeSmartHasSearched = false;
                          _homeSmartResults = const [];
                          _homeSmartError = null;
                        }
                      }),
                      onSubmitted: (_) => _runHomeSmartSearch(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'เบอร์ / @ID / อีเมล / รหัส QR',
                        prefixIcon: const Icon(Icons.search_rounded, size: 19),
                        suffixIcon: _homeSmartSearchCtrl.text.isNotEmpty
                            ? IconButton(
                                tooltip: 'ล้างคำค้นหา',
                                onPressed: () => setState(() {
                                  _homeSmartSearchCtrl.clear();
                                  _homeSmartQuery = '';
                                  _homeSmartHasSearched = false;
                                  _homeSmartResults = const [];
                                  _homeSmartError = null;
                                }),
                                icon: const Icon(Icons.close_rounded, size: 18),
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 40,
                    child: ElevatedButton(
                      onPressed: _homeSmartSearching ? null : _runHomeSmartSearch,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: const Text('ค้นหา'),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => _toggleHomePanel('add_friend'),
                    tooltip: 'เพิ่มเพื่อน 4 ช่องทาง / QR',
                    style: IconButton.styleFrom(
                      backgroundColor: _homeInlinePanel == 'add_friend'
                          ? AppTheme.brandSoft
                          : Colors.white,
                      side: const BorderSide(color: AppTheme.borderSubtle),
                      minimumSize: const Size(38, 38),
                    ),
                    icon: Icon(
                      Icons.qr_code_scanner_rounded,
                      size: 19,
                      color: AppTheme.brandDeep,
                    ),
                  ),
                ],
              ),

              if (_homeSmartHasSearched) ...[
                const SizedBox(height: 8),
                _buildHomeSmartSearchResults(isWide: isWide),
              ],

              const SizedBox(height: 8),
              // Compact Group Actions Row (collapsed forms behind 2 clean buttons)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 38,
                      child: OutlinedButton.icon(
                        onPressed: () => _toggleHomePanel('create_group'),
                        icon: const Icon(Icons.group_add_rounded, size: 16),
                        label: const Text(
                          '+ สร้างกลุ่ม',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 38,
                      child: OutlinedButton.icon(
                        onPressed: () => _toggleHomePanel('join_group'),
                        icon: const Icon(Icons.vpn_key_outlined, size: 16),
                        label: const Text(
                          'เข้ากลุ่มด้วยรหัสเชิญ',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              AnimatedSize(
                duration: AppTheme.motionMed,
                curve: AppTheme.motionCurve,
                child: _buildActiveInlinePanel(
                  _homeInlinePanel,
                  isWide: isWide,
                  onClose: () => setState(() => _homeInlinePanel = null),
                ),
              ),

              // App News Section
              if (officials.isNotEmpty) ...[
                _sectionHeader(
                  'ข่าวสารแอป (${officials.length})',
                  padding: const EdgeInsets.only(bottom: 4),
                ),
                ...officials.map(
                  (c) => ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    leading: UserAvatar(
                      name: c.name,
                      avatarUrl: c.avatarUrl,
                      radius: 17,
                      isOfficial: true,
                    ),
                    title: Text(
                      c.name,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      c.lastMessage?.previewText ?? 'อัปเดตล่าสุดจาก BC Ai Chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => _selectConversation(c, isWide: isWide),
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Groups Section
              if (groups.isNotEmpty) ...[
                _sectionHeader(
                  'กลุ่มสนทนา (${groups.length})',
                  padding: const EdgeInsets.only(bottom: 4),
                ),
                ...groups.map(
                  (g) => ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    leading: UserAvatar(
                      name: g.name,
                      avatarUrl: g.avatarUrl,
                      radius: 17,
                      isGroup: true,
                    ),
                    title: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            '${g.name} (${g.memberCount})',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        PillBadge(
                          text: g.folderLabel,
                          backgroundColor: g.isFamily
                              ? const Color(0xFFDBEAFE)
                              : AppTheme.brandSoft,
                          textColor: g.isFamily
                              ? AppTheme.workBlue
                              : AppTheme.brandDeep,
                        ),
                      ],
                    ),
                    subtitle: Text(
                      g.lastMessage?.previewText ?? 'แตะเพื่อเปิดห้องสนทนากลุ่ม',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => _selectConversation(g, isWide: isWide),
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Friends Section (favorites sorted first, inline ⋯ actions)
              Builder(
                builder: (_) {
                  final hiddenCount = _friends
                      .where((f) => f.isHidden && !f.isBlocked)
                      .length;
                  final blockedCount =
                      _friends.where((f) => f.isBlocked).length;
                  final visibleFriends = _friends
                      .where((f) {
                        if (f.isBlocked) return false;
                        if (!_showHiddenFriends && f.isHidden) return false;
                        if (smartQ.isEmpty) return true;
                        final nameHit = f.displayName.toLowerCase().contains(smartQ);
                        final idHit = f.bcId.toLowerCase().contains(smartQ);
                        final emailHit = f.email.toLowerCase().contains(smartQ);
                        final normPhone = normalizeThaiDigits(
                          f.phone,
                        ).replaceAll(RegExp(r'[\s\-+().]'), '');
                        final phoneHit = smartDigits.isNotEmpty &&
                            normPhone.contains(smartDigits);
                        return nameHit || idHit || emailHit || phoneHit;
                      })
                      .toList()
                    ..sort((a, b) {
                      if (a.isFavorite != b.isFavorite) {
                        return a.isFavorite ? -1 : 1;
                      }
                      return a.displayName.compareTo(b.displayName);
                    });
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionHeader(
                        'เพื่อนและครอบครัว (${visibleFriends.length})',
                        padding: const EdgeInsets.only(bottom: 4),
                        trailing: (hiddenCount > 0 || blockedCount > 0)
                            ? Wrap(
                                spacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (hiddenCount > 0)
                                    TextButton(
                                      onPressed: () => setState(
                                        () => _showHiddenFriends =
                                            !_showHiddenFriends,
                                      ),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        minimumSize: Size.zero,
                                      ),
                                      child: Text(
                                        _showHiddenFriends
                                            ? 'ซ่อนที่พัก ($hiddenCount)'
                                            : 'ที่ซ่อน ($hiddenCount)',
                                        style: const TextStyle(fontSize: 11.5),
                                      ),
                                    ),
                                  if (blockedCount > 0)
                                    TextButton(
                                      onPressed: () => setState(() {
                                        _selectedIndex = 3;
                                        _openSettingsSection = 'privacy';
                                      }),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        minimumSize: Size.zero,
                                      ),
                                      child: Text(
                                        'บล็อก ($blockedCount)',
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          color: AppTheme.dangerRed,
                                        ),
                                      ),
                                    ),
                                ],
                              )
                            : null,
                      ),
                      ...visibleFriends.map((f) {
                        final isMenuOpen = _expandedFriendActionId == f.id;
                        final isConfirmingDelete = _pendingDeleteFriendId == f.id;
                        final friendSub = f.bcId.isNotEmpty
                            ? '@${f.bcId}${f.statusMessage.isNotEmpty ? ' · ${f.statusMessage}' : ''}'
                            : (f.statusMessage.isNotEmpty
                                ? f.statusMessage
                                : f.email);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              leading: UserAvatar(
                                name: f.displayName,
                                avatarUrl: f.avatarUrl,
                                radius: 17,
                                showOnline: f.isOnline && !f.isBlocked,
                                isOfficial: f.isOfficial,
                              ),
                              title: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Text(
                                      f.displayName,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (f.isBlocked) ...[
                                    const SizedBox(width: 6),
                                    const PillBadge(
                                      text: 'บล็อกแล้ว',
                                      backgroundColor: Color(0xFFFEE2E2),
                                      textColor: AppTheme.dangerRed,
                                    ),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                friendSub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  IconButton(
                                    tooltip: f.isFavorite
                                        ? 'เอาออกจากรายการโปรด'
                                        : 'เพิ่มในรายการโปรด',
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      f.isFavorite
                                          ? Icons.star_rounded
                                          : Icons.star_border_rounded,
                                      size: 20,
                                      color: f.isFavorite
                                          ? AppTheme.goldPin
                                          : AppTheme.slateMuted,
                                    ),
                                    onPressed: () async {
                                      await ApiService.instance.updateFriendMeta(
                                        f.id,
                                        isFavorite: !f.isFavorite,
                                      );
                                      await _refreshConversationsAndFriends();
                                    },
                                  ),
                                  IconButton(
                                    tooltip: 'แชท',
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      Icons.chat_bubble_outline_rounded,
                                      size: 18,
                                      color: AppTheme.brandDeep,
                                    ),
                                    onPressed: () =>
                                        _openChatWithFriend(f, isWide: isWide),
                                  ),
                                  IconButton(
                                    tooltip: 'จัดการเพื่อน',
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    padding: EdgeInsets.zero,
                                    icon: Icon(
                                      Icons.more_horiz_rounded,
                                      size: 19,
                                      color: isMenuOpen
                                          ? AppTheme.brandPrimary
                                          : AppTheme.slateBody,
                                    ),
                                    onPressed: () => setState(() {
                                      _expandedFriendActionId =
                                          isMenuOpen ? null : f.id;
                                      _pendingDeleteFriendId = null;
                                    }),
                                  ),
                                ],
                              ),
                              onTap: () => _openChatWithFriend(f, isWide: isWide),
                            ),
                            if (isMenuOpen)
                              Container(
                                margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
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
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        setState(() {
                                          _expandedFriendActionId = null;
                                        });
                                        await ApiService.instance
                                            .updateFriendMeta(
                                          f.id,
                                          isHidden: !f.isHidden,
                                        );
                                        await _refreshConversationsAndFriends();
                                      },
                                      icon: Icon(
                                        f.isHidden
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                        size: 15,
                                      ),
                                      label: Text(
                                        f.isHidden ? 'เลิกซ่อน' : 'ซ่อน',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        minimumSize: const Size(0, 32),
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        setState(() {
                                          _expandedFriendActionId = null;
                                        });
                                        await ApiService.instance
                                            .updateFriendMeta(
                                          f.id,
                                          isBlocked: !f.isBlocked,
                                        );
                                        await _refreshConversationsAndFriends();
                                      },
                                      icon: const Icon(
                                        Icons.block_rounded,
                                        size: 15,
                                      ),
                                      label: Text(
                                        f.isBlocked ? 'ปลดบล็อก' : 'บล็อก',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        minimumSize: const Size(0, 32),
                                      ),
                                    ),
                                    if (!isConfirmingDelete)
                                      OutlinedButton.icon(
                                        onPressed: () => setState(
                                          () => _pendingDeleteFriendId = f.id,
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTheme.dangerRed,
                                          side: BorderSide(
                                            color: AppTheme.dangerRed
                                                .withValues(alpha: 0.45),
                                          ),
                                          visualDensity: VisualDensity.compact,
                                          minimumSize: const Size(0, 32),
                                        ),
                                        icon: const Icon(
                                          Icons.person_remove_outlined,
                                          size: 15,
                                        ),
                                        label: const Text(
                                          'ลบเพื่อน',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      )
                                    else ...[
                                      FilledButton(
                                        onPressed: () async {
                                          final messenger =
                                              ScaffoldMessenger.of(context);
                                          setState(() {
                                            _expandedFriendActionId = null;
                                            _pendingDeleteFriendId = null;
                                          });
                                          try {
                                            await ApiService.instance
                                                .deleteFriend(f.id);
                                            if (mounted) {
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'ลบ ${f.displayName} ออกจากรายชื่อเพื่อนแล้ว',
                                                  ),
                                                ),
                                              );
                                            }
                                          } catch (e) {
                                            if (mounted) {
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    _friendlyUiError(
                                                      e,
                                                      'ลบเพื่อนไม่สำเร็จ',
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }
                                          }
                                          await _refreshConversationsAndFriends();
                                        },
                                        style: FilledButton.styleFrom(
                                          backgroundColor: AppTheme.dangerRed,
                                          minimumSize: const Size(0, 32),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                          ),
                                        ),
                                        child: const Text(
                                          'ยืนยันลบ',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () => setState(
                                          () => _pendingDeleteFriendId = null,
                                        ),
                                        child: const Text(
                                          'ยกเลิก',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                          ],
                        );
                      }),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _homeSmartCtrlQuery() => _homeSmartSearchCtrl.text;

  Widget _buildHomeSmartSearchResults({required bool isWide}) {
    final myId = _user.id;
    return _buildInlinePanelWrapper(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  'ผลการค้นหาผู้ใช้',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _homeSmartHasSearched = false;
                  _homeSmartResults = const [];
                  _homeSmartError = null;
                }),
                child: const Text('ปิด', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (_homeSmartSearching)
            const Padding(
              padding: EdgeInsets.all(10),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_homeSmartError != null)
            Text(
              _homeSmartError!,
              style: const TextStyle(fontSize: 12, color: AppTheme.dangerRed),
            )
          else if (_homeSmartResults.isEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ไม่พบผู้ใช้จาก "$_homeSmartQuery" (${_homeSmartMode == 'phone' ? 'เบอร์โทร' : _homeSmartMode == 'email' ? 'อีเมล' : _homeSmartMode == 'qr' ? 'รหัส QR' : '@BC ID'})',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.slateMuted,
                  ),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () => _toggleHomePanel('add_friend'),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 15),
                  label: const Text(
                    'ลองค้นหาแบบ 4 ช่องทาง',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            )
          else
            for (final u in _homeSmartResults)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    UserAvatar(
                      name: u.displayName,
                      avatarUrl: u.avatarUrl,
                      radius: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            u.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            u.bcId.isNotEmpty ? '@${u.bcId}' : u.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (u.id == myId)
                      PillBadge(
                        text: 'บัญชีของคุณเอง',
                        backgroundColor: AppTheme.brandSoft,
                        textColor: AppTheme.brandDeep,
                      )
                    else if (_friends.any((f) => f.id == u.id))
                      OutlinedButton(
                        onPressed: () => _openChatWithFriend(u, isWide: isWide),
                        child: const Text(
                          'เป็นเพื่อนแล้ว · แชท',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      )
                    else
                      ElevatedButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await ApiService.instance.addFriend(targetId: u.id);
                            await _refreshConversationsAndFriends();
                            if (mounted) {
                              setState(() => _homeSmartHasSearched = false);
                              await _openChatWithFriend(u, isWide: isWide);
                            }
                          } catch (e) {
                            if (mounted) {
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    _friendlyUiError(e, 'เพิ่มเพื่อนไม่สำเร็จ'),
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        child: const Text(
                          'เพิ่ม & แชท',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 1: แชท (CHATS — แยกหมวดโฟลเดอร์ + ค้นหาข้ามห้อง + รายการแชท)
  // ---------------------------------------------------------------------------
  Widget _buildChatFolderChip(String code, String label) {
    final active = _selectedChatFolder == code;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => setState(() => _selectedChatFolder = code),
        child: AnimatedContainer(
          duration: AppTheme.motionFast,
          curve: AppTheme.motionCurve,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppTheme.slateDark : AppTheme.surfaceBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active ? AppTheme.slateDark : AppTheme.borderSubtle,
            ),
            boxShadow: active ? AppTheme.shadowSm : const [],
          ),
          child: AnimatedDefaultTextStyle(
            duration: AppTheme.motionFast,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.35,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.white : AppTheme.slateBody,
            ),
            child: Text(label, maxLines: 1),
          ),
        ),
      ),
    );
  }

  Widget _buildChatsTab({required bool isWide}) {
    const primaryFolders = [
      ('all', 'ทั้งหมด'),
      ('unread', 'ยังไม่อ่าน'),
      ('group', 'กลุ่ม'),
      ('oa', 'ร้านค้า'),
    ];
    const secondaryFolders = [
      ('personal', 'ส่วนตัว'),
      ('family', 'ครอบครัว'),
      ('pinned', 'ปักหมุด'),
      ('archived', 'เก็บถาวร'),
    ];
    final isSecondarySelected = secondaryFolders.any(
      (f) => f.$1 == _selectedChatFolder,
    );
    final showSecondary = _showSecondaryChatFolders || isSecondarySelected;
    final items = _filteredConversations;

    return Column(
      children: [
        // Header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppTheme.borderSubtle)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'แชท',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.35,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.slateDark,
                ),
              ),
              const SizedBox(width: 6),
              if (_totalUnreadCount > 0)
                PillBadge(
                  text: 'ยังไม่อ่าน $_totalUnreadCount',
                  backgroundColor: AppTheme.brandPrimary,
                  textColor: Colors.white,
                ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _isOpeningKeep
                    ? null
                    : () => _openKeepConversation(isWide: isWide),
                icon: _isOpeningKeep
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bookmark_rounded, size: 15),
                label: const Text(
                  'Keep',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.brandDeep,
                  backgroundColor: AppTheme.brandSoft.withValues(alpha: 0.45),
                  side: BorderSide(
                    color: AppTheme.brandPrimary.withValues(alpha: 0.3),
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 30),
                ),
              ),
              const SizedBox(width: 2),
              IconButton(
                onPressed: () => _toggleChatPanel('oa'),
                tooltip: 'ศูนย์รวมร้านค้า',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                iconSize: 19,
                icon: Icon(
                  Icons.storefront_rounded,
                  color: _chatInlinePanel == 'oa' ? AppTheme.brandPrimary : null,
                ),
              ),
              IconButton(
                onPressed: () => _toggleChatPanel('notif'),
                tooltip: 'เสียงและการแจ้งเตือน',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                iconSize: 19,
                icon: Icon(
                  Icons.notifications_rounded,
                  color: _chatInlinePanel == 'notif'
                      ? AppTheme.brandPrimary
                      : null,
                ),
              ),
              IconButton(
                onPressed: () => _toggleChatPanel('join_group'),
                tooltip: 'เข้ากลุ่มด้วยรหัสเชิญ',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                iconSize: 19,
                icon: Icon(
                  Icons.vpn_key_outlined,
                  color: _chatInlinePanel == 'join_group'
                      ? AppTheme.brandPrimary
                      : null,
                ),
              ),
              IconButton(
                onPressed: () => _toggleChatPanel('create_group'),
                tooltip: 'สร้างกลุ่มแชทใหม่',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                iconSize: 19,
                icon: Icon(
                  Icons.group_add_rounded,
                  color: _chatInlinePanel == 'create_group'
                      ? AppTheme.brandPrimary
                      : null,
                ),
              ),
              IconButton(
                onPressed: _refreshConversationsAndFriends,
                tooltip: 'รีเฟรชรายการแชท',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 32),
                iconSize: 19,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),

        if (_chatInlinePanel != null)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: _chatInlinePanel == 'oa' ? 480 : 340,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: _buildActiveInlinePanel(
                _chatInlinePanel,
                isWide: isWide,
                onClose: () => setState(() => _chatInlinePanel = null),
              ),
            ),
          ),

        // Search input
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 3),
          child: TextField(
            controller: _chatSearchCtrl,
            onChanged: _performGlobalSearch,
            decoration: InputDecoration(
              hintText: 'ค้นหาห้องแชท ข้อความ หรือชื่อไฟล์...',
              prefixIcon: const Icon(Icons.search_rounded, size: 19),
              suffixIcon: _chatSearchQuery.isNotEmpty
                  ? IconButton(
                      tooltip: 'ล้างคำค้นหา',
                      onPressed: () {
                        _chatSearchCtrl.clear();
                        _performGlobalSearch('');
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    )
                  : null,
            ),
          ),
        ),

        // Folder Filter Bar (4 primary + pinned inline "ตัวกรอง ▾" for secondary)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 34,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            for (final f in primaryFolders) ...[
                              _buildChatFolderChip(f.$1, f.$2),
                              const SizedBox(width: 6),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => setState(
                        () => _showSecondaryChatFolders =
                            !_showSecondaryChatFolders,
                      ),
                      child: AnimatedContainer(
                        duration: AppTheme.motionFast,
                        curve: AppTheme.motionCurve,
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: showSecondary
                              ? AppTheme.brandSoft
                              : AppTheme.surfaceBg,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: showSecondary
                                ? AppTheme.brandPrimary.withValues(alpha: 0.45)
                                : AppTheme.borderSubtle,
                          ),
                        ),
                        child: Text(
                          showSecondary ? 'ตัวกรอง ▴' : 'ตัวกรอง ▾',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: showSecondary
                                ? AppTheme.brandDeep
                                : AppTheme.slateBody,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (showSecondary) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final f in secondaryFolders)
                      _buildChatFolderChip(f.$1, f.$2),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),

        // Global message search hits (if searching)
        if (_chatSearchQuery.trim().length >= 2 &&
            (_isSearchingGlobal || _globalSearchResults.isNotEmpty))
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            color: const Color(0xFFF8FAFC),
            child: _isSearchingGlobal
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _globalSearchResults.length,
                    itemBuilder: (ctx, i) {
                      final m = _globalSearchResults[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.manage_search_rounded,
                          color: AppTheme.brandDeep,
                        ),
                        title: Text(
                          m.previewText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5,
                          ),
                        ),
                        subtitle: Text(
                          'โดย ${m.senderName} · ${formatThaiTime(m.createdAt)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () {
                          final target = _conversations
                              .where((c) => c.id == m.conversationId)
                              .toList();
                          if (target.isNotEmpty) {
                            _selectConversation(target.first, isWide: isWide);
                          }
                        },
                      );
                    },
                  ),
          ),

        // Conversation List
        Expanded(
          child: _isLoadingInitial
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
              ? const Center(
                  child: Text(
                    'ไม่มีห้องแชทในหมวดหมู่นี้',
                    style: TextStyle(color: AppTheme.slateMuted),
                  ),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (context, index) =>
                      const Divider(indent: 76, height: 1),
                  itemBuilder: (ctx, i) {
                    final conv = items[i];
                    final isSelected =
                        isWide && _activeConversation?.id == conv.id;
                    final timeText = formatThaiTime(
                      conv.lastMessage?.createdAt ?? conv.updatedAt,
                    );

                    final hasUnread = conv.unreadCount > 0;
                    return Material(
                      color: isSelected ? AppTheme.brandSoft : Colors.white,
                      child: InkWell(
                        onTap: () => _selectConversation(conv, isWide: isWide),
                        hoverColor: AppTheme.surfaceBg,
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  UserAvatar(
                                    name: conv.name,
                                    avatarUrl: conv.avatarUrl,
                                    radius: 18,
                                    showOnline: !conv.isGroup && !conv.isKeep,
                                    isOfficial: conv.isOfficial,
                                    isGroup: conv.isGroup,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        // แถว 1: ปักหมุด · ชื่อ · โฟลเดอร์ · เวลา
                                        SizedBox(
                                          height: 20,
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              if (conv.isPinned) ...[
                                                const Icon(
                                                  Icons.push_pin_rounded,
                                                  size: 14,
                                                  color: AppTheme.goldPin,
                                                ),
                                                const SizedBox(width: 4),
                                              ],
                                              if (conv.isEffectivelyMuted) ...[
                                                const Icon(
                                                  Icons.notifications_off_outlined,
                                                  size: 14,
                                                  color: AppTheme.slateMuted,
                                                ),
                                                const SizedBox(width: 4),
                                              ],
                                              Expanded(
                                                child: Text(
                                                  conv.isGroup
                                                      ? '${conv.name} (${conv.memberCount})'
                                                      : conv.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 13.5,
                                                    height: 1.3,
                                                    fontWeight: FontWeight.w700,
                                                    color: AppTheme.slateDark,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              PillBadge(
                                                text: conv.folderLabel,
                                                backgroundColor: conv.isKeep
                                                    ? const Color(0xFFFEF3C7)
                                                    : conv.isFamily
                                                    ? const Color(0xFFDBEAFE)
                                                    : AppTheme.brandSoft,
                                                textColor: conv.isKeep
                                                    ? AppTheme.brandDeep
                                                    : conv.isFamily
                                                    ? AppTheme.workBlue
                                                    : AppTheme.brandDeep,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                timeText,
                                                maxLines: 1,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  height: 1.35,
                                                  color: hasUnread
                                                      ? AppTheme.brandDeep
                                                      : AppTheme.slateMuted,
                                                  fontWeight: hasUnread
                                                      ? FontWeight.w700
                                                      : FontWeight.w400,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 1),
                                        // แถว 2: ข้อความล่าสุด · จำนวนที่ยังไม่อ่าน
                                        SizedBox(
                                          height: 19,
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  conv
                                                          .lastMessage
                                                          ?.previewText ??
                                                      'เริ่มการสนทนา...',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    height: 1.3,
                                                    color: hasUnread
                                                        ? AppTheme.slateDark
                                                        : AppTheme.slateMuted,
                                                    fontWeight: hasUnread
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                  ),
                                                ),
                                              ),
                                              if (hasUnread) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  height: 20,
                                                  constraints:
                                                      const BoxConstraints(
                                                        minWidth: 20,
                                                      ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                      ),
                                                  alignment: Alignment.center,
                                                  decoration: BoxDecoration(
                                                    color:
                                                        AppTheme.brandPrimary,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          999,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '${conv.unreadCount}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      height: 1.2,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Positioned(
                                left: 0,
                                top: 10,
                                bottom: 10,
                                child: Container(
                                  width: 4,
                                  decoration: BoxDecoration(
                                    color: AppTheme.brandPrimary,
                                    borderRadius: BorderRadius.horizontal(
                                      right: Radius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 2: สมุดบันทึก BC (คลังบันทึกส่วนตัวถาวร ซิงค์ตาม Gmail)
  // ---------------------------------------------------------------------------
  // Notes are also saved from chat rooms (AI summaries), so refetch on every visit.
  Future<void> _reloadNotebookNotes() async {
    final fresh = await ApiService.instance.fetchNotes();
    if (!mounted) return;
    setState(() => _notebookNotes = fresh);
  }

  Widget _buildNotebookVaultTab() {
    final isCompact = MediaQuery.of(context).size.width < 600;
    return Scaffold(
      backgroundColor: AppTheme.surfaceBg,
      appBar: AppBar(
        title: const Text(
          'สมุดบันทึก BC',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: ElevatedButton.icon(
                onPressed: () => setState(
                  () => _showCreateNoteInline = !_showCreateNoteInline,
                ),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: Icon(
                  _showCreateNoteInline ? Icons.close_rounded : Icons.add_rounded,
                  size: 16,
                ),
                label: Text(
                  _showCreateNoteInline ? 'ปิด' : '+ จดบันทึกใหม่',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(isCompact ? 10 : 14),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1020),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'เก็บข้อความ ลิงก์ รูปและไฟล์สำคัญไว้ดูย้อนหลังได้ตลอดเวลา',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
                ),
                AnimatedSize(
                  duration: AppTheme.motionMed,
                  curve: AppTheme.motionCurve,
                  child: _showCreateNoteInline
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _buildInlinePanelWrapper(
                            child: _InlineCreateNotePanel(
                              onCancel: () =>
                                  setState(() => _showCreateNoteInline = false),
                              onCreated: () async {
                                setState(() => _showCreateNoteInline = false);
                                await _reloadNotebookNotes();
                              },
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 12),
                if (_notebookNotes.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(28),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                      boxShadow: AppTheme.shadowSm,
                    ),
                    child: const Text(
                      'ยังไม่มีบันทึก กด "+ จดบันทึกใหม่"',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.slateMuted, height: 1.5),
                    ),
                  )
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: _notebookNotes.map((note) {
                      return Container(
                        width: isCompact ? double.infinity : 320,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusLg,
                          ),
                          border: Border.all(color: AppTheme.borderSubtle),
                          boxShadow: AppTheme.shadowSm,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: PillBadge(
                                      text: note.category,
                                      backgroundColor: AppTheme.brandSoft,
                                      textColor: AppTheme.brandDeep,
                                      icon: Icons.bookmark_rounded,
                                    ),
                                  ),
                                ),
                                Text(
                                  formatThaiTime(note.createdAt),
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.35,
                                    color: AppTheme.slateMuted,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () async {
                                    await ApiService.instance.deleteNote(
                                      note.id,
                                    );
                                    await _reloadNotebookNotes();
                                  },
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                    color: AppTheme.dangerRed,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              note.title,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.35,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.slateDark,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              note.content,
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: AppTheme.slateBody,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () async {
                                    await ApiService.instance.toggleNoteLike(
                                      note.id,
                                    );
                                    await _reloadNotebookNotes();
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
                                          note.likedBy.contains(_user.id)
                                              ? Icons.favorite_rounded
                                              : Icons.favorite_border_rounded,
                                          size: 15,
                                          color: note.likedBy.contains(_user.id)
                                              ? AppTheme.brandPrimary
                                              : AppTheme.slateMuted,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${note.likedBy.length}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.slateMuted,
                                          ),
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
                                  '${note.comments.length}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.slateMuted,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 3: ตั้งค่า & เครื่องมือส่วนตัว (รวมเสียงแจ้งเตือน ธีม เครื่องมือเสริม และตั้งค่าระบบ)
  // ---------------------------------------------------------------------------
  Widget _buildSettingsAccordion({
    required String id,
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    final expanded = _openSettingsSection == id;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: expanded
              ? AppTheme.brandPrimary.withValues(alpha: 0.45)
              : AppTheme.borderSubtle,
        ),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            onTap: () => setState(() {
              _openSettingsSection = expanded ? null : id;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: expanded ? AppTheme.brandSoft : AppTheme.surfaceBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      icon,
                      size: 18,
                      color: expanded
                          ? AppTheme.brandPrimary
                          : AppTheme.slateDark,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateDark,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    expanded ? '▴' : '▾',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: expanded
                          ? AppTheme.brandPrimary
                          : AppTheme.slateMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: child,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsAndToolsTab() {
    final ov = _adminOverview;
    final isCompact = MediaQuery.of(context).size.width < 600;
    final enabledApps = _miniApps.where((m) => m.enabled).toList();

    return Scaffold(
      backgroundColor: AppTheme.surfaceBg,
      appBar: AppBar(
        title: const Text(
          'ตั้งค่า & เครื่องมือส่วนตัว',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_user.isAdmin)
            IconButton(
              onPressed: _loadAdminDataQuietly,
              tooltip: 'รีเฟรชข้อมูลระบบ',
              icon: const Icon(Icons.refresh_rounded),
            ),
          IconButton(
            onPressed: widget.onLoggedOut,
            tooltip: 'สลับบัญชี / ออกจากระบบ',
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(isCompact ? 10 : 14),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Personal Profile Quick Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    border: Border.all(color: AppTheme.borderSubtle),
                    boxShadow: AppTheme.shadowSm,
                  ),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          UserAvatar(
                            name: _user.displayName,
                            avatarUrl: _user.avatarUrl,
                            radius: 22,
                            showOnline: true,
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _user.displayName,
                                style: const TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.slateDark,
                                ),
                              ),
                              Text(
                                '@${_user.bcId}${_user.email.isNotEmpty ? ' · ${_user.email}' : ''}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.slateMuted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => setState(() {
                              _selectedIndex = 0;
                              _homeInlinePanel = 'profile';
                            }),
                            icon: const Icon(Icons.edit_rounded, size: 16),
                            label: const Text('แก้ไขโปรไฟล์'),
                          ),
                          OutlinedButton.icon(
                            onPressed: widget.onLoggedOut,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.dangerRed,
                            ),
                            icon: const Icon(Icons.logout_rounded, size: 16),
                            label: const Text('ออกจากระบบ'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // 1. Notifications & DND
                _buildSettingsAccordion(
                  id: 'notifications',
                  icon: Icons.notifications_active_outlined,
                  title: 'การแจ้งเตือน & ห้ามรบกวน',
                  subtitle: 'เสียงแจ้งเตือน ตัวอย่างข้อความ และช่วงเวลาห้ามรบกวน',
                  child: _InlineNotificationPanel(
                    showCloseButton: false,
                    user: _user,
                    onUserUpdated: (updated) {
                      setState(() => _user = updated);
                      widget.onUserChanged(updated);
                    },
                  ),
                ),

                // 2. Privacy & Hidden/Blocked
                _buildSettingsAccordion(
                  id: 'privacy',
                  icon: Icons.lock_outline_rounded,
                  title: 'ความเป็นส่วนตัว',
                  subtitle: 'วิธีเพิ่มเพื่อน รายชื่อที่ซ่อน และรายชื่อที่บล็อก',
                  child: _InlinePrivacyAndBlockedCard(
                    user: _user,
                    friends: _friends,
                    onUserUpdated: (updated) {
                      setState(() => _user = updated);
                      widget.onUserChanged(updated);
                    },
                    onFriendsChanged: _refreshConversationsAndFriends,
                  ),
                ),

                // 3. Account Linking, PIN Recovery & Shop Entry
                _buildSettingsAccordion(
                  id: 'security',
                  icon: Icons.shield_outlined,
                  title: 'ผูกบัญชี & กู้คืน',
                  subtitle: 'เบอร์มือถือ Google รหัส PIN กู้คืน และเปิดร้านค้า',
                  child: _InlineAccountLinkCard(
                    user: _user,
                    authConfig: _authConfig,
                    onUserUpdated: (updated) {
                      setState(() => _user = updated);
                      widget.onUserChanged(updated);
                    },
                    onOpenOaWorkspace: () => setState(() {
                      _selectedIndex = 1;
                      _chatInlinePanel = 'oa';
                    }),
                  ),
                ),

                // 4. Themes & Chat Mini-Apps
                _buildSettingsAccordion(
                  id: 'theme_tools',
                  icon: Icons.palette_outlined,
                  title: 'โทนสีห้องแชท & เครื่องมือเสริม',
                  subtitle: 'ธีมบ้านเชียง 7 สีไทยร่วมสมัย และเครื่องมือในแชท',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPersonalThemeCard(),
                      const SizedBox(height: 12),
                      Container(
                        padding: EdgeInsets.all(isCompact ? 10 : 12),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceBg,
                          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                          border: Border.all(color: AppTheme.borderSubtle),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              alignment: WrapAlignment.spaceBetween,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.widgets_rounded,
                                      color: AppTheme.brandPrimary,
                                    ),
                                    const SizedBox(width: 8),
                                    const Flexible(
                                      child: Text(
                                        'เครื่องมือเสริมในแชท',
                                        style: TextStyle(
                                          fontSize: 15,
                                          height: 1.35,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (_user.isAdmin)
                                  ElevatedButton.icon(
                                    onPressed: () => setState(() {
                                      _editingMiniApp = null;
                                      _showMiniAppFormInline =
                                          !_showMiniAppFormInline;
                                    }),
                                    icon: Icon(
                                      _showMiniAppFormInline
                                          ? Icons.close_rounded
                                          : Icons.add_rounded,
                                      size: 17,
                                    ),
                                    label: Text(
                                      _showMiniAppFormInline
                                          ? 'ปิดฟอร์ม'
                                          : 'เพิ่มเครื่องมือใหม่',
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'เปิดใช้หารค่าข้าว จัดทริปเที่ยว ลิสต์ของฝาก การ์ดชวนนัดเจอ หรือผู้ช่วย AI แล้วส่งเป็นการ์ดเข้าห้องแชทได้ทันที',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: AppTheme.slateMuted,
                              ),
                            ),
                            if (_user.isAdmin)
                              AnimatedSize(
                                duration: AppTheme.motionMed,
                                curve: AppTheme.motionCurve,
                                child: _showMiniAppFormInline
                                    ? Padding(
                                        padding: const EdgeInsets.only(top: 12),
                                        child: _buildInlinePanelWrapper(
                                          child: _InlineMiniAppFormPanel(
                                            key: ValueKey(
                                              _editingMiniApp?.id ?? 'new',
                                            ),
                                            existing: _editingMiniApp,
                                            onCancel: () => setState(() {
                                              _showMiniAppFormInline = false;
                                              _editingMiniApp = null;
                                            }),
                                            onSaved: () async {
                                              setState(() {
                                                _showMiniAppFormInline = false;
                                                _editingMiniApp = null;
                                              });
                                              await _loadAdminDataQuietly();
                                              if (!mounted) return;
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  backgroundColor:
                                                      AppTheme.brandDeep,
                                                  content: const Text(
                                                    'อัปเดตเครื่องมือเสริมเรียบร้อย!',
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: (_user.isAdmin ? _miniApps : enabledApps).map((app) {
                                final color = AppTheme.parseHexColor(app.color);
                                return Container(
                                  width: isCompact ? double.infinity : 320,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(
                                      AppTheme.radiusMd,
                                    ),
                                    border: Border.all(
                                      color: AppTheme.borderSubtle,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Container(
                                            width: 36,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              color: color,
                                              borderRadius: BorderRadius.circular(
                                                10,
                                              ),
                                            ),
                                        child: Icon(
                                          AppTheme.resolveMiniAppIcon(app.icon),
                                          color: Colors.white,
                                          size: 19,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              app.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.5,
                                              ),
                                            ),
                                            Text(
                                              app.category,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color: color,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (_user.isAdmin) ...[
                                        Switch(
                                          value: app.enabled,
                                          activeThumbColor:
                                              AppTheme.brandPrimary,
                                          onChanged: (val) async {
                                            await ApiService.instance
                                                .updateAdminMiniApp(app.id, {
                                                  ...app.toJson(),
                                                  'enabled': val,
                                                });
                                            await _loadAdminDataQuietly();
                                          },
                                        ),
                                        IconButton(
                                          onPressed: () => setState(() {
                                            _editingMiniApp = app;
                                            _showMiniAppFormInline = true;
                                          }),
                                          visualDensity: VisualDensity.compact,
                                          tooltip: 'แก้ไขเครื่องมือเสริม',
                                          icon: const Icon(
                                            Icons.edit_outlined,
                                            size: 18,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    app.subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.slateBody,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          onPressed: () => _openMiniApp(app),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: color,
                                          ),
                                          icon: const Icon(
                                            Icons.rocket_launch_rounded,
                                            size: 15,
                                          ),
                                          label: const Text('เปิดใช้งาน'),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        onPressed: () {
                                          final url = ApiService.instance
                                              .resolveMiniAppUrl(app);
                                          final uri = Uri.tryParse(url);
                                          if (uri != null) {
                                            launchUrl(
                                              uri,
                                              mode:
                                                  LaunchMode.externalApplication,
                                            );
                                          }
                                        },
                                        tooltip: 'เปิด URL ภายนอก',
                                        icon: const Icon(
                                          Icons.open_in_new_rounded,
                                          size: 18,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // 5. Admin Tools (shown only for Admin)
                if (_user.isAdmin)
                  _buildSettingsAccordion(
                    id: 'admin',
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'ผู้ดูแลระบบ',
                    subtitle: 'สถิติพื้นที่ไฟล์ ตั้งค่า AI SMS และส่งข่าวสารแอป',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LayoutBuilder(
                          builder: (context, box) {
                            final compact = box.maxWidth < 600;
                            final tileWidth = compact
                                ? (box.maxWidth - 12) / 2
                                : 255.0;
                            return Wrap(
                              spacing: compact ? 10 : 12,
                              runSpacing: compact ? 10 : 12,
                              children: [
                                _buildMetricCard(
                                  'สมาชิกทั้งหมด',
                                  '${ov?.totalUsers ?? _adminUsers.length} บัญชี',
                                  Icons.people_alt_rounded,
                                  AppTheme.brandPrimary,
                                  width: tileWidth,
                                  compact: compact,
                                ),
                                _buildMetricCard(
                                  'ห้องสนทนาทั้งหมด',
                                  '${ov?.totalConversations ?? _conversations.length} ห้อง',
                                  Icons.forum_rounded,
                                  AppTheme.workBlue,
                                  width: tileWidth,
                                  compact: compact,
                                ),
                                _buildMetricCard(
                                  'ข้อความทั้งหมด',
                                  '${ov?.totalMessages ?? 0} ข้อความ',
                                  Icons.mark_chat_read_rounded,
                                  AppTheme.personalPurple,
                                  width: tileWidth,
                                  compact: compact,
                                ),
                                _buildMetricCard(
                                  'ไฟล์เก็บถาวร',
                                  '${ov?.totalFiles ?? 0} ไฟล์ (${formatFileSize(ov?.totalStorageBytes ?? 0)})',
                                  Icons.cloud_done_rounded,
                                  AppTheme.warningAmber,
                                  width: tileWidth,
                                  compact: compact,
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 14),
                        _buildAiBrainSettingsCard(),
                        const SizedBox(height: 14),
                        _InlineAdminAuthSettingsCard(
                          initialSettings: _authSettings,
                          onUpdated: (settings) async {
                            setState(() => _authSettings = settings);
                            await _loadAuthAndCallsQuietly();
                          },
                        ),
                        const SizedBox(height: 14),
                        _buildBroadcastCard(),
                        const SizedBox(height: 14),
                        _buildUserManagementCard(),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard(
    String label,
    String value,
    IconData icon,
    Color color, {
    double width = 255,
    bool compact = false,
  }) {
    final iconTile = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Icon(icon, color: color, size: 22),
    );
    final labelText = Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 12,
        height: 1.4,
        color: AppTheme.slateMuted,
      ),
    );
    final valueText = Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 15.5,
        height: 1.35,
        fontWeight: FontWeight.w800,
        color: AppTheme.slateDark,
      ),
    );
    if (compact) {
      return Container(
        width: width,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          border: Border.all(color: AppTheme.borderSubtle),
          boxShadow: AppTheme.shadowSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            iconTile,
            const SizedBox(height: 12),
            // Two label lines reserved so every tile in the grid is equal height.
            SizedBox(height: 34, child: labelText),
            const SizedBox(height: 4),
            valueText,
          ],
        ),
      );
    }
    return Container(
      width: width,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          iconTile,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 4), valueText],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalThemeCard() {
    final current = AppTheme.preset.value;
    final tileWidth = MediaQuery.sizeOf(context).width < 600
        ? double.infinity
        : 236.0;
    return Container(
      padding: const EdgeInsets.all(13),
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: AppTheme.brandGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.palette_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ธีมสีของแอป (บ้านเชียง & 7 โทนสีไทยร่วมสมัย)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _user.isAdmin
                          ? 'เลือกโทนสีที่ชอบ เปลี่ยนแล้วซิงค์สดทุกเครื่อง'
                          : 'ธีมปัจจุบัน: ${current.name} (เปลี่ยนได้โดยเจ้าของระบบ)',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.slateMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final p in ThemePreset.all)
                SizedBox(
                  width: tileWidth,
                  child: _ThemePresetTile(
                    preset: p,
                    selected: p.code == current.code,
                    onTap: () => _changeBusinessTheme(p),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _changeBusinessTheme(ThemePreset preset) async {
    if (preset.code == AppTheme.preset.value.code) return;
    final snack = ScaffoldMessenger.of(context);
    try {
      await ApiService.instance.updateBusinessTheme(preset.code);
      snack.showSnackBar(
        SnackBar(content: Text('เปลี่ยนธีมเป็น "${preset.name}" แล้ว')),
      );
    } catch (e) {
      snack.showSnackBar(
        SnackBar(content: Text(_friendlyUiError(e, 'เปลี่ยนธีมไม่สำเร็จ'))),
      );
    }
  }

  Widget _buildAiBrainSettingsCard() {
    String selectedModel = _aiSettings.model;
    final apiKeyCtrl = TextEditingController();
    final promptCtrl = TextEditingController(text: _aiSettings.systemPrompt);

    return StatefulBuilder(
      builder: (ctx, setCardState) {
        return Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(
              color: AppTheme.personalPurple.withValues(alpha: 0.3),
            ),
            boxShadow: AppTheme.shadowMd,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6D28D9), Color(0xFF2563EB)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.psychology_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Text(
                              '🧠 ตั้งค่าสมองกล DeepSeek AI ส่วนตัว',
                              style: TextStyle(
                                fontSize: 15.5,
                                height: 1.35,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.slateDark,
                              ),
                            ),
                            PillBadge(
                              text:
                                  'API Key: ${_aiSettings.maskedKey.isNotEmpty ? _aiSettings.maskedKey : "พร้อมใช้งาน"}',
                              backgroundColor: AppTheme.brandSoft,
                              textColor: AppTheme.brandDeep,
                              icon: Icons.verified_rounded,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'ทำหน้าที่เป็นผู้ช่วยอัจฉริยะให้ครอบครัวและเพื่อนทุกห้องแชท (@ai ถามในกลุ่ม, สรุปแชท, เกลาคำพูด)',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'เลือกโมเดล DeepSeek:',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateDark,
                    ),
                  ),
                  ChoiceChip(
                    selected: selectedModel == 'deepseek-chat',
                    label: const Text('deepseek-chat (DeepSeek-V3)'),
                    onSelected: (_) =>
                        setCardState(() => selectedModel = 'deepseek-chat'),
                  ),
                  ChoiceChip(
                    selected: selectedModel == 'deepseek-reasoner',
                    label: const Text('deepseek-reasoner (DeepSeek-R1)'),
                    onSelected: (_) =>
                        setCardState(() => selectedModel = 'deepseek-reasoner'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: apiKeyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText:
                      'อัปเดต DeepSeek API Key (ปัจจุบัน: ${_aiSettings.maskedKey})',
                  hintText:
                      'เว้นว่างไว้หากใช้ API Key เดิมที่ตั้งค่าแล้วบนเซิร์ฟเวอร์',
                  prefixIcon: const Icon(Icons.key_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: promptCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText:
                      'System Prompt (กำหนดนิสัยและโทนการตอบของ BC AI)',
                  prefixIcon: Icon(Icons.tune_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      final updated = await ApiService.instance
                          .updateAdminAiSettings(
                            model: selectedModel,
                            apiKey: apiKeyCtrl.text,
                            systemPrompt: promptCtrl.text,
                          );
                      if (!mounted) return;
                      setState(() => _aiSettings = updated);
                      apiKeyCtrl.clear();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: AppTheme.brandDeep,
                          content: Text(
                            'บันทึกการตั้งค่าสมองกล DeepSeek AI ส่วนตัวเรียบร้อยแล้ว!',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _friendlyUiError(e, 'บันทึกไม่สำเร็จ'),
                          ),
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.personalPurple,
                  ),
                  icon: const Icon(Icons.save_rounded, size: 17),
                  label: const Text('บันทึกตั้งค่าสมองกล DeepSeek AI'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBroadcastCard() {
    final titleCtrl = TextEditingController(
      text: 'อัปเดตฟีเจอร์ใหม่ BC Ai Chat สำหรับทุกคน',
    );
    final contentCtrl = TextEditingController(
      text:
          'ตอนนี้ชวนเพื่อนหารค่าข้าว จัดทริปเที่ยว ลิสต์ของฝาก และส่งการ์ดชวนนัดเจอได้จากแท็บตั้งค่าและในห้องแชทเลยครับ!',
    );

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.campaign_rounded, color: AppTheme.warningAmber),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ส่งประกาศข่าวสารเข้าห้องข่าวสาร BC Ai Chat ถึงทุกคน',
                  style: TextStyle(
                    fontSize: 15.5,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: titleCtrl,
            decoration: const InputDecoration(labelText: 'หัวข้อข่าวสาร'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: contentCtrl,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'ข้อความข่าวสาร'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: () async {
                try {
                  await ApiService.instance.sendAdminBroadcast(
                    title: titleCtrl.text,
                    content: contentCtrl.text,
                  );
                  await _refreshConversationsAndFriends();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: AppTheme.brandDeep,
                      content: Text(
                        'ส่งข่าวสารเข้าห้องข่าวสาร BC Ai Chat เรียบร้อยแล้ว!',
                      ),
                    ),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: AppTheme.dangerRed,
                      content: Text(
                        _friendlyUiError(e, 'ส่งข่าวสารไม่สำเร็จ'),
                      ),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.send_rounded, size: 17),
              label: const Text('ส่งข่าวสารทันที'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserManagementCard() {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.verified_user_rounded, color: AppTheme.workBlue),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'รายชื่อสมาชิกที่ซิงค์ด้วยบัญชี Gmail',
                  style: TextStyle(
                    fontSize: 15.5,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _adminUsers.length,
            separatorBuilder: (context, index) => const Divider(),
            itemBuilder: (ctx, i) {
              final u = _adminUsers[i];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: UserAvatar(
                  name: u.displayName,
                  avatarUrl: u.avatarUrl,
                  radius: 19,
                ),
                title: Text(
                  u.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: Text(
                  '@${u.bcId}${u.email.isNotEmpty ? ' · ${u.email}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: PillBadge(
                  text: u.role.toUpperCase(),
                  backgroundColor: u.isAdmin
                      ? AppTheme.brandSoft
                      : AppTheme.surfaceBg,
                  textColor: u.isAdmin
                      ? AppTheme.brandDeep
                      : AppTheme.slateBody,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ThemePresetTile extends StatelessWidget {
  final ThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _ThemePresetTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return Material(
      color: selected ? preset.soft : Colors.white,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: selected ? preset.primary : AppTheme.borderSubtle,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: preset.gradient),
                  shape: BoxShape.circle,
                ),
                child: selected
                    ? const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 18,
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      preset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                        height: 1.3,
                      ),
                    ),
                    Text(
                      preset.suitsFor,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.slateMuted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineEditProfilePanel extends StatefulWidget {
  final AppUser user;
  final VoidCallback onCancel;
  final ValueChanged<AppUser> onSaved;

  const _InlineEditProfilePanel({
    required this.user,
    required this.onCancel,
    required this.onSaved,
  });

  @override
  State<_InlineEditProfilePanel> createState() => _InlineEditProfilePanelState();
}

class _InlineEditProfilePanelState extends State<_InlineEditProfilePanel> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _bcIdCtrl;
  late final TextEditingController _statusCtrl;
  Timer? _bcIdTimer;
  bool _saving = false;
  bool _checkingBcId = false;
  bool? _bcIdOk;
  String _bcIdMsg = 'เช่น @jead (a-z, 0-9, ., _, - ยาว 3–30 ตัว ห้ามซ้ำ)';

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.user.displayName);
    _bcIdCtrl = TextEditingController(text: widget.user.bcId);
    _statusCtrl = TextEditingController(text: widget.user.statusMessage);
  }

  void _onBcIdChanged(String raw) {
    _bcIdTimer?.cancel();
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _checkingBcId = false;
        _bcIdOk = false;
        _bcIdMsg = 'กรุณากรอก BC ID อย่างน้อย 3 ตัวอักษร';
      });
      return;
    }
    setState(() => _checkingBcId = true);
    _bcIdTimer = Timer(const Duration(milliseconds: 280), () async {
      try {
        final res = await ApiService.instance.checkBcId(trimmed);
        if (!mounted || _bcIdCtrl.text.trim() != trimmed) return;
        final valid = res['valid'] == true;
        final available = res['available'] == true;
        setState(() {
          _checkingBcId = false;
          _bcIdOk = valid && available;
          _bcIdMsg = (res['message'] ?? '').toString();
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _checkingBcId = false);
      }
    });
  }

  @override
  void dispose() {
    _bcIdTimer?.cancel();
    _nameCtrl.dispose();
    _bcIdCtrl.dispose();
    _statusCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_saving && _bcIdOk != false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Expanded(
              child: Text(
                'แก้ไขโปรไฟล์ & ตั้งค่า BC ID',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: 'ชื่อที่แสดง (Display Name)',
            prefixIcon: Icon(Icons.person_outline_rounded),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _bcIdCtrl,
          onChanged: _onBcIdChanged,
          decoration: const InputDecoration(
            labelText: 'BC ID (เช่น @jead ให้เพื่อนใช้ค้นหา)',
            prefixIcon: Icon(Icons.alternate_email_rounded),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              _checkingBcId
                  ? Icons.sync_rounded
                  : _bcIdOk == true
                  ? Icons.check_circle_outline_rounded
                  : _bcIdOk == false
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              size: 14,
              color: _bcIdOk == true
                  ? Colors.green.shade700
                  : _bcIdOk == false
                  ? Colors.red.shade700
                  : AppTheme.slateMuted,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                _checkingBcId ? 'กำลังตรวจสอบ BC ID...' : _bcIdMsg,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: _bcIdOk == null
                      ? FontWeight.w500
                      : FontWeight.w700,
                  color: _bcIdOk == true
                      ? Colors.green.shade700
                      : _bcIdOk == false
                      ? Colors.red.shade700
                      : AppTheme.slateMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _statusCtrl,
          decoration: const InputDecoration(
            labelText: 'คำคม / สถานะส่วนตัว',
            prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('ยกเลิก')),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: !canSave
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final rawBcId = _bcIdCtrl.text.trim();
                      if (rawBcId.isEmpty) {
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('กรุณากรอก BC ID อย่างน้อย 3 ตัวอักษร'),
                          ),
                        );
                        return;
                      }
                      setState(() => _saving = true);
                      try {
                        final updated = await ApiService.instance.updateProfile(
                          displayName: _nameCtrl.text,
                          bcId: rawBcId,
                          statusMessage: _statusCtrl.text,
                        );
                        if (mounted) widget.onSaved(updated);
                      } catch (e) {
                        if (mounted) {
                          final msg = e
                              .toString()
                              .replaceFirst('Exception: ', '')
                              .trim();
                          setState(() {
                            _saving = false;
                            _bcIdOk = false;
                            _bcIdMsg = msg;
                          });
                          messenger.showSnackBar(
                            SnackBar(content: Text(msg)),
                          );
                        }
                      }
                    },
              child: const Text('บันทึกการเปลี่ยนแปลง'),
            ),
          ],
        ),
      ],
    );
  }
}

class BcQrBox extends StatelessWidget {
  final String data;
  final double size;
  final double quietZonePadding;
  final double outerPadding;
  final double borderRadius;
  final Color borderColor;
  final double borderWidth;

  const BcQrBox({
    super.key,
    required this.data,
    required this.size,
    this.quietZonePadding = 8,
    this.outerPadding = 10,
    this.borderRadius = 14,
    this.borderColor = AppTheme.borderSubtle,
    this.borderWidth = 1,
  });

  @override
  Widget build(BuildContext context) {
    final trimmed = data.trim();
    return Container(
      padding: EdgeInsets.all(outerPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: trimmed.isEmpty
          ? SizedBox(
              width: size,
              height: size,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.qr_code_2_rounded,
                      size: 32,
                      color: AppTheme.slateMuted,
                    ),
                    SizedBox(height: 4),
                    Text(
                      'ยังไม่มี QR',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : QrImageView(
              data: trimmed,
              version: QrVersions.auto,
              size: size,
              padding: EdgeInsets.all(quietZonePadding),
              backgroundColor: Colors.white,
              gapless: true,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: AppTheme.slateDark,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: AppTheme.slateDark,
              ),
            ),
    );
  }
}

class AddFriendInlinePanel extends StatefulWidget {
  final AppUser? currentUser;
  final List<AppUser> friends;
  final ValueChanged<AppUser>? onUserUpdated;
  final VoidCallback onCancel;
  final Future<void> Function(AppUser? friend) onAddedFriend;
  final Future<void> Function(AppUser friend)? onOpenChatWithFriend;
  final Future<List<AppUser>> Function(String query, {String? by})?
  searchUsersFn;
  final Future<Map<String, dynamic>> Function({
    String? targetId,
    String? bcId,
    String? email,
    String? phone,
    String? qrToken,
    String? query,
  })?
  addFriendFn;
  final Future<AppUser> Function()? resetQrFn;

  const AddFriendInlinePanel({
    super.key,
    this.currentUser,
    this.friends = const [],
    this.onUserUpdated,
    required this.onCancel,
    required this.onAddedFriend,
    this.onOpenChatWithFriend,
    this.searchUsersFn,
    this.addFriendFn,
    this.resetQrFn,
  });

  @override
  State<AddFriendInlinePanel> createState() => _AddFriendInlinePanelState();
}

class _AddFriendInlinePanelState extends State<AddFriendInlinePanel> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<AppUser> _results = const [];
  bool _searching = false;
  bool _busyAction = false;
  bool _hasSearched = false;
  String _lastSearchedQuery = '';
  String _mode = 'phone'; // 'phone' | 'qr' | 'email' | 'id'
  String? _statusMsg;
  bool _isError = false;
  late String _myQrToken;

  @override
  void initState() {
    super.initState();
    _myQrToken = _resolveQr(widget.currentUser);
  }

  @override
  void didUpdateWidget(covariant AddFriendInlinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextQr = _resolveQr(widget.currentUser);
    if (nextQr.isNotEmpty && nextQr != _myQrToken) {
      _myQrToken = nextQr;
    }
  }

  String _resolveQr(AppUser? u) {
    if (u == null) return '';
    if (u.qrToken.isNotEmpty) return u.qrToken;
    final id = u.bcId.isNotEmpty ? u.bcId : u.email;
    return id.isNotEmpty ? 'bcaichat://add/$id' : '';
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _extractErr(Object e) =>
      e.toString().replaceFirst('Exception: ', '').trim();

  String _modeLabel(String mode) {
    switch (mode) {
      case 'phone':
        return 'เบอร์โทร';
      case 'qr':
        return 'รหัส QR';
      case 'email':
        return 'อีเมล';
      case 'id':
      default:
        return '@BC ID';
    }
  }

  String get _hintForMode {
    switch (_mode) {
      case 'phone':
        return 'พิมพ์เบอร์โทร เช่น 081-234-5678, +66 หรือเลขไทย';
      case 'qr':
        return 'วางรหัส QR หรือลิงก์ bcaichat://add/...';
      case 'email':
        return 'พิมพ์อีเมล เช่น friend@example.com';
      case 'id':
      default:
        return 'พิมพ์ @BC ID เช่น @kong.bc';
    }
  }

  void _switchMode(String nextMode, {bool clearIfPhoneQuery = false}) {
    setState(() {
      _mode = nextMode;
      _results = const [];
      _hasSearched = false;
      _lastSearchedQuery = '';
      _statusMsg = null;
      _isError = false;
      if (clearIfPhoneQuery &&
          RegExp(r'^[\d๐-๙\s\-+().]+$').hasMatch(_searchCtrl.text.trim())) {
        _searchCtrl.clear();
      }
    });
  }

  Future<void> _runSearch() async {
    final raw = _searchCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _results = const [];
        _hasSearched = false;
        _lastSearchedQuery = '';
        _statusMsg = 'กรุณากรอก${_modeLabel(_mode)}ที่ต้องการค้นหาก่อน';
        _isError = false;
      });
      return;
    }
    final normalized = normalizeFriendSearchQuery(raw, mode: _mode);
    if (normalized.isEmpty) {
      setState(() {
        _results = const [];
        _hasSearched = false;
        _lastSearchedQuery = '';
        _statusMsg = 'กรุณากรอก${_modeLabel(_mode)}ให้ถูกต้อง';
        _isError = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _hasSearched = true;
      _lastSearchedQuery = raw;
      _statusMsg = null;
      _isError = false;
    });
    try {
      final searchFn = widget.searchUsersFn ?? ApiService.instance.searchUsers;
      final found = await searchFn(normalized, by: _mode);
      if (!mounted) return;
      setState(() {
        _results = found;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _statusMsg = _extractErr(e);
        _isError = true;
      });
    }
  }

  /// เปิดหน้าสแกน QR เต็มจอ แล้วนำรหัสที่ได้ไปเพิ่มเพื่อนด้วย flow เดิม
  Future<void> _openQrFullScreen() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => QrFriendScreen(
          myQrData: _myQrToken,
          displayName: widget.currentUser?.displayName ?? '',
          bcId: widget.currentUser?.bcId ?? '',
        ),
      ),
    );
    if (!mounted || code == null || code.isEmpty) return;
    setState(() => _mode = 'qr');
    _searchCtrl.text = code;
    await _addDirectByInput();
  }

  Future<void> _addDirectByInput() async {
    final raw = _searchCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _statusMsg = 'กรุณากรอก${_modeLabel(_mode)}ของเพื่อนก่อนเพิ่มทันที';
        _isError = false;
      });
      return;
    }
    final normalized = normalizeFriendSearchQuery(raw, mode: _mode);
    setState(() {
      _busyAction = true;
      _statusMsg = null;
      _isError = false;
    });
    try {
      final addFn = widget.addFriendFn ?? ApiService.instance.addFriend;
      await addFn(
        phone: _mode == 'phone' ? normalized : null,
        email: _mode == 'email' ? normalized : null,
        bcId: _mode == 'id' ? normalized : null,
        qrToken: _mode == 'qr' ? normalized : null,
        query: normalized,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.brandDeep,
          content: Text('เพิ่มเพื่อนและสร้างห้องแชทเรียบร้อยแล้ว!'),
        ),
      );
      await widget.onAddedFriend(null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMsg = _extractErr(e);
        _isError = true;
      });
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _handleAddResult(AppUser user) async {
    if (_busyAction) return;
    setState(() {
      _busyAction = true;
      _statusMsg = null;
      _isError = false;
    });
    try {
      final addFn = widget.addFriendFn ?? ApiService.instance.addFriend;
      await addFn(targetId: user.id);
      if (!mounted) return;
      await widget.onAddedFriend(user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMsg = _extractErr(e);
        _isError = true;
      });
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _resetQr() async {
    setState(() {
      _busyAction = true;
      _statusMsg = null;
      _isError = false;
    });
    try {
      final updated = await (widget.resetQrFn ?? ApiService.instance.resetMyQr)();
      if (!mounted) return;
      setState(() {
        _busyAction = false;
        _myQrToken = _resolveQr(updated);
        _statusMsg = 'สร้างรหัส QR ใหม่เรียบร้อยแล้ว';
        _isError = false;
      });
      widget.onUserUpdated?.call(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyAction = false;
        _statusMsg = _extractErr(e);
        _isError = true;
      });
    }
  }

  Widget _buildEmptySearchFeedback() {
    final String detail;
    if (_mode == 'phone') {
      detail =
          'หากเพื่อนสมัครด้วย Gmail อาจยังไม่ได้ผูกเบอร์โทรในตั้งค่า หรืออีกฝ่ายปิดการค้นหาด้วยเบอร์โทรไว้\nแนะนำ: ลองค้นหาด้วย @BC ID หรืออีเมลแทน';
    } else if (_mode == 'email') {
      detail =
          'เพื่อนอาจยังไม่ได้ยืนยันอีเมลนี้ สมัครด้วยเบอร์โทร หรือปิดการค้นหาด้วยอีเมลไว้\nแนะนำ: ลองค้นหาด้วย @BC ID หรือเบอร์โทรแทน';
    } else if (_mode == 'id') {
      detail =
          'ตรวจสอบตัวสะกด @BC ID ให้ถูกต้อง (ไม่ต้องเว้นวรรค) หรือลองค้นหาด้วยเบอร์โทร / อีเมลแทน';
    } else {
      detail =
          'รหัส QR นี้อาจหมดอายุหรือถูกรีเซ็ตแล้ว กรุณาขอ QR Code ล่าสุดจากเพื่อน';
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.brandSoft.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.person_search_rounded,
                size: 18,
                color: AppTheme.brandPrimary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'ไม่พบผู้ใช้จาก${_modeLabel(_mode)} "$_lastSearchedQuery"',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              color: AppTheme.slateMuted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (_mode != 'id')
                OutlinedButton.icon(
                  onPressed: () => _switchMode(
                    'id',
                    clearIfPhoneQuery: _mode == 'phone',
                  ),
                  icon: const Icon(Icons.alternate_email_rounded, size: 14),
                  label: const Text(
                    'ค้นหาด้วย @BC ID',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                  ),
                ),
              if (_mode != 'email')
                OutlinedButton.icon(
                  onPressed: () => _switchMode(
                    'email',
                    clearIfPhoneQuery: _mode == 'phone',
                  ),
                  icon: const Icon(Icons.email_outlined, size: 14),
                  label: const Text(
                    'ค้นหาด้วยอีเมล',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                  ),
                ),
              if (_mode == 'email' || _mode == 'id')
                OutlinedButton.icon(
                  onPressed: () => _switchMode('phone'),
                  icon: const Icon(Icons.phone_rounded, size: 14),
                  label: const Text(
                    'ค้นหาด้วยเบอร์โทร',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultRow(AppUser u) {
    final myId =
        widget.currentUser?.id ?? ApiService.instance.currentUser?.id ?? '';
    final isSelf = myId.isNotEmpty && u.id == myId;
    final isExistingFriend =
        !isSelf && widget.friends.any((f) => f.id == u.id);
    final subtitle = u.bcId.isNotEmpty
        ? '@${u.bcId}${u.phone.isNotEmpty ? ' · ${u.phone}' : ''}'
        : (u.phone.isNotEmpty ? u.phone : u.email);

    Widget trailing;
    if (isSelf) {
      trailing = PillBadge(
        text: 'บัญชีของคุณเอง',
        backgroundColor: AppTheme.brandSoft,
        textColor: AppTheme.brandDeep,
        icon: Icons.person_outline_rounded,
      );
    } else if (isExistingFriend) {
      trailing = widget.onOpenChatWithFriend != null
          ? OutlinedButton.icon(
              onPressed: _busyAction
                  ? null
                  : () async {
                      setState(() => _busyAction = true);
                      try {
                        await widget.onOpenChatWithFriend!(u);
                      } finally {
                        if (mounted) {
                          setState(() => _busyAction = false);
                        }
                      }
                    },
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 14),
              label: const Text(
                'เป็นเพื่อนแล้ว · แชท',
                style: TextStyle(fontSize: 11.5),
              ),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
              ),
            )
          : PillBadge(
              text: 'เป็นเพื่อนแล้ว',
              backgroundColor: AppTheme.surfaceBg,
              textColor: AppTheme.slateDark,
              icon: Icons.check_circle_outline_rounded,
            );
    } else {
      trailing = ElevatedButton(
        onPressed: _busyAction ? null : () => _handleAddResult(u),
        style: ElevatedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        child: const Text('เพิ่ม & แชท'),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          UserAvatar(
            name: u.displayName,
            avatarUrl: u.avatarUrl,
            radius: 17,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  u.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.slateMuted,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const channels = [
      (id: 'phone', label: 'เบอร์โทร', icon: Icons.phone_rounded),
      (id: 'qr', label: 'QR Code', icon: Icons.qr_code_2_rounded),
      (id: 'email', label: 'อีเมล', icon: Icons.email_outlined),
      (id: 'id', label: '@BC ID', icon: Icons.alternate_email_rounded),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Expanded(
              child: Text(
                'เพิ่มเพื่อน 4 ช่องทาง',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: channels.map((c) {
            final selected = _mode == c.id;
            return ChoiceChip(
              avatar: Icon(
                c.icon,
                size: 15,
                color: selected ? Colors.white : AppTheme.brandPrimary,
              ),
              label: Text(
                c.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppTheme.slateDark,
                ),
              ),
              selected: selected,
              selectedColor: AppTheme.brandPrimary,
              backgroundColor: AppTheme.surfaceBg,
              visualDensity: VisualDensity.compact,
              showCheckmark: false,
              onSelected: (_) => _switchMode(c.id),
            );
          }).toList(),
        ),
        if (_mode == 'qr') ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceBg,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                BcQrBox(
                  data: _myQrToken,
                  size: 92,
                  quietZonePadding: 6,
                  outerPadding: 6,
                  borderRadius: 10,
                  borderColor: AppTheme.borderSubtle,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'QR Code ของฉัน',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'ให้เพื่อนสแกน หรือกดคัดลอกส่งให้เพื่อน',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          FilledButton.icon(
                            key: const Key('qr-fullscreen-open-btn'),
                            onPressed: _busyAction ? null : _openQrFullScreen,
                            icon: const Icon(
                              Icons.qr_code_scanner_rounded,
                              size: 14,
                            ),
                            label: const Text(
                              'สแกน QR เต็มจอ',
                              style: TextStyle(fontSize: 11.5),
                            ),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _myQrToken),
                              );
                              setState(() {
                                _statusMsg = 'คัดลอกรหัส QR แล้ว';
                                _isError = false;
                              });
                            },
                            icon: const Icon(Icons.copy_rounded, size: 14),
                            label: const Text(
                              'คัดลอก',
                              style: TextStyle(fontSize: 11.5),
                            ),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busyAction ? null : _resetQr,
                            icon: const Icon(Icons.refresh_rounded, size: 14),
                            label: const Text(
                              'รีเซ็ต QR',
                              style: TextStyle(fontSize: 11.5),
                            ),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                keyboardType: TextInputType.text,
                textInputAction: _mode == 'qr'
                    ? TextInputAction.done
                    : TextInputAction.search,
                onSubmitted: (_) =>
                    _mode == 'qr' ? _addDirectByInput() : _runSearch(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: _hintForMode,
                  prefixIcon: const Icon(Icons.search_rounded, size: 19),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _searching ? null : _runSearch,
              child: const Text('ค้นหา'),
            ),
          ],
        ),
        if (_statusMsg != null) ...[
          const SizedBox(height: 6),
          Text(
            _statusMsg!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _isError ? AppTheme.dangerRed : AppTheme.brandDeep,
            ),
          ),
        ],
        if (_searching)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_results.isNotEmpty) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 210),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _results.length,
              separatorBuilder: (_, _) => const Divider(height: 8),
              itemBuilder: (_, idx) => _buildResultRow(_results[idx]),
            ),
          ),
        ] else if (_hasSearched && _statusMsg == null)
          _buildEmptySearchFeedback(),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('ปิด')),
              OutlinedButton.icon(
                onPressed: _busyAction ? null : _addDirectByInput,
                icon: const Icon(Icons.add_rounded, size: 17),
                label: Text(
                  _mode == 'qr' ? 'เพิ่มเพื่อนจาก QR' : 'เพิ่มเพื่อนทันที',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InlineJoinGroupPanel extends StatefulWidget {
  final VoidCallback onCancel;
  final Future<void> Function(Conversation conv) onJoined;

  const _InlineJoinGroupPanel({
    required this.onCancel,
    required this.onJoined,
  });

  @override
  State<_InlineJoinGroupPanel> createState() => _InlineJoinGroupPanelState();
}

class _InlineJoinGroupPanelState extends State<_InlineJoinGroupPanel> {
  final TextEditingController _tokenCtrl = TextEditingController();

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Expanded(
              child: Text(
                'เข้ากลุ่มด้วยรหัสเชิญ',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _tokenCtrl,
          decoration: const InputDecoration(
            labelText: 'รหัสเชิญเข้ากลุ่ม',
            hintText: 'วางรหัสเชิญที่ได้รับจากเพื่อนหรือคนในบ้าน',
            prefixIcon: Icon(Icons.vpn_key_rounded),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('ยกเลิก')),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () async {
                final token = _tokenCtrl.text.trim();
                if (token.isEmpty) return;
                final snack = ScaffoldMessenger.of(context);
                try {
                  final conv = await ApiService.instance.joinConversationByToken(
                    token,
                  );
                  await widget.onJoined(conv);
                } catch (e) {
                  snack.showSnackBar(
                    SnackBar(
                      content: Text(e.toString().replaceAll('Exception: ', '')),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.login_rounded, size: 17),
              label: const Text('เข้าร่วมกลุ่ม'),
            ),
          ],
        ),
      ],
    );
  }
}

class _InlineCreateGroupPanel extends StatefulWidget {
  final List<AppUser> friends;
  final VoidCallback onCancel;
  final Future<void> Function(Conversation conv) onCreated;

  const _InlineCreateGroupPanel({
    required this.friends,
    required this.onCancel,
    required this.onCreated,
  });

  @override
  State<_InlineCreateGroupPanel> createState() =>
      _InlineCreateGroupPanelState();
}

class _InlineCreateGroupPanelState extends State<_InlineCreateGroupPanel> {
  final TextEditingController _nameCtrl = TextEditingController();
  String _folder = 'family';
  final Set<String> _selectedMemberIds = {};
  bool _includeAi = true;
  bool _busy = false;
  String? _errMsg;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectable = widget.friends.where((f) => f.id != 'user_ai').toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Expanded(
              child: Text(
                'สร้างกลุ่มแชทใหม่',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: 'ชื่อกลุ่มแชท',
            hintText: 'เช่น แก๊งเที่ยวเชียงใหม่ หรือ กลุ่มครอบครัว',
            prefixIcon: Icon(Icons.groups_rounded),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('ครอบครัว'),
              selected: _folder == 'family',
              onSelected: (_) => setState(() => _folder = 'family'),
            ),
            ChoiceChip(
              label: const Text('ส่วนตัว / เพื่อน'),
              selected: _folder == 'personal',
              onSelected: (_) => setState(() => _folder = 'personal'),
            ),
          ],
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _includeAi,
          title: const Text(
            'เชิญ 🤖 BC AI เข้ากลุ่มด้วยทันที',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          onChanged: (v) => setState(() => _includeAi = v ?? true),
        ),
        if (selectable.isNotEmpty) ...[
          const Text(
            'เลือกสมาชิกเข้ากลุ่ม:',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView(
              shrinkWrap: true,
              children: selectable.map((f) {
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _selectedMemberIds.contains(f.id),
                  title: Text(
                    f.displayName,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selectedMemberIds.add(f.id);
                    } else {
                      _selectedMemberIds.remove(f.id);
                    }
                  }),
                );
              }).toList(),
            ),
          ),
        ],
        if (_errMsg != null) ...[
          const SizedBox(height: 6),
          Text(
            _errMsg!,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.dangerRed,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('ยกเลิก')),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      final groupName = _nameCtrl.text.trim();
                      if (groupName.isEmpty) {
                        setState(() => _errMsg = 'กรุณาตั้งชื่อกลุ่มแชทก่อน');
                        return;
                      }
                      setState(() {
                        _busy = true;
                        _errMsg = null;
                      });
                      try {
                        final members = {
                          ..._selectedMemberIds,
                          if (_includeAi) 'user_ai',
                        }.toList();
                        final conv = await ApiService.instance
                            .createGroupConversation(
                              name: groupName,
                              folder: _folder,
                              memberIds: members,
                            );
                        if (!mounted) return;
                        await widget.onCreated(conv);
                      } catch (e) {
                        if (!mounted) return;
                        setState(
                          () => _errMsg = e
                              .toString()
                              .replaceFirst('Exception: ', '')
                              .trim(),
                        );
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              icon: const Icon(Icons.check_rounded, size: 17),
              label: const Text('สร้างกลุ่มแชท'),
            ),
          ],
        ),
      ],
    );
  }
}

class _InlineNotificationPanel extends StatefulWidget {
  final VoidCallback? onClose;
  final bool showCloseButton;
  final AppUser? user;
  final ValueChanged<AppUser>? onUserUpdated;

  const _InlineNotificationPanel({
    this.onClose,
    this.showCloseButton = true,
    this.user,
    this.onUserUpdated,
  });

  @override
  State<_InlineNotificationPanel> createState() =>
      _InlineNotificationPanelState();
}

class _InlineNotificationPanelState extends State<_InlineNotificationPanel>
    with WidgetsBindingObserver {
  final _n = NotificationService.instance;
  bool? _ignoringBatteryOptimizations;
  bool _savingRemote = false;

  AppUser? get _effectiveUser =>
      widget.user ?? ApiService.instance.currentUser;

  Future<void> _updateRemote({
    String? dndMode,
    bool? notifyPreview,
    bool? notifyOnMention,
  }) async {
    setState(() => _savingRemote = true);
    try {
      final updated = await ApiService.instance.updateMeSettings(
        dndMode: dndMode,
        notifyPreview: notifyPreview,
        notifyOnMention: notifyOnMention,
      );
      if (!mounted) return;
      widget.onUserUpdated?.call(updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'อัปเดตการตั้งค่าแจ้งเตือนไม่สำเร็จ: ${cleanErrorMessage(e)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingRemote = false);
    }
  }

  String _formatDndTime(DateTime? dt) {
    if (dt == null) return '';
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm น.';
  }

  @override
  void initState() {
    super.initState();
    if (PushService.supported) {
      WidgetsBinding.instance.addObserver(this);
      _refreshBatteryStatus();
    }
  }

  @override
  void dispose() {
    if (PushService.supported) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && PushService.supported) {
      _refreshBatteryStatus();
    }
  }

  Future<void> _refreshBatteryStatus() async {
    final ok = await PushService.instance.isIgnoringBatteryOptimizations();
    if (mounted) {
      setState(() => _ignoringBatteryOptimizations = ok);
    }
  }

  Future<void> _update(Future<void> Function() fn) async {
    await fn();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final batteryOk = _ignoringBatteryOptimizations;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.notifications_active_rounded,
              color: AppTheme.brandPrimary,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'เสียงและการแจ้งเตือน',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            if (widget.showCloseButton && widget.onClose != null)
              IconButton(
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, size: 20),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        if (PushService.supported && batteryOk != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: batteryOk
                  ? const Color(0xFFECFDF5)
                  : const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              border: Border.all(
                color: batteryOk
                    ? const Color(0xFFA7F3D0)
                    : const Color(0xFFFED7AA),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  batteryOk
                      ? Icons.verified_user_rounded
                      : Icons.battery_alert_rounded,
                  size: 18,
                  color: batteryOk
                      ? const Color(0xFF047857)
                      : const Color(0xFFC2410C),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    batteryOk
                        ? 'ทำงานเบื้องหลังตลอดเวลา · เตือนแม้ปิดแอปและปิดหน้าจอ'
                        : 'ระบบประหยัดแบตอาจปิดเสียงเตือนตอนปิดจอ แนะนำให้อนุญาตทำงานเบื้องหลัง',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: batteryOk
                          ? const Color(0xFF065F46)
                          : const Color(0xFF9A3412),
                    ),
                  ),
                ),
                if (!batteryOk) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      await PushService.instance
                          .requestIgnoreBatteryOptimizations();
                      await _refreshBatteryStatus();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.brandPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'อนุญาตทำงานเบื้องหลัง',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _n.popupEnabled,
          activeThumbColor: AppTheme.brandPrimary,
          title: const Text(
            'แจ้งเตือนเมื่อมีแชทเข้า',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
          ),
          onChanged: (v) => _update(() => _n.setPopupEnabled(v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _n.soundEnabled,
          activeThumbColor: AppTheme.brandPrimary,
          title: const Text(
            'เปิดเสียงแจ้งเตือน',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
          ),
          onChanged: (v) => _update(() => _n.setSoundEnabled(v)),
        ),
        if (_effectiveUser != null) ...[
          const Divider(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.bedtime_outlined,
                size: 16,
                color: _effectiveUser!.isDndActive
                    ? AppTheme.brandPrimary
                    : AppTheme.slateMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _effectiveUser!.isDndActive
                      ? 'โหมดห้ามรบกวน (เปิดอยู่ถึง ${_formatDndTime(_effectiveUser!.dndUntilDate)})'
                      : 'โหมดห้ามรบกวนทั้งแอป',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final opt in const [
                (code: 'off', label: 'ปิด'),
                (code: '1h', label: '1 ชม.'),
                (code: '8h', label: '8 ชม.'),
                (code: 'until_8am', label: 'ถึง 08:00 น.'),
              ])
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: (opt.code == 'off' &&
                          !_effectiveUser!.isDndActive)
                      ? AppTheme.brandSoft
                      : AppTheme.surfaceBg,
                  label: Text(
                    opt.label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: _savingRemote
                      ? null
                      : () => _updateRemote(dndMode: opt.code),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _effectiveUser!.notifyPreview,
            activeThumbColor: AppTheme.brandPrimary,
            title: const Text(
              'แสดงตัวอย่างข้อความแจ้งเตือน',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            subtitle: const Text(
              'ปิดเพื่อซ่อนข้อความเป็น "คุณมีข้อความใหม่"',
              style: TextStyle(fontSize: 11),
            ),
            onChanged: _savingRemote
                ? null
                : (v) => _updateRemote(notifyPreview: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _effectiveUser!.notifyOnMention,
            activeThumbColor: AppTheme.brandPrimary,
            title: const Text(
              'เตือนเมื่อถูก @กล่าวถึง (แม้ปิดเสียงห้อง)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            onChanged: _savingRemote
                ? null
                : (v) => _updateRemote(notifyOnMention: v),
          ),
        ],
        if (_n.soundEnabled) ...[
          const SizedBox(height: 6),
          for (final kind in AlertKind.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      kind.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DropdownButton<String>(
                    value: _n.soundOf(kind),
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final s in NotificationService.sounds)
                        DropdownMenuItem(
                          value: s.code,
                          child: Text(
                            s.name,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                    ],
                    onChanged: (code) {
                      if (code == null) return;
                      _update(() async {
                        await _n.setSoundOf(kind, code);
                        _n.playSound(code);
                      });
                    },
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _InlinePrivacyAndBlockedCard extends StatefulWidget {
  final AppUser user;
  final List<AppUser> friends;
  final ValueChanged<AppUser> onUserUpdated;
  final Future<void> Function() onFriendsChanged;

  const _InlinePrivacyAndBlockedCard({
    required this.user,
    required this.friends,
    required this.onUserUpdated,
    required this.onFriendsChanged,
  });

  @override
  State<_InlinePrivacyAndBlockedCard> createState() =>
      _InlinePrivacyAndBlockedCardState();
}

class _InlinePrivacyAndBlockedCardState
    extends State<_InlinePrivacyAndBlockedCard> {
  bool _saving = false;
  bool _showHidden = false;
  bool _showBlocked = false;

  Future<void> _updatePrivacy({
    bool? allowPhone,
    bool? allowId,
    bool? allowEmail,
  }) async {
    setState(() => _saving = true);
    try {
      final updated = await ApiService.instance.updateMeSettings(
        allowAddByPhone: allowPhone,
        allowAddById: allowId,
        allowAddByEmail: allowEmail,
      );
      if (!mounted) return;
      widget.onUserUpdated(updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'บันทึกตั้งค่าความเป็นส่วนตัวไม่สำเร็จ: ${cleanErrorMessage(e)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hiddenFriends = widget.friends
        .where((f) => f.isHidden && !f.isBlocked)
        .toList();
    final blockedFriends = widget.friends.where((f) => f.isBlocked).toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.shield_outlined, color: AppTheme.brandPrimary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'ความเป็นส่วนตัว & รายชื่อที่ซ่อน/บล็อก',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: widget.user.allowAddByPhone,
            activeThumbColor: AppTheme.brandPrimary,
            title: const Text(
              'อนุญาตเพิ่มเพื่อนด้วยเบอร์โทร',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            onChanged: _saving ? null : (v) => _updatePrivacy(allowPhone: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: widget.user.allowAddById,
            activeThumbColor: AppTheme.brandPrimary,
            title: const Text(
              'อนุญาตเพิ่มเพื่อนด้วย @BC ID',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            onChanged: _saving ? null : (v) => _updatePrivacy(allowId: v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: widget.user.allowAddByEmail,
            activeThumbColor: AppTheme.brandPrimary,
            title: const Text(
              'อนุญาตเพิ่มเพื่อนด้วยอีเมล',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            onChanged: _saving ? null : (v) => _updatePrivacy(allowEmail: v),
          ),
          const Divider(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: () => setState(() => _showHidden = !_showHidden),
                icon: Icon(
                  _showHidden
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_outlined,
                  size: 15,
                ),
                label: Text(
                  'รายชื่อที่ซ่อน (${hiddenFriends.length})',
                  style: const TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => setState(() => _showBlocked = !_showBlocked),
                icon: const Icon(
                  Icons.block_rounded,
                  size: 15,
                  color: AppTheme.dangerRed,
                ),
                label: Text(
                  'รายชื่อที่บล็อก (${blockedFriends.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.dangerRed,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (_showHidden) ...[
            const SizedBox(height: 8),
            if (hiddenFriends.isEmpty)
              const Text(
                'ไม่มีเพื่อนที่ซ่อนอยู่',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              )
            else
              for (final f in hiddenFriends)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      UserAvatar(
                        name: f.displayName,
                        avatarUrl: f.avatarUrl,
                        radius: 14,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await ApiService.instance.updateFriendMeta(
                            f.id,
                            isHidden: false,
                          );
                          await widget.onFriendsChanged();
                        },
                        child: const Text(
                          'เลิกซ่อน',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await ApiService.instance.deleteFriend(f.id);
                          await widget.onFriendsChanged();
                        },
                        child: const Text(
                          'ลบ',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.dangerRed,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
          if (_showBlocked) ...[
            const SizedBox(height: 8),
            if (blockedFriends.isEmpty)
              const Text(
                'ไม่มีรายชื่อที่ถูกบล็อก',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              )
            else
              for (final f in blockedFriends)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      UserAvatar(
                        name: f.displayName,
                        avatarUrl: f.avatarUrl,
                        radius: 14,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          await ApiService.instance.updateFriendMeta(
                            f.id,
                            isBlocked: false,
                          );
                          await widget.onFriendsChanged();
                        },
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                        ),
                        child: const Text(
                          'ปลดบล็อก',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: () async {
                          await ApiService.instance.deleteFriend(f.id);
                          await widget.onFriendsChanged();
                        },
                        child: const Text(
                          'ลบ',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.dangerRed,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

class _InlineCreateNotePanel extends StatefulWidget {
  final VoidCallback onCancel;
  final Future<void> Function() onCreated;

  const _InlineCreateNotePanel({
    required this.onCancel,
    required this.onCreated,
  });

  @override
  State<_InlineCreateNotePanel> createState() => _InlineCreateNotePanelState();
}

class _InlineCreateNotePanelState extends State<_InlineCreateNotePanel> {
  final _titleCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  String _category = 'บันทึกสำคัญ';
  bool _saving = false;
  String? _errMsg;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Expanded(
              child: Text(
                'สร้างบันทึกใหม่ในสมุดบันทึก BC',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final cat in const ['บันทึกสำคัญ', 'ครอบครัว', 'ทริป & รูปถ่าย'])
              ChoiceChip(
                label: Text(cat),
                selected: _category == cat,
                onSelected: (_) => setState(() => _category = cat),
              ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _titleCtrl,
          decoration: const InputDecoration(
            labelText: 'หัวข้อบันทึก',
            prefixIcon: Icon(Icons.title_rounded),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _contentCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'ข้อความ / ลิงก์ / รายละเอียดที่ต้องการเก็บถาวร',
          ),
        ),
        if (_errMsg != null) ...[
          const SizedBox(height: 6),
          Text(
            _errMsg!,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.dangerRed,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('ยกเลิก')),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _saving
                  ? null
                  : () async {
                      final title = _titleCtrl.text.trim();
                      if (title.isEmpty) {
                        setState(() => _errMsg = 'กรุณากรอกหัวข้อบันทึกก่อน');
                        return;
                      }
                      setState(() {
                        _saving = true;
                        _errMsg = null;
                      });
                      try {
                        await ApiService.instance.createNote(
                          title: title,
                          content: _contentCtrl.text.trim(),
                          category: _category,
                        );
                        if (!mounted) return;
                        await widget.onCreated();
                      } catch (e) {
                        if (!mounted) return;
                        setState(
                          () => _errMsg = e
                              .toString()
                              .replaceFirst('Exception: ', '')
                              .trim(),
                        );
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    },
              child: const Text('บันทึกเข้าสมุดบันทึก BC'),
            ),
          ],
        ),
      ],
    );
  }
}

class _InlineMiniAppFormPanel extends StatefulWidget {
  final MiniAppItem? existing;
  final VoidCallback onCancel;
  final Future<void> Function() onSaved;

  const _InlineMiniAppFormPanel({
    super.key,
    this.existing,
    required this.onCancel,
    required this.onSaved,
  });

  @override
  State<_InlineMiniAppFormPanel> createState() =>
      _InlineMiniAppFormPanelState();
}

class _InlineMiniAppFormPanelState extends State<_InlineMiniAppFormPanel> {
  late TextEditingController _codeCtrl;
  late TextEditingController _titleCtrl;
  late TextEditingController _subtitleCtrl;
  late TextEditingController _categoryCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _colorCtrl;
  bool _saving = false;
  String? _errMsg;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeCtrl = TextEditingController(text: e?.code ?? 'trip_checklist');
    _titleCtrl = TextEditingController(
      text: e?.title ?? 'เช็กลิสต์จัดกระเป๋าเที่ยว',
    );
    _subtitleCtrl = TextEditingController(
      text: e?.subtitle ?? 'จดของที่ต้องเตรียมก่อนออกทริปกับเพื่อนๆ',
    );
    _categoryCtrl = TextEditingController(
      text: e?.category ?? 'ไลฟ์สไตล์ & ท่องเที่ยว',
    );
    _urlCtrl = TextEditingController(text: e?.url ?? '/miniapp/trip_checklist');
    _colorCtrl = TextEditingController(text: e?.color ?? '#812920');
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _titleCtrl.dispose();
    _subtitleCtrl.dispose();
    _categoryCtrl.dispose();
    _urlCtrl.dispose();
    _colorCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                existing == null
                    ? 'เพิ่มเครื่องมือเสริมใหม่'
                    : 'แก้ไขเครื่องมือ ${existing.title}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _codeCtrl,
          decoration: const InputDecoration(labelText: 'รหัสเครื่องมือ (Code)'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _titleCtrl,
          decoration: const InputDecoration(labelText: 'ชื่อเครื่องมือ'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _subtitleCtrl,
          decoration: const InputDecoration(labelText: 'คำอธิบายสั้นๆ'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _categoryCtrl,
          decoration: const InputDecoration(labelText: 'หมวดหมู่'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _urlCtrl,
          decoration: const InputDecoration(labelText: 'Path หรือ URL'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _colorCtrl,
          decoration: const InputDecoration(labelText: 'สีประจำเครื่องมือ (Hex)'),
        ),
        if (_errMsg != null) ...[
          const SizedBox(height: 6),
          Text(
            _errMsg!,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.dangerRed,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('ยกเลิก')),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _saving
                  ? null
                  : () async {
                      setState(() {
                        _saving = true;
                        _errMsg = null;
                      });
                      try {
                        final payload = {
                          'code': _codeCtrl.text.trim(),
                          'title': _titleCtrl.text.trim(),
                          'subtitle': _subtitleCtrl.text.trim(),
                          'category': _categoryCtrl.text.trim(),
                          'url': _urlCtrl.text.trim(),
                          'color': _colorCtrl.text.trim(),
                          'icon': existing?.icon ?? 'celebration',
                          'enabled': existing?.enabled ?? true,
                        };
                        if (existing == null) {
                          await ApiService.instance.createAdminMiniApp(payload);
                        } else {
                          await ApiService.instance.updateAdminMiniApp(
                            existing.id,
                            payload,
                          );
                        }
                        if (!mounted) return;
                        await widget.onSaved();
                      } catch (e) {
                        if (!mounted) return;
                        setState(
                          () => _errMsg = e
                              .toString()
                              .replaceFirst('Exception: ', '')
                              .trim(),
                        );
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    },
              child: const Text('บันทึกเครื่องมือ'),
            ),
          ],
        ),
      ],
    );
  }
}

class _InlineAccountLinkCard extends StatefulWidget {
  final AppUser user;
  final AuthConfig authConfig;
  final ValueChanged<AppUser> onUserUpdated;
  final VoidCallback onOpenOaWorkspace;

  const _InlineAccountLinkCard({
    required this.user,
    required this.authConfig,
    required this.onUserUpdated,
    required this.onOpenOaWorkspace,
  });

  @override
  State<_InlineAccountLinkCard> createState() => _InlineAccountLinkCardState();
}

class _InlineAccountLinkCardState extends State<_InlineAccountLinkCard> {
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _otpCtrl = TextEditingController();
  final TextEditingController _linkPinCtrl = TextEditingController();
  final TextEditingController _currentPinCtrl = TextEditingController();
  final TextEditingController _newPinCtrl = TextEditingController();
  bool _showPhoneForm = false;
  bool _showPinSetup = false;
  bool _showLogs = false;
  bool _busy = false;
  OtpRequestResult? _challenge;
  int _countdown = 0;
  Timer? _countdownTimer;
  Timer? _googlePollTimer;
  bool _pollingGoogle = false;
  String? _statusMsg;
  String? _errorMsg;
  List<String> _generatedBackupCodes = const [];
  List<RecoveryLogDto> _recoveryLogs = const [];
  bool _loadingLogs = false;

  @override
  void initState() {
    super.initState();
    _phoneCtrl.text = widget.user.phone;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _googlePollTimer?.cancel();
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    _linkPinCtrl.dispose();
    _currentPinCtrl.dispose();
    _newPinCtrl.dispose();
    super.dispose();
  }

  String _genState() {
    final rng = Random.secure();
    return List<int>.generate(
      16,
      (_) => rng.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _requestLinkOtp() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.length < 9) {
      setState(() => _errorMsg = 'กรุณากรอกเบอร์โทรศัพท์มือถือให้ถูกต้อง');
      return;
    }
    setState(() {
      _busy = true;
      _errorMsg = null;
      _statusMsg = null;
    });
    try {
      final res = await ApiService.instance.requestOtp(
        phone: phone,
        purpose: 'link',
      );
      _countdownTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _challenge = res;
        _countdown = 60;
        _statusMsg = 'ส่ง OTP แล้ว (Ref: ${res.refCode})';
      });
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted || _countdown <= 1) {
          t.cancel();
          if (mounted) setState(() => _countdown = 0);
        } else {
          setState(() => _countdown -= 1);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _verifyLinkPhone() async {
    final ch = _challenge;
    final code = _otpCtrl.text.trim();
    if (ch == null || code.length < 4) {
      setState(() => _errorMsg = 'กรุณากรอกรหัส OTP ให้ครบ');
      return;
    }
    setState(() {
      _busy = true;
      _errorMsg = null;
    });
    try {
      final updated = await ApiService.instance.linkPhone(
        challengeId: ch.challengeId,
        otpCode: code,
        refCode: ch.refCode,
        recoveryPin: _linkPinCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _showPhoneForm = false;
        _challenge = null;
        _otpCtrl.clear();
        _linkPinCtrl.clear();
        _statusMsg = 'เชื่อมเบอร์โทรเรียบร้อยแล้ว';
      });
      widget.onUserUpdated(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _startLinkGoogle() async {
    _googlePollTimer?.cancel();
    final state = _genState();
    final url = ApiService.instance.googleStartUrl(mode: 'link', state: state);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      setState(() => _errorMsg = 'ไม่สามารถเปิดเบราว์เซอร์เพื่อเชื่อม Gmail ได้');
      return;
    }
    setState(() {
      _pollingGoogle = true;
      _errorMsg = null;
      _statusMsg = 'กำลังรอยืนยัน Gmail ในเบราว์เซอร์...';
    });
    var ticks = 0;
    _googlePollTimer = Timer.periodic(const Duration(milliseconds: 1500), (
      t,
    ) async {
      ticks += 1;
      if (!mounted || !_pollingGoogle || ticks > 80) {
        t.cancel();
        if (mounted) setState(() => _pollingGoogle = false);
        return;
      }
      try {
        final res = await ApiService.instance.pollGoogleOAuth(state);
        if (!mounted) {
          t.cancel();
          return;
        }
        if (res.status == 'completed' && res.user != null) {
          t.cancel();
          setState(() {
            _pollingGoogle = false;
            _statusMsg = 'เชื่อมบัญชี Gmail สำเร็จ';
          });
          widget.onUserUpdated(res.user!);
        } else if (res.status == 'error') {
          t.cancel();
          setState(() {
            _pollingGoogle = false;
            _errorMsg = res.error.isNotEmpty ? res.error : 'เชื่อม Gmail ไม่สำเร็จ';
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _handleUnlinkGoogle() async {
    setState(() {
      _busy = true;
      _errorMsg = null;
      _statusMsg = null;
    });
    try {
      final updated = await ApiService.instance.unlinkGoogle();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMsg = 'ยกเลิกการเชื่อม Gmail แล้ว';
      });
      widget.onUserUpdated(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleSetupPin() async {
    final pin = _newPinCtrl.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() => _errorMsg = 'กรุณากรอก PIN เป็นตัวเลข 6 หลัก');
      return;
    }
    setState(() {
      _busy = true;
      _errorMsg = null;
      _statusMsg = null;
    });
    try {
      final res = await ApiService.instance.setupRecoveryPin(
        recoveryPin: pin,
        currentPin: widget.user.hasRecoveryPin
            ? _currentPinCtrl.text.trim()
            : null,
        regenerateCodes: true,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _currentPinCtrl.clear();
        _newPinCtrl.clear();
        _generatedBackupCodes = res.backupCodes;
        _statusMsg = 'ตั้งค่า PIN กู้คืนและสร้างรหัสสำรองเรียบร้อยแล้ว';
      });
      widget.onUserUpdated(res.user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _toggleLogs() async {
    final nextShow = !_showLogs;
    setState(() {
      _showLogs = nextShow;
      if (nextShow) _loadingLogs = true;
    });
    if (!nextShow) return;
    try {
      final logs = await ApiService.instance.getRecoveryLogs();
      if (!mounted) return;
      setState(() {
        _recoveryLogs = logs;
        _loadingLogs = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLogs = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final canUnlinkGoogle =
        u.phoneVerified &&
        u.phone.trim().isNotEmpty &&
        (u.hasGoogleLinked || u.emailVerified);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 18,
                color: AppTheme.brandPrimary,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'บัญชี การกู้คืนข้อมูล & ร้านค้า',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
                ),
              ),
              OutlinedButton.icon(
                onPressed: widget.onOpenOaWorkspace,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.storefront_rounded, size: 16),
                label: const Text('จัดการ / เปิดร้านค้า', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_errorMsg != null) ...[
            Text(
              _errorMsg!,
              style: const TextStyle(fontSize: 12, color: AppTheme.dangerRed),
            ),
            const SizedBox(height: 6),
          ],
          if (_statusMsg != null) ...[
            Text(
              _statusMsg!,
              style: const TextStyle(fontSize: 12, color: AppTheme.workBlue),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.phone_android_rounded, size: 17, color: AppTheme.slateMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  u.phone.isNotEmpty
                      ? 'เบอร์โทร: ${u.phone} ${u.phoneVerified ? "(ยืนยันแล้ว)" : ""}'
                      : 'ยังไม่ได้เชื่อมเบอร์โทรศัพท์',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              TextButton(
                onPressed: () =>
                    setState(() => _showPhoneForm = !_showPhoneForm),
                child: Text(u.phoneVerified ? 'เปลี่ยนเบอร์' : 'เชื่อมเบอร์ OTP'),
              ),
            ],
          ),
          if (_showPhoneForm) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'เบอร์โทรศัพท์ใหม่',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: (_busy || _countdown > 0) ? null : _requestLinkOtp,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.brandPrimary,
                  ),
                  child: Text(_countdown > 0 ? '${_countdown}s' : 'ขอ OTP'),
                ),
              ],
            ),
            if (_challenge != null) ...[
              const SizedBox(height: 6),
              if (u.hasRecoveryPin) ...[
                TextField(
                  controller: _linkPinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: 'PIN กู้คืน 6 หลัก (ถ้าเคยตั้ง)',
                    counterText: '',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _otpCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'รหัส OTP (Ref: ${_challenge!.refCode})',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: _busy ? null : _verifyLinkPhone,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.brandDeep,
                    ),
                    child: const Text('ยืนยัน'),
                  ),
                ],
              ),
            ],
          ],
          const Divider(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.mail_outline_rounded, size: 17, color: AppTheme.slateMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  u.hasGoogleLinked || u.emailVerified
                      ? 'Gmail: ${u.email} (ยืนยันแล้ว)'
                      : (u.email.isNotEmpty
                          ? 'อีเมล: ${u.email} (ยังไม่เชื่อม Gmail)'
                          : 'ยังไม่ได้เชื่อมบัญชี Gmail'),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              if (_pollingGoogle)
                TextButton(
                  onPressed: () {
                    _googlePollTimer?.cancel();
                    setState(() => _pollingGoogle = false);
                  },
                  child: const Text('ยกเลิก'),
                )
              else
                Wrap(
                  spacing: 4,
                  children: [
                    if (canUnlinkGoogle)
                      TextButton(
                        onPressed: _busy ? null : _handleUnlinkGoogle,
                        child: const Text(
                          'ยกเลิกเชื่อม',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.dangerRed,
                          ),
                        ),
                      ),
                    OutlinedButton(
                      onPressed: widget.authConfig.googleEnabled
                          ? _startLinkGoogle
                          : null,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: Text(
                        u.hasGoogleLinked ? 'เปลี่ยน Gmail' : 'เชื่อม Gmail',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const Divider(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.pin_outlined, size: 17, color: AppTheme.slateMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  u.hasRecoveryPin
                      ? 'PIN กู้คืน: ตั้งแล้ว (รหัสสำรองเหลือ ${u.recoveryCodesRemaining} ชุด)'
                      : 'PIN กู้คืนบัญชี: ยังไม่ตั้งค่า',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              TextButton(
                onPressed: () =>
                    setState(() => _showPinSetup = !_showPinSetup),
                child: Text(u.hasRecoveryPin ? 'เปลี่ยน PIN' : 'ตั้ง PIN กู้คืน'),
              ),
            ],
          ),
          if (_showPinSetup) ...[
            const SizedBox(height: 6),
            if (u.hasRecoveryPin) ...[
              TextField(
                controller: _currentPinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'PIN ปัจจุบัน (6 หลัก)',
                  counterText: '',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _newPinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: 'PIN กู้คืนใหม่ 6 หลัก',
                      counterText: '',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: _busy ? null : _handleSetupPin,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.brandPrimary,
                  ),
                  child: const Text('บันทึก PIN'),
                ),
              ],
            ),
          ],
          if (_generatedBackupCodes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.surfaceBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Expanded(
                        child: Text(
                          'รหัสสำรองใช้ครั้งเดียว (แสดงครั้งเดียว)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.dangerRed,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text: _generatedBackupCodes.join('\n'),
                            ),
                          );
                          setState(
                            () => _statusMsg = 'คัดลอกรหัสสำรองทั้ง 6 ชุดแล้ว',
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: const Text('คัดลอกทั้งหมด', style: TextStyle(fontSize: 11.5)),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _generatedBackupCodes
                        .map(
                          (c) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppTheme.borderSubtle),
                            ),
                            child: Text(
                              c,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 12),
          InkWell(
            onTap: _toggleLogs,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(Icons.history_rounded, size: 17, color: AppTheme.slateMuted),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'ประวัติกู้คืนและการเชื่อมบัญชีล่าสุด',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(
                    _showLogs
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: AppTheme.slateMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_showLogs) ...[
            const SizedBox(height: 6),
            if (_loadingLogs)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_recoveryLogs.isEmpty)
              const Text(
                'ยังไม่มีประวัติการเชื่อมหรือกู้คืนบัญชี',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              )
            else
              for (final log in _recoveryLogs.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          '${log.actionLabel}${log.detailMasked.isNotEmpty ? ' · ${log.detailMasked}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        log.method,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

class _InlineAdminAuthSettingsCard extends StatefulWidget {
  final AuthSettingsDto? initialSettings;
  final Future<void> Function(AuthSettingsDto updated) onUpdated;

  const _InlineAdminAuthSettingsCard({
    required this.initialSettings,
    required this.onUpdated,
  });

  @override
  State<_InlineAdminAuthSettingsCard> createState() =>
      _InlineAdminAuthSettingsCardState();
}

class _InlineAdminAuthSettingsCardState
    extends State<_InlineAdminAuthSettingsCard> {
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _secretKeyCtrl = TextEditingController();
  final TextEditingController _projectKeyCtrl = TextEditingController();
  final TextEditingController _googleClientCtrl = TextEditingController();
  AuthSettingsDto? _settings;
  bool _loading = false;
  String? _statusMsg;

  @override
  void initState() {
    super.initState();
    _applySettings(widget.initialSettings);
    if (_settings == null) _reload();
  }

  @override
  void didUpdateWidget(covariant _InlineAdminAuthSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSettings != null &&
        widget.initialSettings != oldWidget.initialSettings) {
      _applySettings(widget.initialSettings);
    }
  }

  void _applySettings(AuthSettingsDto? s) {
    if (s == null) return;
    _settings = s;
    if (_projectKeyCtrl.text.isEmpty) _projectKeyCtrl.text = s.smsmktProjectKey;
    if (_googleClientCtrl.text.isEmpty) {
      _googleClientCtrl.text = s.googleClientId;
    }
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _secretKeyCtrl.dispose();
    _projectKeyCtrl.dispose();
    _googleClientCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final s = await ApiService.instance.getAuthSettings();
      if (!mounted) return;
      setState(() {
        _applySettings(s);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _loading = true;
      _statusMsg = null;
    });
    try {
      final s = await ApiService.instance.updateAuthSettings(
        smsmktApiKey: _apiKeyCtrl.text.trim().isNotEmpty
            ? _apiKeyCtrl.text.trim()
            : null,
        smsmktSecretKey: _secretKeyCtrl.text.trim().isNotEmpty
            ? _secretKeyCtrl.text.trim()
            : null,
        smsmktProjectKey: _projectKeyCtrl.text.trim(),
        googleClientId: _googleClientCtrl.text.trim(),
      );
      _apiKeyCtrl.clear();
      _secretKeyCtrl.clear();
      if (!mounted) return;
      setState(() {
        _applySettings(s);
        _loading = false;
        _statusMsg = 'บันทึกตั้งค่า SMSMKT & Google Client ID เรียบร้อยแล้ว';
      });
      await widget.onUpdated(s);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final creditText = s?.creditInfo != null
        ? 'เครดิต SMS คงเหลือ: ${s!.creditInfo!['credit_remain'] ?? s.creditInfo!['credit'] ?? s.creditInfo}'
        : (s?.creditError != null && s!.creditError!.isNotEmpty
            ? 'ตรวจเครดิต: ${s.creditError}'
            : 'ยังไม่มีข้อมูลเครดิต SMSMKT');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderSubtle),
        boxShadow: AppTheme.shadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.sms_outlined, size: 18, color: AppTheme.brandPrimary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'ตั้งค่าการเข้าสู่ระบบ SMSMKT OTP & Google OAuth',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'เช็คเครดิต SMSMKT ล่าสุด',
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              PillBadge(
                text: (s?.phoneOtpReady ?? false)
                    ? 'SMS OTP พร้อมส่ง'
                    : 'ยังไม่ได้ใส่คีย์ SMSMKT',
                backgroundColor: (s?.phoneOtpReady ?? false)
                    ? const Color(0xFFE0F2FE)
                    : const Color(0xFFFEF3C7),
                textColor: (s?.phoneOtpReady ?? false)
                    ? AppTheme.workBlue
                    : AppTheme.warningAmber,
              ),
              PillBadge(
                text: creditText,
                backgroundColor: AppTheme.brandSoft,
                textColor: AppTheme.brandDeep,
              ),
            ],
          ),
          if (_statusMsg != null) ...[
            const SizedBox(height: 6),
            Text(
              _statusMsg!,
              style: const TextStyle(fontSize: 12, color: AppTheme.workBlue),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _apiKeyCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText:
                  'SMSMKT API Key (${s?.smsmktHasKeys == true ? s!.smsmktMaskedApiKey : "ยังไม่ตั้งค่า"})',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secretKeyCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText:
                  'SMSMKT Secret Key (${s?.smsmktHasKeys == true ? s!.smsmktMaskedSecretKey : "ยังไม่ตั้งค่า"})',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _projectKeyCtrl,
            decoration: const InputDecoration(
              labelText: 'SMSMKT Project Key (OTP)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _googleClientCtrl,
            decoration: const InputDecoration(
              labelText: 'Google OAuth Client ID (สำหรับการยืนยัน Gmail)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _loading ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandPrimary,
              ),
              icon: const Icon(Icons.save_rounded, size: 17),
              label: const Text('บันทึกตั้งค่า Auth'),
            ),
          ),
        ],
      ),
    );
  }
}
