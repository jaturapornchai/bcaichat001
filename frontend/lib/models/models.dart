import 'package:intl/intl.dart';

String _extractId(Map<String, dynamic> json) {
  final rawId = json['id'] ?? json['_id'];
  if (rawId is String) return rawId;
  if (rawId is Map && rawId['\$oid'] != null) {
    return rawId['\$oid'].toString();
  }
  return rawId?.toString() ?? '';
}

int _toInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool _toBool(dynamic value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  if (value is num) return value != 0;
  return fallback;
}

String _normalizeBcId(dynamic value) =>
    (value ?? '').toString().trim().replaceFirst(RegExp(r'^@+'), '');

String inferDepartment({
  String? rawDepartment,
  String? email,
  String? name,
  String? role,
}) {
  if (rawDepartment != null && rawDepartment.trim().isNotEmpty) {
    return rawDepartment.trim();
  }
  final lowerEmail = (email ?? '').toLowerCase();
  final lowerName = (name ?? '').toLowerCase();
  final lowerRole = (role ?? '').toLowerCase();

  if (lowerRole == 'admin' ||
      lowerEmail.contains('jead') ||
      lowerName.contains('ลุงจืด') ||
      lowerName.contains('admin')) {
    return 'เจ้าของระบบ';
  }
  if (lowerEmail.contains('ai@') ||
      lowerName.contains('bc ai') ||
      lowerName.contains('ผู้ช่วย')) {
    return 'AI ส่วนตัว';
  }
  if (lowerEmail.contains('demo3') ||
      lowerEmail.contains('nida') ||
      lowerName.contains('บอส') ||
      lowerName.contains('นิดา') ||
      lowerName.contains('พี่สาว') ||
      lowerName.contains('ครอบครัว')) {
    return 'ครอบครัว';
  }
  if (lowerEmail.contains('demo5') ||
      lowerName.contains('ต้น') ||
      lowerName.contains('กีฬา')) {
    return 'ก๊วนกีฬา';
  }
  if (lowerEmail.contains('somchai') ||
      lowerName.contains('สมชาย') ||
      lowerName.contains('เพื่อนบ้าน')) {
    return 'เพื่อนบ้าน';
  }
  if (lowerEmail.contains('official') ||
      lowerName.contains('ข่าวสาร') ||
      lowerName.contains('ประกาศ')) {
    return 'ข่าวสารแอป';
  }
  if (lowerEmail.contains('demo1') ||
      lowerEmail.contains('demo2') ||
      lowerEmail.contains('demo4') ||
      lowerName.contains('ก้อง') ||
      lowerName.contains('แพร') ||
      lowerName.contains('มายด์')) {
    return 'เพื่อนสนิท';
  }
  return 'เพื่อน';
}

String formatThaiTime(String? iso) {
  if (iso == null || iso.trim().isEmpty) return '';
  final parsed = DateTime.tryParse(iso)?.toLocal();
  if (parsed == null) return iso;
  final now = DateTime.now();
  final isToday =
      parsed.year == now.year &&
      parsed.month == now.month &&
      parsed.day == now.day;
  if (isToday) {
    return '${DateFormat('HH:mm').format(parsed)} น.';
  }
  return DateFormat('dd/MM HH:mm').format(parsed);
}

String formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(2)} MB';
}

/// แปลงเลขไทย (๐-๙) เป็นเลขอารบิก (0-9) โดยคงอักขระอื่นไว้ครบถ้วน
String normalizeThaiDigits(String input) {
  const thaiDigits = '๐๑๒๓๔๕๖๗๘๙';
  final buf = StringBuffer();
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    final idx = thaiDigits.indexOf(ch);
    buf.write(idx >= 0 ? idx.toString() : ch);
  }
  return buf.toString();
}

/// ปรับรูปแบบคำค้นหาเพื่อน (เบอร์ไทย/เลขไทย/ขีด/เว้นวรรค/+66 และ @BC ID) ให้ตรงกับ /api/users/search
String normalizeFriendSearchQuery(String raw, {required String mode}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (mode == 'phone') {
    final ascii = normalizeThaiDigits(trimmed);
    var cleaned = ascii.replaceAll(RegExp(r'[\s\-().]'), '');
    if (cleaned.startsWith('+660')) {
      cleaned = '0${cleaned.substring(4)}';
    } else if (cleaned.startsWith('+66')) {
      cleaned = '0${cleaned.substring(3)}';
    } else if (cleaned.startsWith('660') && cleaned.length >= 11) {
      cleaned = '0${cleaned.substring(3)}';
    } else if (cleaned.startsWith('66') && cleaned.length >= 10) {
      cleaned = '0${cleaned.substring(2)}';
    }
    return cleaned.isNotEmpty ? cleaned : trimmed;
  }
  if (mode == 'id' && trimmed.startsWith('@')) {
    return trimmed.substring(1).trim();
  }
  return trimmed;
}

class AppUser {
  final String id;
  final String email;
  final String phone;
  final bool phoneVerified;
  final bool emailVerified;
  final bool hasGoogleLinked;
  final String displayName;
  final String bcId;
  final String avatarUrl;
  final String statusMessage;
  final String qrToken;
  final String role;
  final String department;
  final bool isOfficial;
  final bool isOaBot;
  final String? oaId;
  final bool isOnline;
  final bool isFavorite;
  final bool isBlocked;
  final bool isHidden;
  final bool allowAddByPhone;
  final bool allowAddById;
  final bool allowAddByEmail;
  final bool notifyPreview;
  final bool notifyOnMention;
  final String? dndUntil;
  final bool hasRecoveryPin;
  final int recoveryCodesRemaining;
  final String? lastRecoveredAt;

  const AppUser({
    required this.id,
    required this.email,
    this.phone = '',
    this.phoneVerified = false,
    this.emailVerified = false,
    this.hasGoogleLinked = false,
    required this.displayName,
    required this.bcId,
    required this.avatarUrl,
    required this.statusMessage,
    required this.qrToken,
    required this.role,
    required this.department,
    this.isOfficial = false,
    this.isOaBot = false,
    this.oaId,
    this.isOnline = true,
    this.isFavorite = false,
    this.isBlocked = false,
    this.isHidden = false,
    this.allowAddByPhone = true,
    this.allowAddById = true,
    this.allowAddByEmail = true,
    this.notifyPreview = true,
    this.notifyOnMention = true,
    this.dndUntil,
    this.hasRecoveryPin = false,
    this.recoveryCodesRemaining = 0,
    this.lastRecoveredAt,
  });

  bool get isDndActive {
    final raw = dndUntil?.trim() ?? '';
    if (raw.isEmpty) return false;
    final dt = DateTime.tryParse(raw);
    return dt != null && dt.toUtc().isAfter(DateTime.now().toUtc());
  }

