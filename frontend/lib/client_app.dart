/// ตัวแปรเดียวที่บอกว่าแอปนี้คือ BC Ai Chat (`chat`) หรือ BCAiChatOA (`oa`)
/// — ตั้งตอน build ด้วย `--dart-define=CLIENT_APP=oa`
const String kClientApp = String.fromEnvironment(
  'CLIENT_APP',
  defaultValue: 'chat',
);

/// true เมื่อเป็นแอปร้านค้า BCAiChatOA (const ไว้ใช้เป็นค่าเริ่มต้นของ constructor)
const bool kIsShopApp = kClientApp == 'oa';

bool get isShopApp => kIsShopApp;
