import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class MiniAppRunnerScreen extends StatefulWidget {
  final MiniAppItem miniApp;
  final List<Conversation> conversations;
  final String? initialConversationId;
  final ValueChanged<ChatMessage>? onCardSent;

  const MiniAppRunnerScreen({
    super.key,
    required this.miniApp,
    required this.conversations,
    this.initialConversationId,
    this.onCardSent,
  });

  @override
  State<MiniAppRunnerScreen> createState() => _MiniAppRunnerScreenState();
}

class _MiniAppRunnerScreenState extends State<MiniAppRunnerScreen> {
  late TextEditingController _field1Ctrl;
  late TextEditingController _field2Ctrl;
  late TextEditingController _field3Ctrl;
  late TextEditingController _noteCtrl;

  late String _label1;
  late String _label2;
  late String _label3;
  late String _statusBadge;

  String? _selectedConversationId;
  bool _isSending = false;
  bool _roomPickerExpanded = false;

  @override
  void initState() {
    super.initState();
    _selectedConversationId =
        widget.initialConversationId ??
        (widget.conversations.isNotEmpty
            ? widget.conversations.first.id
            : null);
    _initTemplateFields();
  }

  void _initTemplateFields() {
    final code = widget.miniApp.code.toLowerCase();
    if (code.contains('split') || code.contains('expense')) {
      _label1 = 'มื้อ / กิจกรรมที่หารกัน';
      _label2 = 'รายชื่อเพื่อน & ยอดต่อคน';
      _label3 = 'ยอดรวมทั้งหมด';
      _statusBadge = 'หารค่าข้าวกับเพื่อน';
      _field1Ctrl = TextEditingController(text: 'ปิ้งย่างเกาหลี + คาเฟ่');
      _field2Ctrl = TextEditingController(text: '4 คน คนละ 320 บาท');
      _field3Ctrl = TextEditingController(text: '1,280.00 บาท');
      _noteCtrl = TextEditingController(
        text: 'โอนพร้อมเพย์แล้วส่งสลิปเก็บไว้ในอัลบั้มห้องนี้ได้เลยนะ',
      );
    } else if (code.contains('trip') || code.contains('travel')) {
      _label1 = 'จุดหมายปลายทาง / ทริป';
      _label2 = 'วันเดินทาง & ที่พัก';
      _label3 = 'งบประมาณต่อคนโดยประมาณ';
      _statusBadge = 'แพลนทริปเที่ยว';
      _field1Ctrl = TextEditingController(text: 'ทริปเชียงใหม่ — ม่อนแจ่ม');
      _field2Ctrl = TextEditingController(text: 'ศุกร์ - อาทิตย์ (2 คืน)');
      _field3Ctrl = TextEditingController(text: '3,500 บาท / คน');
      _noteCtrl = TextEditingController(
        text: 'ใครสะดวกขับรถหรือจองคาเฟ่ กดโหวตบอกในห้องแชทเลย',
      );
    } else if (code.contains('wish') || code.contains('gift') || code.contains('quote')) {
      _label1 = 'หมวดของฝาก / ช้อปปิ้ง';
      _label2 = 'รายการที่อยากได้หรือฝากซื้อ';
      _label3 = 'งบ / จำนวนรายการ';
      _statusBadge = 'ลิสต์ของฝาก & ช้อปปิ้ง';
      _field1Ctrl = TextEditingController(text: 'ของฝากญี่ปุ่น & ขนมบ้านเพื่อน');
      _field2Ctrl = TextEditingController(text: 'ชาเขียว 2 กล่อง, พวงกุญแจ, ขนม');
      _field3Ctrl = TextEditingController(text: '3 รายการ (ไม่เกิน 1,000 บาท)');
      _noteCtrl = TextEditingController(
        text: 'เจอร้านแล้วจะถ่ายรูปส่งเข้าแชทให้ดูก่อนซื้อครับ',
      );
    } else if (code.contains('hangout') || code.contains('book') || code.contains('meet')) {
      _label1 = 'กิจกรรมนัดเจอ';
      _label2 = 'วันและเวลานัด';
      _label3 = 'สถานที่ / คาเฟ่';
      _statusBadge = 'ชวนนัดเจอแก๊งเพื่อน';
      _field1Ctrl = TextEditingController(text: 'นัดเจอกินข้าว & เดินเล่นเสาร์นี้');
      _field2Ctrl = TextEditingController(text: 'วันเสาร์ เวลา 17:30 น.');
      _field3Ctrl = TextEditingController(text: 'คาเฟ่ริมน้ำ / ลานจอดสะดวก');
      _noteCtrl = TextEditingController(
        text: 'ชวนทุกคนในกลุ่ม ใครไปได้กดยืนยันในการ์ดได้เลย',
      );
    } else if (code.contains('ai') || code.contains('leave')) {
      _label1 = 'หัวข้อที่อยากให้ AI ช่วย';
      _label2 = 'รายละเอียด / คำถาม';
      _label3 = 'สไตล์คำตอบที่ต้องการ';
      _statusBadge = 'ผู้ช่วย AI ส่วนตัว';
      _field1Ctrl = TextEditingController(text: 'ช่วยคิดแพลนวันหยุดสุดสัปดาห์');
      _field2Ctrl = TextEditingController(
        text: 'อยากได้ร้านอร่อยและคาเฟ่ถ่ายรูปสวยสำหรับ 4 คน',
      );
      _field3Ctrl = TextEditingController(text: 'เป็นกันเอง กระชับ เข้าใจง่าย');
      _noteCtrl = TextEditingController(
        text: 'ส่งการ์ดนี้เข้าห้องเพื่อให้ @ai ช่วยแนะนำต่อได้ทันที',
      );
    } else {
      _label1 = 'หัวข้อรายการ (${widget.miniApp.title})';
      _label2 = 'รายละเอียดหลัก';
      _label3 = 'สถานะ / หมายเหตุ';
      _statusBadge = 'เครื่องมือเสริม BC Ai Chat';
      _field1Ctrl = TextEditingController(
        text: 'รายการใหม่จาก ${widget.miniApp.title}',
      );
      _field2Ctrl = TextEditingController(text: widget.miniApp.subtitle);
      _field3Ctrl = TextEditingController(text: 'พร้อมส่งให้เพื่อน');
      _noteCtrl = TextEditingController(
        text: 'สร้างจากเครื่องมือเสริมใน BC Ai Chat',
      );
    }
  }

