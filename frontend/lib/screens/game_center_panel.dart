import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart' show cleanErrorMessage;

/// ศูนย์เกมกลุ่ม/เดี่ยว AI (BC Game Center) แบบ Inline Zero-Popup
/// รองรับคลัง 100 เกม + สุ่มเกม + 5 เอนจิน (quiz / undercover / hint_race / party_vote / creative_challenge)
/// + ระบบ AI ชวนเล่นอัตโนมัติ (เปิด/ปิดรายห้อง + เลือกช่วงเวลาเว้นระยะ)
class GameCenterPanel extends StatefulWidget {
  final Conversation conversation;
  final ActiveGameState? initialState;
  final GameSession? initialFocusedGame;
  final List<GameCatalogItem>? initialCatalog;
  final List<ChatMessage> recentImageMessages;
  final int wsRefreshTick;
  final bool autoLoad;
  final String? currentUserIdOverride;
  final VoidCallback onClose;
  final ValueChanged<ActiveGameState>? onStateChanged;
  final ValueChanged<Conversation>? onConversationMetaUpdated;

  const GameCenterPanel({
    super.key,
    required this.conversation,
    this.initialState,
    this.initialFocusedGame,
    this.initialCatalog,
    this.recentImageMessages = const [],
    this.wsRefreshTick = 0,
    this.autoLoad = true,
    this.currentUserIdOverride,
    required this.onClose,
    this.onStateChanged,
    this.onConversationMetaUpdated,
  });

  @override
  State<GameCenterPanel> createState() => _GameCenterPanelState();
}

class _GameCenterPanelState extends State<GameCenterPanel> {
  static const List<String> _thaiLetters = ['ก', 'ข', 'ค', 'ง', 'จ', 'ฉ'];
  static const List<String> _quickQuizTopics = [
    'อาหารไทย',
    'ความรู้รอบตัว',
    'ยุค 90',
    'ศัพท์ออฟฟิศ',
    'เที่ยวไทย',
  ];
  static const List<int> _quizCountOptions = [3, 5, 8];
  static const List<int> _cooldownOptions = [15, 30, 60];
  static const List<String> _defaultCategories = [
    'เพื่อน',
    'ครอบครัว',
    'ทำงาน',
    'ความรู้',
    'ทายใจ/ฮา',
    'สร้างสรรค์',
  ];

  final TextEditingController _catalogSearchCtrl = TextEditingController();
  final TextEditingController _quizTopicCtrl = TextEditingController();
  final TextEditingController _undercoverTopicCtrl = TextEditingController();
  final TextEditingController _clueCtrl = TextEditingController();
  final TextEditingController _guessCtrl = TextEditingController();
  final TextEditingController _creativeCtrl = TextEditingController();

  late ActiveGameState _state;
  GameSession? _focusedGame;
  bool _forceLauncher = false;

  List<GameCatalogItem> _catalog = const [];
  List<String> _categories = _defaultCategories;
  int _catalogTotal = 0;
  bool _loadingCatalog = false;
  bool _showAllCatalog = false;

  String _selectedMode = 'auto'; // auto | solo | group
  String _selectedCategory = 'ทั้งหมด';
  int _questionCount = 5;

  bool _loading = false;
  bool _busy = false;
  bool _savingRoomToggle = false;
  String? _errorText;
  String? _infoText;
  bool _revealSecretWord = false;
  String? _selectedCreativeImageMsgId;
  String _lastGameIdForReset = '';

  String get _myUserId =>
      widget.currentUserIdOverride ?? ApiService.instance.currentUser?.id ?? '';

  GameSession? get _currentGame {
    if (_forceLauncher) return null;
    if (_focusedGame != null) return _focusedGame;
    final active = _state.activeGame;
    if (active != null && !active.isCancelled) return active;
    return null;
  }

  @override
  void initState() {
    super.initState();
    _state =
        widget.initialState ??
        ActiveGameState(
          aiGameAutoInvite: widget.conversation.aiGameAutoInvite,
          aiGameInviteCooldownMins:
              widget.conversation.aiGameInviteCooldownMins,
        );
    _focusedGame = widget.initialFocusedGame ?? widget.initialState?.activeGame;
    _lastGameIdForReset = _focusedGame?.id ?? '';
    if (widget.initialCatalog != null) {
      _catalog = widget.initialCatalog!;
      _catalogTotal = widget.initialCatalog!.length;
    }
    if (widget.autoLoad) {
      _loading = widget.initialState == null;
      unawaited(_refreshAll(silent: widget.initialState != null));
      if (widget.initialCatalog == null) {
        unawaited(_loadCatalog());
      }
    }
  }

