import 'package:flutter/material.dart';

import '../client_app.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'oa_customers_section.dart';

/// Full inline Shop Workspace (Zero-Popup, Mobile-First, Baseline-First).
/// Supports: Multi-Shop Self-Service (any user can create unlimited shops),
/// Discover/Follow shops + Claim Coupons + Multi-Role Team Management
/// (owner/admin/agent/marketer), Overview, 1-1 Inbox + Customer Tags/Notes,
/// Bottom Quick Menu <=6, Auto-Reply rules, Coupons create/redeem, and News Broadcasts.
///
/// [shopApp] = true (แอป BCAiChatOA): เฉพาะจัดการ/สร้างร้าน; false (แอป BC Ai Chat):
/// เฉพาะค้นหา/ติดตามร้านและรับคูปอง — ไม่มีส่วนจัดการร้านในแอปแชท
class OaWorkspacePanel extends StatefulWidget {
  final AppUser currentUser;
  final ValueChanged<String>? onOpenConversationId;
  final VoidCallback? onClose;
  final bool shopApp;

  const OaWorkspacePanel({
    super.key,
    required this.currentUser,
    this.onOpenConversationId,
    this.onClose,
    this.shopApp = kIsShopApp,
  });

  @override
  State<OaWorkspacePanel> createState() => _OaWorkspacePanelState();
}

class _OaWorkspacePanelState extends State<OaWorkspacePanel> {
  // แอปแชท: discover เท่านั้น · แอปร้านค้า: manage | create
  late String _topMode = widget.shopApp ? 'manage' : 'discover';
  String _manageTab =
      'chats'; // chats | customers | overview | settings | rich_menu | auto_reply | coupons | broadcasts

  bool _loading = false;
  bool _showCreateAdvanced = false;
  bool _showChatCrm = false;
  String? _statusMsg;
  String? _errorMsg;

  // Discover state
  final TextEditingController _discoverSearchCtrl = TextEditingController();
  List<OaAccountDto> _discoverOas = const [];
  String? _expandedCouponOaId;
  List<OaCoupon> _discoverOaCoupons = const [];

  // Manage state (Multi-Shop + Multi-Role)
  List<OaAccountDto> _myOas = const [];
  OaAccountDto? _selectedOa;
  OaOverview? _overview;
  List<OaStaffMemberDto> _staffMembers = const [];
  List<OaCustomerChatDto> _oaChats = const [];
  OaCustomerChatDto? _selectedChat;
  List<ChatMessage> _chatMessages = const [];
  List<OaAutoReplyRule> _autoReplies = const [];
  List<OaCoupon> _oaCoupons = const [];
  List<OaBroadcast> _broadcasts = const [];

  // Create OA controllers
  final TextEditingController _cHandleCtrl = TextEditingController();
  final TextEditingController _cNameCtrl = TextEditingController();
  final TextEditingController _cCategoryCtrl = TextEditingController(
    text: 'ร้านค้า / บริการ',
  );
  final TextEditingController _cBioCtrl = TextEditingController();
  final TextEditingController _cGreetingCtrl = TextEditingController();
  final TextEditingController _cHoursCtrl = TextEditingController();
  final TextEditingController _cAiPromptCtrl = TextEditingController();
  String _cThemeColor = '#812920';
  bool _cAiEnabled = true;
  bool _cCallsEnabled = true;

  // Edit OA + Team controllers
  final TextEditingController _eNameCtrl = TextEditingController();
  final TextEditingController _eCategoryCtrl = TextEditingController();
  final TextEditingController _eBioCtrl = TextEditingController();
  final TextEditingController _eGreetingCtrl = TextEditingController();
  final TextEditingController _eHoursCtrl = TextEditingController();
  final TextEditingController _eAiPromptCtrl = TextEditingController();
  final TextEditingController _addAdminInputCtrl = TextEditingController();
  String _addAdminRole = 'agent';
  String _eThemeColor = '#812920';
  bool _eIsActive = true;
  bool _eAiEnabled = false;
  bool _eCallsEnabled = true;

  // Rich Menu draft (<= 6 items)
  List<OaRichMenuItem> _richMenuDraft = [];
  final TextEditingController _rmLabelCtrl = TextEditingController();
  final TextEditingController _rmSubCtrl = TextEditingController();
  final TextEditingController _rmValueCtrl = TextEditingController();
  String _rmActionType = 'keyword';

  // Inbox + CRM controllers
  final TextEditingController _chatFilterCtrl = TextEditingController();
  final TextEditingController _chatReplyCtrl = TextEditingController();
  final TextEditingController _crmTagsCtrl = TextEditingController();
  final TextEditingController _crmNoteCtrl = TextEditingController();
  bool _crmAiPaused = false;

  // Auto-reply controllers
  final TextEditingController _arKeywordCtrl = TextEditingController();
  final TextEditingController _arReplyCtrl = TextEditingController();
  String _arMatchMode = 'contains';

  // Coupon controllers
  final TextEditingController _cpCodeCtrl = TextEditingController();
  final TextEditingController _cpTitleCtrl = TextEditingController();
  final TextEditingController _cpDiscountCtrl = TextEditingController();
  final TextEditingController _cpDescCtrl = TextEditingController();
  final TextEditingController _cpMaxCtrl = TextEditingController(text: '100');

  // Broadcast controllers
  List<String> _bcTags = const [];
  final TextEditingController _bcContentCtrl = TextEditingController();
  String? _bcCouponId;

  static const List<String> _themeSwatches = [
    '#812920',
    '#B45309',
    '#1D4ED8',
    '#0F766E',
    '#BE185D',
    '#6D28D9',
  ];

  @override
  void initState() {
    super.initState();
    _loadDiscoverAndMine();
  }

