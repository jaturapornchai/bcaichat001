// จัดวางไทล์วิดีโอคอลกลุ่มให้เห็นครบทุกคนในกรอบเดียว (ไม่ต้องเลื่อน):
// ไทล์ลำดับแรก (คนที่กำลังพูด) ใหญ่สุด ที่เหลือแบ่งพื้นที่ที่เหลือเป็นแถบ
// แล้วย่อ-ขยายตามขนาดกรอบและจำนวนคน

export interface MosaicRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * ลองทั้งแบบไทล์ใหญ่อยู่ซ้ายและอยู่บน กับจำนวนแถบของไทล์เล็กทุกค่า
 * แล้วเลือกแบบที่ด้านสั้นของไทล์เล็กยาวที่สุด (ไทล์เล็กไม่ถูกบีบจนดูไม่ออก)
 */
export function computeMosaicLayout(
  count: number,
  width: number,
  height: number,
  gap = 8
): MosaicRect[] {
  if (count <= 0 || width <= 0 || height <= 0) return [];
  if (count === 1) return [{ x: 0, y: 0, w: width, h: height }];
  const others = count - 1;
  let best: { heroLeft: boolean; lanes: number; unit: number; score: number } | null = null;
  for (const heroLeft of [true, false]) {
    const main = heroLeft ? width : height;
    const cross = heroLeft ? height : width;
    for (let lanes = 1; lanes <= others; lanes += 1) {
      const perLane = Math.ceil(others / lanes);
      // ไทล์ใหญ่กินสองช่วง ไทล์เล็กแถบละหนึ่งช่วง
      const unit = (main - gap * (lanes + 1)) / (lanes + 2);
      const cell = (cross - gap * (perLane - 1)) / perLane;
      const score = Math.min(unit, cell);
      if (score > 0 && (!best || score > best.score)) best = { heroLeft, lanes, unit, score };
    }
  }
  if (!best) return [];

  const { heroLeft, lanes, unit } = best;
  const cross = heroLeft ? height : width;
  const heroMain = unit * 2 + gap;
  const rects: MosaicRect[] = [
    heroLeft ? { x: 0, y: 0, w: heroMain, h: height } : { x: 0, y: 0, w: width, h: heroMain },
  ];
  const base = Math.floor(others / lanes);
  const extra = others % lanes;
  for (let lane = 0; lane < lanes; lane += 1) {
    // แถบที่มีคนน้อยกว่า ไทล์ขยายเต็มแถบ ไม่เหลือช่องว่าง
    const inLane = base + (lane < extra ? 1 : 0);
    const cell = (cross - gap * (inLane - 1)) / inLane;
    const mainPos = (lane + 2) * (unit + gap);
    for (let i = 0; i < inLane; i += 1) {
      const crossPos = i * (cell + gap);
      rects.push(
        heroLeft
          ? { x: mainPos, y: crossPos, w: unit, h: cell }
          : { x: crossPos, y: mainPos, w: cell, h: unit }
      );
    }
  }
  return rects;
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
