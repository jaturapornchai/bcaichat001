import type { RoomToneId, ThemePresetId } from "./types";

export interface ThemePalette {
  id: ThemePresetId;
  name: string;
  subtitle: string;
  primary: string;
  deep: string;
  ring: string;
  ochre: string;
  gold: string;
  surface: string;
  panel: string;
  sand: string;
  card: string;
  border: string;
  soft: string;
  text: string;
  muted: string;
  bubbleSent: string;
  bubbleSentText: string;
  bubbleRecv: string;
}

export const THEME_PRESETS: Record<ThemePresetId, ThemePalette> = {
  ban_chiang: {
    id: "ban_chiang",
    name: "บ้านเชียง (ดินเผาไทย)",
    subtitle: "โทนดินเผาลายเขียนสีร่วมสมัย อบอุ่นเป็นกันเอง",
    primary: "#812920",
    deep: "#681F18",
    ring: "#A04035",
    ochre: "#83280E",
    gold: "#D4A373",
    surface: "#FBF9F8",
    panel: "#F6F3F2",
    sand: "#E4DFD1",
    card: "#FFFFFF",
    border: "#DCC0BC",
    soft: "#FFDAD5",
    text: "#1B1C1C",
    muted: "#615E53",
    bubbleSent: "#FADBD4",
    bubbleSentText: "#2B1410",
    bubbleRecv: "#FFFFFF",
  },
  silk_amber: {
    id: "silk_amber",
    name: "ไหมทองอำพัน",
    subtitle: "อบอุ่นนุ่มนวลสบายตา สไตล์ไหมทองทอมือ",
    primary: "#B45309",
    deep: "#92400E",
    ring: "#D97706",
    ochre: "#78350F",
    gold: "#F59E0B",
    surface: "#FFFDF9",
    panel: "#FAF5EE",
    sand: "#EFE6D5",
    card: "#FFFFFF",
    border: "#E6D0B3",
    soft: "#FEF3C7",
    text: "#1F1A14",
    muted: "#6B5E4E",
    bubbleSent: "#FDE68A",
    bubbleSentText: "#451A03",
    bubbleRecv: "#FFFFFF",
  },
  indigo_kram: {
    id: "indigo_kram",
    name: "ครามสุโขทัย",
    subtitle: "เย็นตาเรียบง่าย โทนครามธรรมชาติอีสาน-เหนือ",
    primary: "#1E40AF",
    deep: "#1E3A8A",
    ring: "#3B82F6",
    ochre: "#1D4ED8",
    gold: "#93C5FD",
    surface: "#F8FAFC",
    panel: "#F1F5F9",
    sand: "#E2E8F0",
    card: "#FFFFFF",
    border: "#CBD5E1",
    soft: "#DBEAFE",
    text: "#0F172A",
    muted: "#475569",
    bubbleSent: "#DBEAFE",
    bubbleSentText: "#172554",
    bubbleRecv: "#FFFFFF",
  },
  jade_celadon: {
    id: "jade_celadon",
    name: "หยกสังคโลก",
    subtitle: "สงบสดชื่นผ่อนคลาย แบบเคลือบเขียวศิลาดล",
    primary: "#13795B",
    deep: "#0F5132",
    ring: "#198754",
    ochre: "#115E59",
    gold: "#6EE7B7",
    surface: "#F7FBF9",
    panel: "#EEF6F3",
    sand: "#DCECE5",
    card: "#FFFFFF",
    border: "#BFDCD1",
    soft: "#D1FAE5",
    text: "#10211B",
    muted: "#496459",
    bubbleSent: "#D1FAE5",
    bubbleSentText: "#064E3B",
    bubbleRecv: "#FFFFFF",
  },
  lotus_rose: {
    id: "lotus_rose",
    name: "บัวหลวงชมพู",
    subtitle: "ละมุนอ่อนโยนสดใส โทนกลีบบัวราชินี",
    primary: "#BE185D",
    deep: "#9D174D",
    ring: "#EC4899",
    ochre: "#831843",
    gold: "#F9A8D4",
    surface: "#FFF9FB",
    panel: "#FDF2F7",
    sand: "#F5DFE9",
    card: "#FFFFFF",
    border: "#F3C6DA",
    soft: "#FCE7F3",
    text: "#24121B",
    muted: "#6B4E5C",
    bubbleSent: "#FCE7F3",
    bubbleSentText: "#500724",
    bubbleRecv: "#FFFFFF",
  },
  spice_cinnamon: {
    id: "spice_cinnamon",
    name: "อบเชยเครื่องเทศ",
    subtitle: "มีชีวิตชีวากระฉับกระเฉง โทนส้มอิฐร่วมสมัย",
    primary: "#C2410C",
    deep: "#9A3412",
    ring: "#EA580C",
    ochre: "#7C2D12",
    gold: "#FDBA74",
    surface: "#FFFAF7",
    panel: "#FBF3EE",
    sand: "#EFE1D6",
    card: "#FFFFFF",
    border: "#ECCABB",
    soft: "#FFEDD5",
    text: "#221610",
    muted: "#6B5548",
    bubbleSent: "#FED7AA",
    bubbleSentText: "#431407",
    bubbleRecv: "#FFFFFF",
  },
  royal_amethyst: {
    id: "royal_amethyst",
    name: "มณีม่วงไทย",
    subtitle: "ลุ่มลึกมีสไตล์ โทนอัญมณีสีม่วงคราม",
    primary: "#6D28D9",
    deep: "#5B21B6",
    ring: "#8B5CF6",
    ochre: "#4C1D95",
    gold: "#C4B5FD",
    surface: "#FAF9FD",
    panel: "#F3F0FA",
    sand: "#E6E0F4",
    card: "#FFFFFF",
    border: "#D5CBEB",
    soft: "#EDE9FE",
    text: "#181326",
    muted: "#584F70",
    bubbleSent: "#EDE9FE",
    bubbleSentText: "#2E1065",
    bubbleRecv: "#FFFFFF",
  },
};

