import 'dart:math' as math;
import 'dart:ui' show Rect;

/// จัดวางไทล์วิดีโอคอลกลุ่มให้เห็นครบทุกคนในกรอบเดียว (ไม่ต้องเลื่อน):
/// ไทล์ลำดับแรก (คนที่กำลังพูด) ใหญ่สุด ที่เหลือแบ่งพื้นที่ที่เหลือเป็นแถบ
/// แล้วย่อ-ขยายตามขนาดกรอบและจำนวนคน
/// (ตรรกะเดียวกับ `web/src/lib/callMosaic.ts`)
///
/// ลองทั้งแบบไทล์ใหญ่อยู่ซ้ายและอยู่บน กับจำนวนแถบของไทล์เล็กทุกค่า
/// แล้วเลือกแบบที่ด้านสั้นของไทล์เล็กยาวที่สุด (ไทล์เล็กไม่ถูกบีบจนดูไม่ออก)
List<Rect> computeCallMosaicLayout(
  int count,
  double width,
  double height, {
  double gap = 8,
}) {
  final hasBox = width > 0 && height > 0 && width.isFinite && height.isFinite;
  if (count <= 0 || !hasBox) return const [];
  if (count == 1) return [Rect.fromLTWH(0, 0, width, height)];
  final others = count - 1;
  var bestScore = 0.0;
  var lanes = 0;
  var unit = 0.0;
  var heroLeft = true;
  for (final left in const [true, false]) {
    final main = left ? width : height;
    final cross = left ? height : width;
    for (var n = 1; n <= others; n++) {
      final perLane = (others / n).ceil();
      // ไทล์ใหญ่กินสองช่วง ไทล์เล็กแถบละหนึ่งช่วง
      final u = (main - gap * (n + 1)) / (n + 2);
      final cell = (cross - gap * (perLane - 1)) / perLane;
      final score = math.min(u, cell);
      if (score > bestScore) {
        bestScore = score;
        lanes = n;
        unit = u;
        heroLeft = left;
      }
    }
  }
  if (lanes == 0) return const [];

  final cross = heroLeft ? height : width;
  final heroMain = unit * 2 + gap;
  final rects = <Rect>[
    heroLeft
        ? Rect.fromLTWH(0, 0, heroMain, height)
        : Rect.fromLTWH(0, 0, width, heroMain),
  ];
  final base = others ~/ lanes;
  final extra = others % lanes;
  for (var lane = 0; lane < lanes; lane++) {
    // แถบที่มีคนน้อยกว่า ไทล์ขยายเต็มแถบ ไม่เหลือช่องว่าง
    final inLane = base + (lane < extra ? 1 : 0);
    final cell = (cross - gap * (inLane - 1)) / inLane;
    final mainPos = (lane + 2) * (unit + gap);
    for (var i = 0; i < inLane; i++) {
      final crossPos = i * (cell + gap);
      rects.add(
        heroLeft
            ? Rect.fromLTWH(mainPos, crossPos, unit, cell)
            : Rect.fromLTWH(crossPos, mainPos, cell, unit),
      );
    }
  }
  return rects;
}

/// คงลำดับเดิมของคนที่ยังอยู่ ต่อท้ายคนใหม่ แล้วย้ายคนที่กำลังพูดขึ้นหน้า
List<String> promoteCallSpeakers(
  List<String> order,
  List<String> present,
  List<String> speaking,
) {
  final kept = order.where(present.contains).toList();
  final merged = [...kept, ...present.where((id) => !kept.contains(id))];
  return [
    ...merged.where(speaking.contains),
    ...merged.where((id) => !speaking.contains(id)),
  ];
}
