// จัดวางไทล์วิดีโอคอลกลุ่มแบบ masonry: ไทล์ลำดับแรก (คนที่กำลังพูด) ใหญ่สุด
// ที่เหลือสูงไม่เท่ากันแล้วเติมลงคอลัมน์ที่เตี้ยที่สุด

export interface MosaicRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

const WIDE_BREAKPOINT = 720;
const HERO_ASPECT = 0.62;
const TILE_ASPECTS = [1.25, 0.9, 1.1, 0.8];

export function computeMosaicLayout(
  count: number,
  width: number,
  gap = 8
): { rects: MosaicRect[]; height: number } {
  if (count <= 0 || width <= 0) return { rects: [], height: 0 };
  const cols = width >= WIDE_BREAKPOINT ? 3 : 2;
  const colW = (width - gap * (cols - 1)) / cols;
  const heroW = colW * 2 + gap;
  const heroH = Math.round(heroW * HERO_ASPECT);
  const rects: MosaicRect[] = [{ x: 0, y: 0, w: heroW, h: heroH }];
  const colHeights = Array.from({ length: cols }, (_, c) => (c < 2 ? heroH + gap : 0));

  for (let i = 1; i < count; i += 1) {
    const col = colHeights.indexOf(Math.min(...colHeights));
    const h = Math.round(colW * TILE_ASPECTS[(i - 1) % TILE_ASPECTS.length]);
    rects.push({ x: col * (colW + gap), y: colHeights[col], w: colW, h });
    colHeights[col] += h + gap;
  }
  return { rects, height: Math.max(...colHeights) - gap };
}

/** คงลำดับเดิมของคนที่ยังอยู่ ต่อท้ายคนใหม่ แล้วย้ายคนที่กำลังพูดขึ้นหน้า */
export function promoteSpeakers(
  order: string[],
  present: string[],
  speaking: string[]
): string[] {
  const kept = order.filter((id) => present.includes(id));
  const merged = [...kept, ...present.filter((id) => !kept.includes(id))];
  const front = merged.filter((id) => speaking.includes(id));
  const next = [...front, ...merged.filter((id) => !speaking.includes(id))];
  const unchanged = next.length === order.length && next.every((id, i) => id === order[i]);
  return unchanged ? order : next;
}
