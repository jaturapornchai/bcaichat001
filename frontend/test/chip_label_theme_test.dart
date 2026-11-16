import 'package:bcaichat_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  /// Colour the chip label is painted with under the app theme.
  Future<Color?> labelColor(
    WidgetTester tester, {
    required bool selected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.buildTheme(),
        home: Scaffold(
          body: ChoiceChip(
            // Same shape as the shop console chips: the label sets only its
            // size and leaves the colour to the theme.
            label: const Text('ลูกค้า', style: TextStyle(fontSize: 12)),
            selected: selected,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    final label = tester.widget<RichText>(
      find.descendant(
        of: find.byType(ChoiceChip),
        matching: find.byType(RichText),
      ),
    );
    return label.text.style?.color;
  }

  testWidgets('chip label takes a readable colour from the theme', (
    tester,
  ) async {
    expect(await labelColor(tester, selected: false), AppTheme.slateBody);
    expect(await labelColor(tester, selected: true), AppTheme.brandDeep);
  });
}
