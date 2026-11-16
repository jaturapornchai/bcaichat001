import 'dart:ui' show Rect;

import 'package:bcaichat_app/screens/call_mosaic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeCallMosaicLayout', () {
    const boxes = [(344.0, 520.0), (1960.0, 1210.0), (900.0, 300.0), (300.0, 900.0)];

    test('ทุกไทล์อยู่ในกรอบและไม่ซ้อนทับกัน ทุกขนาดจอและจำนวนคน', () {
      for (final (width, height) in boxes) {
        for (var count = 1; count <= 12; count++) {
          final rects = computeCallMosaicLayout(count, width, height);
          final why = '$width x $height, $count คน';
          expect(rects, hasLength(count), reason: why);
          for (var a = 0; a < rects.length; a++) {
            expect(rects[a].left, greaterThanOrEqualTo(-0.01), reason: why);
            expect(rects[a].top, greaterThanOrEqualTo(-0.01), reason: why);
            expect(rects[a].right, lessThanOrEqualTo(width + 0.01), reason: why);
            expect(rects[a].bottom, lessThanOrEqualTo(height + 0.01), reason: why);
            expect(rects[a].shortestSide, greaterThan(20), reason: why);
            for (var b = a + 1; b < rects.length; b++) {
              expect(rects[a].overlaps(rects[b]), isFalse, reason: '$why $a $b');
            }
          }
        }
      }
    });

    test('ไทล์แรก (คนที่กำลังพูด) ใหญ่กว่าไทล์อื่นเสมอ', () {
      for (final (width, height) in boxes) {
        final rects = computeCallMosaicLayout(7, width, height);
        final heroArea = rects.first.width * rects.first.height;
        for (final r in rects.skip(1)) {
          expect(r.width * r.height, lessThan(heroArea));
        }
      }
    });

    test('จอกว้าง 3 คน: ไทล์ใหญ่อยู่ซ้ายเต็มความสูง อีกสองไทล์ซ้อนกันทางขวา', () {
      final rects = computeCallMosaicLayout(3, 1960, 1210);
      expect(rects[0], const Rect.fromLTWH(0, 0, 1304, 1210));
      expect(rects[1], const Rect.fromLTWH(1312, 0, 648, 601));
      expect(rects[2], const Rect.fromLTWH(1312, 609, 648, 601));
    });

    test('จอตั้ง 3 คน: ไทล์ใหญ่อยู่บนเต็มความกว้าง อีกสองไทล์เรียงข้างกันด้านล่าง', () {
      final rects = computeCallMosaicLayout(3, 344, 520);
      expect(rects[0], const Rect.fromLTWH(0, 0, 344, 344));
      expect(rects[1], const Rect.fromLTWH(0, 352, 168, 168));
      expect(rects[2], const Rect.fromLTWH(176, 352, 168, 168));
    });

    test('ไม่มีไทล์หรือกรอบเป็นศูนย์ คืนค่าว่าง', () {
      expect(computeCallMosaicLayout(0, 360, 500), isEmpty);
      expect(computeCallMosaicLayout(3, 0, 500), isEmpty);
      expect(computeCallMosaicLayout(3, 360, 0), isEmpty);
      expect(computeCallMosaicLayout(3, 360, double.infinity), isEmpty);
    });
  });

  group('promoteCallSpeakers', () {
    test('คนที่พูดขึ้นหน้า คนอื่นคงลำดับเดิม', () {
      expect(
        promoteCallSpeakers(['a', 'b', 'c', 'd'], ['a', 'b', 'c', 'd'], ['c']),
        ['c', 'a', 'b', 'd'],
      );
    });

    test('ตัดคนที่ออกจากสาย และต่อท้ายคนเข้าใหม่', () {
      expect(promoteCallSpeakers(['a', 'b', 'c'], ['c', 'a', 'e'], const []), [
        'a',
        'c',
        'e',
      ]);
    });
  });
}
