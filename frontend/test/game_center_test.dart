import 'dart:convert';
import 'dart:io';

import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/screens/chat_room_screen.dart';
import 'package:bcaichat_app/screens/game_center_panel.dart';
import 'package:bcaichat_app/screens/main_shell.dart';
import 'package:bcaichat_app/services/api_service.dart';
import 'package:bcaichat_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_http.dart';

void main() {
  setUp(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.setCustomBaseUrl('http://127.0.0.1:8096');
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Conversation makeGroupRoom({bool? autoInvite, int cooldownMins = 30}) {
    return Conversation.fromJson({
      'id': 'c_game_group',
      'kind': 'group',
      'name': 'แก๊งเล่นเกม',
      'folder': 'personal',
      'member_ids': ['u1', 'u2', 'u3'],
      'member_count': 3,
      'ai_game_auto_invite': ?autoInvite,
      'ai_game_invite_cooldown_mins': cooldownMins,
    });
  }

  List<GameCatalogItem> sampleCatalog() => [
    GameCatalogItem.fromJson({
      'number': 1,
      'id': 'thai_food_quiz',
      'name': 'ควิซอาหารไทย',
      'tagline': 'ทายเมนูเด็ดทั่วไทย 4 ภาค',
      'emoji': '🍜',
      'category': 'ความรู้',
      'play_mode': 'both',
      'min_players': 1,
      'engine': 'quiz',
      'default_rounds': 5,
    }),
    GameCatalogItem.fromJson({
      'number': 31,
      'id': 'street_food_spy',
      'name': 'สายลับสตรีทฟู้ด',
      'tagline': 'หาสายลับแฝงตัวในตลาดนัด',
      'emoji': '🕵️',
      'category': 'เพื่อน',
      'play_mode': 'group',
      'min_players': 2,
      'engine': 'undercover',
      'default_rounds': 1,
    }),
    GameCatalogItem.fromJson({
      'number': 46,
      'id': 'dish_from_hints',
      'name': 'ทายเมนูจาก 5 ส่วนผสม',
      'tagline': 'ยิ่งทายไวแต้มยิ่งพุ่ง',
      'emoji': '💡',
      'category': 'ครอบครัว',
      'play_mode': 'solo',
      'min_players': 1,
      'engine': 'hint_race',
      'default_rounds': 3,
    }),
    GameCatalogItem.fromJson({
      'number': 66,
      'id': 'would_you_rather_fun',
      'name': 'เลือกอะไรดีสายฮา',
      'tagline': 'คำถามชวนถกจนขำค้าง',
      'emoji': '🗳️',
      'category': 'ทายใจ/ฮา',
      'play_mode': 'both',
      'min_players': 1,
      'engine': 'party_vote',
      'default_rounds': 5,
    }),
    GameCatalogItem.fromJson({
      'number': 86,
      'id': 'two_line_poem',
      'name': 'แต่งกลอน 2 วรรคชิงแชมป์',
      'tagline': 'ให้ BC AI ตัดสินความครีเอต',
      'emoji': '✍️',
      'category': 'สร้างสรรค์',
      'play_mode': 'both',
      'min_players': 1,
      'engine': 'creative_challenge',
      'default_rounds': 3,
    }),
  ];

  // ---------------------------------------------------------------------------
  // 1. DTO Unit Tests (All 5 Engines + Catalog + Conversation/AiAdminSettings)
  // ---------------------------------------------------------------------------
  test('Game DTOs parse quiz, undercover, hint_race, party_vote, creative_challenge & defaults safely', () {
    // Conversation default auto-invite: true for group non-OA, false for direct & OA
    final groupConv = Conversation.fromJson({
      'id': 'c1',
      'kind': 'group',
      'name': 'กลุ่มเพื่อน',
    });
    expect(groupConv.aiGameAutoInvite, isTrue);
    expect(groupConv.aiGameInviteCooldownMins, 30);

    final directConv = Conversation.fromJson({
      'id': 'c2',
      'kind': 'direct',
      'name': 'แชท 1-1',
    });
    expect(directConv.aiGameAutoInvite, isFalse);

    final oaConv = Conversation.fromJson({
      'id': 'c3',
      'kind': 'group',
      'oa_id': 'oa_shop',
      'name': 'ร้านค้า',
    });
    expect(oaConv.aiGameAutoInvite, isFalse);

    final aiSettings = AiAdminSettings.fromJson({
      'enabled': true,
      'proactive_game_invites': false,
    });
    expect(aiSettings.proactiveGameInvites, isFalse);
    expect(const AiAdminSettings().proactiveGameInvites, isTrue);

    // Quiz unrevealed secrecy + revealed index 0 safety
    final unrevealedQuiz = GameSession.fromJson({
      'id': 'g_q1',
      'conversation_id': 'c1',
      'game_type': 'quiz',
      'title': 'ควิซอาหารไทย',
      'status': 'playing',
      'phase': 'question',
      'round_index': 0,
      'total_rounds': 3,
      'round_revealed': false,
      'current_question': {
        'question': 'ต้มยำกุ้งใส่สมุนไพรใด?',
        'options': ['ตะไคร้', 'อบเชย', 'กานพลู', 'โป๊ยกั๊ก'],
        'correct_index': null,
        'explanation': null,
        'my_choice': 0,
        'choice_counts': [1, 0, 0, 0],
      },
    });
    expect(unrevealedQuiz.isQuiz, isTrue);
    expect(unrevealedQuiz.currentQuestion!.correctIndex, isNull);
    expect(unrevealedQuiz.currentQuestion!.myChoice, 0);

    final revealedQuiz = GameSession.fromJson({
      'id': 'g_q1',
      'conversation_id': 'c1',
      'game_type': 'quiz',
      'title': 'ควิซอาหารไทย',
      'status': 'playing',
      'round_revealed': true,
      'current_question': {
        'question': 'ต้มยำกุ้งใส่สมุนไพรใด?',
        'options': ['ตะไคร้', 'อบเชย', 'กานพลู', 'โป๊ยกั๊ก'],
        'correct_index': 0,
        'explanation': 'ตะไคร้ ใบมะกรูด ข่า คือเครื่องต้มยำหลัก',
        'my_choice': 0,
        'choice_counts': [2, 0, 0, 0],
      },
    });
    expect(revealedQuiz.currentQuestion!.correctIndex, 0);
    expect(revealedQuiz.currentQuestion!.explanation, contains('ตะไคร้'));

    // Undercover DTO
    final ucSession = GameSession.fromJson({
      'id': 'g_uc1',
      'conversation_id': 'c1',
      'game_type': 'undercover',
      'title': 'ใครคือสายลับ',
      'status': 'finished',
      'phase': 'finished',
      'undercover': {
        'category': 'สตรีทฟู้ด',
        'my_secret_word': 'ส้มตำ',
        'my_clue': 'แซ่บๆ มีมะละกอ',
        'my_vote': 'u2',
        'clues': [
          {'user_id': 'u1', 'display_name': 'ก้อง', 'clue': 'แซ่บๆ มีมะละกอ'},
        ],
        'vote_counts': {'u2': 2},
        'revealed_spy_id': 'u2',
        'revealed_spy_name': 'แพร',
        'revealed_civilian_word': 'ส้มตำ',
        'revealed_spy_word': 'ยำวุ้นเส้น',
        'winner_side': 'civilians',
      },
    });
    expect(ucSession.isUndercover, isTrue);
    expect(ucSession.undercover!.revealedSpyName, 'แพร');
    expect(ucSession.undercover!.revealedCivilianWord, 'ส้มตำ');
    expect(ucSession.undercover!.revealedSpyWord, 'ยำวุ้นเส้น');
    expect(ucSession.undercover!.voteCounts['u2'], 2);

    // Hint Race, Party Vote, Creative Challenge, Catalog, Proactive
    final hintSession = GameSession.fromJson({
      'id': 'g_hr1',
      'conversation_id': 'c1',
      'game_type': 'hint_race',
      'title': 'ทายเมนูจาก 5 ส่วนผสม',
      'status': 'playing',
      'hint_race': {
        'revealed_hints': ['มีเส้นจันท์', 'ใส่ถั่วงอกและกุ้ยช่าย'],
        'total_hints': 5,
        'hint_level': 2,
        'solved_by_name': null,
        'revealed_answer': null,
        'my_guesses': ['ราดหน้า'],
      },
    });
    expect(hintSession.isHintRace, isTrue);
    expect(hintSession.hintRace!.revealedHints.length, 2);
    expect(hintSession.hintRace!.revealedAnswer, isNull);

    final partySession = GameSession.fromJson({
      'id': 'g_pv1',
      'conversation_id': 'c1',
      'game_type': 'party_vote',
      'title': 'เลือกอะไรดีสายฮา',
      'status': 'playing',
      'round_revealed': true,
      'party_vote': {
        'prompt': 'กินข้าวฟรีตลอดชีวิต หรือ บินฟรีทั่วโลก?',
        'options': ['กินข้าวฟรีตลอดชีวิต', 'บินฟรีทั่วโลก'],
        'my_choice': 1,
        'choice_counts': [1, 2],
        'commentary': 'สายเที่ยวชนะขาด!',
      },
    });
    expect(partySession.isPartyVote, isTrue);
    expect(partySession.partyVote!.commentary, 'สายเที่ยวชนะขาด!');

    final creativeSession = GameSession.fromJson({
      'id': 'g_cc1',
      'conversation_id': 'c1',
      'game_type': 'creative_challenge',
      'title': 'แต่งกลอน 2 วรรค',
      'status': 'playing',
      'creative_challenge': {
        'prompt': 'แต่งกลอนเรื่องกาแฟเช้าวันจันทร์',
        'tip': 'คล้องจองและฮาๆ',
        'requires_image': false,
        'my_submitted': true,
        'entries': [
          {
            'user_id': 'u1',
            'display_name': 'ก้อง',
            'text': 'เช้าวันจันทร์ง่วงหนักมาก ขอลาเต้สักแก้ว',
            'score': 92,
            'judge_comment': 'โดนใจมนุษย์ออฟฟิศ!',
          },
        ],
      },
    });
    expect(creativeSession.isCreativeChallenge, isTrue);
    expect(creativeSession.creativeChallenge!.entries.first.score, 92);

    final inviteCardMsg = ChatMessage.fromJson({
      'id': 'm_inv',
      'conversation_id': 'c1',
      'sender_id': 'user_ai',
      'sender_name': 'BC AI',
      'type': 'rich_card',
      'content': 'มาเล่นกัน',
      'card_payload': {
        'kind': 'game_invite',
        'game_id': 'g_q1',
        'title': 'ควิซอาหารไทย',
      },
    });
    expect(inviteCardMsg.previewText, contains('🎮 ควิซอาหารไทย'));
  });

  // ---------------------------------------------------------------------------
  // 2. ApiService Game Center Endpoints Test
  // ---------------------------------------------------------------------------
  test('ApiService game endpoints send expected HTTP methods, paths, and payloads', () async {
    final fake = FakeHttpOverrides((req) {
      if (req.method == 'GET' && req.uri.path == '/api/games/catalog') {
        return (
          200,
          {
            'total': 100,
            'categories': ['เพื่อน', 'ความรู้'],
            'games': [
              {
                'number': 1,
                'id': 'thai_food_quiz',
                'name': 'ควิซอาหารไทย',
                'emoji': '🍜',
                'category': 'ความรู้',
                'play_mode': 'both',
                'min_players': 1,
                'engine': 'quiz',
                'default_rounds': 5,
              },
            ],
          },
        );
      }
      if (req.method == 'POST' && req.uri.path == '/api/conversations/c1/games/random') {
        return (
          200,
          {
            'id': 'g_rand',
            'conversation_id': 'c1',
            'game_type': 'hint_race',
            'catalog_id': 'dish_from_hints',
            'title': 'ทายเมนูจาก 5 ส่วนผสม',
            'status': 'playing',
            'phase': 'hint',
          },
        );
      }
      if (req.method == 'POST' && req.uri.path == '/api/games/g_rand/guess') {
        return (
          200,
          {
            'id': 'g_rand',
            'conversation_id': 'c1',
            'game_type': 'hint_race',
            'title': 'ทายเมนูจาก 5 ส่วนผสม',
            'status': 'playing',
            'round_revealed': true,
          },
        );
      }
      if (req.method == 'POST' && req.uri.path == '/api/games/g_cc/submit') {
        return (
          200,
          {
            'id': 'g_cc',
            'conversation_id': 'c1',
            'game_type': 'creative_challenge',
            'title': 'แต่งกลอน',
            'status': 'playing',
          },
        );
      }
      if (req.method == 'PUT' && req.uri.path == '/api/conversations/c1/meta') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return (
          200,
          {
            'id': 'c1',
            'kind': 'group',
            'name': 'กลุ่ม',
            'ai_game_auto_invite': body['ai_game_auto_invite'] ?? true,
            'ai_game_invite_cooldown_mins':
                body['ai_game_invite_cooldown_mins'] ?? 30,
          },
        );
      }
      return (200, <String, dynamic>{});
    });
    HttpOverrides.global = fake;

    final cat = await ApiService.instance.listGameCatalog(
      mode: 'solo',
      category: 'ความรู้',
      q: 'อาหาร',
    );
    expect(cat.total, 100);
    expect(cat.games.first.id, 'thai_food_quiz');
    expect(fake.requests.last.uri.queryParameters['mode'], 'solo');

    final rand = await ApiService.instance.startRandomGame(
      'c1',
      mode: 'solo',
      category: 'ครอบครัว',
      autoStart: true,
    );
    expect(rand.id, 'g_rand');
    expect(rand.isHintRace, isTrue);

    final guessed = await ApiService.instance.submitHintGuess('g_rand', 'ผัดไทย');
    expect(guessed.roundRevealed, isTrue);
    expect(jsonDecode(fake.requests.last.body)['guess'], 'ผัดไทย');

    await ApiService.instance.submitCreativeEntry(
      'g_cc',
      text: 'กลอนเด็ด',
      imageMessageId: 'm_img_9',
    );
    final ccBody = jsonDecode(fake.requests.last.body) as Map<String, dynamic>;
    expect(ccBody['text'], 'กลอนเด็ด');
    expect(ccBody['image_message_id'], 'm_img_9');

    final updated = await ApiService.instance.updateConversationMeta(
      'c1',
      aiGameAutoInvite: false,
      aiGameInviteCooldownMins: 60,
    );
    expect(updated?.aiGameAutoInvite, isFalse);
    expect(updated?.aiGameInviteCooldownMins, 60);
  });

  // ---------------------------------------------------------------------------
  // 3. GameCenterPanel Widget Test: Launcher + Catalog + Random + Toggle ON/OFF
  // ---------------------------------------------------------------------------
  testWidgets(
    'GameCenterPanel renders 100-game randomizer, catalog search, per-room ON/OFF toggle & cooldown',
    (WidgetTester tester) async {
      final fake = FakeHttpOverrides((req) {
        if (req.method == 'PUT' && req.uri.path.endsWith('/meta')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return (
            200,
            {
              'id': 'c_game_group',
              'kind': 'group',
              'name': 'แก๊งเล่นเกม',
              'ai_game_auto_invite': body['ai_game_auto_invite'] ?? true,
              'ai_game_invite_cooldown_mins':
                  body['ai_game_invite_cooldown_mins'] ?? 30,
            },
          );
        }
        if (req.method == 'POST' && req.uri.path.endsWith('/games/random')) {
          return (
            200,
            {
              'id': 'g_rand_1',
              'conversation_id': 'c_game_group',
              'game_type': 'quiz',
              'catalog_id': 'thai_food_quiz',
              'emoji': '🍜',
              'title': 'ควิซอาหารไทย',
              'status': 'lobby',
              'phase': 'lobby',
              'host_message': 'มาประลองความรู้เรื่องอาหารไทยกัน!',
              'players': [
                {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 0},
              ],
            },
          );
        }
        return (200, <String, dynamic>{});
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(400, 880);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: GameCenterPanel(
              conversation: makeGroupRoom(autoInvite: true, cooldownMins: 30),
              initialState: const ActiveGameState(
                aiGameAutoInvite: true,
                aiGameInviteCooldownMins: 30,
                proactiveEnabledGlobally: true,
                recentGames: [
                  GameSummary(
                    id: 'g_old',
                    gameType: 'quiz',
                    title: 'ควิซยุค 90',
                    status: 'finished',
                    winnerNames: ['แพร'],
                    playerCount: 3,
                  ),
                ],
              ),
              initialCatalog: sampleCatalog(),
              autoLoad: false,
              currentUserIdOverride: 'u1',
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('🎮 เครื่องเล่นเกมกลุ่ม AI'), findsOneWidget);
      expect(find.text('AI ชวนเล่นอัตโนมัติ'), findsOneWidget);
      expect(find.text('15 นาที'), findsOneWidget);
      expect(find.text('30 นาที'), findsOneWidget);
      expect(find.text('60 นาที'), findsOneWidget);
      expect(find.byKey(const Key('game-random-btn')), findsOneWidget);
      expect(find.byKey(const Key('game-proactive-btn')), findsOneWidget);

      // Search 100-game catalog for 'สายลับ'
      await tester.enterText(
        find.byKey(const Key('game-catalog-search')),
        'สายลับ',
      );
      await tester.pumpAndSettle();
      expect(find.text('สายลับสตรีทฟู้ด'), findsOneWidget);
      expect(find.text('ควิซอาหารไทย'), findsNothing);

      // Toggle cooldown to 60 mins
      await tester.tap(find.byKey(const Key('game-cooldown-60')));
      await tester.pumpAndSettle();
      final cdReq = fake.requests.lastWhere((r) => r.method == 'PUT');
      expect(jsonDecode(cdReq.body)['ai_game_invite_cooldown_mins'], 60);

      // Toggle room auto-invite OFF -> cooldown chips hide
      await tester.tap(find.byKey(const Key('game-auto-invite-switch')));
      await tester.pumpAndSettle();
      final offReq = fake.requests.lastWhere((r) => r.method == 'PUT');
      expect(jsonDecode(offReq.body)['ai_game_auto_invite'], isFalse);
      expect(find.text('15 นาที'), findsNothing);

      // Tap randomizer button -> transitions into Lobby view
      await tester.tap(find.byKey(const Key('game-random-btn')));
      await tester.pumpAndSettle();
      expect(find.text('มาประลองความรู้เรื่องอาหารไทยกัน!'), findsOneWidget);
      expect(find.byKey(const Key('game-start-btn')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // ---------------------------------------------------------------------------
  // 4. GameCenterPanel Widget Test: Quiz Playing -> Reveal -> Finished
  // ---------------------------------------------------------------------------
  testWidgets(
    'GameCenterPanel plays Quiz round (answer -> reveal explanation -> finished leaderboard)',
    (WidgetTester tester) async {
      final fake = FakeHttpOverrides((req) {
        if (req.method == 'POST' && req.uri.path == '/api/games/g_q/answer') {
          return (
            200,
            {
              'id': 'g_q',
              'conversation_id': 'c_game_group',
              'game_type': 'quiz',
              'title': 'ควิซอาหารไทย',
              'status': 'playing',
              'phase': 'question',
              'round_index': 0,
              'total_rounds': 1,
              'round_revealed': true,
              'players': [
                {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 140, 'answered': true},
              ],
              'current_question': {
                'question': 'ส้มตำไทยดั้งเดิมใส่ถั่วอะไร?',
                'options': ['ถั่วลิสงคั่ว', 'ถั่วดำ', 'ถั่วแดง', 'ถั่วเหลือง'],
                'correct_index': 0,
                'explanation': 'ส้มตำไทยใส่ถั่วลิสงคั่วเพิ่มความหอมมัน',
                'my_choice': 0,
                'choice_counts': [1, 0, 0, 0],
              },
            },
          );
        }
        if (req.method == 'POST' && req.uri.path == '/api/games/g_q/next') {
          return (
            200,
            {
              'id': 'g_q',
              'conversation_id': 'c_game_group',
              'game_type': 'quiz',
              'title': 'ควิซอาหารไทย',
              'status': 'finished',
              'phase': 'finished',
              'round_index': 0,
              'total_rounds': 1,
              'round_revealed': true,
              'players': [
                {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 140},
              ],
              'winner_names': ['ก้อง'],
            },
          );
        }
        return (200, <String, dynamic>{});
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(400, 880);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final playingQuiz = GameSession.fromJson({
        'id': 'g_q',
        'conversation_id': 'c_game_group',
        'game_type': 'quiz',
        'title': 'ควิซอาหารไทย',
        'status': 'playing',
        'phase': 'question',
        'round_index': 0,
        'total_rounds': 1,
        'round_revealed': false,
        'players': [
          {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 0, 'answered': false},
        ],
        'current_question': {
          'question': 'ส้มตำไทยดั้งเดิมใส่ถั่วอะไร?',
          'options': ['ถั่วลิสงคั่ว', 'ถั่วดำ', 'ถั่วแดง', 'ถั่วเหลือง'],
          'correct_index': null,
          'explanation': null,
          'my_choice': null,
          'choice_counts': [0, 0, 0, 0],
        },
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: GameCenterPanel(
              conversation: makeGroupRoom(),
              initialState: ActiveGameState(activeGame: playingQuiz),
              initialFocusedGame: playingQuiz,
              autoLoad: false,
              currentUserIdOverride: 'u1',
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ส้มตำไทยดั้งเดิมใส่ถั่วอะไร?'), findsOneWidget);
      expect(find.text('ก'), findsOneWidget);
      expect(find.text('ถั่วลิสงคั่ว'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quiz-option-0')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('ส้มตำไทยใส่ถั่วลิสงคั่วเพิ่มความหอมมัน'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('game-next-btn')));
      await tester.pumpAndSettle();
      expect(find.textContaining('ผู้ชนะ: ก้อง'), findsOneWidget);
      expect(find.byKey(const Key('game-play-again-btn')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // ---------------------------------------------------------------------------
  // 5. GameCenterPanel Widget Test: Undercover (Tap-to-Reveal, Clue, Vote excludes self)
  // ---------------------------------------------------------------------------
  testWidgets(
    'GameCenterPanel Undercover hides secret word until tapped, submits clue, and excludes self in vote list',
    (WidgetTester tester) async {
      final fake = FakeHttpOverrides((req) {
        if (req.method == 'POST' && req.uri.path == '/api/games/g_uc/clue') {
          return (
            200,
            {
              'id': 'g_uc',
              'conversation_id': 'c_game_group',
              'game_type': 'undercover',
              'title': 'ใครคือสายลับ',
              'status': 'playing',
              'phase': 'vote',
              'players': [
                {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 0},
                {'user_id': 'u2', 'display_name': 'แพร', 'score': 0},
              ],
              'undercover': {
                'category': 'เครื่องดื่ม',
                'my_secret_word': 'ชาไทย',
                'my_clue': 'สีส้มหวานมัน',
                'clues': [
                  {'user_id': 'u1', 'display_name': 'ก้อง', 'clue': 'สีส้มหวานมัน'},
                  {'user_id': 'u2', 'display_name': 'แพร', 'clue': 'สีเขียวหอมๆ'},
                ],
                'vote_counts': <String, int>{},
              },
            },
          );
        }
        return (200, <String, dynamic>{});
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(400, 880);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ucPlaying = GameSession.fromJson({
        'id': 'g_uc',
        'conversation_id': 'c_game_group',
        'game_type': 'undercover',
        'title': 'ใครคือสายลับ',
        'status': 'playing',
        'phase': 'clue',
        'players': [
          {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 0},
          {'user_id': 'u2', 'display_name': 'แพร', 'score': 0},
        ],
        'undercover': {
          'category': 'เครื่องดื่ม',
          'my_secret_word': 'ชาไทย',
          'clues': <Object?>[],
          'vote_counts': <String, int>{},
        },
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: GameCenterPanel(
              conversation: makeGroupRoom(),
              initialState: ActiveGameState(activeGame: ucPlaying),
              initialFocusedGame: ucPlaying,
              autoLoad: false,
              currentUserIdOverride: 'u1',
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Secret word must be hidden by default!
      expect(find.text('ชาไทย'), findsNothing);
      expect(find.textContaining('แตะเพื่อดูคำลับ'), findsOneWidget);

      // Tap to reveal secret word
      await tester.tap(find.byKey(const Key('undercover-secret-card')));
      await tester.pumpAndSettle();
      expect(find.text('ชาไทย'), findsOneWidget);

      // Tap again to hide secret word
      await tester.tap(find.byKey(const Key('undercover-secret-card')));
      await tester.pumpAndSettle();
      expect(find.text('ชาไทย'), findsNothing);

      // Submit clue -> transitions to vote phase
      await tester.enterText(
        find.byKey(const Key('undercover-clue-input')),
        'สีส้มหวานมัน',
      );
      await tester.tap(find.byKey(const Key('undercover-clue-submit')));
      await tester.pumpAndSettle();

      // Self ('u1') MUST be excluded from vote targets; 'u2' must be present!
      expect(find.byKey(const Key('undercover-vote-u1')), findsNothing);
      expect(find.byKey(const Key('undercover-vote-u2')), findsOneWidget);
      expect(find.byKey(const Key('undercover-finish-btn')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // ---------------------------------------------------------------------------
  // 6. GameCenterPanel Widget Tests for Hint Race, Party Vote, Creative Challenge
  // ---------------------------------------------------------------------------
  testWidgets(
    'GameCenterPanel renders hint_race, party_vote, and creative_challenge engines inline',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 880);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Hint Race
      final hrGame = GameSession.fromJson({
        'id': 'g_hr',
        'conversation_id': 'c_game_group',
        'game_type': 'hint_race',
        'title': 'ทายเมนูจาก 5 ส่วนผสม',
        'status': 'playing',
        'round_index': 0,
        'total_rounds': 3,
        'players': [
          {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 50},
        ],
        'hint_race': {
          'revealed_hints': ['เมนูเส้นผัดกระทะร้อน'],
          'total_hints': 5,
          'hint_level': 1,
          'my_guesses': <String>[],
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: GameCenterPanel(
              conversation: makeGroupRoom(),
              initialState: ActiveGameState(activeGame: hrGame),
              initialFocusedGame: hrGame,
              autoLoad: false,
              currentUserIdOverride: 'u1',
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('เมนูเส้นผัดกระทะร้อน'), findsOneWidget);
      expect(find.textContaining('ขอคำใบ้เพิ่ม'), findsOneWidget);

      // Party Vote
      final pvGame = GameSession.fromJson({
        'id': 'g_pv',
        'conversation_id': 'c_game_group',
        'game_type': 'party_vote',
        'title': 'เลือกอะไรดีสายฮา',
        'status': 'playing',
        'round_index': 0,
        'total_rounds': 5,
        'round_revealed': true,
        'players': [
          {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 100},
        ],
        'party_vote': {
          'prompt': 'ตื่นตี 5 ทุกวัน หรือ นอนตี 2 ทุกคืน?',
          'options': ['ตื่นตี 5', 'นอนตี 2'],
          'my_choice': 0,
          'choice_counts': [2, 1],
          'commentary': 'สายเช้ากำลังมาแรง!',
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: GameCenterPanel(
              conversation: makeGroupRoom(),
              initialState: ActiveGameState(activeGame: pvGame),
              initialFocusedGame: pvGame,
              autoLoad: false,
              currentUserIdOverride: 'u1',
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('สายเช้ากำลังมาแรง!'), findsOneWidget);
      expect(find.text('67% (2 คน)'), findsOneWidget);

      // Creative Challenge
      final ccGame = GameSession.fromJson({
        'id': 'g_cc',
        'conversation_id': 'c_game_group',
        'game_type': 'creative_challenge',
        'title': 'แต่งกลอน 2 วรรค',
        'status': 'playing',
        'round_index': 0,
        'total_rounds': 3,
        'players': [
          {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 90},
        ],
        'creative_challenge': {
          'prompt': 'ตั้งแคปชันรูปกาแฟเย็นวันจันทร์',
          'tip': 'สั้นๆ ขำๆ',
          'requires_image': false,
          'my_submitted': false,
          'entries': [
            {
              'user_id': 'u2',
              'display_name': 'แพร',
              'text': 'กาแฟไม่ได้ทำให้ตื่น แต่ทำให้มีแรงบ่น',
              'score': 95,
              'judge_comment': 'เฉียบมาก!',
            },
          ],
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: GameCenterPanel(
              conversation: makeGroupRoom(),
              initialState: ActiveGameState(activeGame: ccGame),
              initialFocusedGame: ccGame,
              autoLoad: false,
              currentUserIdOverride: 'u1',
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ตั้งแคปชันรูปกาแฟเย็นวันจันทร์'), findsOneWidget);
      expect(find.text('⭐ 95 คะแนน'), findsOneWidget);
      expect(find.textContaining('เฉียบมาก!'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // ---------------------------------------------------------------------------
  // 7. ChatRoomScreen Integration Test: Active Banner, + Tray & game_invite Card
  // ---------------------------------------------------------------------------
  testWidgets(
    'ChatRoomScreen displays Active Game Banner, + tray game button, and game_invite card actions',
    (WidgetTester tester) async {
      final inviteMessage = {
        'id': 'm_game_inv_1',
        'conversation_id': 'c_game_group',
        'sender_id': 'user_ai',
        'sender_name': 'BC AI',
        'type': 'rich_card',
        'content': 'มาเล่นควิซอาหารไทยกัน!',
        'card_payload': {
          'kind': 'game_invite',
          'game_id': 'g_live_1',
          'game_type': 'quiz',
          'title': 'ควิซอาหารไทย',
          'topic': 'อาหารไทย',
          'proactive': true,
          'host_message': 'ห้องเงียบๆ มาแข่งควิซสั้นๆ 3 ข้อกันไหม?',
        },
        'created_at': '2026-11-22T12:00:00Z',
      };

      final activeGameJson = {
        'id': 'g_live_1',
        'conversation_id': 'c_game_group',
        'game_type': 'quiz',
        'title': 'ควิซอาหารไทย',
        'topic': 'อาหารไทย',
        'status': 'lobby',
        'phase': 'lobby',
        'proactive': true,
        'host_message': 'ห้องเงียบๆ มาแข่งควิซสั้นๆ 3 ข้อกันไหม?',
        'players': [
          {'user_id': 'u2', 'display_name': 'แพร', 'score': 0},
        ],
      };

      final fake = FakeHttpOverrides((req) {
        if (req.method == 'GET' && req.uri.path.endsWith('/messages')) {
          return (200, [inviteMessage]);
        }
        if (req.method == 'GET' && req.uri.path.endsWith('/games/active')) {
          return (
            200,
            {
              'active_game': activeGameJson,
              'recent_games': <Object?>[],
              'ai_game_auto_invite': true,
              'ai_game_invite_cooldown_mins': 30,
              'proactive_enabled_globally': true,
            },
          );
        }
        if (req.method == 'GET' && req.uri.path == '/api/games/catalog') {
          return (200, {'total': 100, 'categories': ['เพื่อน'], 'games': []});
        }
        if (req.method == 'POST' && req.uri.path == '/api/games/g_live_1/join') {
          return (
            200,
            {
              ...activeGameJson,
              'players': [
                {'user_id': 'u2', 'display_name': 'แพร', 'score': 0},
                {'user_id': 'u1', 'display_name': 'ก้อง', 'score': 0},
              ],
            },
          );
        }
        if (req.method == 'PUT' && req.uri.path.endsWith('/meta')) {
          return (
            200,
            {
              'id': 'c_game_group',
              'kind': 'group',
              'name': 'แก๊งเล่นเกม',
              'ai_game_auto_invite': false,
              'ai_game_invite_cooldown_mins': 30,
            },
          );
        }
        return (200, <String, dynamic>{});
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(420, 880);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final room = makeGroupRoom(autoInvite: true);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: ChatRoomScreen(
              conversation: room,
              allConversations: [room],
              miniApps: const [],
              friends: const [],
              isEmbedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Active Game Banner appears at top of room
      expect(find.byKey(const Key('active-game-banner')), findsOneWidget);
      expect(find.text('เปิดเกม'), findsOneWidget);

      // game_invite card appears with both buttons
      expect(find.text('🎮 เข้าร่วมเล่นเลย'), findsOneWidget);
      expect(find.text('🔕 ปิดชวนเล่นห้องนี้'), findsOneWidget);

      // Tap 1-tap mute button -> sends ai_game_auto_invite: false & shows SnackBar
      await tester.tap(find.byKey(const Key('game-invite-mute-g_live_1')));
      await tester.pumpAndSettle();
      final putReq = fake.requests.lastWhere((r) => r.method == 'PUT');
      expect(jsonDecode(putReq.body)['ai_game_auto_invite'], isFalse);
      expect(
        find.textContaining('ปิดไม่ให้ AI ชวนเล่นเกมอัตโนมัติในห้องนี้แล้ว'),
        findsOneWidget,
      );

      // Tap join button -> joins game & opens GameCenterPanel inline (Zero-Popup!)
      await tester.tap(find.byKey(const Key('game-invite-join-g_live_1')));
      await tester.pumpAndSettle();
      expect(find.byType(GameCenterPanel), findsOneWidget);
      expect(
        fake.requests.any((r) => r.uri.path == '/api/games/g_live_1/join'),
        isTrue,
      );

      // Close inline panel, dismiss SnackBar covering composer, & check + tray has 'เกมกลุ่ม AI'
      await tester.tap(find.byKey(const Key('game-panel-close-btn')));
      await tester.pumpAndSettle();
      ScaffoldMessenger.of(
        tester.element(find.byType(ChatRoomScreen)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
      await tester.pumpAndSettle();
      expect(find.text('เกมกลุ่ม AI'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  // ---------------------------------------------------------------------------
  // 8. AdminAiSettingsCard Global Proactive Game Invite Switch
  // ---------------------------------------------------------------------------
  testWidgets(
    'AdminAiSettingsCard toggles global proactive_game_invites switch and saves it',
    (WidgetTester tester) async {
      final fake = FakeHttpOverrides((req) {
        if (req.method == 'PUT' && req.uri.path == '/api/admin/ai-settings') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return (
            200,
            {
              'enabled': body['enabled'] ?? true,
              'managed_by_system': true,
              'system_ready': true,
              'system_prompt': body['system_prompt'] ?? '',
              'auto_reply_in_groups': body['auto_reply_in_groups'] ?? true,
              'redact_confidential': body['redact_confidential'] ?? true,
              'proactive_game_invites': body['proactive_game_invites'] ?? true,
              'updated_at': '2026-11-22T12:00:00Z',
            },
          );
        }
        return null;
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AiAdminSettings? updated;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: AdminAiSettingsCard(
                initialSettings: const AiAdminSettings(),
                onUpdated: (s) => updated = s,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('ให้ BC AI ชวนเล่นเกมในกลุ่มอัตโนมัติ (ทั้งระบบ)'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('bc-ai-proactive-games-switch')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('bc-ai-save-btn')));
      await tester.tap(find.byKey(const Key('bc-ai-save-btn')));
      await tester.pumpAndSettle();

      expect(updated?.proactiveGameInvites, isFalse);
      final putBody = jsonDecode(fake.requests.last.body) as Map<String, dynamic>;
      expect(putBody['proactive_game_invites'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
