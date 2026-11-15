import 'dart:math' as math;
import 'dart:ui' show Rect;

/// จัดวางไทล์วิดีโอคอลกลุ่มแบบ masonry: ไทล์ลำดับแรก (คนที่กำลังพูด) ใหญ่สุด
/// ที่เหลือสูงไม่เท่ากันแล้วเติมลงคอลัมน์ที่เตี้ยที่สุด
/// (ตรรกะเดียวกับ `web/src/lib/callMosaic.ts`)
class CallMosaicLayout {
  final List<Rect> rects;
  final double height;
  const CallMosaicLayout(this.rects, this.height);
}

const double _wideBreakpoint = 720;
const double _heroAspect = 0.62;
const List<double> _tileAspects = [1.25, 0.9, 1.1, 0.8];

CallMosaicLayout computeCallMosaicLayout(
  int count,
  double width, {
  double gap = 8,
}) {
  if (count <= 0 || width <= 0) return const CallMosaicLayout([], 0);
  final cols = width >= _wideBreakpoint ? 3 : 2;
  final colW = (width - gap * (cols - 1)) / cols;
  final heroW = colW * 2 + gap;
  final heroH = (heroW * _heroAspect).roundToDouble();
  final rects = <Rect>[Rect.fromLTWH(0, 0, heroW, heroH)];
  final colHeights = [for (var c = 0; c < cols; c++) c < 2 ? heroH + gap : 0.0];

  for (var i = 1; i < count; i++) {
    final col = colHeights.indexOf(colHeights.reduce(math.min));
    final h = (colW * _tileAspects[(i - 1) % _tileAspects.length])
        .roundToDouble();
    rects.add(Rect.fromLTWH(col * (colW + gap), colHeights[col], colW, h));
    colHeights[col] += h + gap;
  }
  return CallMosaicLayout(rects, colHeights.reduce(math.max) - gap);
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
