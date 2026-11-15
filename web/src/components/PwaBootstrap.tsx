"use client";

import { useEffect } from "react";
import { initPwaListeners } from "@/lib/pwa";

/** Boots PWA install event capture & auto-updating service worker at root layout. */
export function PwaBootstrap() {
  useEffect(() => {
    initPwaListeners();
  }, []);

  return null;
}