  @override
  void dispose() {
    _discoverSearchCtrl.dispose();
    _cHandleCtrl.dispose();
    _cNameCtrl.dispose();
    _cCategoryCtrl.dispose();
    _cBioCtrl.dispose();
    _cGreetingCtrl.dispose();
    _cHoursCtrl.dispose();
    _cAiPromptCtrl.dispose();
    _eNameCtrl.dispose();
    _eCategoryCtrl.dispose();
    _eBioCtrl.dispose();
    _eGreetingCtrl.dispose();
    _eHoursCtrl.dispose();
    _eAiPromptCtrl.dispose();
    _addAdminInputCtrl.dispose();
    _rmLabelCtrl.dispose();
    _rmSubCtrl.dispose();
    _rmValueCtrl.dispose();
    _chatFilterCtrl.dispose();
    _chatReplyCtrl.dispose();
    _crmTagsCtrl.dispose();
    _crmNoteCtrl.dispose();
    _arKeywordCtrl.dispose();
    _arReplyCtrl.dispose();
    _cpCodeCtrl.dispose();
    _cpTitleCtrl.dispose();
    _cpDiscountCtrl.dispose();
    _cpDescCtrl.dispose();
    _cpMaxCtrl.dispose();
    _bcContentCtrl.dispose();
    super.dispose();
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'owner':
        return 'เจ้าของร้าน';
      case 'admin':
        return 'แอดมินร้าน';
      case 'agent':
        return 'คนตอบแชท';
      case 'marketer':
        return 'การตลาด';
      default:
        return role.isEmpty ? 'ทีมงาน' : role;
    }
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'owner':
        return const Color(0xFF7A4A12);
      default:
        return AppTheme.brandDeep;
    }
  }

  Color _roleBg(String role) => role == 'owner'
      ? AppTheme.goldClay.withValues(alpha: 0.18)
      : AppTheme.tintStrong;

  bool _isTabAllowed(OaAccountDto oa, String tab) {
    final uid = widget.currentUser.id;
    switch (tab) {
      case 'overview':
      case 'settings':
        return oa.canManage(uid);
      case 'chats':
      case 'customers':
        return oa.canHandleChats(uid);
      case 'rich_menu':
        return oa.canEditRichMenu(uid);
      case 'auto_reply':
      case 'broadcasts':
        return oa.canDoMarketing(uid);
      case 'coupons':
        return oa.canDoMarketing(uid) || oa.canHandleChats(uid);
      default:
        return true;
    }
  }

  Future<void> _loadDiscoverAndMine() async {
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      // แต่ละแอปโหลดเฉพาะของตัวเอง: แอปแชท = ร้านที่ค้นพบ, แอปร้านค้า = ร้านของฉัน
      final disc = widget.shopApp
          ? const <OaAccountDto>[]
          : await ApiService.instance.discoverOas(
              q: _discoverSearchCtrl.text.trim(),
            );
      final mine = widget.shopApp
          ? await ApiService.instance.fetchMyOas()
          : const <OaAccountDto>[];
      if (!mounted) return;
      setState(() {
        _discoverOas = disc;
        _myOas = mine;
        _loading = false;
        if (widget.shopApp && mine.isEmpty) _topMode = 'create';
      });
      if (_selectedOa != null) {
        final refreshed = mine.where((o) => o.id == _selectedOa!.id).firstOrNull;
        if (refreshed != null) {
          _selectOa(refreshed, reloadData: _topMode == 'manage');
        } else if (mine.isNotEmpty) {
          _selectOa(mine.first, reloadData: _topMode == 'manage');
        }
      } else if (mine.isNotEmpty) {
        _selectOa(mine.first, reloadData: _topMode == 'manage');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _selectOa(OaAccountDto oa, {bool reloadData = true}) {
    _selectedOa = oa;
    _eNameCtrl.text = oa.displayName;
    _eCategoryCtrl.text = oa.category;
    _eBioCtrl.text = oa.bio;
    _eGreetingCtrl.text = oa.greetingMessage;
    _eHoursCtrl.text = oa.businessHours;
    _eAiPromptCtrl.text = oa.aiKnowledgePrompt;
    _eThemeColor = oa.themeColor.isNotEmpty ? oa.themeColor : '#812920';
    _eIsActive = oa.isActive;
    _eAiEnabled = oa.aiEnabled;
    _eCallsEnabled = oa.callsEnabled;
    _richMenuDraft = List<OaRichMenuItem>.from(oa.richMenu);
    if (!_isTabAllowed(oa, _manageTab)) {
      _manageTab =
          oa.canHandleChats(widget.currentUser.id) ? 'chats' : 'overview';
    }
    if (oa.effectiveRole(widget.currentUser.id) != 'owner' &&
        _addAdminRole == 'admin') {
      _addAdminRole = 'agent';
    }
    if (reloadData) {
      Future<void>.microtask(_loadManageTabData);
    }
  }

  Future<void> _loadManageTabData() async {
    final oa = _selectedOa;
    if (oa == null) return;
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      switch (_manageTab) {
        case 'overview':
          final ov = await ApiService.instance.fetchOaOverview(oa.id);
          if (!mounted) return;
          setState(() {
            _overview = ov;
            _loading = false;
          });
          break;
        case 'settings':
          final staff = await ApiService.instance.fetchOaAdmins(oa.id);
          if (!mounted) return;
          setState(() {
            _staffMembers = staff;
            _loading = false;
          });
          break;
        case 'chats':
          final chats = await ApiService.instance.fetchOaChats(
            oa.id,
            q: _chatFilterCtrl.text.trim(),
          );
          final coupons = await ApiService.instance.fetchOaCoupons(oa.id);
          if (!mounted) return;
          setState(() {
            _oaChats = chats;
            _oaCoupons = coupons;
            _loading = false;
          });
          if (_selectedChat != null) {
            final match = chats
                .where((c) => c.conversationId == _selectedChat!.conversationId)
                .firstOrNull;
            if (match != null) {
              await _openOaCustomerChat(match);
            }
          }
          break;
        case 'auto_reply':
          final rules = await ApiService.instance.fetchOaAutoReplies(oa.id);
          if (!mounted) return;
          setState(() {
            _autoReplies = rules;
            _loading = false;
          });
          break;
        case 'coupons':
          final coupons = await ApiService.instance.fetchOaCoupons(oa.id);
          if (!mounted) return;
          setState(() {
            _oaCoupons = coupons;
            _loading = false;
          });
          break;
        case 'broadcasts':
          final results = await Future.wait([
            ApiService.instance.fetchOaBroadcasts(oa.id),
            ApiService.instance.fetchOaCoupons(oa.id),
          ]);
          if (!mounted) return;
          setState(() {
            _broadcasts = results[0] as List<OaBroadcast>;
            _oaCoupons = results[1] as List<OaCoupon>;
            _loading = false;
          });
          break;
        default:
          if (!mounted) return;
          setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _openOaCustomerChat(OaCustomerChatDto chat) async {
    final oa = _selectedOa;
    if (oa == null) return;
    setState(() {
      _selectedChat = chat;
      _crmTagsCtrl.text = chat.tags.join(', ');
      _crmNoteCtrl.text = chat.crmNote;
      _crmAiPaused = chat.aiPaused;
    });
    try {
      final msgs = await ApiService.instance.fetchOaChatMessages(
        oa.id,
        chat.conversationId,
      );
      if (!mounted) return;
      setState(() => _chatMessages = msgs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _openCustomerChatFromCrm(OaCustomerChatDto chat) async {
    setState(() => _manageTab = 'chats');
    await _loadManageTabData();
    await _openOaCustomerChat(chat);
  }

  Future<void> _followOrUnfollow(OaAccountDto oa) async {
    setState(() {
      _loading = true;
      _errorMsg = null;
      _statusMsg = null;
    });
    try {
      if (oa.isFollowing) {
        await ApiService.instance.unfollowOa(oa.id);
        _statusMsg = 'เลิกติดตาม ${oa.displayName} แล้ว';
      } else {
        final res = await ApiService.instance.followOa(oa.id);
        _statusMsg = 'ติดตาม ${oa.displayName} สำเร็จ';
        if (res.conversationId.isNotEmpty) {
          widget.onOpenConversationId?.call(res.conversationId);
        }
      }
      await _loadDiscoverAndMine();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _toggleDiscoverCoupons(OaAccountDto oa) async {
    if (_expandedCouponOaId == oa.id) {
      setState(() {
        _expandedCouponOaId = null;
        _discoverOaCoupons = const [];
      });
      return;
    }
    try {
      final list = await ApiService.instance.fetchOaCoupons(oa.id);
      if (!mounted) return;
      setState(() {
        _expandedCouponOaId = oa.id;
        _discoverOaCoupons = list;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _claimDiscoverCoupon(String oaId, OaCoupon coupon) async {
    try {
      await ApiService.instance.claimOaCoupon(oaId, coupon.id);
      final updated = await ApiService.instance.fetchOaCoupons(oaId);
      if (!mounted) return;
      setState(() {
        _discoverOaCoupons = updated;
        _statusMsg = 'เก็บคูปอง ${coupon.code} สำเร็จ';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _handleCreateOa() async {
    final handle = _cHandleCtrl.text.trim();
    final name = _cNameCtrl.text.trim();
    if (handle.isEmpty || name.isEmpty) {
      setState(() => _errorMsg = 'กรุณากรอก @ไอดีร้าน และชื่อร้านค้า / กิจการ');
      return;
    }
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      final created = await ApiService.instance.createOa(
        handle: handle,
        displayName: name,
        category: _cCategoryCtrl.text.trim(),
        bio: _cBioCtrl.text.trim(),
        themeColor: _cThemeColor,
        greetingMessage: _cGreetingCtrl.text.trim(),
        businessHours: _cHoursCtrl.text.trim(),
        aiEnabled: _cAiEnabled,
        callsEnabled: _cCallsEnabled,
        aiKnowledgePrompt: _cAiPromptCtrl.text.trim(),
      );
      _cHandleCtrl.clear();
      _cNameCtrl.clear();
      _cBioCtrl.clear();
      _cGreetingCtrl.clear();
      _cHoursCtrl.clear();
      _cAiPromptCtrl.clear();
      await _loadDiscoverAndMine();
      if (!mounted) return;
      setState(() {
        _topMode = 'manage';
        _manageTab = 'overview';
        _statusMsg = 'เปิดร้าน "${created.displayName}" สำเร็จ';
      });
      _selectOa(created);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleUpdateOaSettings() async {
    final oa = _selectedOa;
    if (oa == null) return;
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      final updated = await ApiService.instance.updateOa(
        oa.id,
        displayName: _eNameCtrl.text.trim(),
        category: _eCategoryCtrl.text.trim(),
        bio: _eBioCtrl.text.trim(),
        themeColor: _eThemeColor,
        greetingMessage: _eGreetingCtrl.text.trim(),
        businessHours: _eHoursCtrl.text.trim(),
        isActive: _eIsActive,
        aiEnabled: _eAiEnabled,
        callsEnabled: _eCallsEnabled,
        aiKnowledgePrompt: _eAiPromptCtrl.text.trim(),
      );
      if (!mounted) return;
      _selectOa(updated, reloadData: false);
      setState(() {
        _loading = false;
        _statusMsg = 'บันทึกการตั้งค่าร้านค้าแล้ว';
      });
      await _loadDiscoverAndMine();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleAddAdmin() async {
    final oa = _selectedOa;
    final raw = _addAdminInputCtrl.text.trim();
    if (oa == null || raw.isEmpty) return;
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      final updated = await ApiService.instance.addOaAdmin(
        oa.id,
        query: raw,
        role: _addAdminRole,
      );
      _addAdminInputCtrl.clear();
      final staff = await ApiService.instance.fetchOaAdmins(oa.id);
      if (!mounted) return;
      _selectOa(updated, reloadData: false);
      setState(() {
        _staffMembers = staff;
        _loading = false;
        _statusMsg = 'เพิ่มทีมงาน (${_roleLabel(_addAdminRole)}) สำเร็จ';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleUpdateMemberRole(String uid, String newRole) async {
    final oa = _selectedOa;
    if (oa == null) return;
    try {
      final updated = await ApiService.instance.updateOaAdminRole(
        oa.id,
        uid,
        role: newRole,
      );
      final staff = await ApiService.instance.fetchOaAdmins(oa.id);
      if (!mounted) return;
      _selectOa(updated, reloadData: false);
      setState(() {
        _staffMembers = staff;
        _statusMsg = 'เปลี่ยนบทบาททีมงานเป็น ${_roleLabel(newRole)} แล้ว';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _handleRemoveAdmin(String uid) async {
    final oa = _selectedOa;
    if (oa == null) return;
    try {
      final updated = await ApiService.instance.removeOaAdmin(oa.id, uid);
      final staff = await ApiService.instance.fetchOaAdmins(oa.id);
      if (!mounted) return;
      _selectOa(updated, reloadData: false);
      setState(() {
        _staffMembers = staff;
        _statusMsg = 'นำทีมงานออกจากร้านแล้ว';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _saveRichMenu() async {
    final oa = _selectedOa;
    if (oa == null) return;
    setState(() {
      _loading = true;
      _errorMsg = null;
    });
    try {
      final updated = await ApiService.instance.updateOa(
        oa.id,
        richMenu: _richMenuDraft.take(6).toList(),
      );
      if (!mounted) return;
      _selectOa(updated, reloadData: false);
      setState(() {
        _loading = false;
        _statusMsg = 'บันทึกเมนูลัดใต้แชท (${updated.richMenu.length} ปุ่ม) แล้ว';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _addRichMenuItemDraft() {
    if (_richMenuDraft.length >= 6) {
      setState(() => _errorMsg = 'เมนูลัดใต้แชทเพิ่มได้สูงสุด 6 ปุ่ม');
      return;
    }
    final label = _rmLabelCtrl.text.trim();
    final val = _rmValueCtrl.text.trim();
    if (label.isEmpty || val.isEmpty) {
      setState(() => _errorMsg = 'กรุณากรอกชื่อปุ่มและค่าการทำงาน');
      return;
    }
    setState(() {
      _errorMsg = null;
      _richMenuDraft = [
        ..._richMenuDraft,
        OaRichMenuItem(
          id: 'rm_${DateTime.now().millisecondsSinceEpoch}',
          label: label,
          subtitle: _rmSubCtrl.text.trim(),
          actionType: _rmActionType,
          actionValue: val,
          icon: _rmActionType == 'coupon'
              ? 'ticket'
              : (_rmActionType == 'url' ? 'link' : 'sparkles'),
        ),
      ];
      _rmLabelCtrl.clear();
      _rmSubCtrl.clear();
      _rmValueCtrl.clear();
    });
  }

  Future<void> _sendOaReply({String? couponId}) async {
    final oa = _selectedOa;
    final chat = _selectedChat;
    if (oa == null || chat == null) return;
    final content = _chatReplyCtrl.text.trim();
    if (content.isEmpty && couponId == null) return;
    try {
      await ApiService.instance.sendOaChatMessage(
        oa.id,
        chat.conversationId,
        msgType: couponId != null ? 'rich_card' : 'text',
        content: content.isNotEmpty ? content : 'ส่งคูปองพิเศษให้คุณ',
        couponId: couponId,
      );
      _chatReplyCtrl.clear();
      await _openOaCustomerChat(chat);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _saveCustomerCrm() async {
    final oa = _selectedOa;
    final chat = _selectedChat;
    if (oa == null || chat == null) return;
    final tags = _crmTagsCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      await ApiService.instance.updateOaFollowerCrm(
        oa.id,
        chat.customerId,
        tags: tags,
        crmNote: _crmNoteCtrl.text.trim(),
        aiPaused: _crmAiPaused,
      );
      if (!mounted) return;
      setState(() => _statusMsg = 'บันทึกแท็ก & โน้ตของ ${chat.customerName} แล้ว');
      await _loadManageTabData();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _createAutoReply() async {
    final oa = _selectedOa;
    final kw = _arKeywordCtrl.text.trim();
    final reply = _arReplyCtrl.text.trim();
    if (oa == null || kw.isEmpty || reply.isEmpty) {
      setState(() => _errorMsg = 'กรุณากรอกคำค้นหาและข้อความตอบกลับ');
      return;
    }
    try {
      await ApiService.instance.createOaAutoReply(
        oa.id,
        keyword: kw,
        matchMode: _arMatchMode,
        replyText: reply,
      );
      _arKeywordCtrl.clear();
      _arReplyCtrl.clear();
      if (!mounted) return;
      setState(() => _statusMsg = 'เพิ่มกฎตอบกลับ "$kw" แล้ว');
      await _loadManageTabData();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _createCoupon() async {
    final oa = _selectedOa;
    final code = _cpCodeCtrl.text.trim();
    final title = _cpTitleCtrl.text.trim();
    if (oa == null || code.isEmpty || title.isEmpty) {
      setState(() => _errorMsg = 'กรุณากรอกโค้ดและชื่อคูปอง');
      return;
    }
    try {
      await ApiService.instance.createOaCoupon(
        oa.id,
        code: code,
        title: title,
        discountText: _cpDiscountCtrl.text.trim(),
        description: _cpDescCtrl.text.trim(),
        maxClaims: int.tryParse(_cpMaxCtrl.text.trim()),
      );
      _cpCodeCtrl.clear();
      _cpTitleCtrl.clear();
      _cpDiscountCtrl.clear();
      _cpDescCtrl.clear();
      if (!mounted) return;
      setState(() => _statusMsg = 'สร้างคูปอง $code สำเร็จ');
      await _loadManageTabData();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _sendBroadcast() async {
    final oa = _selectedOa;
    final content = _bcContentCtrl.text.trim();
    if (oa == null || (content.isEmpty && _bcCouponId == null)) {
      setState(() => _errorMsg = 'กรุณากรอกข้อความหรือเลือกคูปอง');
      return;
    }
    try {
      final res = await ApiService.instance.sendOaBroadcast(
        oa.id,
        targetTags: _bcTags,
        msgType: _bcCouponId != null ? 'rich_card' : 'text',
        content: content.isNotEmpty
            ? content
            : 'โปรโมชั่นพิเศษจาก ${oa.displayName}',
        couponId: _bcCouponId,
      );
      _bcContentCtrl.clear();
      _bcCouponId = null;
      if (!mounted) return;
      setState(
        () => _statusMsg = 'ส่งข่าวถึงผู้ติดตาม ${res.recipientCount} คนแล้ว',
      );
      await _loadManageTabData();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(10),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppTheme.hairline),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopHeader(),
          const SizedBox(height: 8),
          if (_errorMsg != null) ...[
            _buildBanner(_errorMsg!, isError: true),
            const SizedBox(height: 6),
          ],
          if (_statusMsg != null) ...[
            _buildBanner(_statusMsg!, isError: false),
            const SizedBox(height: 6),
          ],
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: AppTheme.brandPrimary,
              ),
            ),
          if (_topMode == 'discover')
            _buildDiscoverSection()
          else if (_topMode == 'create')
            _buildCreateSection()
          else
            _buildManageSection(),
        ],
      ),
    );
  }

  Widget _buildTopHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.storefront_rounded, size: 18, color: AppTheme.brandPrimary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.shopApp ? 'จัดการร้านค้า' : 'ค้นหาและติดตามร้านค้า',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.slateDark,
                ),
              ),
            ),
            IconButton(
              tooltip: 'รีเฟรชร้านค้า',
              onPressed: _loadDiscoverAndMine,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
            if (widget.onClose != null)
              IconButton(
                tooltip: 'ซ่อนแผงร้านค้า',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, size: 18),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              ),
          ],
        ),
        if (widget.shopApp) ...[
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 0,
            children: [
              _modeChip('manage', 'ร้านของฉัน (${_myOas.length})'),
              _modeChip('create', '+ สร้างกิจการ / ร้านค้าใหม่'),
            ],
          ),
        ],
      ],
    );
  }

  Widget _modeChip(String mode, String label) {
    final selected = _topMode == mode;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: (_) {
        setState(() {
          _topMode = mode;
          _errorMsg = null;
        });
        if (mode == 'manage' && _selectedOa != null) {
          Future<void>.microtask(_loadManageTabData);
        }
      },
    );
  }

  Widget _buildBanner(String text, {required bool isError}) {
    final c = isError ? AppTheme.dangerRed : const Color(0xFF027A48);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: isError ? const Color(0xFFFEF3F2) : const Color(0xFFECFDF3),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(
          color: isError ? const Color(0xFFFECDCA) : const Color(0xFFABEFC6),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 15,
            color: c,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: c)),
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoverSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _discoverSearchCtrl,
                onSubmitted: (_) => _loadDiscoverAndMine(),
                decoration: const InputDecoration(
                  hintText: 'ค้นหาชื่อร้าน, @ไอดีร้าน, หมวดหมู่...',
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: _loadDiscoverAndMine,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 36),
              ),
              child: const Text('ค้นหา', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_discoverOas.isEmpty)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              'ยังไม่พบร้านค้า ลองค้นหาด้วยชื่อร้านหรือ @ไอดีร้าน',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
            ),
          )
        else
          for (final oa in _discoverOas) ...[
            _buildDiscoverOaCard(oa),
            const SizedBox(height: 6),
          ],
      ],
    );
  }

  Widget _buildDiscoverOaCard(OaAccountDto oa) {
    final tint = AppTheme.parseHexColor(
      oa.themeColor,
      fallback: AppTheme.brandPrimary,
    );
    final showingCoupons = _expandedCouponOaId == oa.id;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              UserAvatar(
                name: oa.displayName,
                avatarUrl: oa.avatarUrl,
                radius: 20,
                isOfficial: oa.isVerified,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            oa.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.slateDark,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        PillBadge(
                          text: oa.category,
                          backgroundColor: tint.withValues(alpha: 0.12),
                          textColor: tint,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${oa.handle} · ผู้ติดตาม ${oa.followerCount} คน${oa.callsEnabled ? " · โทรได้" : ""}',
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
          if (oa.bio.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              oa.bio,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppTheme.slateBody),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () => _toggleDiscoverCoupons(oa),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                ),
                icon: const Icon(Icons.local_offer_outlined, size: 14),
                label: Text(
                  showingCoupons ? 'ซ่อนคูปอง' : 'คูปอง',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              const Spacer(),
              if (oa.isFollowing && oa.conversationId != null) ...[
                OutlinedButton(
                  onPressed: () =>
                      widget.onOpenConversationId?.call(oa.conversationId!),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 30),
                  ),
                  child: const Text('เปิดแชท', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 6),
              ],
              FilledButton(
                onPressed: () => _followOrUnfollow(oa),
                style: FilledButton.styleFrom(
                  backgroundColor: oa.isFollowing
                      ? AppTheme.slateMuted
                      : AppTheme.brandPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 30),
                ),
                child: Text(
                  oa.isFollowing ? 'เลิกติดตาม' : 'ติดตาม & แชท',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          if (showingCoupons) ...[
            const Divider(height: 12),
            if (_discoverOaCoupons.isEmpty)
              const Text(
                'ยังไม่มีคูปองจากร้านนี้',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              )
            else
              for (final cp in _discoverOaCoupons)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      PillBadge(
                        text: cp.code,
                        backgroundColor: AppTheme.tintStrong,
                        textColor: AppTheme.brandDeep,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${cp.title}${cp.discountText.isNotEmpty ? " (${cp.discountText})" : ""}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: cp.isClaimed
                            ? null
                            : () => _claimDiscoverCoupon(oa.id, cp),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 28),
                        ),
                        child: Text(
                          cp.isClaimed ? 'เก็บแล้ว' : 'เก็บคูปอง',
                          style: const TextStyle(fontSize: 11),
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

  Widget _buildCreateSection() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'สร้างกิจการ / ร้านค้าใหม่',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.slateDark,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _cNameCtrl,
            decoration: const InputDecoration(
              labelText: 'ชื่อร้าน / กิจการ',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _cHandleCtrl,
            decoration: const InputDecoration(
              labelText: 'ไอดีร้าน (ภาษาอังกฤษ/ตัวเลข/_ เช่น ban_chiang_cafe)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _cCategoryCtrl,
            decoration: const InputDecoration(
              labelText: 'หมวดหมู่ (เช่น คาเฟ่, ร้านค้า, บริการ)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _showCreateAdvanced = !_showCreateAdvanced),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              ),
              icon: Icon(
                _showCreateAdvanced
                    ? Icons.tune_rounded
                    : Icons.settings_suggest_outlined,
                size: 16,
              ),
              label: Text(
                _showCreateAdvanced
                    ? 'ตั้งค่าเพิ่มเติม ▴'
                    : 'ตั้งค่าเพิ่มเติม ▾',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          if (_showCreateAdvanced) ...[
            const SizedBox(height: 6),
            TextField(
              controller: _cBioCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'คำแนะนำตัว / รายละเอียดร้าน',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _cGreetingCtrl,
              decoration: const InputDecoration(
                labelText: 'ข้อความทักทายเมื่อลูกค้ากดติดตาม',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _cHoursCtrl,
              decoration: const InputDecoration(
                labelText: 'เวลาทำการ (เช่น จันทร์-อาทิตย์ 09:00-20:00)',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('สีประจำร้าน:', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                for (final hex in _themeSwatches)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      onTap: () => setState(() => _cThemeColor = hex),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: AppTheme.parseHexColor(hex),
                          shape: BoxShape.circle,
                          border: _cThemeColor == hex
                              ? Border.all(color: AppTheme.slateDark, width: 2)
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'เปิด AI ตอบแชทช่วยทีมงาน',
                style: TextStyle(fontSize: 12.5),
              ),
              value: _cAiEnabled,
              onChanged: (v) => setState(() => _cAiEnabled = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'เปิดรับสายโทรเสียง / วิดีโอจากลูกค้า',
                style: TextStyle(fontSize: 12.5),
              ),
              value: _cCallsEnabled,
              onChanged: (v) => setState(() => _cCallsEnabled = v),
            ),
            TextField(
              controller: _cAiPromptCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'คลังความรู้ / บุคลิก AI ประจำร้าน (ถ้าเปิด AI)',
                isDense: true,
              ),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: FilledButton.icon(
              onPressed: _loading ? null : _handleCreateOa,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandPrimary,
              ),
              icon: const Icon(Icons.add_business_rounded, size: 18),
              label: const Text('สร้างร้านค้า'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildManageSection() {
    if (_myOas.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const Text(
              'คุณยังไม่ได้สร้างหรือเข้าร่วมทีมร้านค้าใดๆ',
              style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => setState(() => _topMode = 'create'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandPrimary,
              ),
              child: const Text('+ สร้างกิจการ / ร้านค้าแรกของคุณ'),
            ),
          ],
        ),
      );
    }

    final oa = _selectedOa ?? _myOas.first;
    final myId = widget.currentUser.id;
    final myRole = oa.effectiveRole(myId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Multi-Shop Switcher with Role Badges + Create Another Shop button
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 0,
          children: [
            for (final item in _myOas) ...[
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        item.displayName,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(width: 4),
                      PillBadge(
                        text: _roleLabel(item.effectiveRole(myId)),
                        backgroundColor: _roleBg(item.effectiveRole(myId)),
                        textColor: _roleColor(item.effectiveRole(myId)),
                      ),
                    ],
                  ),
                  selected: item.id == oa.id,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _selectOa(item)),
                ),
              ),
            ],
            ActionChip(
              avatar: const Icon(Icons.add_business_outlined, size: 15),
              label: const Text(
                'สร้างร้านใหม่',
                style: TextStyle(fontSize: 11.5),
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _topMode = 'create'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 0,
          children: [
            if (oa.canHandleChats(myId))
              _manageTabChip('chats', 'แชทลูกค้า'),
            if (oa.canHandleChats(myId)) _manageTabChip('customers', 'ลูกค้า'),
            _manageTabChip('overview', 'ภาพรวม'),
            _manageTabChip('settings', 'ตั้งค่า & ทีม'),
            if (oa.canEditRichMenu(myId))
              _manageTabChip(
                'rich_menu',
                'เมนูลัด (${_richMenuDraft.length}/6)',
              ),
            if (oa.canDoMarketing(myId))
              _manageTabChip('auto_reply', 'ตอบอัตโนมัติ'),
            if (oa.canDoMarketing(myId) || oa.canHandleChats(myId))
              _manageTabChip('coupons', 'คูปอง'),
            if (oa.canDoMarketing(myId))
              _manageTabChip('broadcasts', 'ส่งข่าว'),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '@${oa.handle}',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
            ),
            const SizedBox(width: 6),
            PillBadge(
              text: 'บทบาทของคุณ: ${_roleLabel(myRole)}',
              backgroundColor: _roleBg(myRole),
              textColor: _roleColor(myRole),
            ),
          ],
        ),
        const SizedBox(height: 8),
        switch (_manageTab) {
          'overview' => _buildOverviewTab(),
          'chats' => _buildOaInboxTab(),
          'customers' => OaCustomersSection(
            key: ValueKey('customers-${oa.id}'),
            oa: oa,
            onOpenChat: _openCustomerChatFromCrm,
          ),
          'settings' => _buildSettingsTab(oa),
          'rich_menu' => _buildRichMenuTab(),
          'auto_reply' => _buildAutoReplyTab(),
          'coupons' => _buildCouponsTab(oa),
          'broadcasts' => _buildBroadcastsTab(),
          _ => _buildOverviewTab(),
        },
      ],
    );
  }

  Widget _manageTabChip(String tab, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
        selected: _manageTab == tab,
        visualDensity: VisualDensity.compact,
        onSelected: (_) {
          setState(() => _manageTab = tab);
          Future<void>.microtask(_loadManageTabData);
        },
      ),
    );
  }

  Widget _buildOverviewTab() {
    final s = _overview?.stats;
    if (s == null) {
      return const Text(
        'กำลังโหลดสถิติภาพรวม...',
        style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              // แบ่งช่องสถิติให้เต็มความกว้างการ์ด (3 ช่องต่อแถว จอแคบเหลือ 2)
              final cols = box.maxWidth >= 330 ? 3 : 2;
              final w = ((box.maxWidth - 8 * (cols - 1)) / cols)
                  .floorToDouble();
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _statBox('ผู้ติดตาม', '${s.followerCount}', w),
                  _statBox('ห้องแชทค้าง', '${s.activeChatsCount}', w),
                  _statBox('กฎตอบอัตโนมัติ', '${s.autoReplyCount}', w),
                  _statBox('คูปองใช้งาน', '${s.activeCouponCount}', w),
                  _statBox('ยอดเก็บคูปอง', '${s.totalCouponClaims}', w),
                  _statBox('ส่งข่าวถึงลูกค้า', '${s.broadcastCount}', w),
                ],
              );
            },
          ),
          if (s.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'แท็ก & โน้ตลูกค้า',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final t in s.tags)
                  PillBadge(
                    text: '${t.tag} (${t.count})',
                    backgroundColor: AppTheme.tintStrong,
                    textColor: AppTheme.brandDeep,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statBox(String label, String val, double width) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: AppTheme.well(radius: AppTheme.radiusSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            val,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppTheme.slateDark,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppTheme.slateMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildOaInboxTab() {
    final chat = _selectedChat;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _chatFilterCtrl,
                  onSubmitted: (_) => _loadManageTabData(),
                  decoration: const InputDecoration(
                    hintText: 'ค้นหาชื่อลูกค้าหรือแท็ก...',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: _loadManageTabData,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 34),
                ),
                child: const Text('กรอง', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_oaChats.isEmpty)
            const Text(
              'ยังไม่มีแชทจากลูกค้า',
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            )
          else
            for (final c in _oaChats)
              InkWell(
                onTap: () => _openOaCustomerChat(c),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _selectedChat?.conversationId == c.conversationId
                        ? AppTheme.tint
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      UserAvatar(
                        name: c.customerName,
                        avatarUrl: c.customerAvatar,
                        radius: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    c.customerName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (c.aiPaused) ...[
                                  const SizedBox(width: 4),
                                  const PillBadge(
                                    text: 'พัก AI',
                                    backgroundColor: Color(0xFFFEF3C7),
                                    textColor: AppTheme.warningAmber,
                                  ),
                                ],
                                for (final t in c.tags.take(2)) ...[
                                  const SizedBox(width: 4),
                                  PillBadge(
                                    text: t,
                                    backgroundColor: AppTheme.tintStrong,
                                    textColor: AppTheme.brandDeep,
                                  ),
                                ],
                              ],
                            ),
                            if (c.lastMessage != null)
                              Text(
                                c.lastMessage!.previewText,
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
                      if (c.unreadForOa > 0)
                        PillBadge(
                          text: '${c.unreadForOa}',
                          backgroundColor: AppTheme.brandPrimary,
                          textColor: Colors.white,
                        ),
                    ],
                  ),
                ),
              ),
          if (chat != null) ...[
            const Divider(height: 14),
            Text(
              'สนทนากับ ${chat.customerName} (${chat.customerPhone.isNotEmpty ? chat.customerPhone : chat.customerBcId})',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.panelBg,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final m in _chatMessages)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${m.senderName}: ${m.previewText}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatReplyCtrl,
                    onSubmitted: (_) => _sendOaReply(),
                    decoration: const InputDecoration(
                      hintText: 'ตอบกลับในนามร้านค้า...',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: () => _sendOaReply(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 34),
                  ),
                  child: const Text('ส่ง', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (_oaCoupons.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final cp in _oaCoupons.take(4))
                    ActionChip(
                      label: Text(
                        'แจกคูปอง ${cp.code}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _sendOaReply(couponId: cp.id),
                    ),
                ],
              ),
            ],
            const Divider(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _showChatCrm = !_showChatCrm),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                ),
                icon: const Icon(Icons.label_outline_rounded, size: 16),
                label: Text(
                  _showChatCrm
                      ? 'แท็ก & โน้ตลูกค้า ▴'
                      : 'แท็ก & โน้ตลูกค้า ▾',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            if (_showChatCrm) ...[
              const SizedBox(height: 6),
              TextField(
                controller: _crmTagsCtrl,
                decoration: const InputDecoration(
                  labelText: 'แท็ก (คั่นด้วยลูกน้ำ เช่น VIP, นัดรับของ)',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _crmNoteCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'โน้ตส่วนตัวของร้าน',
                  isDense: true,
                ),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'หยุด AI ตอบอัตโนมัติชั่วคราว (แอดมินคุยเอง)',
                  style: TextStyle(fontSize: 12),
                ),
                value: _crmAiPaused,
                onChanged: (v) => setState(() => _crmAiPaused = v),
              ),
              FilledButton.tonal(
                onPressed: _saveCustomerCrm,
                child: const Text('บันทึกแท็ก & โน้ตลูกค้า'),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsTab(OaAccountDto oa) {
    final myId = widget.currentUser.id;
    final myRole = oa.effectiveRole(myId);
    final canEdit = oa.canEditProfile(myId);
    final canManageTeam = oa.canManageTeam(myId);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!canEdit)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'คุณอยู่ในบทบาท "${_roleLabel(myRole)}" (เฉพาะเจ้าของร้านหรือแอดมินร้านที่แก้ไขข้อมูลร้านและจัดการทีมได้)',
                style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              ),
            )
          else ...[
            TextField(
              controller: _eNameCtrl,
              decoration: const InputDecoration(
                labelText: 'ชื่อร้านค้า / กิจการ',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _eCategoryCtrl,
              decoration: const InputDecoration(labelText: 'หมวดหมู่', isDense: true),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _eBioCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'คำแนะนำร้าน',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _eGreetingCtrl,
              decoration: const InputDecoration(
                labelText: 'ข้อความต้อนรับ',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _eHoursCtrl,
              decoration: const InputDecoration(
                labelText: 'เวลาทำการ',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('สีธีมร้านค้า:', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                for (final hex in _themeSwatches)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      onTap: () => setState(() => _eThemeColor = hex),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: AppTheme.parseHexColor(hex),
                          shape: BoxShape.circle,
                          border: _eThemeColor == hex
                              ? Border.all(color: AppTheme.slateDark, width: 2)
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'เปิดแสดงร้านค้าสาธารณะ',
                style: TextStyle(fontSize: 12.5),
              ),
              value: _eIsActive,
              onChanged: (v) => setState(() => _eIsActive = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'เปิด AI ช่วยตอบแชทร้านค้า',
                style: TextStyle(fontSize: 12.5),
              ),
              value: _eAiEnabled,
              onChanged: (v) => setState(() => _eAiEnabled = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'อนุญาตให้ลูกค้าโทรเสียง/วิดีโอเข้าร้านค้า',
                style: TextStyle(fontSize: 12.5),
              ),
              value: _eCallsEnabled,
              onChanged: (v) => setState(() => _eCallsEnabled = v),
            ),
            TextField(
              controller: _eAiPromptCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'ข้อมูลร้าน / Prompt สำหรับ AI',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _loading ? null : _handleUpdateOaSettings,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandPrimary,
              ),
              child: const Text('บันทึกการตั้งค่าร้านค้า'),
            ),
            const Divider(height: 16),
          ],

          // Team / Staff Management (GET/POST/PUT/DELETE /api/oa/:id/admins)
          const Text(
            'ทีมงาน & คนตอบแชท',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          if (_staffMembers.isEmpty)
            const Text(
              'กำลังโหลดรายชื่อทีมงาน...',
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            )
          else
            for (final m in _staffMembers) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  border: Border(
                    bottom: BorderSide(color: AppTheme.hairline),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    UserAvatar(
                      name: m.displayName.isNotEmpty ? m.displayName : m.userId,
                      avatarUrl: m.avatarUrl,
                      radius: 15,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.displayName.isNotEmpty ? m.displayName : m.userId,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            [
                              if (m.bcId.isNotEmpty) '@${m.bcId}',
                              if (m.phone.isNotEmpty) m.phone,
                              if (m.email.isNotEmpty) m.email,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (m.role == 'owner' ||
                        !canManageTeam ||
                        (myRole == 'admin' && m.role == 'admin'))
                      PillBadge(
                        text: _roleLabel(m.role),
                        backgroundColor: _roleBg(m.role),
                        textColor: _roleColor(m.role),
                      )
                    else ...[
                      DropdownButton<String>(
                        value: m.role,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.slateDark,
                        ),
                        items: [
                          if (myRole == 'owner')
                            const DropdownMenuItem(
                              value: 'admin',
                              child: Text('แอดมินร้าน'),
                            ),
                          const DropdownMenuItem(
                            value: 'agent',
                            child: Text('คนตอบแชท'),
                          ),
                          const DropdownMenuItem(
                            value: 'marketer',
                            child: Text('การตลาด'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null && v != m.role) {
                            _handleUpdateMemberRole(m.userId, v);
                          }
                        },
                      ),
                    ],
                    if (m.role != 'owner' &&
                        ((myRole == 'owner') ||
                            (myRole == 'admin' && m.role != 'admin') ||
                            m.userId == myId))
                      IconButton(
                        tooltip: m.userId == myId ? 'ออกจากทีม' : 'ลบออกจากทีม',
                        onPressed: () => _handleRemoveAdmin(m.userId),
                        icon: const Icon(Icons.person_remove_outlined, size: 17),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            ],
          if (canManageTeam) ...[
            const SizedBox(height: 6),
            TextField(
              controller: _addAdminInputCtrl,
              decoration: const InputDecoration(
                labelText: 'เพิ่มทีมงานด้วย เบอร์โทร / @bc_id / Gmail',
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _addAdminRole,
                    isDense: true,
                    decoration: const InputDecoration(labelText: 'บทบาท'),
                    items: [
                      const DropdownMenuItem(
                        value: 'agent',
                        child: Text('คนตอบแชท & รับสาย'),
                      ),
                      const DropdownMenuItem(
                        value: 'marketer',
                        child: Text('ฝ่ายการตลาด & ส่งข่าว'),
                      ),
                      if (myRole == 'owner')
                        const DropdownMenuItem(
                          value: 'admin',
                          child: Text('แอดมินร้าน'),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => _addAdminRole = v ?? 'agent'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _loading ? null : _handleAddAdmin,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                  label: const Text('เพิ่มทีมงาน'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRichMenuTab() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'เมนูลัดใต้แชทร้านค้า (${_richMenuDraft.length}/6 ปุ่ม)',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < _richMenuDraft.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  PillBadge(
                    text: _richMenuDraft[i].actionType,
                    backgroundColor: AppTheme.tintStrong,
                    textColor: AppTheme.brandDeep,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_richMenuDraft[i].label} -> ${_richMenuDraft[i].actionValue}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _richMenuDraft = List<OaRichMenuItem>.from(
                          _richMenuDraft,
                        )..removeAt(i);
                      });
                    },
                    icon: const Icon(Icons.delete_outline, size: 17),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          TextField(
            controller: _rmLabelCtrl,
            decoration: const InputDecoration(
              labelText: 'ชื่อปุ่ม (เช่น เมนูแนะนำ)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _rmSubCtrl,
            decoration: const InputDecoration(
              labelText: 'คำอธิบายสั้น (ไม่บังคับ)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _rmActionType,
            isDense: true,
            decoration: const InputDecoration(labelText: 'ประเภทการทำงาน'),
            items: const [
              DropdownMenuItem(
                value: 'keyword',
                child: Text('ส่งคำสำคัญเข้าแชท'),
              ),
              DropdownMenuItem(
                value: 'ai_prompt',
                child: Text('ถาม AI ของร้าน'),
              ),
              DropdownMenuItem(
                value: 'coupon',
                child: Text('เก็บ/เปิดคูปอง'),
              ),
              DropdownMenuItem(
                value: 'url',
                child: Text('เปิดลิงก์ภายนอก'),
              ),
            ],
            onChanged: (v) => setState(() => _rmActionType = v ?? 'keyword'),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _rmValueCtrl,
            decoration: const InputDecoration(
              labelText: 'ค่าการทำงาน (เช่น สินค้าขายดี / รหัสคูปอง / ลิงก์เว็บ)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _richMenuDraft.length >= 6
                    ? null
                    : _addRichMenuItemDraft,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('เพิ่มปุ่ม'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _loading ? null : _saveRichMenu,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.brandPrimary,
                  ),
                  child: const Text('บันทึกเมนูลัดใต้แชท'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAutoReplyTab() {
    final oa = _selectedOa;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _arKeywordCtrl,
            decoration: const InputDecoration(
              labelText: 'คำค้นหา (เช่น ราคา, โปรโมชั่น, เวลาเปิด)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _arMatchMode,
            isDense: true,
            decoration: const InputDecoration(labelText: 'เงื่อนไขการจับคู่'),
            items: const [
              DropdownMenuItem(
                value: 'contains',
                child: Text('มีคำนี้อยู่ในข้อความ (contains)'),
              ),
              DropdownMenuItem(
                value: 'exact',
                child: Text('ตรงกันทั้งหมด (exact)'),
              ),
            ],
            onChanged: (v) => setState(() => _arMatchMode = v ?? 'contains'),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _arReplyCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'ข้อความตอบกลับอัตโนมัติ',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          FilledButton(
            onPressed: _createAutoReply,
            child: const Text('เพิ่มกฎตอบอัตโนมัติ'),
          ),
          const Divider(height: 14),
          if (_autoReplies.isEmpty)
            const Text(
              'ยังไม่มีกฎตอบกลับอัตโนมัติ',
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            )
          else
            for (final r in _autoReplies)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    PillBadge(
                      text: r.keyword,
                      backgroundColor: AppTheme.tintStrong,
                      textColor: AppTheme.brandDeep,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${r.replyText} (ถูกใช้ ${r.hitCount} ครั้ง)',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (oa != null)
                      IconButton(
                        onPressed: () async {
                          await ApiService.instance.deleteOaAutoReply(
                            oa.id,
                            r.id,
                          );
                          await _loadManageTabData();
                        },
                        icon: const Icon(Icons.delete_outline, size: 17),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildCouponsTab(OaAccountDto oa) {
    final myId = widget.currentUser.id;
    final canCreateCoupon = oa.canDoMarketing(myId);
    final canRedeemCoupon = oa.canHandleChats(myId);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (canCreateCoupon) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _cpCodeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'โค้ดคูปอง',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _cpDiscountCtrl,
                    decoration: const InputDecoration(
                      labelText: 'ส่วนลด (เช่น ลด 20%)',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _cpTitleCtrl,
              decoration: const InputDecoration(
                labelText: 'ชื่อคูปอง',
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _cpDescCtrl,
                    decoration: const InputDecoration(
                      labelText: 'เงื่อนไขคูปอง',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _cpMaxCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'จำนวนสิทธิ์',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _createCoupon,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brandPrimary,
              ),
              child: const Text('สร้างคูปองใหม่'),
            ),
            const Divider(height: 14),
          ],
          if (_oaCoupons.isEmpty)
            const Text(
              'ยังไม่มีคูปอง',
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            )
          else
            for (final cp in _oaCoupons)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  border: Border(
                    bottom: BorderSide(color: AppTheme.hairline),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    PillBadge(
                      text: cp.code,
                      backgroundColor: AppTheme.tintStrong,
                      textColor: AppTheme.brandDeep,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${cp.title} ${cp.discountText}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'เก็บแล้ว ${cp.claimsCount} · ใช้แล้ว ${cp.redeemedCount}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!cp.isClaimed)
                      TextButton(
                        onPressed: () async {
                          await ApiService.instance.claimOaCoupon(oa.id, cp.id);
                          await _loadManageTabData();
                        },
                        child: const Text('เก็บ', style: TextStyle(fontSize: 11.5)),
                      ),
                    if (canRedeemCoupon)
                      FilledButton.tonal(
                        onPressed: cp.isRedeemed
                            ? null
                            : () async {
                                await ApiService.instance.redeemOaCoupon(
                                  oa.id,
                                  cp.id,
                                );
                                await _loadManageTabData();
                              },
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: Text(
                          cp.isRedeemed ? 'ใช้แล้ว' : 'ใช้สิทธิ์',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildBroadcastsTab() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'ส่งถึงแท็กเฉพาะกลุ่ม (ไม่เลือก = ทุกคนที่ติดตาม)',
            style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
          ),
          const SizedBox(height: 4),
          if (_selectedOa != null)
            OaTagFilterChips(
              key: ValueKey('bc-tags-${_selectedOa!.id}'),
              oaId: _selectedOa!.id,
              selected: _bcTags,
              showMatch: true,
              onChanged: (tags) => setState(() => _bcTags = tags),
            ),
          const SizedBox(height: 6),
          TextField(
            controller: _bcContentCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'ข้อความข่าวสารถึงผู้ติดตาม',
              isDense: true,
            ),
          ),
          if (_oaCoupons.isNotEmpty) ...[
            const SizedBox(height: 6),
            DropdownButtonFormField<String?>(
              initialValue: _bcCouponId,
              isDense: true,
              decoration: const InputDecoration(labelText: 'แนบคูปอง (ไม่บังคับ)'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('ไม่แนบคูปอง'),
                ),
                for (final cp in _oaCoupons)
                  DropdownMenuItem<String?>(
                    value: cp.id,
                    child: Text('${cp.code} · ${cp.title}'),
                  ),
              ],
              onChanged: (v) => setState(() => _bcCouponId = v),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _sendBroadcast,
            icon: const Icon(Icons.campaign_outlined, size: 18),
            label: const Text('ส่งข่าวถึงลูกค้า'),
          ),
          const Divider(height: 14),
          if (_broadcasts.isEmpty)
            const Text(
              'ยังไม่มีประวัติส่งข่าวถึงลูกค้า',
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            )
          else
            for (final b in _broadcasts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    PillBadge(
                      text: '${b.recipientCount} คน',
                      backgroundColor: AppTheme.tintStrong,
                      textColor: AppTheme.brandDeep,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${b.audienceTags.isNotEmpty ? "[${b.audienceTags.join(", ")}] " : ""}${b.content}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