  @override
  void didUpdateWidget(covariant GameCenterPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id != widget.conversation.id) {
      _forceLauncher = false;
      _focusedGame = widget.initialFocusedGame;
      _revealSecretWord = false;
      _selectedCreativeImageMsgId = null;
      _errorText = null;
      _infoText = null;
      if (widget.autoLoad) {
        unawaited(_refreshAll(silent: false));
      }
    } else {
      if (widget.initialFocusedGame != null &&
          widget.initialFocusedGame?.id != oldWidget.initialFocusedGame?.id) {
        _focusedGame = widget.initialFocusedGame;
        _forceLauncher = false;
        _syncGameResetIfNeeded(_focusedGame);
      }
      if (oldWidget.wsRefreshTick != widget.wsRefreshTick && widget.autoLoad) {
        unawaited(_refreshAll(silent: true));
      }
    }
  }

  @override
  void dispose() {
    _catalogSearchCtrl.dispose();
    _quizTopicCtrl.dispose();
    _undercoverTopicCtrl.dispose();
    _clueCtrl.dispose();
    _guessCtrl.dispose();
    _creativeCtrl.dispose();
    super.dispose();
  }

  void _syncGameResetIfNeeded(GameSession? game) {
    final nextId = game?.id ?? '';
    if (nextId != _lastGameIdForReset) {
      _lastGameIdForReset = nextId;
      _revealSecretWord = false;
      _selectedCreativeImageMsgId = null;
      _clueCtrl.clear();
      _guessCtrl.clear();
      _creativeCtrl.clear();
    }
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _errorText = null;
      });
    }
    try {
      final activeState = await ApiService.instance.getActiveGame(
        widget.conversation.id,
      );
      GameSession? refreshedFocus = activeState.activeGame;
      if (_focusedGame != null &&
          !_forceLauncher &&
          !_focusedGame!.isFinished &&
          (refreshedFocus == null || refreshedFocus.id != _focusedGame!.id)) {
        try {
          refreshedFocus = await ApiService.instance.getGame(_focusedGame!.id);
        } catch (_) {
          // Keep active game from room if old focused game is gone.
        }
      } else if (_focusedGame?.isFinished == true && !_forceLauncher) {
        refreshedFocus = _focusedGame;
      }
      if (!mounted) return;
      setState(() {
        _state = activeState;
        if (!_forceLauncher) {
          if (refreshedFocus != null && !refreshedFocus.isCancelled) {
            _focusedGame = refreshedFocus;
          } else if (activeState.activeGame != null) {
            _focusedGame = activeState.activeGame;
          } else if (_focusedGame?.isFinished != true) {
            _focusedGame = null;
          }
        }
        _syncGameResetIfNeeded(_focusedGame);
        _loading = false;
      });
      widget.onStateChanged?.call(activeState);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!silent) {
          _errorText = cleanErrorMessage(e);
        }
      });
    }
  }

  Future<void> _loadCatalog() async {
    if (_loadingCatalog) return;
    setState(() => _loadingCatalog = true);
    try {
      final res = await ApiService.instance.listGameCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = res.games;
        _catalogTotal = res.total > 0 ? res.total : res.games.length;
        if (res.categories.isNotEmpty) {
          _categories = res.categories;
        }
        _loadingCatalog = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingCatalog = false);
    }
  }

  List<GameCatalogItem> get _filteredCatalog {
    final q = _catalogSearchCtrl.text.trim().toLowerCase();
    return _catalog.where((item) {
      if (_selectedMode == 'solo' && !item.supportsSolo) return false;
      if (_selectedMode == 'group' && !item.supportsGroup) return false;
      if (_selectedCategory != 'ทั้งหมด' &&
          item.category != _selectedCategory) {
        return false;
      }
      if (q.isEmpty) return true;
      return item.name.toLowerCase().contains(q) ||
          item.tagline.toLowerCase().contains(q) ||
          item.category.toLowerCase().contains(q) ||
          item.engineLabel.toLowerCase().contains(q) ||
          item.id.toLowerCase().contains(q) ||
          '#${item.number}'.contains(q) ||
          '${item.number}' == q;
    }).toList();
  }

  Future<void> _updateRoomAutoInvite({bool? enabled, int? cooldownMins}) async {
    if (_savingRoomToggle) return;
    setState(() {
      _savingRoomToggle = true;
      _errorText = null;
    });
    try {
      final updatedConv = await ApiService.instance.updateConversationMeta(
        widget.conversation.id,
        aiGameAutoInvite: enabled,
        aiGameInviteCooldownMins: cooldownMins,
      );
      if (!mounted) return;
      final nextState = _state.copyWith(
        aiGameAutoInvite: enabled ?? updatedConv?.aiGameAutoInvite,
        aiGameInviteCooldownMins:
            cooldownMins ?? updatedConv?.aiGameInviteCooldownMins,
      );
      setState(() {
        _state = nextState;
        _savingRoomToggle = false;
        _infoText = enabled == false
            ? 'ปิดให้ AI ชวนเล่นเกมอัตโนมัติในห้องนี้แล้ว'
            : enabled == true
            ? 'เปิดให้ AI ชวนเล่นเกมอัตโนมัติในห้องนี้แล้ว'
            : 'อัปเดตระยะเวลาเว้นช่วงชวนเล่นเป็น ${nextState.aiGameInviteCooldownMins} นาทีแล้ว';
      });
      widget.onStateChanged?.call(nextState);
      if (updatedConv != null) {
        widget.onConversationMetaUpdated?.call(updatedConv);
      } else {
        widget.onConversationMetaUpdated?.call(
          widget.conversation.copyWith(
            aiGameAutoInvite: nextState.aiGameAutoInvite,
            aiGameInviteCooldownMins: nextState.aiGameInviteCooldownMins,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingRoomToggle = false;
        _errorText = cleanErrorMessage(e);
      });
    }
  }

  Future<void> _runGameAction(
    Future<GameSession> Function() action, {
    String? successNote,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorText = null;
      _infoText = null;
    });
    try {
      final session = await action();
      if (!mounted) return;
      final isCancelled = session.isCancelled;
      final nextState = _state.copyWith(
        activeGame: session.isActive ? session : null,
        clearActiveGame: !session.isActive,
      );
      setState(() {
        _busy = false;
        _state = nextState;
        _forceLauncher = isCancelled;
        _focusedGame = isCancelled ? null : session;
        _syncGameResetIfNeeded(_focusedGame);
        if (successNote != null) _infoText = successNote;
      });
      widget.onStateChanged?.call(nextState);
      if (widget.autoLoad && (session.isFinished || session.isCancelled)) {
        unawaited(_refreshAll(silent: true));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorText = cleanErrorMessage(e);
      });
    }
  }

  Future<void> _handleProactiveInvite() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorText = null;
      _infoText = null;
    });
    try {
      final res = await ApiService.instance.triggerProactiveGameInvite(
        widget.conversation.id,
        force: true,
      );
      if (!mounted) return;
      if (res.invited && res.game != null) {
        final nextState = _state.copyWith(activeGame: res.game);
        setState(() {
          _busy = false;
          _state = nextState;
          _forceLauncher = false;
          _focusedGame = res.game;
          _syncGameResetIfNeeded(res.game);
          _infoText = 'BC AI สร้างเกมชวนทุกคนในห้องแล้ว!';
        });
        widget.onStateChanged?.call(nextState);
      } else {
        setState(() {
          _busy = false;
          _errorText = res.reason ?? 'ยังไม่สามารถให้ AI ชวนเล่นเกมได้ในตอนนี้';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorText = cleanErrorMessage(e);
      });
    }
  }

  Future<void> _handleStartRandomGame() async {
    final autoStart =
        _selectedMode == 'solo' ||
        (_selectedMode == 'auto' && !widget.conversation.isGroup);
    await _runGameAction(
      () => ApiService.instance.startRandomGame(
        widget.conversation.id,
        mode: _selectedMode,
        category: _selectedCategory == 'ทั้งหมด' ? null : _selectedCategory,
        autoStart: autoStart,
      ),
    );
  }

  Future<void> _handleStartCatalogGame(GameCatalogItem item) async {
    final autoStart = item.minPlayers == 1 && !widget.conversation.isGroup;
    await _runGameAction(
      () => ApiService.instance.createGame(
        widget.conversation.id,
        gameType: item.engine,
        gameId: item.id,
        autoStart: autoStart,
      ),
    );
  }

  Future<void> _handleCreateQuiz() async {
    await _runGameAction(
      () => ApiService.instance.createGame(
        widget.conversation.id,
        gameType: 'quiz',
        topic: _quizTopicCtrl.text.trim(),
        questionCount: _questionCount,
        autoStart: !widget.conversation.isGroup,
      ),
    );
  }

  Future<void> _handleCreateUndercover() async {
    await _runGameAction(
      () => ApiService.instance.createGame(
        widget.conversation.id,
        gameType: 'undercover',
        topic: _undercoverTopicCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final game = _currentGame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const Divider(height: 1, color: AppTheme.hairline),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  children: [
                    _buildAutoInviteToggleCard(),
                    if (_errorText != null) ...[
                      const SizedBox(height: 6),
                      _buildBannerBox(
                        text: _errorText!,
                        isError: true,
                        onDismiss: () => setState(() => _errorText = null),
                      ),
                    ],
                    if (_infoText != null) ...[
                      const SizedBox(height: 6),
                      _buildBannerBox(
                        text: _infoText!,
                        isError: false,
                        onDismiss: () => setState(() => _infoText = null),
                      ),
                    ],
                    const SizedBox(height: 8),
                    if (game == null)
                      _buildLauncherView()
                    else if (game.isLobby)
                      _buildLobbyView(game)
                    else if (game.isFinished)
                      _buildFinishedView(game)
                    else if (game.isPlaying)
                      _buildPlayingView(game)
                    else
                      _buildLauncherView(),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final totalBadge = _catalogTotal > 0 ? _catalogTotal : 100;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: const BoxDecoration(color: Colors.white),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: AppTheme.brandGradient,
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: const Icon(
              Icons.sports_esports_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  '🎮 เครื่องเล่นเกมกลุ่ม AI',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                    height: 1.25,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.tintStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$totalBadge เกม',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.brandDeep,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'รีเฟรชสถานะเกม',
            onPressed: _busy ? null : () => _refreshAll(silent: false),
            icon: const Icon(Icons.refresh_rounded, size: 18),
          ),
          IconButton(
            key: const Key('game-panel-close-btn'),
            visualDensity: VisualDensity.compact,
            tooltip: 'ปิด',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close_rounded, size: 19),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoInviteToggleCard() {
    final autoOn = _state.aiGameAutoInvite;
    final cooldown = _state.aiGameInviteCooldownMins;
    final globalOff = !_state.proactiveEnabledGlobally;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: AppTheme.well(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                autoOn
                    ? Icons.auto_awesome_rounded
                    : Icons.notifications_off_outlined,
                size: 16,
                color: autoOn ? AppTheme.brandPrimary : AppTheme.slateMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI ชวนเล่นอัตโนมัติ',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateDark,
                        height: 1.25,
                      ),
                    ),
                    if (globalOff)
                      const Text(
                        'แอดมินปิดการชวนอัตโนมัติทั้งระบบไว้ชั่วคราว',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.warningAmber,
                        ),
                      ),
                  ],
                ),
              ),
              Switch(
                key: const Key('game-auto-invite-switch'),
                value: autoOn,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: _savingRoomToggle
                    ? null
                    : (val) => _updateRoomAutoInvite(enabled: val),
              ),
            ],
          ),
          if (autoOn) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'เว้นระยะชวน:',
                  style: TextStyle(fontSize: 11, color: AppTheme.slateMuted),
                ),
                for (final mins in _cooldownOptions)
                  ChoiceChip(
                    key: Key('game-cooldown-$mins'),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selected: cooldown == mins,
                    label: Text('$mins นาที', style: const TextStyle(fontSize: 11)),
                    onSelected: _savingRoomToggle
                        ? null
                        : (_) => _updateRoomAutoInvite(cooldownMins: mins),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBannerBox({
    required String text,
    required bool isError,
    required VoidCallback onDismiss,
  }) {
    final bg = isError ? const Color(0xFFFEF2F2) : const Color(0xFFECFDF5);
    final border = isError ? const Color(0xFFFECACA) : const Color(0xFFA7F3D0);
    final fg = isError ? AppTheme.dangerRed : const Color(0xFF047857);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_rounded,
            size: 16,
            color: fg,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: fg, height: 1.3),
            ),
          ),
          InkWell(
            onTap: onDismiss,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close_rounded, size: 15, color: fg),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 1. Launcher View (Hero Randomizer + 100-Game Picker + Quiz/Undercover + Recent)
  // ---------------------------------------------------------------------------
  Widget _buildLauncherView() {
    final filtered = _filteredCatalog;
    final hasSearch = _catalogSearchCtrl.text.trim().isNotEmpty;
    final visibleCatalog = (_showAllCatalog || hasSearch || filtered.length <= 10)
        ? filtered
        : filtered.take(10).toList();
    final totalDisplay = _catalogTotal > 0 ? _catalogTotal : 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero Randomizer + Proactive AI Summon Card
        Container(
          padding: const EdgeInsets.all(10),
          decoration: AppTheme.surface(radius: AppTheme.radiusMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text('🎲', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'สุ่มเกมสนุกจาก $totalDisplay เกม! (เล่นคนเดียวหรือเป็นกลุ่ม)',
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _modeChoiceChip('auto', 'อัตโนมัติ'),
                  _modeChoiceChip('solo', 'เล่นคนเดียว'),
                  _modeChoiceChip('group', 'เล่นเป็นกลุ่ม'),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _categoryChoiceChip('ทั้งหมด'),
                  for (final cat in _categories) _categoryChoiceChip(cat),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton.icon(
                    key: const Key('game-random-btn'),
                    onPressed: _busy ? null : _handleStartRandomGame,
                    icon: _busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.casino_rounded, size: 17),
                    label: Text('🎲 สุ่มเกมสนุกจาก $totalDisplay เกม!'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('game-proactive-btn'),
                    onPressed: _busy ? null : _handleProactiveInvite,
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: const Text('✨ ให้ AI คิดเกมชวนทุกคนตอนนี้'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // 100-Game Searchable Catalog Picker
        Container(
          padding: const EdgeInsets.all(10),
          decoration: AppTheme.surface(radius: AppTheme.radiusMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.grid_view_rounded,
                    size: 16,
                    color: AppTheme.slateBody,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'คลัง $totalDisplay เกม (${filtered.length} เกมที่ตรงเงื่อนไข)',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateDark,
                      ),
                    ),
                  ),
                  if (_loadingCatalog)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                key: const Key('game-catalog-search'),
                controller: _catalogSearchCtrl,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'ค้นหาเกมจากคลัง 100 เกม (เช่น อาหาร, สายลับ, #1)...',
                  prefixIcon: const Icon(Icons.search_rounded, size: 17),
                  suffixIcon: _catalogSearchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 16),
                          onPressed: () {
                            _catalogSearchCtrl.clear();
                            setState(() {});
                          },
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              if (visibleCatalog.isEmpty)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: AppTheme.well(radius: AppTheme.radiusSm),
                  child: Text(
                    _loadingCatalog
                        ? 'กำลังโหลดคลัง 100 เกม...'
                        : 'ไม่พบเกมที่ตรงคำค้นหา ลองเปลี่ยนหมวดหรือกดสุ่มเกมได้เลย',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.slateMuted,
                    ),
                  ),
                )
              else ...[
                for (final item in visibleCatalog) ...[
                  _buildCatalogRow(item),
                  const SizedBox(height: 5),
                ],
                if (!hasSearch && filtered.length > 10)
                  Align(
                    alignment: Alignment.center,
                    child: TextButton.icon(
                      key: const Key('game-catalog-expand-btn'),
                      onPressed: () =>
                          setState(() => _showAllCatalog = !_showAllCatalog),
                      icon: Icon(
                        _showAllCatalog
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                      ),
                      label: Text(
                        _showAllCatalog
                            ? 'ย่อรายการเกม'
                            : 'ดูทั้งหมด (${filtered.length} เกม)',
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Quick Custom Quiz Launcher
        Container(
          padding: const EdgeInsets.all(10),
          decoration: AppTheme.surface(radius: AppTheme.radiusMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '🧠 ควิซสายฟ้า AI (กำหนดหัวข้อเอง)',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'พิมพ์หัวข้อที่อยากแข่ง ให้ BC AI ออกข้อสอบพร้อมเฉลยสดๆ',
                style: TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
              ),
              const SizedBox(height: 6),
              TextField(
                key: const Key('game-quiz-topic-input'),
                controller: _quizTopicCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'หัวข้อควิซ เช่น อาหารไทย, การเงิน, กาแฟ...',
                  prefixIcon: Icon(Icons.quiz_outlined, size: 17),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final topic in _quickQuizTopics)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      label: Text(topic, style: const TextStyle(fontSize: 11)),
                      onPressed: () => setState(() {
                        _quizTopicCtrl.text = topic;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'จำนวนข้อ:',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.slateBody),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final cnt in _quizCountOptions)
                          ChoiceChip(
                            key: Key('game-quiz-count-$cnt'),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            selected: _questionCount == cnt,
                            label: Text(
                              '$cnt ข้อ',
                              style: const TextStyle(fontSize: 11),
                            ),
                            onSelected: (_) =>
                                setState(() => _questionCount = cnt),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                key: const Key('game-create-quiz-btn'),
                onPressed: _busy ? null : _handleCreateQuiz,
                icon: const Icon(Icons.bolt_rounded, size: 17),
                label: const Text('เริ่มควิซสายฟ้า AI'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Quick Custom Undercover Launcher
        Container(
          padding: const EdgeInsets.all(10),
          decoration: AppTheme.surface(radius: AppTheme.radiusMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '🕵️ ใครคือสายลับ (2+ คน)',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'ทุกคนได้คำลับต่างกัน 1 คน ช่วยกันใบ้คำแล้วโหวตจับสายลับ!',
                style: TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
              ),
              const SizedBox(height: 6),
              TextField(
                key: const Key('game-undercover-topic-input'),
                controller: _undercoverTopicCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'หมวดคำลับ (เว้นว่างให้ AI สุ่มให้)',
                  prefixIcon: Icon(Icons.visibility_off_outlined, size: 17),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('game-create-undercover-btn'),
                onPressed: _busy ? null : _handleCreateUndercover,
                icon: const Icon(Icons.person_search_rounded, size: 17),
                label: const Text('เปิดวงจับสายลับ'),
              ),
            ],
          ),
        ),

        // Recent Games History
        if (_state.recentGames.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text(
            'ประวัติเกมล่าสุดในห้องนี้',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.slateDark,
            ),
          ),
          const SizedBox(height: 5),
          for (final recent in _state.recentGames.take(5)) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: AppTheme.well(radius: AppTheme.radiusSm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(recent.emoji, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          recent.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.slateDark,
                          ),
                        ),
                        Text(
                          recent.winnerNames.isNotEmpty
                              ? '🏆 ${recent.winnerNames.join(", ")} · ${recent.playerCount} คน'
                              : '${recent.playerCount} คน · ${recent.status == 'finished' ? 'จบเกมแล้ว' : recent.status}',
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
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ],
    );
  }

  Widget _modeChoiceChip(String mode, String label) {
    return ChoiceChip(
      key: Key('game-mode-$mode'),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selected: _selectedMode == mode,
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      onSelected: (_) => setState(() => _selectedMode = mode),
    );
  }

  Widget _categoryChoiceChip(String category) {
    return ChoiceChip(
      key: Key('game-cat-$category'),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selected: _selectedCategory == category,
      label: Text(category, style: const TextStyle(fontSize: 11)),
      onSelected: (_) => setState(() => _selectedCategory = category),
    );
  }

  Widget _buildCatalogRow(GameCatalogItem item) {
    return InkWell(
      key: Key('game-catalog-item-${item.id}'),
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      onTap: _busy ? null : () => _handleStartCatalogGame(item),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: AppTheme.well(radius: AppTheme.radiusSm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(color: AppTheme.hairline),
              ),
              child: Text(item.emoji, style: const TextStyle(fontSize: 17)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        '#${item.number}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.brandPrimary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.slateDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (item.tagline.isNotEmpty)
                    Text(
                      item.tagline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _miniTag(item.playModeLabel, AppTheme.tintStrong, AppTheme.brandDeep),
                      _miniTag(item.engineLabel, Colors.white, AppTheme.slateBody),
                      _miniTag(item.category, Colors.white, AppTheme.slateMuted),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.brandPrimary,
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: const Text(
                'เล่นเลย',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniTag(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. Lobby View
  // ---------------------------------------------------------------------------
  Widget _buildLobbyView(GameSession game) {
    final isJoined = game.hasPlayer(_myUserId);
    final minPlayers = game.minPlayersRequired;
    final canStart = game.players.length >= minPlayers;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _miniTag(
                '${game.defaultEmoji} ${_engineDisplayName(game.gameType)}',
                AppTheme.tintStrong,
                AppTheme.brandDeep,
              ),
              if (game.proactive)
                _miniTag(
                  '✨ AI ชวนเล่น',
                  const Color(0xFFF3E8FF),
                  AppTheme.personalPurple,
                ),
              if (game.topic.isNotEmpty)
                _miniTag(game.topic, AppTheme.panelBg, AppTheme.slateBody),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            game.title,
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.slateDark,
              height: 1.3,
            ),
          ),
          if (game.hostMessage.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(9),
              decoration: AppTheme.well(radius: AppTheme.radiusSm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 16,
                    color: AppTheme.personalPurple,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      game.hostMessage,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.slateDark,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'ผู้เล่นในวง (${game.players.length} คน)',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.slateDark,
            ),
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final p in game.players)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: p.userId == _myUserId
                        ? AppTheme.tintStrong
                        : AppTheme.panelBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: p.userId == _myUserId
                          ? AppTheme.brandPrimary
                          : AppTheme.hairline,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.person_rounded,
                        size: 14,
                        color: p.userId == _myUserId
                            ? AppTheme.brandDeep
                            : AppTheme.slateBody,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        p.userId == _myUserId
                            ? '${p.displayName} (คุณ)'
                            : p.displayName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.userId == _myUserId
                              ? AppTheme.brandDeep
                              : AppTheme.slateDark,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (!canStart) ...[
            const SizedBox(height: 6),
            Text(
              'รอผู้เล่นอย่างน้อย $minPlayers คนก่อนกดเริ่มเกม',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppTheme.warningAmber,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!isJoined)
                ElevatedButton.icon(
                  key: const Key('game-join-btn'),
                  onPressed: _busy
                      ? null
                      : () => _runGameAction(
                          () => ApiService.instance.joinGame(game.id),
                        ),
                  icon: const Icon(Icons.group_add_rounded, size: 17),
                  label: const Text('เข้าร่วมเกม'),
                ),
              ElevatedButton.icon(
                key: const Key('game-start-btn'),
                onPressed: (_busy || !canStart)
                    ? null
                    : () => _runGameAction(
                        () => ApiService.instance.startGame(game.id),
                      ),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('เริ่มเกมเลย!'),
              ),
              OutlinedButton.icon(
                key: const Key('game-cancel-btn'),
                onPressed: _busy
                    ? null
                    : () => _runGameAction(
                        () => ApiService.instance.cancelGame(game.id),
                        successNote: 'ยกเลิกห้องเกมแล้ว',
                      ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.dangerRed,
                ),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('ยกเลิกเกม'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3. Playing Router (All 5 Engines)
  // ---------------------------------------------------------------------------
  Widget _buildPlayingView(GameSession game) {
    if (game.isQuiz && game.currentQuestion != null) {
      return _buildQuizPlayingView(game, game.currentQuestion!);
    }
    if (game.isUndercover && game.undercover != null) {
      return _buildUndercoverPlayingView(game, game.undercover!);
    }
    if (game.isHintRace && game.hintRace != null) {
      return _buildHintRacePlayingView(game, game.hintRace!);
    }
    if (game.isPartyVote && game.partyVote != null) {
      return _buildPartyVotePlayingView(game, game.partyVote!);
    }
    if (game.isCreativeChallenge && game.creativeChallenge != null) {
      return _buildCreativePlayingView(game, game.creativeChallenge!);
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${game.defaultEmoji} ${game.title}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'กำลังโหลดข้อมูลรอบปัจจุบัน...',
            style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : () => _refreshAll(silent: false),
            child: const Text('โหลดใหม่'),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveScoreStrip(GameSession game) {
    final sorted = List<GamePlayer>.from(game.players)
      ..sort((a, b) => b.score.compareTo(a.score));
    return Wrap(
      spacing: 6,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final p in sorted)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
            decoration: BoxDecoration(
              color: p.userId == _myUserId
                  ? AppTheme.tintStrong
                  : AppTheme.panelBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: p.userId == _myUserId
                    ? AppTheme.brandPrimary
                    : AppTheme.hairline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  p.displayName,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateDark,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${p.score} แต้ม',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.brandDeep,
                  ),
                ),
                if (p.answered || p.voted) ...[
                  const SizedBox(width: 3),
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 13,
                    color: Color(0xFF047857),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPlayingHeaderRow(GameSession game, String progressLabel) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _miniTag(
          '${game.defaultEmoji} $progressLabel',
          AppTheme.tintStrong,
          AppTheme.brandDeep,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            game.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppTheme.slateDark,
            ),
          ),
        ),
        TextButton(
          key: const Key('game-cancel-playing-btn'),
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.dangerRed,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: _busy
              ? null
              : () => _runGameAction(
                  () => ApiService.instance.cancelGame(game.id),
                  successNote: 'ยกเลิกเกมแล้ว',
                ),
          child: const Text('ยกเลิก', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  // --- Engine 1: Quiz ---
  Widget _buildQuizPlayingView(GameSession game, QuizQuestionView q) {
    final isJoined = game.hasPlayer(_myUserId);
    final answeredCount = game.players.where((p) => p.answered).length;
    final isLastRound = game.roundIndex + 1 >= game.totalRounds;

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPlayingHeaderRow(
            game,
            'ข้อ ${game.roundIndex + 1}/${game.totalRounds}',
          ),
          const SizedBox(height: 4),
          Text(
            'ตอบแล้ว $answeredCount/${game.players.length} คน',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
          ),
          const SizedBox(height: 6),
          _buildLiveScoreStrip(game),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: AppTheme.well(radius: AppTheme.radiusMd),
            child: Text(
              q.question,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateDark,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < q.options.length; i++) ...[
            _buildQuizOptionTile(game, q, i, isJoined),
            const SizedBox(height: 6),
          ],
          if (game.roundRevealed && (q.explanation ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(color: const Color(0xFFA7F3D0)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: Color(0xFF047857),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'เฉลย: ${q.explanation}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF065F46),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          ElevatedButton.icon(
            key: const Key('game-next-btn'),
            onPressed: _busy
                ? null
                : () => _runGameAction(
                    () => ApiService.instance.advanceGame(game.id),
                  ),
            icon: Icon(
              game.roundRevealed
                  ? Icons.arrow_forward_rounded
                  : Icons.fact_check_outlined,
              size: 17,
            ),
            label: Text(
              !game.roundRevealed
                  ? 'เฉลย / ข้อถัดไป'
                  : (isLastRound ? 'สรุปคะแนนสุดท้าย' : 'ข้อถัดไป'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuizOptionTile(
    GameSession game,
    QuizQuestionView q,
    int index,
    bool isJoined,
  ) {
    final letter = index < _thaiLetters.length
        ? _thaiLetters[index]
        : '${index + 1}';
    final isSelected = q.myChoice == index;
    final isCorrect = game.roundRevealed && q.correctIndex == index;
    final isWrongMine =
        game.roundRevealed && isSelected && q.correctIndex != index;
    final count = index < q.choiceCounts.length ? q.choiceCounts[index] : 0;

    Color bg = Colors.white;
    Color border = AppTheme.hairlineStrong;
    Color badgeBg = AppTheme.panelBg;
    Color badgeFg = AppTheme.slateDark;

    if (isCorrect) {
      bg = const Color(0xFFECFDF5);
      border = const Color(0xFF047857);
      badgeBg = const Color(0xFF047857);
      badgeFg = Colors.white;
    } else if (isWrongMine) {
      bg = const Color(0xFFFEF2F2);
      border = AppTheme.dangerRed;
      badgeBg = AppTheme.dangerRed;
      badgeFg = Colors.white;
    } else if (isSelected) {
      bg = AppTheme.tintStrong;
      border = AppTheme.brandPrimary;
      badgeBg = AppTheme.brandPrimary;
      badgeFg = Colors.white;
    }

    final canTap =
        !_busy && !game.roundRevealed && q.myChoice == null && isJoined;

    return InkWell(
      key: Key('quiz-option-$index'),
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      onTap: canTap
          ? () => _runGameAction(
              () => ApiService.instance.submitQuizAnswer(game.id, index),
            )
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(color: border, width: isSelected || isCorrect ? 1.4 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: badgeFg,
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                q.options[index],
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.slateDark,
                  height: 1.35,
                ),
              ),
            ),
            if (game.roundRevealed) ...[
              const SizedBox(width: 6),
              Text(
                '$count คน',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.slateMuted,
                ),
              ),
              if (isCorrect) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: Color(0xFF047857),
                ),
              ] else if (isWrongMine) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.cancel_rounded,
                  size: 16,
                  color: AppTheme.dangerRed,
                ),
              ],
            ] else if (isSelected) ...[
              const SizedBox(width: 6),
              Text(
                'เลือกแล้ว',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.brandDeep,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- Engine 2: Undercover ---
  Widget _buildUndercoverPlayingView(GameSession game, UndercoverView uc) {
    final isJoined = game.hasPlayer(_myUserId);
    final isVotePhase = game.phase == 'vote';

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPlayingHeaderRow(
            game,
            isVotePhase ? 'รอบโหวตสายลับ' : 'รอบให้คำใบ้',
          ),
          if (uc.category.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'หมวดคำลับ: ${uc.category}',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
            ),
          ],
          const SizedBox(height: 8),

          // Tap-to-show/hide secret word card (hidden by default!)
          InkWell(
            key: const Key('undercover-secret-card'),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            onTap: () => setState(() => _revealSecretWord = !_revealSecretWord),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                gradient: _revealSecretWord ? AppTheme.brandGradient : null,
                color: _revealSecretWord ? null : AppTheme.panelBg,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(
                  color: _revealSecretWord
                      ? AppTheme.brandDeep
                      : AppTheme.hairlineStrong,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    _revealSecretWord
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    size: 20,
                    color: _revealSecretWord
                        ? Colors.white
                        : AppTheme.brandPrimary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'คำลับของคุณ',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: _revealSecretWord
                                ? Colors.white.withValues(alpha: 0.9)
                                : AppTheme.slateMuted,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _revealSecretWord
                              ? (uc.mySecretWord ?? 'คุณกำลังรับชมเกมนี้อยู่')
                              : 'แตะเพื่อดูคำลับ (ระวังคนข้างๆ แอบมอง!)',
                          style: TextStyle(
                            fontSize: _revealSecretWord ? 17 : 12.5,
                            fontWeight: FontWeight.w700,
                            color: _revealSecretWord
                                ? Colors.white
                                : AppTheme.slateDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _revealSecretWord ? 'ซ่อน' : 'เปิดดู',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: _revealSecretWord
                          ? Colors.white
                          : AppTheme.brandPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          if (!isVotePhase) ...[
            if (isJoined && (uc.myClue ?? '').isEmpty) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('undercover-clue-input'),
                      controller: _clueCtrl,
                      maxLength: 140,
                      decoration: const InputDecoration(
                        isDense: true,
                        counterText: '',
                        hintText: 'พิมพ์คำใบ้ 1 ประโยค (ห้ามบอกคำตรงๆ)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    key: const Key('undercover-clue-submit'),
                    onPressed: _busy
                        ? null
                        : () {
                            final clue = _clueCtrl.text.trim();
                            if (clue.isEmpty) return;
                            _clueCtrl.clear();
                            unawaited(
                              _runGameAction(
                                () => ApiService.instance.submitUndercoverClue(
                                  game.id,
                                  clue,
                                ),
                              ),
                            );
                          },
                    child: const Text('ส่งคำใบ้'),
                  ),
                ],
              ),
            ] else if ((uc.myClue ?? '').isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  border: Border.all(color: const Color(0xFFA7F3D0)),
                ),
                child: Text(
                  'คุณส่งคำใบ้แล้ว: "${uc.myClue}"',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF047857),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'คำใบ้ที่ส่งแล้ว (${uc.clues.length}/${game.players.length})',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.slateDark,
              ),
            ),
            const SizedBox(height: 5),
            if (uc.clues.isEmpty)
              const Text(
                'ยังไม่มีใครส่งคำใบ้ พิมพ์เป็นคนแรกเลย!',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              )
            else
              for (final c in uc.clues) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: AppTheme.well(radius: AppTheme.radiusSm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        '${c.displayName}: ',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateDark,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          c.clue,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.slateBody,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
              ],
            const SizedBox(height: 8),
            ElevatedButton.icon(
              key: const Key('undercover-to-vote-btn'),
              onPressed: _busy
                  ? null
                  : () => _runGameAction(
                      () => ApiService.instance.advanceGame(game.id),
                    ),
              icon: const Icon(Icons.how_to_vote_rounded, size: 17),
              label: const Text('เข้าสู่รอบโหวต'),
            ),
          ] else ...[
            if (uc.clues.isNotEmpty) ...[
              const Text(
                'สรุปคำใบ้ทั้งหมด:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.slateDark,
                ),
              ),
              const SizedBox(height: 4),
              for (final c in uc.clues) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '• ${c.displayName}: ${c.clue}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.slateBody,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
            ],
            const Text(
              'โหวตเลือกคนที่คิดว่าเป็นสายลับ (โหวตตัวเองไม่ได้)',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.slateDark,
              ),
            ),
            const SizedBox(height: 6),
            for (final p in game.players.where((pl) => pl.userId != _myUserId)) ...[
              _buildVotePlayerRow(game, uc, p, isJoined),
              const SizedBox(height: 5),
            ],
            const SizedBox(height: 6),
            ElevatedButton.icon(
              key: const Key('undercover-finish-btn'),
              onPressed: _busy
                  ? null
                  : () => _runGameAction(
                      () => ApiService.instance.advanceGame(game.id),
                    ),
              icon: const Icon(Icons.gavel_rounded, size: 17),
              label: const Text('สรุปผลสายลับ'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVotePlayerRow(
    GameSession game,
    UndercoverView uc,
    GamePlayer player,
    bool isJoined,
  ) {
    final votedThis = uc.myVote == player.userId;
    final votes = uc.voteCounts[player.userId] ?? 0;
    final canVote = !_busy && isJoined && uc.myVote == null;

    return Container(
      key: Key('undercover-vote-row-${player.userId}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: votedThis ? AppTheme.tintStrong : AppTheme.panelBg,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(
          color: votedThis ? AppTheme.brandPrimary : AppTheme.hairline,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  player.displayName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateDark,
                  ),
                ),
                if (votes > 0)
                  Text(
                    'ได้ $votes โหวต',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.slateMuted,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            key: Key('undercover-vote-${player.userId}'),
            onPressed: canVote
                ? () => _runGameAction(
                    () => ApiService.instance.submitUndercoverVote(
                      game.id,
                      player.userId,
                    ),
                  )
                : null,
            style: ElevatedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            child: Text(
              votedThis ? 'โหวตแล้ว ✓' : 'โหวตคนนี้',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // --- Engine 3: Hint Race ---
  Widget _buildHintRacePlayingView(GameSession game, HintRaceView hr) {
    final isJoined = game.hasPlayer(_myUserId);
    final isSolvedOrRevealed =
        game.roundRevealed ||
        hr.solvedByName != null ||
        hr.revealedAnswer != null;
    final isLastRound = game.roundIndex + 1 >= game.totalRounds;
    final hasMoreHints = !isSolvedOrRevealed && hr.hintLevel < hr.totalHints;

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPlayingHeaderRow(
            game,
            'ข้อ ${game.roundIndex + 1}/${game.totalRounds} · คำใบ้ ${hr.hintLevel}/${hr.totalHints}',
          ),
          const SizedBox(height: 6),
          _buildLiveScoreStrip(game),
          const SizedBox(height: 8),
          for (var i = 0; i < hr.revealedHints.length; i++) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: AppTheme.well(radius: AppTheme.radiusSm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _miniTag(
                    'คำใบ้ ${i + 1}',
                    AppTheme.tintStrong,
                    AppTheme.brandDeep,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hr.revealedHints[i],
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppTheme.slateDark,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),
          ],
          if (isSolvedOrRevealed) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(color: const Color(0xFFA7F3D0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hr.solvedByName != null)
                    Text(
                      '🎉 ${hr.solvedByName} ทายถูกแล้ว!',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF047857),
                      ),
                    ),
                  Text(
                    'เฉลย: ${hr.revealedAnswer ?? "-"}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF065F46),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (isJoined) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('hint-race-guess-input'),
                    controller: _guessCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'พิมพ์คำตอบที่ทายได้เลย...',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton(
                  key: const Key('hint-race-guess-btn'),
                  onPressed: _busy
                      ? null
                      : () {
                          final guess = _guessCtrl.text.trim();
                          if (guess.isEmpty) return;
                          _guessCtrl.clear();
                          unawaited(
                            _runGameAction(
                              () => ApiService.instance.submitHintGuess(
                                game.id,
                                guess,
                              ),
                            ),
                          );
                        },
                  child: const Text('ทายเลย'),
                ),
              ],
            ),
            if (hr.myGuesses.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'ที่เคยทาย:',
                    style: TextStyle(fontSize: 11, color: AppTheme.slateMuted),
                  ),
                  for (final g in hr.myGuesses)
                    _miniTag(g, AppTheme.panelBg, AppTheme.slateBody),
                ],
              ),
            ],
          ],
          const SizedBox(height: 8),
          ElevatedButton.icon(
            key: const Key('game-next-btn'),
            onPressed: _busy
                ? null
                : () => _runGameAction(
                    () => ApiService.instance.advanceGame(game.id),
                  ),
            icon: Icon(
              hasMoreHints
                  ? Icons.tips_and_updates_outlined
                  : Icons.arrow_forward_rounded,
              size: 17,
            ),
            label: Text(
              hasMoreHints
                  ? 'ขอคำใบ้เพิ่ม (${hr.hintLevel}/${hr.totalHints})'
                  : (!isSolvedOrRevealed
                        ? 'เฉลยคำตอบ'
                        : (isLastRound ? 'สรุปคะแนนสุดท้าย' : 'ข้อถัดไป')),
            ),
          ),
        ],
      ),
    );
  }

  // --- Engine 4: Party Vote ---
  Widget _buildPartyVotePlayingView(GameSession game, PartyVoteView pv) {
    final isJoined = game.hasPlayer(_myUserId);
    final isLastRound = game.roundIndex + 1 >= game.totalRounds;
    final totalVotes = pv.choiceCounts.fold<int>(0, (sum, c) => sum + c);

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPlayingHeaderRow(
            game,
            'รอบ ${game.roundIndex + 1}/${game.totalRounds}',
          ),
          const SizedBox(height: 6),
          _buildLiveScoreStrip(game),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: AppTheme.well(radius: AppTheme.radiusMd),
            child: Text(
              pv.prompt,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateDark,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < pv.options.length; i++) ...[
            _buildPartyVoteOption(game, pv, i, totalVotes, isJoined),
            const SizedBox(height: 6),
          ],
          if (game.roundRevealed && (pv.commentary ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0xFFF3E8FF),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(
                  color: AppTheme.personalPurple.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 16,
                    color: AppTheme.personalPurple,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pv.commentary!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.slateDark,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          ElevatedButton.icon(
            key: const Key('game-next-btn'),
            onPressed: _busy
                ? null
                : () => _runGameAction(
                    () => ApiService.instance.advanceGame(game.id),
                  ),
            icon: const Icon(Icons.arrow_forward_rounded, size: 17),
            label: Text(
              !game.roundRevealed
                  ? 'เฉลยผลโหวต'
                  : (isLastRound ? 'สรุปคะแนนสุดท้าย' : 'รอบถัดไป'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartyVoteOption(
    GameSession game,
    PartyVoteView pv,
    int index,
    int totalVotes,
    bool isJoined,
  ) {
    final isSelected = pv.myChoice == index;
    final count = index < pv.choiceCounts.length ? pv.choiceCounts[index] : 0;
    final pct = totalVotes > 0 ? ((count * 100) / totalVotes).round() : 0;
    final canTap =
        !_busy && !game.roundRevealed && pv.myChoice == null && isJoined;

    return InkWell(
      key: Key('party-option-$index'),
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      onTap: canTap
          ? () => _runGameAction(
              () => ApiService.instance.submitQuizAnswer(game.id, index),
            )
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.tintStrong : Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: isSelected ? AppTheme.brandPrimary : AppTheme.hairlineStrong,
            width: isSelected ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    pv.options[index],
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.slateDark,
                    ),
                  ),
                ),
                if (game.roundRevealed)
                  Text(
                    '$pct% ($count คน)',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brandDeep,
                    ),
                  )
                else if (isSelected)
                  Text(
                    'โหวตแล้ว ✓',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.brandDeep,
                    ),
                  ),
              ],
            ),
            if (game.roundRevealed) ...[
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: totalVotes > 0 ? count / totalVotes : 0,
                  minHeight: 6,
                  backgroundColor: AppTheme.panelBg,
                  color: AppTheme.brandPrimary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- Engine 5: Creative Challenge ---
  Widget _buildCreativePlayingView(GameSession game, CreativeChallengeView cc) {
    final isJoined = game.hasPlayer(_myUserId);
    final isLastRound = game.roundIndex + 1 >= game.totalRounds;

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPlayingHeaderRow(
            game,
            'โจทย์ ${game.roundIndex + 1}/${game.totalRounds}',
          ),
          const SizedBox(height: 6),
          _buildLiveScoreStrip(game),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: AppTheme.well(radius: AppTheme.radiusMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cc.requiresImage) ...[
                  _miniTag(
                    '📷 ภารกิจภาพถ่าย (แนบภาพจากแชทได้)',
                    const Color(0xFFFEF3C7),
                    AppTheme.warningAmber,
                  ),
                  const SizedBox(height: 5),
                ],
                Text(
                  cc.prompt,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                    height: 1.4,
                  ),
                ),
                if (cc.tip.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'ทริค: ${cc.tip}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.slateMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (!game.roundRevealed && isJoined && !cc.mySubmitted) ...[
            TextField(
              key: const Key('creative-entry-input'),
              controller: _creativeCtrl,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'เขียนคำตอบ/ไอเดียสุดสร้างสรรค์ของคุณ...',
              ),
            ),
            if (cc.requiresImage && widget.recentImageMessages.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'แนบภาพล่าสุดในห้อง:',
                    style: TextStyle(fontSize: 11, color: AppTheme.slateMuted),
                  ),
                  for (final imgMsg in widget.recentImageMessages.take(4))
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      selected: _selectedCreativeImageMsgId == imgMsg.id,
                      label: Text(
                        imgMsg.attachment?.fileName ?? 'รูปภาพ',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onSelected: (sel) => setState(() {
                        _selectedCreativeImageMsgId = sel ? imgMsg.id : null;
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            ElevatedButton.icon(
              key: const Key('creative-submit-btn'),
              onPressed: _busy
                  ? null
                  : () {
                      final text = _creativeCtrl.text.trim();
                      if (text.isEmpty) return;
                      _creativeCtrl.clear();
                      final imgId = _selectedCreativeImageMsgId;
                      setState(() => _selectedCreativeImageMsgId = null);
                      unawaited(
                        _runGameAction(
                          () => ApiService.instance.submitCreativeEntry(
                            game.id,
                            text: text,
                            imageMessageId: imgId,
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('ส่งผลงานให้ AI ตัดสิน'),
            ),
          ] else if (!game.roundRevealed && cc.mySubmitted) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(color: const Color(0xFFA7F3D0)),
              ),
              child: const Text(
                'ส่งผลงานเรียบร้อยแล้ว! รอเพื่อนคนอื่นหรือกดให้ BC AI ตัดสินคะแนน',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF047857),
                ),
              ),
            ),
          ],
          if (cc.entries.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'ผลงานที่ส่งเข้ามา (${cc.entries.length})',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.slateDark,
              ),
            ),
            const SizedBox(height: 5),
            for (final entry in cc.entries) ...[
              Container(
                padding: const EdgeInsets.all(9),
                decoration: AppTheme.well(radius: AppTheme.radiusSm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            entry.displayName,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateDark,
                            ),
                          ),
                        ),
                        if (entry.score != null)
                          _miniTag(
                            '⭐ ${entry.score} คะแนน',
                            AppTheme.tintStrong,
                            AppTheme.brandDeep,
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.text,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.slateDark,
                        height: 1.35,
                      ),
                    ),
                    if ((entry.judgeComment ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '💬 คอมเมนต์ BC AI: ${entry.judgeComment}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppTheme.personalPurple,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 5),
            ],
          ],
          const SizedBox(height: 6),
          ElevatedButton.icon(
            key: const Key('game-next-btn'),
            onPressed: _busy
                ? null
                : () => _runGameAction(
                    () => ApiService.instance.advanceGame(game.id),
                  ),
            icon: const Icon(Icons.auto_awesome_rounded, size: 17),
            label: Text(
              !game.roundRevealed
                  ? 'ให้ BC AI ตัดสินคะแนน'
                  : (isLastRound ? 'สรุปคะแนนสุดท้าย' : 'โจทย์ถัดไป'),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. Finished View (Winner Banner + Undercover Reveal + Leaderboard)
  // ---------------------------------------------------------------------------
  Widget _buildFinishedView(GameSession game) {
    final sorted = List<GamePlayer>.from(game.players)
      ..sort((a, b) => b.score.compareTo(a.score));
    final uc = game.undercover;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.surface(radius: AppTheme.radiusMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: AppTheme.brandGradient,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🏆 จบเกมแล้ว · ${game.title}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  game.winnerNames.isNotEmpty
                      ? 'ผู้ชนะ: ${game.winnerNames.join(", ")}'
                      : 'ขอบคุณทุกคนที่มาร่วมสนุก!',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.94),
                  ),
                ),
              ],
            ),
          ),
          if (game.isUndercover && uc != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: AppTheme.well(radius: AppTheme.radiusMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '🕵️ เฉลยสายลับตัวจริง',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateDark,
                    ),
                  ),
                  const SizedBox(height: 5),
                  _revealPairRow('สายลับตัวจริง', uc.revealedSpyName ?? '-'),
                  _revealPairRow('คำชาวบ้าน', uc.revealedCivilianWord ?? '-'),
                  _revealPairRow('คำสายลับ', uc.revealedSpyWord ?? '-'),
                  if (uc.winnerSide != null) ...[
                    const SizedBox(height: 4),
                    _miniTag(
                      uc.winnerSide == 'spy'
                          ? '🕵️ สายลับเนียนรอดชนะ!'
                          : '🎉 ฝั่งชาวบ้านจับสายลับได้สำเร็จ!',
                      AppTheme.tintStrong,
                      AppTheme.brandDeep,
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            'ตารางคะแนน (Leaderboard)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppTheme.slateDark,
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < sorted.length; i++) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: AppTheme.well(radius: AppTheme.radiusSm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      i == 0
                          ? '🥇'
                          : i == 1
                          ? '🥈'
                          : i == 2
                          ? '🥉'
                          : '#${i + 1}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      sorted[i].displayName,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateDark,
                      ),
                    ),
                  ),
                  Text(
                    '${sorted[i].score} แต้ม',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.brandDeep,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),
          ],
          const SizedBox(height: 8),
          ElevatedButton.icon(
            key: const Key('game-play-again-btn'),
            onPressed: () => setState(() {
              _forceLauncher = true;
              _focusedGame = null;
              _errorText = null;
              _infoText = null;
            }),
            icon: const Icon(Icons.replay_rounded, size: 17),
            label: const Text('เล่นเกมใหม่'),
          ),
        ],
      ),
    );
  }

  Widget _revealPairRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              '$label:',
              style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateDark,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _engineDisplayName(String engine) {
    switch (engine) {
      case 'quiz':
        return 'ควิซสายฟ้า AI';
      case 'undercover':
        return 'ใครคือสายลับ';
      case 'hint_race':
        return 'ทายคำใบ้ AI';
      case 'party_vote':
        return 'โหวตฮาประจำวง';
      case 'creative_challenge':
        return 'ชาเลนจ์สร้างสรรค์ AI';
      default:
        return 'เกมกลุ่ม AI';
    }
  }
}
