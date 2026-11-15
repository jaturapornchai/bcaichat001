import 'package:bcaichat_app/screens/call_mosaic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeCallMosaicLayout', () {
    test('ไทล์แรกใหญ่สุดกินสองคอลัมน์ ที่เหลือกว้างหนึ่งคอลัมน์', () {
      final layout = computeCallMosaicLayout(5, 360);
      expect(layout.rects, hasLength(5));
      expect(layout.rects.first.width, 360);
      for (final r in layout.rects.skip(1)) {
        expect(r.width, 176);
        expect(r.top, greaterThanOrEqualTo(layout.rects.first.bottom));
      }
      expect(layout.height, greaterThan(layout.rects.first.height));
    });

    test('ไทล์ไม่ซ้อนทับกัน ทั้งจอแคบและจอกว้าง', () {
      for (final width in [360.0, 900.0]) {
        final rects = computeCallMosaicLayout(8, width).rects;
        for (var a = 0; a < rects.length; a++) {
          for (var b = a + 1; b < rects.length; b++) {
            expect(
              rects[a].overlaps(rects[b]),
              isFalse,
              reason: '$width $a $b',
            );
          }
          expect(rects[a].right, lessThanOrEqualTo(width + 0.01));
        }
      }
    });

    test('ไม่มีไทล์หรือความกว้างศูนย์ คืนค่าว่าง', () {
      expect(computeCallMosaicLayout(0, 360).rects, isEmpty);
      expect(computeCallMosaicLayout(3, 0).height, 0);
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
