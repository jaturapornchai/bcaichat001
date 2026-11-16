import { Suspense } from "react";
import { BcChatApp } from "@/components/BcChatApp";

export default function HomePage() {
  return (
    <Suspense
      fallback={
        <main className="bc-spiral-bg flex min-h-screen items-center justify-center p-6">
          <div className="rounded-3xl border border-[var(--bc-border)] bg-white px-8 py-6 text-center shadow-sm">
            <h1 className="text-lg font-bold text-[#812920]">BC Ai Chat</h1>
            <p className="mt-1 text-xs text-[#615E53]">กำลังโหลด...</p>
          </div>
        </main>
      }
    >
      <BcChatApp />
    </Suspense>
  );
}