  DateTime? get dndUntilDate {
    final raw = dndUntil?.trim() ?? '';
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  bool get isAdmin => role.toLowerCase() == 'admin';

  AppUser copyWith({
    String? email,
    String? phone,
    bool? phoneVerified,
    bool? emailVerified,
    bool? hasGoogleLinked,
    String? displayName,
    String? bcId,
    String? avatarUrl,
    String? statusMessage,
    String? qrToken,
    String? role,
    String? department,
    bool? isOaBot,
    String? oaId,
    bool? isFavorite,
    bool? isBlocked,
    bool? isHidden,
    bool? allowAddByPhone,
    bool? allowAddById,
    bool? allowAddByEmail,
    bool? notifyPreview,
    bool? notifyOnMention,
    String? dndUntil,
    bool clearDndUntil = false,
    bool? hasRecoveryPin,
    int? recoveryCodesRemaining,
    String? lastRecoveredAt,
  }) => AppUser(
    id: id,
    email: email ?? this.email,
    phone: phone ?? this.phone,
    phoneVerified: phoneVerified ?? this.phoneVerified,
    emailVerified: emailVerified ?? this.emailVerified,
    hasGoogleLinked: hasGoogleLinked ?? this.hasGoogleLinked,
    displayName: displayName ?? this.displayName,
    bcId: bcId ?? this.bcId,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    statusMessage: statusMessage ?? this.statusMessage,
    qrToken: qrToken ?? this.qrToken,
    role: role ?? this.role,
    department: department ?? this.department,
    isOfficial: isOfficial,
    isOaBot: isOaBot ?? this.isOaBot,
    oaId: oaId ?? this.oaId,
    isOnline: isOnline,
    isFavorite: isFavorite ?? this.isFavorite,
    isBlocked: isBlocked ?? this.isBlocked,
    isHidden: isHidden ?? this.isHidden,
    allowAddByPhone: allowAddByPhone ?? this.allowAddByPhone,
    allowAddById: allowAddById ?? this.allowAddById,
    allowAddByEmail: allowAddByEmail ?? this.allowAddByEmail,
    notifyPreview: notifyPreview ?? this.notifyPreview,
    notifyOnMention: notifyOnMention ?? this.notifyOnMention,
    dndUntil: clearDndUntil ? null : (dndUntil ?? this.dndUntil),
    hasRecoveryPin: hasRecoveryPin ?? this.hasRecoveryPin,
    recoveryCodesRemaining:
        recoveryCodesRemaining ?? this.recoveryCodesRemaining,
    lastRecoveredAt: lastRecoveredAt ?? this.lastRecoveredAt,
  );

  factory AppUser.fromJson(Map<String, dynamic> json) {
    final email = (json['email'] ?? '').toString();
    final phone = (json['phone'] ?? '').toString();
    final displayName =
        (json['display_name'] ?? json['displayName'] ?? json['name'] ?? '')
            .toString();
    final role = (json['role'] ?? 'user').toString();
    final rawOaId = (json['oa_id'] ?? json['oaId'])?.toString().trim() ?? '';
    final rawDnd = (json['dnd_until'] ?? json['dndUntil'])?.toString().trim() ?? '';
    final rawRecoveredAt =
        (json['last_recovered_at'] ?? json['lastRecoveredAt'])
            ?.toString()
            .trim() ??
        '';

    return AppUser(
      id: _extractId(json),
      email: email,
      phone: phone,
      phoneVerified: _toBool(
        json['phone_verified'] ?? json['phoneVerified'],
        false,
      ),
      emailVerified: _toBool(
        json['email_verified'] ?? json['emailVerified'],
        false,
      ),
      hasGoogleLinked: _toBool(
        json['has_google_linked'] ?? json['hasGoogleLinked'],
        false,
      ),
      displayName: displayName,
      bcId: _normalizeBcId(json['bc_id'] ?? json['bcId']),
      avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? '').toString(),
      statusMessage:
          (json['status_message'] ??
                  json['statusMessage'] ??
                  'พร้อมแชทบน BC Ai Chat')
              .toString(),
      qrToken: (json['qr_token'] ?? json['qrToken'] ?? '').toString(),
      role: role,
      department: inferDepartment(
        rawDepartment: json['department']?.toString(),
        email: email,
        name: displayName,
        role: role,
      ),
      isOfficial: _toBool(json['is_official'] ?? json['isOfficial'], false),
      isOaBot: _toBool(json['is_oa_bot'] ?? json['isOaBot'], false),
      oaId: rawOaId.isEmpty ? null : rawOaId,
      isOnline: _toBool(json['is_online'] ?? json['isOnline'], true),
      isFavorite: _toBool(json['is_favorite'] ?? json['isFavorite'], false),
      isBlocked: _toBool(json['is_blocked'] ?? json['isBlocked'], false),
      isHidden: _toBool(json['is_hidden'] ?? json['isHidden'], false),
      allowAddByPhone: _toBool(
        json['allow_add_by_phone'] ?? json['allowAddByPhone'],
        true,
      ),
      allowAddById: _toBool(
        json['allow_add_by_id'] ?? json['allowAddById'],
        true,
      ),
      allowAddByEmail: _toBool(
        json['allow_add_by_email'] ?? json['allowAddByEmail'],
        true,
      ),
      notifyPreview: _toBool(
        json['notify_preview'] ?? json['notifyPreview'],
        true,
      ),
      notifyOnMention: _toBool(
        json['notify_on_mention'] ?? json['notifyOnMention'],
        true,
      ),
      dndUntil: rawDnd.isEmpty ? null : rawDnd,
      hasRecoveryPin: _toBool(
        json['has_recovery_pin'] ?? json['hasRecoveryPin'],
        false,
      ),
      recoveryCodesRemaining: _toInt(
        json['recovery_codes_remaining'] ?? json['recoveryCodesRemaining'],
        0,
      ),
      lastRecoveredAt: rawRecoveredAt.isEmpty ? null : rawRecoveredAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'phone': phone,
    'phone_verified': phoneVerified,
    'email_verified': emailVerified,
    'has_google_linked': hasGoogleLinked,
    'display_name': displayName,
    'bc_id': bcId,
    'avatar_url': avatarUrl,
    'status_message': statusMessage,
    'qr_token': qrToken,
    'role': role,
    'department': department,
    'is_official': isOfficial,
    'is_oa_bot': isOaBot,
    if (oaId != null) 'oa_id': oaId,
    'is_online': isOnline,
    'is_favorite': isFavorite,
    'is_blocked': isBlocked,
    'is_hidden': isHidden,
    'allow_add_by_phone': allowAddByPhone,
    'allow_add_by_id': allowAddById,
    'allow_add_by_email': allowAddByEmail,
    'notify_preview': notifyPreview,
    'notify_on_mention': notifyOnMention,
    'dnd_until': dndUntil,
    'has_recovery_pin': hasRecoveryPin,
    'recovery_codes_remaining': recoveryCodesRemaining,
    'last_recovered_at': lastRecoveredAt,
  };
}

class AttachmentInfo {
  final String key;
  final String url;
  final String fileName;
  final String mimeType;
  final int fileSize;

  const AttachmentInfo({
    required this.key,
    required this.url,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
  });

  bool get isImage => mimeType.toLowerCase().startsWith('image/');

