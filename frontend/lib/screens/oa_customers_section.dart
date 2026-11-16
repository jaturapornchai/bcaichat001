import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

String _cleanError(Object e) => e.toString().replaceFirst('Exception: ', '');

/// ชิปแท็กเลือกได้หลายอัน (เลือกอันไหนก็ได้ = ต้องมีอย่างน้อยหนึ่งแท็ก)
/// โหลดจำนวนคนต่อแท็กจาก `customer-tags` และบอกจำนวนคนที่ตรงเมื่อ [showMatch]
class OaTagFilterChips extends StatefulWidget {
  final String oaId;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final bool showMatch;

  const OaTagFilterChips({
    super.key,
    required this.oaId,
    required this.selected,
    required this.onChanged,
    this.showMatch = false,
  });

  @override
  State<OaTagFilterChips> createState() => _OaTagFilterChipsState();
}

class _OaTagFilterChipsState extends State<OaTagFilterChips> {
  OaTagSummary? _summary;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OaTagFilterChips old) {
    super.didUpdateWidget(old);
    if (old.oaId != widget.oaId || !_sameTags(old.selected, widget.selected)) {
      _load();
    }
  }

  bool _sameTags(List<String> a, List<String> b) =>
      a.length == b.length && a.every(b.contains);

  Future<void> _load() async {
    final requested = List<String>.of(widget.selected);
    try {
      final s = await ApiService.instance.fetchOaCustomerTags(
        widget.oaId,
        tags: requested,
      );
      if (!mounted || !_sameTags(requested, widget.selected)) return;
      setState(() {
        _summary = s;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _cleanError(e));
    }
  }

  void _toggle(String tag) {
    final next = List<String>.of(widget.selected);
    next.contains(tag) ? next.remove(tag) : next.add(tag);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    final tags = s?.tags ?? const <OaTagCount>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          Text(
            _error!,
            style: const TextStyle(fontSize: 11.5, color: AppTheme.dangerRed),
          )
        else if (s != null && tags.isEmpty)
          const Text(
            'ยังไม่มีแท็กลูกค้า — ติดแท็กได้ในหน้ารายละเอียดลูกค้า',
            style: TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final t in tags)
                FilterChip(
                  label: Text(
                    '${t.tag} (${t.count})',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  selected: widget.selected.contains(t.tag),
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _toggle(t.tag),
                ),
            ],
          ),
        if (widget.showMatch && s != null) ...[
          const SizedBox(height: 4),
          Text(
            'จะส่งถึง ${s.matchCount} คน'
            '${widget.selected.isEmpty ? " (ผู้ติดตามทุกคน)" : ""}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.brandDeep,
            ),
          ),
        ],
      ],
    );
  }
}

/// หัวข้อ "ลูกค้า" ของคอนโซลร้านค้า: รายชื่อ + ค้นหา/กรอง + รายละเอียดแบบ inline
class OaCustomersSection extends StatefulWidget {
  final OaAccountDto oa;

  /// เปิดห้องแชทของลูกค้าในกล่องข้อความเดิม
  final ValueChanged<OaCustomerChatDto> onOpenChat;

  const OaCustomersSection({
    super.key,
    required this.oa,
    required this.onOpenChat,
  });

  @override
  State<OaCustomersSection> createState() => _OaCustomersSectionState();
}

class _OaCustomersSectionState extends State<OaCustomersSection> {
  static const int _pageSize = 30;
  static const List<(String, String)> _sorts = [
    ('recent', 'ล่าสุด'),
    ('name', 'ชื่อ ก-ฮ'),
    ('followed', 'วันที่ติดตาม'),
  ];

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _tagsCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();
  Timer? _debounce;