  @override
  void dispose() {
    _field1Ctrl.dispose();
    _field2Ctrl.dispose();
    _field3Ctrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _buildCardPayload() {
    final user = ApiService.instance.currentUser;
    return {
      'app_code': widget.miniApp.code,
      'app_title': widget.miniApp.title,
      'category': widget.miniApp.category,
      'color': widget.miniApp.color,
      'icon': widget.miniApp.icon,
      'badge': _statusBadge,
      'title': _field1Ctrl.text.trim(),
      'subtitle': _field2Ctrl.text.trim(),
      'highlight': _field3Ctrl.text.trim(),
      'note': _noteCtrl.text.trim(),
      'fields': [
        {'label': _label1, 'value': _field1Ctrl.text.trim()},
        {'label': _label2, 'value': _field2Ctrl.text.trim()},
        {'label': _label3, 'value': _field3Ctrl.text.trim()},
      ],
      'submitted_by': user?.displayName ?? 'ผู้ใช้งาน',
      'submitted_email': user?.email ?? '',
      'external_url': ApiService.instance.resolveMiniAppUrl(widget.miniApp),
    };
  }

  Future<void> _openExternalWebView() async {
    final url = ApiService.instance.resolveMiniAppUrl(widget.miniApp);
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _sendRichCardToChat() async {
    final targetId = _selectedConversationId;
    if (targetId == null || targetId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณาเลือกห้องแชทปลายทางก่อนส่งการ์ด')),
      );
      return;
    }

    setState(() => _isSending = true);
    try {
      final payload = _buildCardPayload();
      final msg = await ApiService.instance.sendMessage(
        targetId,
        type: 'rich_card',
        content: '${widget.miniApp.title}: ${_field1Ctrl.text.trim()}',
        cardPayload: payload,
      );
      if (!mounted) return;
      widget.onCardSent?.call(msg);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.brandDeep,
          content: Text(
            'ส่งการ์ด "${widget.miniApp.title}" เข้าห้องแชทเรียบร้อยแล้ว',
          ),
        ),
      );
      Navigator.of(context).pop(msg);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.dangerRed,
          content: Text('ส่งการ์ดไม่สำเร็จ: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = AppTheme.parseHexColor(widget.miniApp.color);
    final user = ApiService.instance.currentUser;
    final narrow = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      backgroundColor: AppTheme.surfaceBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        // A childless DecoratedBox collapses to 0x0 here; expand it so the
        // gradient actually fills the bar behind the white title.
        flexibleSpace: const SizedBox.expand(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: AppTheme.navyGradient),
          ),
        ),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                boxShadow: AppTheme.glow(accentColor, strength: 0.28),
              ),
              child: Icon(
                AppTheme.resolveMiniAppIcon(widget.miniApp.icon),
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.miniApp.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.3,
                    ),
                  ),
                  Text(
                    'Mini-App WebView Bridge · หมวด ${widget.miniApp.category}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF94A3B8),
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'เปิด WebView เต็มจอ',
            onPressed: _openExternalWebView,
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(narrow ? 10 : 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // SSO Status Bar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.brandSoft,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    border: Border.all(
                      color: AppTheme.brandPrimary.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.verified_user_rounded,
                        color: AppTheme.brandDeep,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'เชื่อมต่อ SSO ด้วยบัญชี Gmail: ${user?.email ?? "-"} (${user?.displayName ?? "-"}) เรียบร้อยแล้ว',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.brandDeep,
                            height: 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PillBadge(
                        text: 'JS Bridge Active',
                        backgroundColor: Colors.white,
                        textColor: AppTheme.brandDeep,
                        icon: Icons.check_circle_rounded,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildFormCard(accentColor),
                    const SizedBox(height: 14),
                    _buildRichCardPreview(accentColor),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(String text, {bool strong = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
          color: strong ? AppTheme.slateDark : AppTheme.slateBody,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _folderBadge(Conversation conv) {
    return PillBadge(
      text: conv.folderLabel,
      backgroundColor: AppTheme.brandSoft,
      textColor: AppTheme.brandDeep,
    );
  }

  Widget _roomAvatar(Conversation conv, double radius) {
    return UserAvatar(
      name: conv.name,
      avatarUrl: conv.avatarUrl.isEmpty ? null : conv.avatarUrl,
      radius: radius,
      isGroup: conv.kind == 'group',
    );
  }

  Widget _buildRoomPicker() {
    Conversation? selected;
    for (final c in widget.conversations) {
      if (c.id == _selectedConversationId) selected = c;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: AppTheme.surfaceBg,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            onTap: () =>
                setState(() => _roomPickerExpanded = !_roomPickerExpanded),
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(
                  color: _roomPickerExpanded
                      ? AppTheme.brandPrimary
                      : AppTheme.borderSubtle,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (selected != null)
                    _roomAvatar(selected, 16)
                  else
                    const Icon(
                      Icons.forum_outlined,
                      size: 20,
                      color: AppTheme.slateMuted,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      selected?.name ?? 'แตะเพื่อเลือกห้องแชท',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateDark,
                        height: 1.3,
                      ),
                    ),
                  ),
                  if (selected != null) ...[
                    const SizedBox(width: 8),
                    _folderBadge(selected),
                  ],
                  const SizedBox(width: 6),
                  Icon(
                    _roomPickerExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: AppTheme.slateMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_roomPickerExpanded) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.all(6),
              itemCount: widget.conversations.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (_, i) {
                final conv = widget.conversations[i];
                final isSel = conv.id == _selectedConversationId;
                return Material(
                  color: isSel ? AppTheme.brandSoft : AppTheme.surfaceBg,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    onTap: () => setState(() {
                      _selectedConversationId = conv.id;
                      _roomPickerExpanded = false;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _roomAvatar(conv, 15),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              conv.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.slateDark,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          _folderBadge(conv),
                          if (isSel) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.check_circle_rounded,
                              size: 16,
                              color: AppTheme.brandPrimary,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFormCard(Color accentColor) {
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.edit_document, color: accentColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'กรอกข้อมูล ${widget.miniApp.title}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          _fieldLabel(_label1),
          TextField(controller: _field1Ctrl, onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),

          _fieldLabel(_label2),
          TextField(controller: _field2Ctrl, onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),

          _fieldLabel(_label3),
          TextField(controller: _field3Ctrl, onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),

          _fieldLabel('หมายเหตุเพิ่มเติม'),
          TextField(
            controller: _noteCtrl,
            maxLines: 2,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 18),

          _fieldLabel('เลือกห้องแชทปลายทางที่ต้องการส่งการ์ด', strong: true),
          if (widget.conversations.isEmpty)
            const Text(
              'ยังไม่มีห้องแชท กรุณาเปิดห้องแชทก่อน',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.dangerRed,
                height: 1.4,
              ),
            )
          else
            _buildRoomPicker(),

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: ElevatedButton.icon(
              onPressed: _isSending ? null : _sendRichCardToChat,
              style: ElevatedButton.styleFrom(backgroundColor: accentColor),
              icon: _isSending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded, size: 18),
              label: const Text(
                'ส่งการ์ดโต้ตอบเข้าห้องแชท',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRichCardPreview(Color accentColor) {
    final user = ApiService.instance.currentUser;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF5EFEA), Color(0xFFEADBD7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.visibility_rounded,
                color: AppTheme.slateBody,
                size: 16,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'ตัวอย่างการ์ดโต้ตอบที่จะแสดงในห้องแชท',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateBody,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Simulated Rich Card bubble
          Container(
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  color: accentColor,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        AppTheme.resolveMiniAppIcon(widget.miniApp.icon),
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.miniApp.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _statusBadge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _field1Ctrl.text.isEmpty ? '-' : _field1Ctrl.text,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.slateDark,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _field2Ctrl.text.isEmpty ? '-' : _field2Ctrl.text,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.slateBody,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceBg,
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusSm,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                _label3,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppTheme.slateMuted,
                                  height: 1.4,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _field3Ctrl.text.isEmpty
                                    ? '-'
                                    : _field3Ctrl.text,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: accentColor,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_noteCtrl.text.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'หมายเหตุ: ${_noteCtrl.text.trim()}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.slateMuted,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const Divider(height: 22),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.account_circle_outlined,
                            size: 15,
                            color: AppTheme.slateMuted,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              'ผู้ส่ง: ${user?.displayName ?? "คุณ"}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.slateMuted,
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'เปิดดูรายละเอียด',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: accentColor,
                                height: 1.3,
                              ),
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
      ),
    );
  }
}
