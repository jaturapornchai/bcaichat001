"use client";

import { useEffect, useState } from "react";
import QRCode from "qrcode";

interface QrCodeSvgProps {
  value: string;
  size?: number;
  darkColor?: string;
  lightColor?: string;
  className?: string;
}

export function QrCodeSvg({
  value,
  size = 180,
  darkColor = "#681F18",
  lightColor = "#FFFFFF",
  className = "",
}: QrCodeSvgProps) {
  const [svgMarkup, setSvgMarkup] = useState<string>("");

  useEffect(() => {
    let active = true;
    QRCode.toString(value || "BC_AI_CHAT", {
      type: "svg",
      margin: 2,
      color: {
        dark: darkColor,
        light: lightColor,
      },
    })
      .then((svg) => {
        if (active) setSvgMarkup(svg);
      })
      .catch(() => {
        if (active) setSvgMarkup("");
      });
    return () => {
      active = false;
    };
  }, [value, darkColor, lightColor]);

  if (!svgMarkup) {
    return (
      <div
        style={{ width: size, height: size }}
        className={`flex shrink-0 items-center justify-center rounded-xl border bg-white text-xs text-[var(--bc-muted)] ${className}`}
      >
        กำลังสร้าง QR...
      </div>
    );
  }

  return (
    <div
      data-testid="qr-code-svg"
      style={{ width: size, height: size }}
      className={`shrink-0 overflow-hidden rounded-xl border border-[var(--bc-line)] bg-white p-1.5 shadow-sm [&>svg]:block [&>svg]:h-full [&>svg]:w-full ${className}`}
      dangerouslySetInnerHTML={{ __html: svgMarkup }}
    />
  );
}