  List<String> _filterTags = const [];
  bool? _following;
  String _sort = 'recent';
  List<OaCustomer> _items = const [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;
  int _requestSeq = 0;
  int _tagsRefresh = 0;
  String? _error;
  String? _status;

  OaCustomer? _selected;
  OaCustomerDetail? _detail;
  bool _detailLoading = false;
  bool _aiPaused = false;

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  @override
  void didUpdateWidget(covariant OaCustomersSection old) {
    super.didUpdateWidget(old);
    if (old.oa.id != widget.oa.id) {
      _selected = null;
      _detail = null;
      _filterTags = const [];
      _loadList();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _tagsCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _loadList);
  }

  Future<void> _loadList({bool more = false}) async {
    final seq = ++_requestSeq;
    final page = more ? _page + 1 : 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiService.instance.fetchOaCustomers(
        widget.oa.id,
        q: _searchCtrl.text,
        tags: _filterTags,
        following: _following,
        sort: _sort,
        page: page,
        limit: _pageSize,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _items = more ? [..._items, ...res.items] : res.items;
        _total = res.total;
        _page = page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = _cleanError(e);
      });
    }
  }

  void _setFilter(VoidCallback change) {
    setState(change);
    _loadList();
  }

  Future<void> _openDetail(OaCustomer c) async {
    setState(() {
      _selected = c;
      _detail = null;
      _detailLoading = true;
      _status = null;
      _tagsCtrl.text = c.tags.join(', ');
      _noteCtrl.text = c.chat.crmNote;
      _aiPaused = c.chat.aiPaused;
    });
    try {
      final d = await ApiService.instance.fetchOaCustomerDetail(
        widget.oa.id,
        c.id,
      );
      if (!mounted || _selected?.id != c.id) return;
      setState(() {
        _detail = d;
        _detailLoading = false;
        _tagsCtrl.text = d.customer.tags.join(', ');
        _noteCtrl.text = d.customer.chat.crmNote;
        _aiPaused = d.customer.chat.aiPaused;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _detailLoading = false;
        _error = _cleanError(e);
      });
    }
  }

  Future<void> _saveCrm() async {
    final c = _selected;
    if (c == null) return;
    final tags = _tagsCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      await ApiService.instance.updateOaFollowerCrm(
        widget.oa.id,
        c.id,
        tags: tags,
        crmNote: _noteCtrl.text.trim(),
        aiPaused: _aiPaused,
      );
      if (!mounted) return;
      setState(() {
        _status = 'บันทึกข้อมูลของ ${c.name} แล้ว';
        _error = null;
        _tagsRefresh++;
      });
      await _loadList();
      await _openDetailKeepStatus(c);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _cleanError(e));
    }
  }

  Future<void> _openDetailKeepStatus(OaCustomer c) async {
    final status = _status;
    await _openDetail(c);
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: AppTheme.dangerRed),
            ),
            const SizedBox(height: 6),
          ],
          if (_status != null) ...[
            Text(
              _status!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF027A48)),
            ),
            const SizedBox(height: 6),
          ],
          if (_selected != null)
            _buildDetail(_selected!)
          else
            _buildList(),
        ],
      ),
    );
  }

  Widget _buildList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          decoration: const InputDecoration(
            hintText: 'ค้นหาชื่อ เบอร์ @ไอดี หรืออีเมลลูกค้า...',
            prefixIcon: Icon(Icons.search_rounded, size: 18),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        ),
        const SizedBox(height: 6),
        OaTagFilterChips(
          key: ValueKey('crm-tags-${widget.oa.id}-$_tagsRefresh'),
          oaId: widget.oa.id,
          selected: _filterTags,
          onChanged: (tags) => _setFilter(() => _filterTags = tags),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _choice('ทั้งหมด', _following == null, () => _setFilter(() => _following = null)),
            _choice('ติดตามอยู่', _following == true, () => _setFilter(() => _following = true)),
            _choice('เลิกติดตาม', _following == false, () => _setFilter(() => _following = false)),
            const Text(
              '·',
              style: TextStyle(color: AppTheme.slateMuted),
            ),
            for (final s in _sorts)
              _choice('เรียง: ${s.$2}', _sort == s.$1, () => _setFilter(() => _sort = s.$1)),
          ],
        ),
        const SizedBox(height: 6),
        if (_loading && _items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(10),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(10),
            child: Text(
              'ยังไม่พบลูกค้าตามเงื่อนไขนี้',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            ),
          )
        else
          for (final c in _items) _buildRow(c),
        if (_items.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'แสดง ${_items.length} จาก $_total',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
              ),
              if (_items.length < _total) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _loading ? null : () => _loadList(more: true),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 30),
                  ),
                  child: const Text('โหลดเพิ่ม', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _choice(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => onTap(),
    );
  }

  Widget _buildRow(OaCustomer c) {
    final last = c.chat.lastMessage?.previewText ?? '';
    final day = formatThaiDay(c.chat.updatedAt);
    return InkWell(
      key: ValueKey('crm-row-${c.id}'),
      onTap: () => _openDetail(c),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
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
            UserAvatar(
              name: c.name,
              avatarUrl: c.chat.customerAvatar,
              radius: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        c.name,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.slateDark,
                        ),
                      ),
                      for (final t in c.tags.take(3))
                        PillBadge(
                          text: t,
                          backgroundColor: AppTheme.tintStrong,
                          textColor: AppTheme.brandDeep,
                        ),
                    ],
                  ),
                  Text(
                    [
                      if (day.isNotEmpty) 'ใช้งานล่าสุด $day',
                      if (last.isNotEmpty) last,
                    ].join(' · '),
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
            PillBadge(
              text: c.isFollowing ? 'ติดตามอยู่' : 'เลิกติดตาม',
              backgroundColor: c.isFollowing
                  ? AppTheme.tintStrong
                  : AppTheme.panelBg,
              textColor: c.isFollowing
                  ? AppTheme.brandDeep
                  : AppTheme.slateMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetail(OaCustomer c) {
    final d = _detail;
    final chat = (d?.customer ?? c).chat;
    final contact = [
      if (chat.customerBcId.isNotEmpty) '@${chat.customerBcId}',
      if (chat.customerPhone.isNotEmpty) chat.customerPhone,
      if (chat.customerEmail.isNotEmpty) chat.customerEmail,
    ];
    return Column(
      key: const ValueKey('crm-detail'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                _selected = null;
                _detail = null;
                _status = null;
              }),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('กลับไปรายชื่อ', style: TextStyle(fontSize: 12)),
            ),
            const Spacer(),
            if (_detailLoading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            UserAvatar(name: c.name, avatarUrl: chat.customerAvatar, radius: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    contact.isEmpty ? 'ไม่มีข้อมูลติดต่อ' : contact.join(' · '),
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.slateMuted,
                    ),
                  ),
                  Text(
                    c.isFollowing
                        ? 'ติดตามร้านอยู่${formatThaiDay(c.followedAt).isEmpty ? "" : " · ตั้งแต่ ${formatThaiDay(c.followedAt)}"}'
                        : 'เลิกติดตามร้านแล้ว',
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
        TextField(
          controller: _tagsCtrl,
          decoration: const InputDecoration(
            labelText: 'แท็ก (คั่นด้วยลูกน้ำ เช่น VIP, ลูกค้าประจำ)',
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _noteCtrl,
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
          value: _aiPaused,
          onChanged: (v) => setState(() => _aiPaused = v),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonal(
              onPressed: _saveCrm,
              child: const Text('บันทึกข้อมูลลูกค้า'),
            ),
            if (chat.conversationId.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => widget.onOpenChat(chat),
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                label: const Text('เปิดแชทลูกค้า'),
              )
            else
              const Text(
                'ยังไม่เคยแชทกับร้าน',
                style: TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
              ),
          ],
        ),
        const Divider(height: 16),
        if (d != null) ...[
          Text(
            'คูปอง: รับแล้ว ${d.couponsClaimed} · ใช้แล้ว ${d.couponsRedeemed}'
            ' · ข่าวที่ได้รับ ${d.broadcastsReceived}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          if (d.coupons.isEmpty)
            const Text(
              'ยังไม่เคยรับคูปอง',
              style: TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
            )
          else
            for (final cp in d.coupons)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    PillBadge(
                      text: cp.isRedeemed ? 'ใช้แล้ว' : 'ยังไม่ใช้',
                      backgroundColor: cp.isRedeemed
                          ? AppTheme.panelBg
                          : AppTheme.tintStrong,
                      textColor: cp.isRedeemed
                          ? AppTheme.slateMuted
                          : AppTheme.brandDeep,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${cp.code} · ${cp.title}'
                        '${cp.discountText.isEmpty ? "" : " · ${cp.discountText}"}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 6),
          const Text(
            'ข่าวสารที่ลูกค้าได้รับ',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          if (d.broadcasts.isEmpty)
            const Text(
              'ยังไม่เคยได้รับข่าวสาร',
              style: TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
            )
          else
            for (final b in d.broadcasts)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '${formatThaiDay(b.createdAt)} · '
                  '${b.targetTags.isEmpty ? "" : "[${b.targetTags.join(", ")}] "}'
                  '${b.content}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
        ],
      ],
    );
  }
}