  factory AttachmentInfo.fromJson(Map<String, dynamic> json) {
    return AttachmentInfo(
      key: (json['key'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      fileName: (json['file_name'] ?? json['fileName'] ?? 'เอกสารแนบ')
          .toString(),
      mimeType:
          (json['mime_type'] ?? json['mimeType'] ?? 'application/octet-stream')
              .toString(),
      fileSize: _toInt(json['file_size'] ?? json['fileSize']),
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'url': url,
    'file_name': fileName,
    'mime_type': mimeType,
    'file_size': fileSize,
  };
}

class ReplySummary {
  final String id;
  final String senderName;
  final String content;
  final String type;

  const ReplySummary({
    required this.id,
    required this.senderName,
    required this.content,
    required this.type,
  });

  factory ReplySummary.fromJson(Map<String, dynamic> json) {
    return ReplySummary(
      id: _extractId(json),
      senderName: (json['sender_name'] ?? json['senderName'] ?? 'สมาชิก')
          .toString(),
      content: (json['content'] ?? '').toString(),
      type: (json['type'] ?? 'text').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender_name': senderName,
    'content': content,
    'type': type,
  };
}

class PollOption {
  final String id;
  final String text;
  final List<String> voterIds;

  const PollOption({
    required this.id,
    required this.text,
    this.voterIds = const [],
  });

  factory PollOption.fromJson(Map<String, dynamic> json) {
    final raw = json['voter_ids'] ?? json['voterIds'];
    return PollOption(
      id: (json['id'] ?? '').toString(),
      text: (json['text'] ?? '').toString(),
      voterIds: raw is List ? raw.map((e) => e.toString()).toList() : const [],
    );
  }
}

class PollData {
  final String question;
  final List<PollOption> options;
  final bool allowMultiple;
  final bool isAnonymous;
  final bool isClosed;
  final String? closedAt;

  const PollData({
    required this.question,
    this.options = const [],
    this.allowMultiple = false,
    this.isAnonymous = false,
    this.isClosed = false,
    this.closedAt,
  });

  int get totalVotes => options.fold(0, (sum, o) => sum + o.voterIds.length);

  int get uniqueVotersCount =>
      options.expand((o) => o.voterIds).toSet().length;

  factory PollData.fromJson(Map<String, dynamic> json) {
    final rawOpts = json['options'];
    return PollData(
      question: (json['question'] ?? '').toString(),
      options: rawOpts is List
          ? rawOpts
                .whereType<Map>()
                .map((e) => PollOption.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      allowMultiple: _toBool(
        json['allow_multiple'] ?? json['allowMultiple'],
        false,
      ),
      isAnonymous: _toBool(json['is_anonymous'] ?? json['isAnonymous'], false),
      isClosed: _toBool(json['is_closed'] ?? json['isClosed'], false),
      closedAt: json['closed_at']?.toString(),
    );
  }
}

class EventData {
  final String title;
  final String description;
  final String startsAt;
  final String? endsAt;
  final String location;
  final List<String> goingIds;
  final List<String> maybeIds;
  final List<String> notGoingIds;

  const EventData({
    required this.title,
    this.description = '',
    required this.startsAt,
    this.endsAt,
    this.location = '',
    this.goingIds = const [],
    this.maybeIds = const [],
    this.notGoingIds = const [],
  });

  factory EventData.fromJson(Map<String, dynamic> json) {
    List<String> listOf(dynamic v) =>
        v is List ? v.map((e) => e.toString()).toList() : const [];
    return EventData(
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      startsAt: (json['starts_at'] ?? json['startsAt'] ?? '').toString(),
      endsAt: json['ends_at']?.toString() ?? json['endsAt']?.toString(),
      location: (json['location'] ?? '').toString(),
      goingIds: listOf(json['going_ids'] ?? json['goingIds']),
      maybeIds: listOf(json['maybe_ids'] ?? json['maybeIds']),
      notGoingIds: listOf(json['not_going_ids'] ?? json['notGoingIds']),
    );
  }
}

class LocationData {
  final double latitude;
  final double longitude;
  final String title;
  final String address;
  final String mapUrl;

  const LocationData({
    required this.latitude,
    required this.longitude,
    this.title = '',
    this.address = '',
    this.mapUrl = '',
  });

  String get resolvedMapUrl {
    final trimmed = mapUrl.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return 'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';
  }

  factory LocationData.fromJson(Map<String, dynamic> json) {
    final lat =
        double.tryParse((json['latitude'] ?? json['lat'] ?? 0).toString()) ??
        0.0;
    final lng =
        double.tryParse(
          (json['longitude'] ?? json['lng'] ?? json['lon'] ?? 0).toString(),
        ) ??
        0.0;
    final rawUrl = (json['map_url'] ?? json['mapUrl'] ?? '').toString().trim();
    return LocationData(
      latitude: lat,
      longitude: lng,
      title: (json['title'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
      mapUrl: rawUrl.isNotEmpty
          ? rawUrl
          : 'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    );
  }

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'title': title,
    'address': address,
    'map_url': resolvedMapUrl,
  };
}

class ContactCardData {
  final String userId;
  final String displayName;
  final String bcId;
  final String avatarUrl;
  final String statusMessage;

  const ContactCardData({
    required this.userId,
    required this.displayName,
    this.bcId = '',
    this.avatarUrl = '',
    this.statusMessage = '',
  });

  factory ContactCardData.fromJson(Map<String, dynamic> json) =>
      ContactCardData(
        userId: (json['user_id'] ?? json['userId'] ?? json['id'] ?? '')
            .toString(),
        displayName:
            (json['display_name'] ?? json['displayName'] ?? 'เพื่อน BC')
                .toString(),
        bcId: _normalizeBcId(json['bc_id'] ?? json['bcId']),
        avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? '').toString(),
        statusMessage:
            (json['status_message'] ?? json['statusMessage'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'display_name': displayName,
    'bc_id': bcId,
    'avatar_url': avatarUrl,
    'status_message': statusMessage,
  };
}

class LadderEntry {
  final String player;
  final String result;

  const LadderEntry({required this.player, required this.result});

  factory LadderEntry.fromJson(Map<String, dynamic> json) => LadderEntry(
    player: (json['player'] ?? '').toString(),
    result: (json['result'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {'player': player, 'result': result};
}

class LadderGameData {
  final String title;
  final List<LadderEntry> entries;

  const LadderGameData({required this.title, required this.entries});

  factory LadderGameData.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    final list = raw is List
        ? raw
              .whereType<Map>()
              .map((e) => LadderEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const <LadderEntry>[];
    return LadderGameData(
      title: (json['title'] ?? 'เกมสุ่มบันได').toString(),
      entries: list,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
}

class ChatMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final String senderName;
  final String senderAvatar;
  final String senderDepartment;
  final String type; // text | sticker | image | file | audio | rich_card | poll | event | location | contact | ladder | call_log | system
  final String content;
  final String? stickerCode;
  final AttachmentInfo? attachment;
  final Map<String, dynamic>? cardPayload;
  final ReplySummary? replyTo;
  final String? replyToId;
  final List<String> readBy;
  final int readCount;
  final bool isUnsent;
  final bool isConfidential;
  final String priority; // normal | urgent | silent
  final String? taskStatus; // open | accepted | done
  final String? acceptedBy;
  final String? acceptedAt;
  final Map<String, List<String>> reactions;
  final List<String> mentions;
  final int? audioDurationSec;
  final PollData? poll;
  final EventData? eventData;
  final LocationData? locationData;
  final ContactCardData? contactData;
  final LadderGameData? ladderData;
  final String? editedAt;
  final String? forwardedFrom;
  final String? expireAt;
  final String createdAt;

  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.senderAvatar,
    required this.senderDepartment,
    required this.type,
    required this.content,
    this.stickerCode,
    this.attachment,
    this.cardPayload,
    this.replyTo,
    this.replyToId,
    required this.readBy,
    required this.readCount,
    required this.isUnsent,
    this.isConfidential = false,
    this.priority = 'normal',
    this.taskStatus,
    this.acceptedBy,
    this.acceptedAt,
    this.reactions = const {},
    this.mentions = const [],
    this.audioDurationSec,
    this.poll,
    this.eventData,
    this.locationData,
    this.contactData,
    this.ladderData,
    this.editedAt,
    this.forwardedFrom,
    this.expireAt,
    required this.createdAt,
  });

  bool get isEdited => (editedAt ?? '').trim().isNotEmpty;
  bool get isForwarded => (forwardedFrom ?? '').trim().isNotEmpty;
  bool get isExpiring => (expireAt ?? '').trim().isNotEmpty;

  ChatMessage copyWith({
    String? content,
    String? editedAt,
    List<String>? readBy,
    int? readCount,
  }) => ChatMessage(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    senderName: senderName,
    senderAvatar: senderAvatar,
    senderDepartment: senderDepartment,
    type: type,
    content: content ?? this.content,
    stickerCode: stickerCode,
    attachment: attachment,
    cardPayload: cardPayload,
    replyTo: replyTo,
    replyToId: replyToId,
    readBy: readBy ?? this.readBy,
    readCount: readCount ?? this.readCount,
    isUnsent: isUnsent,
    isConfidential: isConfidential,
    priority: priority,
    taskStatus: taskStatus,
    acceptedBy: acceptedBy,
    acceptedAt: acceptedAt,
    reactions: reactions,
    mentions: mentions,
    audioDurationSec: audioDurationSec,
    poll: poll,
    eventData: eventData,
    locationData: locationData,
    contactData: contactData,
    ladderData: ladderData,
    editedAt: editedAt ?? this.editedAt,
    forwardedFrom: forwardedFrom,
    expireAt: expireAt,
    createdAt: createdAt,
  );

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawAttachment = json['attachment'];
    final rawCard = json['card_payload'] ?? json['cardPayload'];
    final rawReply = json['reply_to'] ?? json['replyTo'];
    final rawReadBy = json['read_by'] ?? json['readBy'];

    final readByList = rawReadBy is List
        ? rawReadBy.map((e) => e.toString()).toList()
        : <String>[];

    final cardMap = rawCard is Map<String, dynamic>
        ? rawCard
        : (rawCard is Map ? Map<String, dynamic>.from(rawCard) : null);

    final rawReactions = json['reactions'];
    final parsedReactions = <String, List<String>>{};
    if (rawReactions is Map) {
      for (final entry in rawReactions.entries) {
        if (entry.value is List) {
          parsedReactions[entry.key.toString()] = (entry.value as List)
              .map((e) => e.toString())
              .toList();
        }
      }
    }

    final rawMentions = json['mentions'];
    final mentionsList = rawMentions is List
        ? rawMentions.map((e) => e.toString()).toList()
        : const <String>[];

    final rawPoll = json['poll'];
    final parsedPoll = rawPoll is Map
        ? PollData.fromJson(Map<String, dynamic>.from(rawPoll))
        : null;

    final rawEvent = json['event_data'] ?? json['eventData'];
    final parsedEvent = rawEvent is Map
        ? EventData.fromJson(Map<String, dynamic>.from(rawEvent))
        : null;

    final senderName =
        (json['sender_name'] ?? json['senderName'] ?? 'ผู้ใช้งาน').toString();
    final rawContent = (json['content'] ?? '').toString();

    final confidentialFlag =
        _toBool(json['is_confidential'] ?? json['isConfidential'], false) ||
        _toBool(cardMap?['is_confidential'], false) ||
        rawContent.startsWith('[ลับส่วนตัว]') ||
        rawContent.startsWith('[ลับเฉพาะองค์กร]');

    final rawPriority =
        (json['priority'] ?? cardMap?['priority'] ?? 'normal').toString();
    final rawTaskStatus =
        (json['task_status'] ?? json['taskStatus'] ?? cardMap?['task_status'])
            ?.toString();
    final rawAcceptedBy =
        (json['accepted_by'] ?? json['acceptedBy'] ?? cardMap?['accepted_by'])
            ?.toString();
    final rawAcceptedAt =
        (json['accepted_at'] ?? json['acceptedAt'] ?? cardMap?['accepted_at'])
            ?.toString();

    final rawType = (json['type'] ?? json['message_type'] ?? 'text').toString();
    final normalizedType = rawType.endsWith('_card') && cardMap != null
        ? 'rich_card'
        : rawType;

    final rawAudioDur =
        json['audio_duration_sec'] ?? json['audioDurationSec'];

    final rawLoc = json['location_data'] ?? json['locationData'];
    final parsedLoc = rawLoc is Map
        ? LocationData.fromJson(Map<String, dynamic>.from(rawLoc))
        : null;

    final rawContact = json['contact_data'] ?? json['contactData'];
    final parsedContact = rawContact is Map
        ? ContactCardData.fromJson(Map<String, dynamic>.from(rawContact))
        : null;

    final rawLadder = json['ladder_data'] ?? json['ladderData'];
    final parsedLadder = rawLadder is Map
        ? LadderGameData.fromJson(Map<String, dynamic>.from(rawLadder))
        : null;

    final rawEditedAt =
        (json['edited_at'] ?? json['editedAt'])?.toString().trim();
    final rawForwardedFrom =
        (json['forwarded_from'] ?? json['forwardedFrom'])?.toString().trim();
    final rawExpireAt =
        (json['expire_at'] ?? json['expireAt'])?.toString().trim();

    return ChatMessage(
      id: _extractId(json),
      conversationId:
          (json['conversation_id'] ?? json['conversationId'] ?? '').toString(),
      senderId: (json['sender_id'] ?? json['senderId'] ?? '').toString(),
      senderName: senderName,
      senderAvatar:
          (json['sender_avatar'] ?? json['senderAvatar'] ?? '').toString(),
      senderDepartment: inferDepartment(
        rawDepartment:
            (json['sender_department'] ?? json['senderDepartment'])?.toString(),
        name: senderName,
      ),
      type: normalizedType,
      content: rawContent,
      stickerCode: json['sticker_code']?.toString(),
      attachment: rawAttachment is Map<String, dynamic>
          ? AttachmentInfo.fromJson(rawAttachment)
          : (rawAttachment is Map
                ? AttachmentInfo.fromJson(
                    Map<String, dynamic>.from(rawAttachment),
                  )
                : null),
      cardPayload: cardMap,
      replyTo: rawReply is Map<String, dynamic>
          ? ReplySummary.fromJson(rawReply)
          : (rawReply is Map
                ? ReplySummary.fromJson(Map<String, dynamic>.from(rawReply))
                : null),
      replyToId: json['reply_to_id']?.toString(),
      readBy: readByList,
      readCount: _toInt(
        json['read_count'] ?? json['readCount'],
        readByList.length > 1 ? readByList.length - 1 : 0,
      ),
      isUnsent: _toBool(json['is_unsent'] ?? json['isUnsent'], false),
      isConfidential: confidentialFlag,
      priority: rawPriority.isEmpty ? 'normal' : rawPriority,
      taskStatus: rawTaskStatus,
      acceptedBy: rawAcceptedBy,
      acceptedAt: rawAcceptedAt,
      reactions: parsedReactions,
      mentions: mentionsList,
      audioDurationSec: rawAudioDur != null ? _toInt(rawAudioDur) : null,
      poll: parsedPoll,
      eventData: parsedEvent,
      locationData: parsedLoc,
      contactData: parsedContact,
      ladderData: parsedLadder,
      editedAt: (rawEditedAt != null && rawEditedAt.isNotEmpty)
          ? rawEditedAt
          : null,
      forwardedFrom:
          (rawForwardedFrom != null && rawForwardedFrom.isNotEmpty)
          ? rawForwardedFrom
          : null,
      expireAt: (rawExpireAt != null && rawExpireAt.isNotEmpty)
          ? rawExpireAt
          : null,
      createdAt: (json['created_at'] ?? json['createdAt'] ?? '').toString(),
    );
  }

  String get cleanContent {
    for (final tag in const ['[ลับส่วนตัว] ', '[ลับส่วนตัว]', '[ลับเฉพาะองค์กร] ', '[ลับเฉพาะองค์กร]']) {
      if (content.startsWith(tag)) {
        return content.substring(tag.length).trimLeft();
      }
    }
    return content;
  }

  String get previewText {
    if (isUnsent) return 'ยกเลิกข้อความและลบข้อมูลแล้ว';
    final prefix = isConfidential ? '🔒 [ลับส่วนตัว] ' : '';
    switch (type) {
      case 'sticker':
        return '$prefix[สติ๊กเกอร์] $cleanContent';
      case 'image':
        return '$prefix[รูปภาพ] ${attachment?.fileName ?? cleanContent}';
      case 'file':
        return '$prefix[ไฟล์เอกสาร] ${attachment?.fileName ?? cleanContent}';
      case 'audio':
        final dur = audioDurationSec != null && audioDurationSec! > 0
            ? ' (${audioDurationSec}s)'
            : '';
        return '$prefix[ข้อความเสียง]$dur';
      case 'rich_card':
        final title = cardPayload?['title']?.toString() ?? cleanContent;
        return '$prefix[การ์ดโต้ตอบ] $title';
      case 'poll':
        final q = poll?.question ?? cleanContent;
        return '$prefix[โพล] $q';
      case 'event':
        final t = eventData?.title ?? cleanContent;
        return '$prefix[นัดหมาย] $t';
      case 'location':
        final locTitle = locationData?.title.trim() ?? '';
        final label = locTitle.isNotEmpty
            ? locTitle
            : (cleanContent.isNotEmpty ? cleanContent : 'ตำแหน่งที่ตั้ง');
        return '$prefix📍 $label';
      case 'contact':
        final name = contactData?.displayName.trim() ?? '';
        final label = name.isNotEmpty ? name : cleanContent;
        return '$prefix👤 แนะนำเพื่อน: $label';
      case 'ladder':
        final gameTitle = ladderData?.title.trim() ?? '';
        final label = gameTitle.isNotEmpty ? gameTitle : cleanContent;
        return '$prefix🎲 เกมสุ่มบันได: $label';
      case 'call_log':
        final callType = (cardPayload?['call_type'] ?? 'audio').toString();
        final status = (cardPayload?['status'] ?? 'ended').toString();
        final dur = _toInt(cardPayload?['duration_sec'], 0);
        final kindLabel = callType == 'video' ? 'วิดีโอคอล' : 'โทรด้วยเสียง';
        if (status == 'missed') return '$prefix[$kindLabel - ไม่ได้รับสาย]';
        if (status == 'declined') return '$prefix[$kindLabel - ปฏิเสธสาย]';
        if (dur > 0) {
          final mins = dur ~/ 60;
          final secs = dur % 60;
          final durText = mins > 0
              ? '$mins:${secs.toString().padLeft(2, '0')} นาที'
              : '$secs วินาที';
          return '$prefix[$kindLabel $durText]';
        }
        return '$prefix[$kindLabel]';
      default:
        return '$prefix$cleanContent';
    }
  }
}

class OaRichMenuItem {
  final String id;
  final String label;
  final String subtitle;
  final String actionType; // keyword | coupon | url | ai_prompt
  final String actionValue;
  final String icon;

  const OaRichMenuItem({
    required this.id,
    required this.label,
    this.subtitle = '',
    this.actionType = 'keyword',
    this.actionValue = '',
    this.icon = 'sparkles',
  });

  factory OaRichMenuItem.fromJson(Map<String, dynamic> json) => OaRichMenuItem(
    id: (json['id'] ?? json['_id'] ?? '').toString(),
    label: (json['label'] ?? '').toString(),
    subtitle: (json['subtitle'] ?? '').toString(),
    actionType: (json['action_type'] ?? json['actionType'] ?? 'keyword')
        .toString(),
    actionValue: (json['action_value'] ?? json['actionValue'] ?? '').toString(),
    icon: (json['icon'] ?? 'sparkles').toString(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'subtitle': subtitle,
    'action_type': actionType,
    'action_value': actionValue,
    'icon': icon,
  };
}

class Conversation {
  final String id;
  final String kind; // direct | group | official | oa
  final String name;
  final String avatarUrl;
  final String folder; // personal | work | official | oa
  final bool isPinned;
  final bool isMuted;
  final String? mutedUntil;
  final bool isBlockedByMe;
  final bool isArchived;
  final String inviteToken;
  final String? oaId;
  final String? oaHandle;
  final List<OaRichMenuItem> richMenu;
  final List<String> adminIds;
  final List<String> memberIds;
  final int memberCount;
  final int unreadCount;
  final ChatMessage? pinnedMessage;
  final ChatMessage? lastMessage;
  final AppUser? peerUser;
  final String updatedAt;

  const Conversation({
    required this.id,
    required this.kind,
    required this.name,
    required this.avatarUrl,
    required this.folder,
    required this.isPinned,
    this.isMuted = false,
    this.mutedUntil,
    this.isBlockedByMe = false,
    this.isArchived = false,
    this.inviteToken = '',
    this.oaId,
    this.oaHandle,
    this.richMenu = const [],
    this.adminIds = const [],
    required this.memberIds,
    required this.memberCount,
    required this.unreadCount,
    this.pinnedMessage,
    this.lastMessage,
    this.peerUser,
    required this.updatedAt,
  });

  bool get isEffectivelyMuted {
    if (isMuted) return true;
    final raw = mutedUntil?.trim() ?? '';
    if (raw.isEmpty) return false;
    final dt = DateTime.tryParse(raw);
    return dt != null && dt.toUtc().isAfter(DateTime.now().toUtc());
  }

  DateTime? get mutedUntilDate {
    final raw = mutedUntil?.trim() ?? '';
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  Conversation copyWith({
    bool? isPinned,
    bool? isMuted,
    String? mutedUntil,
    bool clearMutedUntil = false,
    bool? isBlockedByMe,
    bool? isArchived,
    int? unreadCount,
  }) => Conversation(
    id: id,
    kind: kind,
    name: name,
    avatarUrl: avatarUrl,
    folder: folder,
    isPinned: isPinned ?? this.isPinned,
    isMuted: isMuted ?? this.isMuted,
    mutedUntil: clearMutedUntil ? null : (mutedUntil ?? this.mutedUntil),
    isBlockedByMe: isBlockedByMe ?? this.isBlockedByMe,
    isArchived: isArchived ?? this.isArchived,
    inviteToken: inviteToken,
    oaId: oaId,
    oaHandle: oaHandle,
    richMenu: richMenu,
    adminIds: adminIds,
    memberIds: memberIds,
    memberCount: memberCount,
    unreadCount: unreadCount ?? this.unreadCount,
    pinnedMessage: pinnedMessage,
    lastMessage: lastMessage,
    peerUser: peerUser,
    updatedAt: updatedAt,
  );

  bool get isGroup => kind == 'group';
  bool get isKeep => kind == 'keep';
  bool get isOfficial => kind == 'official' || folder == 'official';
  bool get isOa => kind == 'oa' || (oaId != null && oaId!.isNotEmpty);
  bool get isFamily => folder == 'family' || folder == 'work';
  bool get isWork => isFamily;

  String get folderLabel {
    if (isArchived || folder == 'archived') return 'เก็บถาวร';
    if (isKeep) return 'Keep ส่วนตัว';
    if (isOa) return 'ร้านค้า';
    switch (folder) {
      case 'family':
      case 'work':
        return 'ครอบครัว';
      case 'official':
        return 'ข่าวสารแอป';
      default:
        return 'ส่วนตัว';
    }
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['member_ids'] ?? json['memberIds'];
    final members = rawMembers is List
        ? rawMembers.map((e) => e.toString()).toList()
        : <String>[];

    final rawPinned = json['pinned_message'] ?? json['pinnedMessage'];
    final rawLast = json['last_message'] ?? json['lastMessage'];
    final rawPeer = json['peer_user'] ?? json['peerUser'];

    final rawAdmins = json['admin_ids'] ?? json['adminIds'];
    final adminList = rawAdmins is List
        ? rawAdmins.map((e) => e.toString()).toList()
        : const <String>[];

    final rawMenu = json['rich_menu'] ?? json['richMenu'];
    final menuList = rawMenu is List
        ? rawMenu
              .whereType<Map>()
              .map((e) => OaRichMenuItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const <OaRichMenuItem>[];

    final rawOaId = (json['oa_id'] ?? json['oaId'])?.toString().trim() ?? '';
    final rawOaHandle =
        (json['oa_handle'] ?? json['oaHandle'])?.toString().trim() ?? '';
    final rawMutedUntil =
        (json['muted_until'] ?? json['mutedUntil'])?.toString().trim() ?? '';

    return Conversation(
      id: _extractId(json),
      kind: (json['kind'] ?? json['type'] ?? 'direct').toString(),
      name: (json['name'] ?? json['title'] ?? 'ห้องสนทนา').toString(),
      avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? '').toString(),
      folder: (json['folder'] ?? 'personal').toString(),
      isPinned: _toBool(json['is_pinned'] ?? json['isPinned'], false),
      isMuted: _toBool(json['is_muted'] ?? json['isMuted'], false),
      mutedUntil: rawMutedUntil.isEmpty ? null : rawMutedUntil,
      isBlockedByMe: _toBool(
        json['is_blocked_by_me'] ?? json['isBlockedByMe'],
        false,
      ),
      isArchived: _toBool(json['is_archived'] ?? json['isArchived'], false),
      inviteToken:
          (json['invite_token'] ?? json['inviteToken'] ?? '').toString(),
      oaId: rawOaId.isEmpty ? null : rawOaId,
      oaHandle: rawOaHandle.isEmpty ? null : rawOaHandle,
      richMenu: menuList,
      adminIds: adminList,
      memberIds: members,
      memberCount: _toInt(
        json['member_count'] ?? json['memberCount'],
        members.isNotEmpty ? members.length : 2,
      ),
      unreadCount: _toInt(json['unread_count'] ?? json['unreadCount'], 0),
      pinnedMessage: rawPinned is Map<String, dynamic>
          ? ChatMessage.fromJson(rawPinned)
          : (rawPinned is Map
                ? ChatMessage.fromJson(Map<String, dynamic>.from(rawPinned))
                : null),
      lastMessage: rawLast is Map<String, dynamic>
          ? ChatMessage.fromJson(rawLast)
          : (rawLast is Map
                ? ChatMessage.fromJson(Map<String, dynamic>.from(rawLast))
                : null),
      peerUser: rawPeer is Map<String, dynamic>
          ? AppUser.fromJson(rawPeer)
          : (rawPeer is Map
                ? AppUser.fromJson(Map<String, dynamic>.from(rawPeer))
                : null),
      updatedAt: (json['updated_at'] ?? json['updatedAt'] ?? '').toString(),
    );
  }
}

class VaultData {
  final List<ChatMessage> images;
  final List<ChatMessage> files;
  final List<ChatMessage> links;

  const VaultData({
    required this.images,
    required this.files,
    required this.links,
  });

  factory VaultData.fromJson(Map<String, dynamic> json) {
    List<ChatMessage> parseList(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    return VaultData(
      images: parseList(json['images']),
      files: parseList(json['files']),
      links: parseList(json['links']),
    );
  }
}

class MiniAppItem {
  final String id;
  final String code;
  final String title;
  final String subtitle;
  final String category;
  final String icon;
  final String color;
  final String url;
  final bool enabled;

  const MiniAppItem({
    required this.id,
    required this.code,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.icon,
    required this.color,
    required this.url,
    required this.enabled,
  });

  factory MiniAppItem.fromJson(Map<String, dynamic> json) {
    return MiniAppItem(
      id: _extractId(json),
      code: (json['code'] ?? 'custom_app').toString(),
      title: (json['title'] ?? json['name'] ?? 'Mini-App').toString(),
      subtitle:
          (json['subtitle'] ?? json['description'] ?? 'บริการเสริม BC Ai Chat')
              .toString(),
      category: (json['category'] ?? 'ไลฟ์สไตล์ & เพื่อน').toString(),
      icon: (json['icon'] ?? 'widgets').toString(),
      color: (json['color'] ?? '#812920').toString(),
      url: (json['url'] ?? '').toString(),
      enabled: _toBool(json['enabled'] ?? json['is_enabled'], true),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'code': code,
    'title': title,
    'subtitle': subtitle,
    'category': category,
    'icon': icon,
    'color': color,
    'url': url,
    'enabled': enabled,
  };
}

class NoteComment {
  final String id;
  final String userId;
  final String userName;
  final String content;
  final String createdAt;

  const NoteComment({
    required this.id,
    required this.userId,
    required this.userName,
    required this.content,
    required this.createdAt,
  });

  factory NoteComment.fromJson(Map<String, dynamic> json) {
    return NoteComment(
      id: (json['id'] ?? '').toString(),
      userId: (json['user_id'] ?? json['userId'] ?? '').toString(),
      userName: (json['user_name'] ?? json['userName'] ?? 'สมาชิก').toString(),
      content: (json['content'] ?? '').toString(),
      createdAt: (json['created_at'] ?? json['createdAt'] ?? '').toString(),
    );
  }
}

class NoteItem {
  final String id;
  final String userId;
  final String ownerName;
  final String? conversationId;
  final String title;
  final String content;
  final String category;
  final String color;
  final bool isPinned;
  final List<String> likedBy;
  final List<NoteComment> comments;
  final List<AttachmentInfo> attachments;
  final AttachmentInfo? attachment;
  final String createdAt;

  const NoteItem({
    required this.id,
    required this.userId,
    this.ownerName = '',
    this.conversationId,
    required this.title,
    required this.content,
    required this.category,
    required this.color,
    this.isPinned = false,
    this.likedBy = const [],
    this.comments = const [],
    this.attachments = const [],
    this.attachment,
    required this.createdAt,
  });

  factory NoteItem.fromJson(Map<String, dynamic> json) {
    final rawAtt = json['attachment'];
    final rawAtts = json['attachments'];
    final atts = rawAtts is List
        ? rawAtts
              .whereType<Map>()
              .map((e) => AttachmentInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const <AttachmentInfo>[];
    final singleAtt = rawAtt is Map
        ? AttachmentInfo.fromJson(Map<String, dynamic>.from(rawAtt))
        : (atts.isNotEmpty ? atts.first : null);
    final rawLikes = json['liked_by'] ?? json['likedBy'];
    final rawComments = json['comments'];
    return NoteItem(
      id: _extractId(json),
      userId:
          (json['user_id'] ?? json['userId'] ?? json['owner_id'] ?? '')
              .toString(),
      ownerName: (json['owner_name'] ?? json['ownerName'] ?? '').toString(),
      conversationId: json['conversation_id']?.toString(),
      title: (json['title'] ?? 'บันทึกสำคัญ').toString(),
      content: (json['content'] ?? '').toString(),
      category: (json['category'] ?? 'ทั่วไป').toString(),
      color: (json['color'] ?? '#812920').toString(),
      isPinned: _toBool(json['is_pinned'] ?? json['isPinned'], false),
      likedBy: rawLikes is List
          ? rawLikes.map((e) => e.toString()).toList()
          : const [],
      comments: rawComments is List
          ? rawComments
                .whereType<Map>()
                .map((e) => NoteComment.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      attachments: atts,
      attachment: singleAtt,
      createdAt: (json['created_at'] ?? json['createdAt'] ?? '').toString(),
    );
  }
}

class AlbumItem {
  final String id;
  final String conversationId;
  final String title;
  final String description;
  final List<AttachmentInfo> photos;
  final String createdBy;
  final String createdByName;
  final String createdAt;
  final String updatedAt;

  const AlbumItem({
    required this.id,
    required this.conversationId,
    required this.title,
    this.description = '',
    this.photos = const [],
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AlbumItem.fromJson(Map<String, dynamic> json) {
    final rawPhotos = json['photos'];
    return AlbumItem(
      id: _extractId(json),
      conversationId:
          (json['conversation_id'] ?? json['conversationId'] ?? '').toString(),
      title: (json['title'] ?? 'อัลบั้มรูปภาพ').toString(),
      description: (json['description'] ?? '').toString(),
      photos: rawPhotos is List
          ? rawPhotos
                .whereType<Map>()
                .map(
                  (e) => AttachmentInfo.fromJson(Map<String, dynamic>.from(e)),
                )
                .toList()
          : const [],
      createdBy: (json['created_by'] ?? json['createdBy'] ?? '').toString(),
      createdByName:
          (json['created_by_name'] ?? json['createdByName'] ?? '').toString(),
      createdAt: (json['created_at'] ?? json['createdAt'] ?? '').toString(),
      updatedAt: (json['updated_at'] ?? json['updatedAt'] ?? '').toString(),
    );
  }
}

class AdminOverview {
  final int totalUsers;
  final int totalConversations;
  final int totalMessages;
  final int totalFiles;
  final int totalStorageBytes;
  final int totalMiniApps;
  final String minioBucket;
  final String mongoDb;

  const AdminOverview({
    required this.totalUsers,
    required this.totalConversations,
    required this.totalMessages,
    required this.totalFiles,
    required this.totalStorageBytes,
    required this.totalMiniApps,
    required this.minioBucket,
    required this.mongoDb,
  });

  factory AdminOverview.fromJson(Map<String, dynamic> json) {
    return AdminOverview(
      totalUsers: _toInt(json['total_users'] ?? json['users_count']),
      totalConversations: _toInt(
        json['total_conversations'] ?? json['conversations_count'],
      ),
      totalMessages: _toInt(json['total_messages'] ?? json['messages_count']),
      totalFiles: _toInt(json['total_files'] ?? json['files_count']),
      totalStorageBytes: _toInt(
        json['total_storage_bytes'] ?? json['storage_bytes'],
      ),
      totalMiniApps: _toInt(json['total_mini_apps'] ?? json['mini_apps_count']),
      minioBucket: (json['minio_bucket'] ?? 'bcaichat-storage').toString(),
      mongoDb: (json['mongo_db'] ?? 'bcaichat (127.0.0.1:27030)').toString(),
    );
  }
}

class AiSummaryResult {
  final String summary;
  final List<String> actionItems;
  final List<String> decisions;
  final String model;

  const AiSummaryResult({
    required this.summary,
    required this.actionItems,
    required this.decisions,
    required this.model,
  });

  factory AiSummaryResult.fromJson(Map<String, dynamic> json) {
    List<String> toStrList(dynamic raw) {
      if (raw is List) {
        return raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      return const [];
    }

    final rawSummary =
        (json['summary'] ??
                json['executive_summary'] ??
                json['result'] ??
                json['content'] ??
                '')
            .toString()
            .trim();

    var actions = toStrList(json['action_items'] ?? json['actionItems']);
    var decisions = toStrList(json['decisions'] ?? json['key_decisions']);

    if (actions.isEmpty && rawSummary.isNotEmpty) {
      final lines = rawSummary
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.startsWith('- ') || l.startsWith('• '))
          .map((l) => l.substring(2).trim())
          .toList();
      if (lines.isNotEmpty) {
        actions = lines.take(4).toList();
      }
    }

    return AiSummaryResult(
      summary: rawSummary.isNotEmpty
          ? rawSummary
          : 'สรุปผลการสนทนาในห้องแชทเรียบร้อยแล้ว',
      actionItems: actions,
      decisions: decisions,
      model: (json['model'] ?? 'deepseek-chat').toString(),
    );
  }

  String toFormattedNote() {
    final buf = StringBuffer();
    buf.writeln('✨ สรุปแชทโดยสมองกล DeepSeek AI ($model)');
    buf.writeln('📌 สรุปประเด็นสำคัญ:');
    buf.writeln(summary);
    if (actionItems.isNotEmpty) {
      buf.writeln('\n✅ สิ่งที่ต้องทำต่อ:');
      for (final item in actionItems) {
        buf.writeln('• $item');
      }
    }
    if (decisions.isNotEmpty) {
      buf.writeln('\n💡 ข้อตกลงและการตัดสินใจ:');
      for (final d in decisions) {
        buf.writeln('• $d');
      }
    }
    return buf.toString().trim();
  }
}

class AiAssistResult {
  final String suggestion;
  final List<String> alternatives;
  final String mode;
  final String model;

  const AiAssistResult({
    required this.suggestion,
    required this.alternatives,
    required this.mode,
    required this.model,
  });

  factory AiAssistResult.fromJson(Map<String, dynamic> json) {
    final mainText =
        (json['suggestion'] ??
                json['result'] ??
                json['content'] ??
                json['reply'] ??
                json['text'] ??
                '')
            .toString()
            .trim();
    final rawAlt = json['alternatives'] ?? json['options'] ?? json['suggestions'];
    final altList = rawAlt is List
        ? rawAlt
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];

    return AiAssistResult(
      suggestion: mainText,
      alternatives: altList,
      mode: (json['mode'] ?? 'polite').toString(),
      model: (json['model'] ?? 'deepseek-chat').toString(),
    );
  }
}

class AiAdminSettings {
  final String model;
  final String maskedKey;
  final bool hasKey;
  final String systemPrompt;
  final bool enabled;

  const AiAdminSettings({
    required this.model,
    required this.maskedKey,
    required this.hasKey,
    required this.systemPrompt,
    required this.enabled,
  });

  factory AiAdminSettings.fromJson(Map<String, dynamic> json) {
    final masked =
        (json['masked_key'] ?? json['api_key_masked'] ?? json['maskedKey'] ?? '')
            .toString();
    return AiAdminSettings(
      model: (json['model'] ?? 'deepseek-chat').toString(),
      maskedKey: masked.isNotEmpty ? masked : 'ตั้งค่าผ่านระบบหลังบ้าน',
      hasKey: _toBool(
        json['has_key'] ?? json['hasKey'] ?? json['configured'],
        masked.isNotEmpty,
      ),
      systemPrompt:
          (json['system_prompt'] ??
                  json['systemPrompt'] ??
                  'คุณคือ BC AI ผู้ช่วยส่วนตัวประจำทุกห้องแชทของ BC Ai Chat ช่วยคิดคำตอบ เกลาข้อความ สรุปนัดหมาย และช่วยวางแผนกับครอบครัวและเพื่อนๆ อย่างเป็นกันเอง')
              .toString(),
      enabled: _toBool(json['enabled'], true),
    );
  }
}

class QuickTestUser {
  final int slot;
  final String id;
  final String displayName;
  final String bcId;
  final String phone;
  final String role;
  final String badge;

  const QuickTestUser({
    required this.slot,
    required this.id,
    required this.displayName,
    this.bcId = '',
    this.phone = '',
    this.role = 'user',
    this.badge = '',
  });

  factory QuickTestUser.fromJson(Map<String, dynamic> json) => QuickTestUser(
    slot: _toInt(json['slot'], 0),
    id: _extractId(json),
    displayName:
        (json['display_name'] ?? json['displayName'] ?? '').toString(),
    bcId: _normalizeBcId(json['bc_id'] ?? json['bcId']),
    phone: (json['phone'] ?? '').toString(),
    role: (json['role'] ?? 'user').toString(),
    badge: (json['badge'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'slot': slot,
    'id': id,
    'display_name': displayName,
    'bc_id': bcId,
    'phone': phone,
    'role': role,
    'badge': badge,
  };
}

class AuthConfig {
  final bool phoneOtpEnabled;
  final bool phoneOtpReady;
  final bool googleEnabled;
  final String googleClientId;
  final bool adminBootstrapEnabled;
  final bool livekitEnabled;
  final bool demoEnabled;
  final bool testUsersEnabled;
  final List<QuickTestUser> testUsers;

  const AuthConfig({
    this.phoneOtpEnabled = true,
    this.phoneOtpReady = false,
    this.googleEnabled = false,
    this.googleClientId = '',
    this.adminBootstrapEnabled = false,
    this.livekitEnabled = false,
    this.demoEnabled = false,
    this.testUsersEnabled = false,
    this.testUsers = const [],
  });

  factory AuthConfig.fromJson(Map<String, dynamic> json) {
    final rawTestUsers = json['test_users'] ?? json['testUsers'];
    final parsedTestUsers = rawTestUsers is List
        ? rawTestUsers
              .whereType<Map>()
              .map((e) => QuickTestUser.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const <QuickTestUser>[];
    return AuthConfig(
      phoneOtpEnabled: _toBool(
        json['phone_otp_enabled'] ?? json['phoneOtpEnabled'],
        true,
      ),
      phoneOtpReady: _toBool(
        json['phone_otp_ready'] ?? json['phoneOtpReady'],
        false,
      ),
      googleEnabled: _toBool(
        json['google_enabled'] ?? json['googleEnabled'],
        false,
      ),
      googleClientId:
          (json['google_client_id'] ?? json['googleClientId'] ?? '').toString(),
      adminBootstrapEnabled: _toBool(
        json['admin_bootstrap_enabled'] ?? json['adminBootstrapEnabled'],
        false,
      ),
      livekitEnabled: _toBool(
        json['livekit_enabled'] ?? json['livekitEnabled'],
        false,
      ),
      demoEnabled: _toBool(json['demo_enabled'] ?? json['demoEnabled'], false),
      testUsersEnabled: _toBool(
        json['test_users_enabled'] ?? json['testUsersEnabled'],
        false,
      ),
      testUsers: parsedTestUsers,
    );
  }
}

class OtpRequestResult {
  final String challengeId;
  final String refCode;
  final String maskedPhone;
  final int expiresInSec;

  const OtpRequestResult({
    required this.challengeId,
    required this.refCode,
    required this.maskedPhone,
    this.expiresInSec = 300,
  });

  factory OtpRequestResult.fromJson(Map<String, dynamic> json) =>
      OtpRequestResult(
        challengeId:
            (json['challenge_id'] ?? json['challengeId'] ?? '').toString(),
        refCode: (json['ref_code'] ?? json['refCode'] ?? '').toString(),
        maskedPhone:
            (json['masked_phone'] ?? json['maskedPhone'] ?? '').toString(),
        expiresInSec: _toInt(
          json['expires_in_sec'] ?? json['expiresInSec'],
          300,
        ),
      );
}

class AuthResult {
  final String token;
  final AppUser user;
  final bool isNewUser;

  const AuthResult({
    required this.token,
    required this.user,
    this.isNewUser = false,
  });
}

class GoogleOAuthPollResult {
  final String status; // pending | completed | verified_for_recovery | error | not_found
  final String mode;
  final String token;
  final AppUser? user;
  final String oauthState;
  final String email;
  final String error;

  const GoogleOAuthPollResult({
    required this.status,
    this.mode = 'login',
    this.token = '',
    this.user,
    this.oauthState = '',
    this.email = '',
    this.error = '',
  });

  factory GoogleOAuthPollResult.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    return GoogleOAuthPollResult(
      status: (json['status'] ?? 'pending').toString(),
      mode: (json['mode'] ?? 'login').toString(),
      token: (json['token'] ?? '').toString(),
      user: rawUser is Map
          ? AppUser.fromJson(Map<String, dynamic>.from(rawUser))
          : null,
      oauthState: (json['oauth_state'] ?? json['oauthState'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      error: (json['error'] ?? '').toString(),
    );
  }
}

class RecoverySetupResult {
  final AppUser user;
  final List<String> backupCodes;

  const RecoverySetupResult({
    required this.user,
    this.backupCodes = const [],
  });
}

class RecoveryLogDto {
  final String id;
  final String userId;
  final String action;
  final String method;
  final String detailMasked;
  final String createdAt;

  const RecoveryLogDto({
    required this.id,
    required this.userId,
    required this.action,
    required this.method,
    this.detailMasked = '',
    this.createdAt = '',
  });

  String get actionLabel {
    switch (action) {
      case 'link_phone':
        return 'เชื่อมเบอร์โทร';
      case 'change_phone':
        return 'เปลี่ยนเบอร์โทร';
      case 'link_google':
        return 'เชื่อม Gmail';
      case 'change_google':
        return 'เปลี่ยน Gmail';
      case 'unlink_google':
        return 'ยกเลิกเชื่อม Gmail';
      case 'setup_recovery_pin':
        return 'ตั้งค่า PIN กู้คืนบัญชี';
      case 'recover_change_phone':
        return 'กู้คืน & เปลี่ยนเบอร์โทร';
      case 'recover_change_google':
        return 'กู้คืน & เปลี่ยน Gmail';
      default:
        return action;
    }
  }

  factory RecoveryLogDto.fromJson(Map<String, dynamic> json) => RecoveryLogDto(
    id: _extractId(json),
    userId: (json['user_id'] ?? json['userId'] ?? '').toString(),
    action: (json['action'] ?? '').toString(),
    method: (json['method'] ?? '').toString(),
    detailMasked: (json['detail_masked'] ?? json['detailMasked'] ?? '')
        .toString(),
    createdAt: (json['created_at'] ?? json['createdAt'] ?? '').toString(),
  );
}

class AuthSettingsDto {
  final bool smsmktHasKeys;
  final String smsmktMaskedApiKey;
  final String smsmktMaskedSecretKey;
  final String smsmktProjectKey;
  final bool phoneOtpReady;
  final String googleClientId;
  final bool googleEnabled;
  final Map<String, dynamic>? creditInfo;
  final String? creditError;
  final String updatedAt;

  const AuthSettingsDto({
    this.smsmktHasKeys = false,
    this.smsmktMaskedApiKey = '',
    this.smsmktMaskedSecretKey = '',
    this.smsmktProjectKey = '',
    this.phoneOtpReady = false,
    this.googleClientId = '',
    this.googleEnabled = false,
    this.creditInfo,
    this.creditError,
    this.updatedAt = '',
  });

  factory AuthSettingsDto.fromJson(Map<String, dynamic> json) {
    final rawCredit = json['credit_info'];
    return AuthSettingsDto(
      smsmktHasKeys: _toBool(json['smsmkt_has_keys'], false),
      smsmktMaskedApiKey: (json['smsmkt_masked_api_key'] ?? '').toString(),
      smsmktMaskedSecretKey:
          (json['smsmkt_masked_secret_key'] ?? '').toString(),
      smsmktProjectKey: (json['smsmkt_project_key'] ?? '').toString(),
      phoneOtpReady: _toBool(json['phone_otp_ready'], false),
      googleClientId: (json['google_client_id'] ?? '').toString(),
      googleEnabled: _toBool(json['google_enabled'], false),
      creditInfo: rawCredit is Map
          ? Map<String, dynamic>.from(rawCredit)
          : null,
      creditError: json['credit_error']?.toString(),
      updatedAt: (json['updated_at'] ?? '').toString(),
    );
  }
}

class OaStaffMemberDto {
  final String userId;
  final String displayName;
  final String bcId;
  final String phone;
  final String email;
  final String avatarUrl;
  final String role; // owner | admin | agent | marketer

  const OaStaffMemberDto({
    required this.userId,
    required this.displayName,
    this.bcId = '',
    this.phone = '',
    this.email = '',
    this.avatarUrl = '',
    this.role = 'agent',
  });

  factory OaStaffMemberDto.fromJson(Map<String, dynamic> json) =>
      OaStaffMemberDto(
        userId: (json['user_id'] ?? json['userId'] ?? json['id'] ?? '')
            .toString(),
        displayName:
            (json['display_name'] ?? json['displayName'] ?? '').toString(),
        bcId: _normalizeBcId(json['bc_id'] ?? json['bcId']),
        phone: (json['phone'] ?? '').toString(),
        email: (json['email'] ?? '').toString(),
        avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? '').toString(),
        role: (json['role'] ?? 'agent').toString(),
      );
}

class OaAccountDto {
  final String id;
  final String handle;
  final String displayName;
  final String category;
  final String bio;
  final String avatarUrl;
  final String themeColor;
  final String greetingMessage;
  final String businessHours;
  final String ownerId;
  final List<String> adminIds;
  final String? myRole; // owner | admin | agent | marketer
  final Map<String, String> staffRoles;
  final String botUserId;
  final bool isVerified;
  final bool isActive;
  final bool aiEnabled;
  final String aiKnowledgePrompt;
  final bool callsEnabled;
  final List<OaRichMenuItem> richMenu;
  final int followerCount;
  final bool isFollowing;
  final String? conversationId;
  final String createdAt;
  final String updatedAt;

  const OaAccountDto({
    required this.id,
    required this.handle,
    required this.displayName,
    this.category = 'ร้านค้า / บริการ',
    this.bio = '',
    this.avatarUrl = '',
    this.themeColor = '#812920',
    this.greetingMessage = '',
    this.businessHours = '',
    this.ownerId = '',
    this.adminIds = const [],
    this.myRole,
    this.staffRoles = const {},
    this.botUserId = '',
    this.isVerified = false,
    this.isActive = true,
    this.aiEnabled = false,
    this.aiKnowledgePrompt = '',
    this.callsEnabled = true,
    this.richMenu = const [],
    this.followerCount = 0,
    this.isFollowing = false,
    this.conversationId,
    this.createdAt = '',
    this.updatedAt = '',
  });

  String effectiveRole(String userId) {
    if (myRole != null && myRole!.isNotEmpty) return myRole!;
    if (userId.isEmpty) return '';
    if (ownerId == userId) return 'owner';
    final mapped = staffRoles[userId];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    if (adminIds.contains(userId)) return 'admin';
    return '';
  }

  bool canManage(String userId) => effectiveRole(userId).isNotEmpty;

  bool canEditProfile(String userId) {
    final r = effectiveRole(userId);
    return r == 'owner' || r == 'admin';
  }

  bool canEditRichMenu(String userId) {
    final r = effectiveRole(userId);
    return r == 'owner' || r == 'admin' || r == 'marketer';
  }

  bool canHandleChats(String userId) {
    final r = effectiveRole(userId);
    return r == 'owner' || r == 'admin' || r == 'agent';
  }

  bool canDoMarketing(String userId) {
    final r = effectiveRole(userId);
    return r == 'owner' || r == 'admin' || r == 'marketer';
  }

  bool canManageTeam(String userId) {
    final r = effectiveRole(userId);
    return r == 'owner' || r == 'admin';
  }

  factory OaAccountDto.fromJson(Map<String, dynamic> json) {
    final rawAdmins = json['admin_ids'] ?? json['adminIds'];
    final rawMenu = json['rich_menu'] ?? json['richMenu'];
    final rawStaff = json['staff_roles'] ?? json['staffRoles'];
    final rawRole = (json['my_role'] ?? json['myRole'])?.toString().trim();
    final conv = (json['conversation_id'] ?? json['conversationId'])
        ?.toString()
        .trim();
    return OaAccountDto(
      id: _extractId(json),
      handle: (json['handle'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['displayName'] ?? '').toString(),
      category: (json['category'] ?? 'ร้านค้า / บริการ').toString(),
      bio: (json['bio'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? '').toString(),
      themeColor:
          (json['theme_color'] ?? json['themeColor'] ?? '#812920').toString(),
      greetingMessage:
          (json['greeting_message'] ?? json['greetingMessage'] ?? '').toString(),
      businessHours:
          (json['business_hours'] ?? json['businessHours'] ?? '').toString(),
      ownerId: (json['owner_id'] ?? json['ownerId'] ?? '').toString(),
      adminIds: rawAdmins is List
          ? rawAdmins.map((e) => e.toString()).toList()
          : const [],
      myRole: (rawRole == null || rawRole.isEmpty) ? null : rawRole,
      staffRoles: rawStaff is Map
          ? rawStaff.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
      botUserId: (json['bot_user_id'] ?? json['botUserId'] ?? '').toString(),
      isVerified: _toBool(json['is_verified'] ?? json['isVerified'], false),
      isActive: _toBool(json['is_active'] ?? json['isActive'], true),
      aiEnabled: _toBool(json['ai_enabled'] ?? json['aiEnabled'], false),
      aiKnowledgePrompt:
          (json['ai_knowledge_prompt'] ?? json['aiKnowledgePrompt'] ?? '')
              .toString(),
      callsEnabled: _toBool(
        json['calls_enabled'] ?? json['callsEnabled'],
        true,
      ),
      richMenu: rawMenu is List
          ? rawMenu
                .whereType<Map>()
                .map((e) => OaRichMenuItem.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
      followerCount: _toInt(json['follower_count'] ?? json['followerCount'], 0),
      isFollowing: _toBool(json['is_following'] ?? json['isFollowing'], false),
      conversationId: conv == null || conv.isEmpty ? null : conv,
      createdAt: (json['created_at'] ?? json['createdAt'] ?? '').toString(),
      updatedAt: (json['updated_at'] ?? json['updatedAt'] ?? '').toString(),
    );
  }
}

class OaTagCount {
  final String tag;
  final int count;

  const OaTagCount({required this.tag, required this.count});

  factory OaTagCount.fromJson(Map<String, dynamic> json) => OaTagCount(
    tag: (json['tag'] ?? '').toString(),
    count: _toInt(json['count'], 0),
  );
}

class OaOverviewStats {
  final int followerCount;
  final int activeChatsCount;
  final int autoReplyCount;
  final int activeCouponCount;
  final int totalCouponClaims;
  final int broadcastCount;
  final List<OaTagCount> tags;

  const OaOverviewStats({
    this.followerCount = 0,
    this.activeChatsCount = 0,
    this.autoReplyCount = 0,
    this.activeCouponCount = 0,
    this.totalCouponClaims = 0,
    this.broadcastCount = 0,
    this.tags = const [],
  });

  factory OaOverviewStats.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    return OaOverviewStats(
      followerCount: _toInt(json['follower_count'], 0),
      activeChatsCount: _toInt(json['active_chats_count'], 0),
      autoReplyCount: _toInt(json['auto_reply_count'], 0),
      activeCouponCount: _toInt(json['active_coupon_count'], 0),
      totalCouponClaims: _toInt(json['total_coupon_claims'], 0),
      broadcastCount: _toInt(json['broadcast_count'], 0),
      tags: rawTags is List
          ? rawTags
                .whereType<Map>()
                .map((e) => OaTagCount.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
    );
  }
}

class OaOverview {
  final OaAccountDto oa;
  final OaOverviewStats stats;

  const OaOverview({required this.oa, required this.stats});

  factory OaOverview.fromJson(Map<String, dynamic> json) => OaOverview(
    oa: OaAccountDto.fromJson(
      Map<String, dynamic>.from((json['oa'] as Map?) ?? const {}),
    ),
    stats: OaOverviewStats.fromJson(
      Map<String, dynamic>.from((json['stats'] as Map?) ?? const {}),
    ),
  );
}

class OaCustomerChatDto {
  final String conversationId;
  final String oaId;
  final String customerId;
  final String customerName;
  final String customerAvatar;
  final String customerBcId;
  final String customerPhone;
  final String customerEmail;
  final List<String> tags;
  final String crmNote;
  final bool aiPaused;
  final int unreadForOa;
  final ChatMessage? lastMessage;
  final String updatedAt;

  const OaCustomerChatDto({
    required this.conversationId,
    required this.oaId,
    required this.customerId,
    required this.customerName,
    this.customerAvatar = '',
    this.customerBcId = '',
    this.customerPhone = '',
    this.customerEmail = '',
    this.tags = const [],
    this.crmNote = '',
    this.aiPaused = false,
    this.unreadForOa = 0,
    this.lastMessage,
    this.updatedAt = '',
  });

  factory OaCustomerChatDto.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final rawLast = json['last_message'];
    return OaCustomerChatDto(
      conversationId: (json['conversation_id'] ?? '').toString(),
      oaId: (json['oa_id'] ?? '').toString(),
      customerId: (json['customer_id'] ?? '').toString(),
      customerName: (json['customer_name'] ?? 'ลูกค้า').toString(),
      customerAvatar: (json['customer_avatar'] ?? '').toString(),
      customerBcId: _normalizeBcId(json['customer_bc_id'] ?? json['customerBcId']),
      customerPhone: (json['customer_phone'] ?? '').toString(),
      customerEmail: (json['customer_email'] ?? '').toString(),
      tags: rawTags is List
          ? rawTags.map((e) => e.toString()).toList()
          : const [],
      crmNote: (json['crm_note'] ?? '').toString(),
      aiPaused: _toBool(json['ai_paused'], false),
      unreadForOa: _toInt(json['unread_for_oa'], 0),
      lastMessage: rawLast is Map
          ? ChatMessage.fromJson(Map<String, dynamic>.from(rawLast))
          : null,
      updatedAt: (json['updated_at'] ?? '').toString(),
    );
  }
}

class OaAutoReplyRule {
  final String id;
  final String oaId;
  final String keyword;
  final String matchMode; // contains | exact
  final String replyText;
  final Map<String, dynamic>? cardPayload;
  final bool isActive;
  final int hitCount;
  final String createdAt;

  const OaAutoReplyRule({
    required this.id,
    required this.oaId,
    required this.keyword,
    this.matchMode = 'contains',
    required this.replyText,
    this.cardPayload,
    this.isActive = true,
    this.hitCount = 0,
    this.createdAt = '',
  });

  factory OaAutoReplyRule.fromJson(Map<String, dynamic> json) {
    final rawCard = json['card_payload'];
    return OaAutoReplyRule(
      id: _extractId(json),
      oaId: (json['oa_id'] ?? '').toString(),
      keyword: (json['keyword'] ?? '').toString(),
      matchMode: (json['match_mode'] ?? 'contains').toString(),
      replyText: (json['reply_text'] ?? '').toString(),
      cardPayload: rawCard is Map
          ? Map<String, dynamic>.from(rawCard)
          : null,
      isActive: _toBool(json['is_active'], true),
      hitCount: _toInt(json['hit_count'], 0),
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}

class OaCoupon {
  final String id;
  final String oaId;
  final String code;
  final String title;
  final String description;
  final String discountText;
  final String expiresAt;
  final int maxClaims;
  final int claimsCount;
  final int redeemedCount;
  final bool isClaimed;
  final bool isRedeemed;
  final bool isActive;
  final String createdAt;

  const OaCoupon({
    required this.id,
    required this.oaId,
    required this.code,
    required this.title,
    this.description = '',
    this.discountText = '',
    this.expiresAt = '',
    this.maxClaims = 0,
    this.claimsCount = 0,
    this.redeemedCount = 0,
    this.isClaimed = false,
    this.isRedeemed = false,
    this.isActive = true,
    this.createdAt = '',
  });

  factory OaCoupon.fromJson(Map<String, dynamic> json) {
    final claimedBy = json['claimed_by'];
    final redeemedBy = json['redeemed_by'];
    final claimsCount = _toInt(
      json['claims_count'],
      claimedBy is List ? claimedBy.length : 0,
    );
    final redeemedCount = _toInt(
      json['redeemed_count'],
      redeemedBy is List ? redeemedBy.length : 0,
    );
    return OaCoupon(
      id: _extractId(json),
      oaId: (json['oa_id'] ?? '').toString(),
      code: (json['code'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      discountText: (json['discount_text'] ?? '').toString(),
      expiresAt: (json['expires_at'] ?? '').toString(),
      maxClaims: _toInt(json['max_claims'], 0),
      claimsCount: claimsCount,
      redeemedCount: redeemedCount,
      isClaimed: _toBool(json['is_claimed'], false),
      isRedeemed: _toBool(json['is_redeemed'], false),
      isActive: _toBool(json['is_active'], true),
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}

class OaBroadcast {
  final String id;
  final String oaId;
  final String targetTag;
  final String msgType;
  final String content;
  final String? couponId;
  final int recipientCount;
  final String createdAt;

  const OaBroadcast({
    required this.id,
    required this.oaId,
    this.targetTag = '',
    this.msgType = 'text',
    required this.content,
    this.couponId,
    this.recipientCount = 0,
    this.createdAt = '',
  });

  factory OaBroadcast.fromJson(Map<String, dynamic> json) => OaBroadcast(
    id: _extractId(json),
    oaId: (json['oa_id'] ?? '').toString(),
    targetTag: (json['target_tag'] ?? '').toString(),
    msgType: (json['msg_type'] ?? 'text').toString(),
    content: (json['content'] ?? '').toString(),
    couponId: json['coupon_id']?.toString(),
    recipientCount: _toInt(json['recipient_count'], 0),
    createdAt: (json['created_at'] ?? '').toString(),
  );
}

class CallParticipantState {
  final String userId;
  final String displayName;
  final String avatarUrl;
  final String state;
  final bool mutedAudio;
  final bool videoEnabled;
  final String updatedAt;

  const CallParticipantState({
    required this.userId,
    this.displayName = '',
    this.avatarUrl = '',
    this.state = 'joined',
    this.mutedAudio = false,
    this.videoEnabled = false,
    this.updatedAt = '',
  });

  factory CallParticipantState.fromJson(Map<String, dynamic> json) =>
      CallParticipantState(
        userId: (json['user_id'] ?? json['userId'] ?? '').toString(),
        displayName:
            (json['display_name'] ?? json['displayName'] ?? '').toString(),
        avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? '').toString(),
        state: (json['state'] ?? 'joined').toString(),
        mutedAudio: _toBool(
          json['muted_audio'] ?? json['mutedAudio'],
          false,
        ),
        videoEnabled: _toBool(
          json['video_enabled'] ?? json['videoEnabled'],
          false,
        ),
        updatedAt: (json['updated_at'] ?? json['updatedAt'] ?? '').toString(),
      );
}

class CallSessionDto {
  final String id;
  final String conversationId;
  final String roomName;
  final String callType; // audio | video
  final String status; // ringing | active | ended | missed | declined
  final String initiatorId;
  final String initiatorName;
  final String initiatorAvatar;
  final String? oaId;
  final List<String> targetUserIds;
  final List<CallParticipantState> participants;
  final String startedAt;
  final String? answeredAt;
  final String? endedAt;
  final int durationSec;
  final String? endReason;

  const CallSessionDto({
    required this.id,
    required this.conversationId,
    required this.roomName,
    this.callType = 'audio',
    this.status = 'ringing',
    required this.initiatorId,
    this.initiatorName = '',
    this.initiatorAvatar = '',
    this.oaId,
    this.targetUserIds = const [],
    this.participants = const [],
    this.startedAt = '',
    this.answeredAt,
    this.endedAt,
    this.durationSec = 0,
    this.endReason,
  });

  bool get isVideo => callType == 'video';
  bool get isRinging => status == 'ringing';
  bool get isActive => status == 'active';
  bool get isTerminal =>
      status == 'ended' || status == 'missed' || status == 'declined';

  factory CallSessionDto.fromJson(Map<String, dynamic> json) {
    final rawTargets = json['target_user_ids'] ?? json['targetUserIds'];
    final rawParts = json['participants'];
    final rawOa = (json['oa_id'] ?? json['oaId'])?.toString().trim() ?? '';
    return CallSessionDto(
      id: _extractId(json),
      conversationId:
          (json['conversation_id'] ?? json['conversationId'] ?? '').toString(),
      roomName: (json['room_name'] ?? json['roomName'] ?? '').toString(),
      callType: (json['call_type'] ?? json['callType'] ?? 'audio').toString(),
      status: (json['status'] ?? 'ringing').toString(),
      initiatorId:
          (json['initiator_id'] ?? json['initiatorId'] ?? '').toString(),
      initiatorName:
          (json['initiator_name'] ?? json['initiatorName'] ?? '').toString(),
      initiatorAvatar:
          (json['initiator_avatar'] ?? json['initiatorAvatar'] ?? '').toString(),
      oaId: rawOa.isEmpty ? null : rawOa,
      targetUserIds: rawTargets is List
          ? rawTargets.map((e) => e.toString()).toList()
          : const [],
      participants: rawParts is List
          ? rawParts
                .whereType<Map>()
                .map(
                  (e) => CallParticipantState.fromJson(
                    Map<String, dynamic>.from(e),
                  ),
                )
                .toList()
          : const [],
      startedAt: (json['started_at'] ?? json['startedAt'] ?? '').toString(),
      answeredAt: json['answered_at']?.toString(),
      endedAt: json['ended_at']?.toString(),
      durationSec: _toInt(json['duration_sec'] ?? json['durationSec'], 0),
      endReason: json['end_reason']?.toString(),
    );
  }
}

class CallJoinSession {
  final CallSessionDto call;
  final String livekitUrl;
  final String token;

  const CallJoinSession({
    required this.call,
    required this.livekitUrl,
    required this.token,
  });

  factory CallJoinSession.fromJson(Map<String, dynamic> json) {
    final rawCall = json['call'];
    return CallJoinSession(
      call: CallSessionDto.fromJson(
        rawCall is Map ? Map<String, dynamic>.from(rawCall) : json,
      ),
      livekitUrl:
          (json['livekit_url'] ?? json['livekitUrl'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
    );
  }
}