export const THEME_PRESET_LIST: ThemePalette[] = [
  THEME_PRESETS.ban_chiang,
  THEME_PRESETS.silk_amber,
  THEME_PRESETS.indigo_kram,
  THEME_PRESETS.jade_celadon,
  THEME_PRESETS.lotus_rose,
  THEME_PRESETS.spice_cinnamon,
  THEME_PRESETS.royal_amethyst,
];

export interface RoomToneOption {
  id: RoomToneId;
  label: string;
  bg: string;
  isDark: boolean;
  swatch: string;
}

export const ROOM_TONES: Record<RoomToneId, RoomToneOption> = {
  ban_chiang_cream: {
    id: "ban_chiang_cream",
    label: "ครีมดินเผาบ้านเชียง",
    bg: "#F5EFEA",
    isDark: false,
    swatch: "#F5EFEA",
  },
  terracotta_night: {
    id: "terracotta_night",
    label: "รัตติกาลดินเผา",
    bg: "#1C1412",
    isDark: true,
    swatch: "#1C1412",
  },
  ivory_white: {
    id: "ivory_white",
    label: "ขาวงาช้าง",
    bg: "#FBF9F8",
    isDark: false,
    swatch: "#FBF9F8",
  },
};

export function normalizeThemeId(raw?: string | null): ThemePresetId {
  if (raw && raw in THEME_PRESETS) {
    return raw as ThemePresetId;
  }
  return "ban_chiang";
}

export function applyThemeCssVars(themeId: ThemePresetId): ThemePalette {
  const palette = THEME_PRESETS[themeId] ?? THEME_PRESETS.ban_chiang;
  if (typeof document !== "undefined") {
    const root = document.documentElement;
    root.style.setProperty("--bc-primary", palette.primary);
    root.style.setProperty("--bc-deep", palette.deep);
    root.style.setProperty("--bc-ring", palette.ring);
    root.style.setProperty("--bc-ochre", palette.ochre);
    root.style.setProperty("--bc-gold", palette.gold);
    root.style.setProperty("--bc-surface", palette.surface);
    root.style.setProperty("--bc-panel", palette.panel);
    root.style.setProperty("--bc-sand", palette.sand);
    root.style.setProperty("--bc-card", palette.card);
    root.style.setProperty("--bc-border", palette.border);
    root.style.setProperty("--bc-soft", palette.soft);
    root.style.setProperty("--bc-text", palette.text);
    root.style.setProperty("--bc-muted", palette.muted);
    root.style.setProperty("--bc-bubble-sent", palette.bubbleSent);
    root.style.setProperty("--bc-bubble-sent-text", palette.bubbleSentText);
    root.style.setProperty("--bc-bubble-recv", palette.bubbleRecv);
    root.dataset.bcTheme = palette.id;
  }
  return palette;
}

export interface OriginalStickerDef {
  code: string;
  label: string;
  accent: string;
  bg: string;
  motif: "wave" | "spark" | "check" | "star" | "flame" | "bolt" | "leaf" | "trophy";
}

export const ORIGINAL_THAI_STICKERS: OriginalStickerDef[] = [
  { code: "pottery_hello", label: "สวัสดีครับ", accent: "#812920", bg: "#FADBD4", motif: "wave" },
  { code: "pottery_thanks", label: "ขอบคุณครับ", accent: "#92400E", bg: "#FEF3C7", motif: "leaf" },
  { code: "pottery_roger", label: "รับทราบ", accent: "#13795B", bg: "#D1FAE5", motif: "check" },
  { code: "pottery_great", label: "ยอดเยี่ยม", accent: "#1E40AF", bg: "#DBEAFE", motif: "star" },
  { code: "pottery_fighting", label: "สู้ๆ นะ", accent: "#C2410C", bg: "#FFEDD5", motif: "flame" },
  { code: "pottery_urgent", label: "ด่วนจี๋", accent: "#9D174D", bg: "#FCE7F3", motif: "bolt" },
  { code: "pottery_sorry", label: "ขออภัยครับ", accent: "#5B21B6", bg: "#EDE9FE", motif: "spark" },
  { code: "pottery_congrats", label: "ยินดีด้วย", accent: "#83280E", bg: "#F5EFEA", motif: "trophy" },
];

export const REACTION_EMOJIS = ["👍", "❤️", "😂", "😮", "😢", "🙏"] as const;
