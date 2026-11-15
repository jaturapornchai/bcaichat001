import 'package:flutter_test/flutter_test.dart';
import 'package:bcaichat_app/theme/app_theme.dart';

void main() {
  test('avatar initials never show dangling Thai marks or brackets', () {
    expect(avatarInitials('ลุงจืด (Super Admin)'), 'ล');
    expect(avatarInitials('ลุงจืด (เจ้าของระบบ)'), 'ลจ');
    expect(avatarInitials('สมชาย เพื่อนบ้าน'), 'สพ');
    expect(avatarInitials('นิดา พี่สาว'), 'นพ');
    expect(avatarInitials('ห้องแชทลับครอบครัว E2E'), 'ห');
    expect(avatarInitials('เจด ใจดี'), 'จจ');
    expect(avatarInitials('BC Ai Chat'), 'BA');
    expect(avatarInitials('🤖 BC AI'), 'BA');
    expect(avatarInitials('🤖 BC AI ผู้ช่วยส่วนตัว'), 'BA');
    expect(avatarInitials('🤖 ผู้ช่วยส่วนตัว'), 'ผ');
    expect(avatarInitials('🇹🇭 สวัสดี ไทยแลนด์'), 'สท');
    expect(avatarInitials('👨‍👩‍👧 ครอบครัวอบอุ่น'), 'ค');
    expect(avatarInitials('🌸น้ำใส'), 'น');
    expect(avatarInitials('🤖😊🎉'), 'BC');
    expect(avatarInitials('   '), 'BC');
  });
}
