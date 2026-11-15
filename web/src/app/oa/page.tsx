import { Suspense } from "react";
import { BcChatApp } from "@/components/BcChatApp";

export default function OaPage() {
  return (
    <Suspense>
      <BcChatApp initialTab="oa" />
    </Suspense>
  );
}
