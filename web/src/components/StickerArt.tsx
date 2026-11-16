"use client";

import { ORIGINAL_THAI_STICKERS, type OriginalStickerDef } from "@/lib/themes";
import { resolveMediaUrl } from "@/lib/api";

export function UserAvatar({
  name,
  avatarUrl,
  size = 40,
  isAi = false,
  isOfficial = false,
}: {
  name: string;
  avatarUrl?: string;
  size?: number;
  isAi?: boolean;
  isOfficial?: boolean;
}) {
  const initial = (Array.from((name || "B").trim())[0] || "B").toUpperCase();
  const resolved = resolveMediaUrl(avatarUrl);
  const showImage = Boolean(resolved && !resolved.includes("ui-avatars.com"));

  if (showImage || isOfficial) {
    return (
      <img
        src={showImage ? resolved : "/icons/logo.png"}
        alt={name}
        width={size}
        height={size}
        style={{ width: size, height: size }}
        className={isOfficial ? "bc-avatar-img bc-avatar-gold" : "bc-avatar-img"}
      />
    );
  }

  return (
    <div
      style={{
        width: size,
        height: size,
        ...(isAi ? { background: "linear-gradient(145deg, #6366F1, #6D28D9)" } : {}),
      }}
      className="bc-avatar select-none"
      aria-label={name}
    >
      <span style={{ fontSize: Math.max(12, Math.round(size * 0.4)) }}>
        {isAi ? "🤖" : initial}
      </span>
    </div>
  );
}

export function StickerArt({
  code,
  fallbackLabel,
  size = 112,
}: {
  code?: string | null;
  fallbackLabel?: string;
  size?: number;
}) {
  const def: OriginalStickerDef =
    ORIGINAL_THAI_STICKERS.find((s) => s.code === code) || {
      code: code || "pottery_hello",
      label: fallbackLabel || "สวัสดีครับ",
      accent: "#812920",
      bg: "#FADBD4",
      motif: "wave",
    };

  return (
    <div
      style={{
        width: size,
        backgroundColor: def.bg,
        borderColor: def.accent,
      }}
      className="inline-flex flex-col items-center justify-center rounded-2xl border-2 px-3 py-2.5 shadow-sm select-none"
    >
      <svg
        width={Math.round(size * 0.44)}
        height={Math.round(size * 0.44)}
        viewBox="0 0 64 64"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        aria-hidden="true"
      >
        <circle cx="32" cy="32" r="28" fill="#FFFFFF" stroke={def.accent} strokeWidth="2.5" />
        <path
          d="M12 24C20 18 28 30 36 24C44 18 48 26 52 24"
          stroke={def.accent}
          strokeOpacity="0.45"
          strokeWidth="2"
          strokeLinecap="round"
        />
        {def.motif === "wave" && (
          <path
            d="M18 39C23 33 29 45 35 39C40 34 44 41 47 38"
            stroke={def.accent}
            strokeWidth="3.2"
            strokeLinecap="round"
          />
        )}
        {def.motif === "leaf" && (
          <path
            d="M22 44C22 30 34 22 44 22C44 34 36 44 22 44Z"
            fill={def.accent}
            fillOpacity="0.18"
            stroke={def.accent}
            strokeWidth="2.6"
          />
        )}
        {def.motif === "check" && (
          <path
            d="M21 35L29 43L44 25"
            stroke={def.accent}
            strokeWidth="3.6"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        )}
        {def.motif === "star" && (
          <path
            d="M32 18L36.2 26.8L46 28.2L39 35L40.6 44.8L32 40.2L23.4 44.8L25 35L18 28.2L27.8 26.8L32 18Z"
            fill={def.accent}
            fillOpacity="0.2"
            stroke={def.accent}
            strokeWidth="2.4"
            strokeLinejoin="round"
          />
        )}
        {def.motif === "flame" && (
          <path
            d="M33 17C38 25 44 29 44 37C44 43.6 38.6 48 32 48C25.4 48 20 43.6 20 37C20 31 24 27 28 24C28 29 31 30 33 17Z"
            fill={def.accent}
            fillOpacity="0.2"
            stroke={def.accent}
            strokeWidth="2.5"
            strokeLinejoin="round"
          />
        )}
        {def.motif === "bolt" && (
          <path
            d="M35 17L22 34H32L29 47L43 29H33L35 17Z"
            fill={def.accent}
            fillOpacity="0.22"
            stroke={def.accent}
            strokeWidth="2.5"
            strokeLinejoin="round"
          />
        )}
        {def.motif === "spark" && (
          <path
            d="M32 18V46M18 32H46M23 23L41 41M41 23L23 41"
            stroke={def.accent}
            strokeWidth="2.6"
            strokeLinecap="round"
          />
        )}
        {def.motif === "trophy" && (
          <path
            d="M23 22H41V31C41 36 37 40 32 40C27 40 23 36 23 31V22ZM27 45H37M32 40V45"
            stroke={def.accent}
            strokeWidth="2.6"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        )}
      </svg>
      <span
        style={{ color: def.accent }}
        className="mt-1.5 text-center text-xs font-semibold leading-tight"
      >
        {fallbackLabel || def.label}
      </span>
      <span className="mt-0.5 text-[9px] font-medium text-[var(--bc-muted)]">
        อารมณ์ดีดินเผาไทย
      </span>
    </div>
  );
}
