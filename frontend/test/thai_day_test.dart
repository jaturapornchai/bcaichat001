import 'package:bcaichat_app/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // สร้างเวลาแบบ local แล้วแปลงเป็น ISO UTC เพื่อให้ผลไม่ขึ้นกับเขตเวลาของเครื่องที่รัน
  String iso(int y, int m, int d, [int h = 12]) =>
      DateTime(y, m, d, h).toUtc().toIso8601String();
  final now = DateTime(2026, 11, 16, 9);

  test('formatThaiDay: วันนี้ / เมื่อวาน / วันอื่น / ต่างปี', () {
    expect(formatThaiDay(iso(2026, 11, 16, 0), now: now), 'วันนี้');
    expect(formatThaiDay(iso(2026, 11, 15, 23), now: now), 'เมื่อวาน');
    // 14 พ.ย. 2026 ตรงกับวันเสาร์
    expect(formatThaiDay(iso(2026, 11, 14), now: now), 'ส. 14 พ.ย.');
    // 31 ธ.ค. 2025 ตรงกับวันพุธ — ต่างปีต้องต่อท้ายด้วย พ.ศ.
    expect(formatThaiDay(iso(2025, 12, 31), now: now), 'พ. 31 ธ.ค. 2568');
  });

  test('formatThaiDay: อ่านวันที่ไม่ได้คืนค่าว่าง', () {
    expect(formatThaiDay(null, now: now), '');
    expect(formatThaiDay('', now: now), '');
    expect(formatThaiDay('ไม่ใช่วันที่', now: now), '');
  });

  test('isSameLocalDay: เทียบตามวันของเครื่อง ไม่ใช่ตามชั่วโมง', () {
    expect(isSameLocalDay(iso(2026, 11, 16, 0), iso(2026, 11, 16, 23)), isTrue);
    expect(isSameLocalDay(iso(2026, 11, 15, 23), iso(2026, 11, 16, 0)), isFalse);
    expect(isSameLocalDay(null, iso(2026, 11, 16)), isFalse);
  });
}
