"use client";

import { useEffect, useRef, useState } from "react";
import {
  Bot,
  CheckCircle2,
  ChevronDown,
  ChevronUp,
  KeyRound,
  Lock,
  Mail,
  MessageSquareText,
  MonitorDown,
  Phone,
  RefreshCw,
  ShieldAlert,
  Sparkles,
  Store,
  Video,
} from "lucide-react";
import { api, openGoogleOAuthPopup } from "@/lib/api";
import { usePwaInstall } from "@/lib/pwa";
import { SITE_NAME, type SiteId } from "@/lib/site";
import type { AuthConfig, OtpChallengeResponse, UserProfile } from "@/lib/types";
import { UserAvatar } from "./StickerArt";

interface LoginViewProps {
  authConfig: AuthConfig | null;
  onAuthenticated: (token: string, user: UserProfile) => void;
  initialError?: string | null;
  site?: SiteId;
}

export function LoginView({
  authConfig,
  onAuthenticated,
  initialError,
  site = "chat",
}: LoginViewProps) {
  const siteName = SITE_NAME[site];
  const [phone, setPhone] = useState("");
  const [otpCode, setOtpCode] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [challenge, setChallenge] = useState<OtpChallengeResponse | null>(null);
  const [countdown, setCountdown] = useState(0);

  const [showBootstrap, setShowBootstrap] = useState(false);
  const [bootstrapCode, setBootstrapCode] = useState("");
  const [bootstrapName, setBootstrapName] = useState("");

  const [busy, setBusy] = useState(false);
  const [googleWaiting, setGoogleWaiting] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(initialError || null);
  const [infoMsg, setInfoMsg] = useState<string | null>(null);
  const [showPwaGuide, setShowPwaGuide] = useState(false);

  const { canPromptInstall, isStandalone, justInstalled, isIos, promptInstall } = usePwaInstall();
  const pwaInstalled = isStandalone || justInstalled;

  // Account Recovery (Change Phone / Change Gmail)
  const [showRecovery, setShowRecovery] = useState(false);
  const [recoveryTab, setRecoveryTab] = useState<"change_phone" | "change_google">("change_phone");
  const [recPhoneVerifyMethod, setRecPhoneVerifyMethod] = useState<"google" | "pin_or_code">(
    "google"
  );
  const [recGoogleVerifyMethod, setRecGoogleVerifyMethod] = useState<"phone_otp" | "pin_or_code">(
    "phone_otp"
  );
  const [recOldGoogle, setRecOldGoogle] = useState<{ state: string; email: string } | null>(null);
  const [recNewGoogle, setRecNewGoogle] = useState<{ state: string; email: string } | null>(null);
  const [recIdentifier, setRecIdentifier] = useState("");
  const [recSecret, setRecSecret] = useState("");
  const [recNewPhone, setRecNewPhone] = useState("");
  const [recNewPhoneChallenge, setRecNewPhoneChallenge] =
    useState<OtpChallengeResponse | null>(null);
  const [recNewPhoneOtp, setRecNewPhoneOtp] = useState("");
  const [recOldPhone, setRecOldPhone] = useState("");
  const [recOldPhoneChallenge, setRecOldPhoneChallenge] =
    useState<OtpChallengeResponse | null>(null);
  const [recOldPhoneOtp, setRecOldPhoneOtp] = useState("");
  const [recRevokeOtherSessions, setRecRevokeOtherSessions] = useState(true);

  const oauthCleanupRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    if (initialError) setErrorMsg(initialError);
  }, [initialError]);

  useEffect(() => {
    if (countdown <= 0) return;
    const timer = setInterval(() => {
      setCountdown((prev) => (prev <= 1 ? 0 : prev - 1));
    }, 1000);
    return () => clearInterval(timer);
  }, [countdown]);

  useEffect(() => {
    return () => {
      oauthCleanupRef.current?.();
      oauthCleanupRef.current = null;
    };
  }, []);

  const handleRequestOtp = async (e?: React.FormEvent) => {
    e?.preventDefault();
    const cleaned = phone.trim();
    if (!cleaned) {
      setErrorMsg("กรุณากรอกเบอร์โทรศัพท์");
      return;
    }
    setBusy(true);
    setErrorMsg(null);
    setInfoMsg(null);
    try {
      const res = await api.requestPhoneOtp({ phone: cleaned, purpose: "auth" });
      setChallenge(res);
      setOtpCode("");
      setCountdown(60);
      setInfoMsg(`ส่งรหัส OTP ไปยัง ${res.masked_phone} แล้ว (Ref: ${res.ref_code})`);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "ส่งรหัส OTP ไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleVerifyOtp = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!challenge) return;
    if (!otpCode.trim()) {
      setErrorMsg("กรุณากรอกรหัส OTP ที่ได้รับ");
      return;
    }
    setBusy(true);
    setErrorMsg(null);
    try {
      const res = await api.verifyPhoneOtp({
        challenge_id: challenge.challenge_id,
        otp_code: otpCode.trim(),
        display_name: displayName.trim() || undefined,
        ref_code: challenge.ref_code,
      });
      onAuthenticated(res.token, res.user);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "ยืนยัน OTP ไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleGoogleLogin = () => {
    oauthCleanupRef.current?.();
    oauthCleanupRef.current = null;
    setErrorMsg(null);
    setInfoMsg(null);
    setGoogleWaiting(true);

    const stop = openGoogleOAuthPopup({
      mode: "login",
      windowName: "bcaichat_google_oauth",
      onResult: (data) => {
        setGoogleWaiting(false);
        oauthCleanupRef.current = null;
        if (data.token && data.user) {
          onAuthenticated(data.token, data.user);
        }
      },
      onError: (msg) => {
        setGoogleWaiting(false);
        oauthCleanupRef.current = null;
        setErrorMsg(msg);
      },
      onCancel: () => {
        setGoogleWaiting(false);
        oauthCleanupRef.current = null;
      },
    });
    if (!stop) {
      setGoogleWaiting(false);
      return;
    }
    oauthCleanupRef.current = stop;
  };

  const handleRecoveryGoogleVerify = (target: "old_google" | "new_google") => {
    oauthCleanupRef.current?.();
    oauthCleanupRef.current = null;
    setErrorMsg(null);
    setInfoMsg(null);
    setGoogleWaiting(true);

    const stop = openGoogleOAuthPopup({
      mode: "recover",
      windowName: `bcaichat_google_recover_${target}`,
      onResult: (data, state) => {
        setGoogleWaiting(false);
        oauthCleanupRef.current = null;
        const verifiedState = data.oauth_state || state;
        const verifiedEmail = data.email || "Gmail ยืนยันแล้ว";
        if (target === "old_google") {
          setRecOldGoogle({ state: verifiedState, email: verifiedEmail });
          setInfoMsg(`ยืนยัน Gmail เดิมสำเร็จ: ${verifiedEmail}`);
        } else {
          setRecNewGoogle({ state: verifiedState, email: verifiedEmail });
          setInfoMsg(`ยืนยัน Gmail ใหม่สำเร็จ: ${verifiedEmail}`);
        }
      },
      onError: (msg) => {
        setGoogleWaiting(false);
        oauthCleanupRef.current = null;
        setErrorMsg(msg);
      },
      onCancel: () => {
        setGoogleWaiting(false);
        oauthCleanupRef.current = null;
      },
    });
    if (!stop) {
      setGoogleWaiting(false);
      return;
    }
    oauthCleanupRef.current = stop;
  };

  const handleRequestRecoveryOtp = async (target: "new_phone" | "old_phone") => {
    const rawPhone = (target === "new_phone" ? recNewPhone : recOldPhone).trim();
    if (!rawPhone) {
      setErrorMsg("กรุณากรอกเบอร์โทรศัพท์");
      return;
    }
    setBusy(true);
    setErrorMsg(null);
    setInfoMsg(null);
    try {
      const ch = await api.requestPhoneOtp({ phone: rawPhone, purpose: "recover" });
      if (target === "new_phone") {
        setRecNewPhoneChallenge(ch);
        setRecNewPhoneOtp("");
      } else {
        setRecOldPhoneChallenge(ch);
        setRecOldPhoneOtp("");
      }
      setInfoMsg(`ส่งรหัส OTP ไปยัง ${ch.masked_phone} แล้ว (Ref: ${ch.ref_code})`);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "ส่ง OTP กู้คืนไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleSubmitRecoverChangePhone = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!recNewPhoneChallenge || !recNewPhoneOtp.trim()) {
      setErrorMsg("กรุณาขอและกรอกรหัส OTP ของเบอร์โทรศัพท์ใหม่");
      return;
    }
    if (recPhoneVerifyMethod === "google" && !recOldGoogle) {
      setErrorMsg("กรุณากดยืนยันตัวตนด้วย Gmail เดิมก่อน");
      return;
    }
    if (recPhoneVerifyMethod === "pin_or_code" && (!recIdentifier.trim() || !recSecret.trim())) {
      setErrorMsg("กรุณากรอกตัวระบุบัญชีเดิม และ PIN 6 หลัก หรือรหัสสำรอง");
      return;
    }
    setBusy(true);
    setErrorMsg(null);
    try {
      const res = await api.recoverChangePhone({
        method: recPhoneVerifyMethod,
        google_oauth_state:
          recPhoneVerifyMethod === "google" ? recOldGoogle?.state : undefined,
        identifier:
          recPhoneVerifyMethod === "pin_or_code" ? recIdentifier.trim() : undefined,
        recovery_secret:
          recPhoneVerifyMethod === "pin_or_code" ? recSecret.trim() : undefined,
        new_phone_challenge_id: recNewPhoneChallenge.challenge_id,
        new_phone_otp_code: recNewPhoneOtp.trim(),
        new_phone_ref_code: recNewPhoneChallenge.ref_code,
        revoke_other_sessions: recRevokeOtherSessions,
      });
      onAuthenticated(res.token, res.user);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "กู้คืนและเปลี่ยนเบอร์ไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleSubmitRecoverChangeGoogle = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!recNewGoogle) {
      setErrorMsg("กรุณายืนยันบัญชี Gmail ใหม่ก่อน");
      return;
    }
    if (recGoogleVerifyMethod === "phone_otp" && (!recOldPhoneChallenge || !recOldPhoneOtp.trim())) {
      setErrorMsg("กรุณาขอและกรอกรหัส OTP ของเบอร์โทรศัพท์ที่ผูกไว้");
      return;
    }
    if (recGoogleVerifyMethod === "pin_or_code" && (!recIdentifier.trim() || !recSecret.trim())) {
      setErrorMsg("กรุณากรอกตัวระบุบัญชีเดิม และ PIN 6 หลัก หรือรหัสสำรอง");
      return;
    }
    setBusy(true);
    setErrorMsg(null);
    try {
      const res = await api.recoverChangeGoogle({
        method: recGoogleVerifyMethod,
        phone_challenge_id:
          recGoogleVerifyMethod === "phone_otp" ? recOldPhoneChallenge?.challenge_id : undefined,
        phone_otp_code:
          recGoogleVerifyMethod === "phone_otp" ? recOldPhoneOtp.trim() : undefined,
        phone_ref_code:
          recGoogleVerifyMethod === "phone_otp" ? recOldPhoneChallenge?.ref_code : undefined,
        identifier:
          recGoogleVerifyMethod === "pin_or_code" ? recIdentifier.trim() : undefined,
        recovery_secret:
          recGoogleVerifyMethod === "pin_or_code" ? recSecret.trim() : undefined,
        new_google_oauth_state: recNewGoogle.state,
        revoke_other_sessions: recRevokeOtherSessions,
      });
      onAuthenticated(res.token, res.user);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "กู้คืนและเปลี่ยน Gmail ไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleBootstrapAdmin = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!bootstrapCode.trim()) {
      setErrorMsg("กรุณากรอกรหัสยืนยันเจ้าของระบบ");
      return;
    }
    setBusy(true);
    setErrorMsg(null);
    try {
      const res = await api.bootstrapAdmin({
        code: bootstrapCode.trim(),
        display_name: bootstrapName.trim() || undefined,
      });
      onAuthenticated(res.token, res.user);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "รหัสเจ้าของระบบไม่ถูกต้อง");
    } finally {
      setBusy(false);
    }
  };

  const handleQuickTestLogin = async (slot: number) => {
    setBusy(true);
    setErrorMsg(null);
    try {
      const res = await api.testQuickLogin({ slot });
      onAuthenticated(res.token, res.user);
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : "เข้าใช้งานบัญชีทดสอบไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handlePwaInstallClick = async () => {
    if (pwaInstalled) {
      setShowPwaGuide(false);
      setInfoMsg(`ติดตั้ง ${siteName} บนเครื่องนี้เรียบร้อยแล้ว`);
      return;
    }
    if (canPromptInstall) {
      const outcome = await promptInstall();
      if (outcome === "accepted") {
        setShowPwaGuide(false);
        setInfoMsg(`ติดตั้ง ${siteName} สำเร็จ เปิดใช้งานจากหน้าจอหลักได้ทันที`);
        return;
      }
      if (outcome === "dismissed") {
        return;
      }
    }
    setShowPwaGuide((v) => !v);
  };

  return (
    <div className="bc-spiral-bg flex min-h-[100dvh] flex-col items-center justify-center overflow-x-hidden px-3 py-5 sm:px-4 sm:py-8">
      <main className="mx-auto w-full max-w-md space-y-3">
        {/* Single Centered Login Card */}
        <section className="rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-4 shadow-md sm:p-5">
          {/* Card Brand Header (Single <h1> on page) */}
          <div className="mb-3.5 flex items-center gap-3">
            <img
              src="/icons/logo.png"
              alt={`โลโก้ ${siteName}`}
              width={48}
              height={48}
              data-testid="brand-logo-img"
              className="h-12 w-12 shrink-0 rounded-full object-cover shadow-xs"
            />
            <div className="min-w-0 flex-1">
              <h1 className="text-lg font-bold leading-tight tracking-tight text-[var(--bc-text)]">
                {siteName}
              </h1>
              <p className="mt-0.5 truncate text-xs text-[var(--bc-muted)]">
                {site === "oa"
                  ? "จัดการแชทลูกค้า คูปอง และข่าวสารของร้านคุณ"
                  : "แชทกับครอบครัว เพื่อน ผู้ช่วย AI และร้านค้า"}
              </p>
            </div>
          </div>

          {errorMsg && (
            <div
              role="alert"
              className="mb-3 rounded-xl border border-red-300 bg-red-50 px-3 py-2 text-xs font-medium text-red-800"
            >
              {errorMsg}
            </div>
          )}

          {infoMsg && (
            <div className="mb-3 rounded-xl border border-[var(--bc-primary)]/30 bg-[var(--bc-soft)]/50 px-3 py-2 text-xs font-medium text-[var(--bc-deep)]">
              {infoMsg}
            </div>
          )}

          {/* Primary Phone OTP Login */}
          {!challenge ? (
            <form onSubmit={handleRequestOtp} className="space-y-2.5">
              <div>
                <label
                  htmlFor="login-phone-field"
                  className="mb-1 block text-xs font-semibold text-[var(--bc-text)]"
                >
                  เบอร์มือถือ
                </label>
                <div className="relative flex items-center">
                  <Phone className="pointer-events-none absolute left-3 h-4 w-4 text-[var(--bc-muted)]" />
                  <input
                    id="login-phone-field"
                    type="tel"
                    required
                    value={phone}
                    onChange={(e) => setPhone(e.target.value)}
                    placeholder="081-234-5678"
                    data-testid="login-phone-input"
                    className="min-h-[38px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] py-2 pl-9 pr-3 text-sm text-[var(--bc-text)] outline-none focus:border-[var(--bc-primary)]"
                  />
                </div>
              </div>

              {authConfig && !authConfig.phone_otp_ready && (
                <p className="rounded-lg border border-amber-300 bg-amber-50 px-2.5 py-1.5 text-[11px] text-amber-800">
                  ระบบส่งรหัส OTP ยังไม่พร้อมใช้งาน (ผู้ดูแลระบบยังไม่ได้ตั้งค่า)
                </p>
              )}

              <button
                type="submit"
                disabled={busy || googleWaiting}
                data-testid="request-otp-btn"
                className="flex min-h-[40px] w-full items-center justify-center gap-2 rounded-xl px-4 py-2 text-sm font-bold text-white shadow-sm transition hover:brightness-95 disabled:opacity-60"
                style={{
                  background: "linear-gradient(135deg, var(--bc-deep), var(--bc-primary))",
                }}
              >
                <Phone className="h-4 w-4 shrink-0" />
                <span>{busy ? "กำลังส่งรหัส OTP..." : "รับรหัส OTP"}</span>
              </button>
            </form>
          ) : (
            <form
              onSubmit={handleVerifyOtp}
              className="space-y-2.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-3"
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="text-xs font-bold text-[var(--bc-text)]">
                  ยืนยันรหัส OTP ({challenge.masked_phone})
                </span>
                <span className="inline-flex items-center rounded-full bg-[var(--bc-soft)] px-2.5 py-0.5 text-[11px] font-bold text-[var(--bc-deep)]">
                  Ref: {challenge.ref_code}
                </span>
              </div>

              <div>
                <label
                  htmlFor="login-otp-field"
                  className="mb-1 block text-xs font-semibold text-[var(--bc-text)]"
                >
                  รหัส OTP 6 หลัก
                </label>
                <input
                  id="login-otp-field"
                  type="text"
                  inputMode="numeric"
                  maxLength={8}
                  required
                  value={otpCode}
                  onChange={(e) => setOtpCode(e.target.value)}
                  placeholder="กรอกรหัส 6 หลัก"
                  data-testid="login-otp-code-input"
                  className="min-h-[38px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-1.5 text-center text-sm font-bold tracking-widest text-[var(--bc-text)] outline-none focus:border-[var(--bc-primary)]"
                />
              </div>

              <div>
                <label
                  htmlFor="login-name-field"
                  className="mb-1 block text-xs font-semibold text-[var(--bc-text)]"
                >
                  ชื่อเล่น (สำหรับผู้ใช้ใหม่)
                </label>
                <input
                  id="login-name-field"
                  type="text"
                  value={displayName}
                  onChange={(e) => setDisplayName(e.target.value)}
                  placeholder="เช่น นิดา หรือ ก้อง"
                  data-testid="login-display-name-input"
                  className="min-h-[38px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-1.5 text-xs text-[var(--bc-text)] outline-none focus:border-[var(--bc-primary)]"
                />
              </div>

              <button
                type="submit"
                disabled={busy}
                data-testid="verify-otp-btn"
                className="flex min-h-[40px] w-full items-center justify-center gap-1.5 rounded-xl px-4 py-2 text-sm font-bold text-white shadow-sm transition hover:brightness-95 disabled:opacity-60"
                style={{
                  background: "linear-gradient(135deg, var(--bc-deep), var(--bc-primary))",
                }}
              >
                <span>{busy ? "กำลังตรวจสอบ..." : "ยืนยันเข้าสู่ระบบ"}</span>
              </button>

              <div className="flex items-center justify-between gap-2 pt-0.5 text-xs">
                <button
                  type="button"
                  disabled={busy || countdown > 0}
                  onClick={() => void handleRequestOtp()}
                  className="inline-flex min-h-[32px] items-center gap-1 font-semibold text-[var(--bc-primary)] disabled:text-[var(--bc-muted)]"
                >
                  <RefreshCw className="h-3.5 w-3.5 shrink-0" />
                  <span>
                    {countdown > 0 ? `ขอรหัสใหม่ (${countdown} วิ)` : "ขอรหัส OTP ใหม่"}
                  </span>
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => {
                    setChallenge(null);
                    setOtpCode("");
                    setInfoMsg(null);
                  }}
                  className="min-h-[32px] font-semibold text-[var(--bc-muted)] hover:text-[var(--bc-text)]"
                >
                  เปลี่ยนเบอร์โทร
                </button>
              </div>
            </form>
          )}

          <div className="my-3 flex items-center gap-2.5">
            <div className="h-px flex-1 bg-[var(--bc-border)]" />
            <span className="text-xs font-medium text-[var(--bc-muted)]">หรือ</span>
            <div className="h-px flex-1 bg-[var(--bc-border)]" />
          </div>

          {/* Primary Google OAuth Login */}
          <div className="space-y-1.5">
            <button
              type="button"
              disabled={busy || googleWaiting || (authConfig !== null && !authConfig.google_enabled)}
              onClick={handleGoogleLogin}
              data-testid="google-login-btn"
              className="flex min-h-[40px] w-full items-center justify-center gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-4 py-2 text-sm font-bold text-[var(--bc-text)] transition hover:border-[var(--bc-primary)] hover:bg-[var(--bc-soft)]/50 disabled:opacity-60"
            >
              <Mail className="h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
              <span>
                {googleWaiting ? "กำลังรอยืนยันบัญชี Google..." : "เข้าใช้งานด้วย Google"}
              </span>
            </button>

            {googleWaiting && (
              <button
                type="button"
                onClick={() => oauthCleanupRef.current?.()}
                className="min-h-[32px] w-full rounded-lg border border-[var(--bc-border)] bg-[var(--bc-surface)] px-3 py-1 text-xs font-semibold text-[var(--bc-muted)] hover:text-[var(--bc-text)]"
              >
                ยกเลิก
              </button>
            )}

            {authConfig && !authConfig.google_enabled && (
              <p className="text-center text-[11px] text-[var(--bc-muted)]">
                ยังไม่ได้เปิดใช้งานการเข้าสู่ระบบด้วย Google บนเซิร์ฟเวอร์
              </p>
            )}
          </div>

          {/* Install Web App (PWA) Card */}
          <div className="mt-3 space-y-1.5">
            <button
              type="button"
              onClick={() => void handlePwaInstallClick()}
              data-testid="pwa-install-btn"
              aria-expanded={showPwaGuide}
              className="flex w-full items-center gap-3 rounded-xl border border-[var(--bc-primary)]/35 bg-[var(--bc-soft)]/45 px-3.5 py-2.5 text-left transition hover:border-[var(--bc-primary)] hover:bg-[var(--bc-soft)]/75"
            >
              {pwaInstalled ? (
                <CheckCircle2 className="h-6 w-6 shrink-0 text-[var(--bc-primary)]" />
              ) : (
                <MonitorDown className="h-6 w-6 shrink-0 text-[var(--bc-primary)]" />
              )}
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-bold leading-snug text-[var(--bc-deep)]">
                  {pwaInstalled
                    ? `ติดตั้งแอป ${siteName} แล้ว (PWA)`
                    : "ติดตั้งจากเบราว์เซอร์ (PWA)"}
                </span>
                <span className="block text-[11px] leading-snug text-[var(--bc-primary)]">
                  {pwaInstalled
                    ? "ใช้งานเต็มจอบนเครื่องนี้ • อัปเดตเองอัตโนมัติ"
                    : "ไม่ต้องโหลดไฟล์ ไม่มีคำเตือน อัปเดตเอง"}
                </span>
              </span>
            </button>

            {showPwaGuide && !pwaInstalled && (
              <div
                data-testid="pwa-install-inline-guide"
                className="space-y-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-3 py-2 text-[11px] leading-relaxed text-[var(--bc-text)]"
              >
                <div className="font-bold text-[var(--bc-deep)]">
                  วิธีติดตั้ง {siteName} บน{isIos ? " iPhone / iPad (Safari)" : " Chrome / Edge / มือถือ"}
                </div>
                {isIos ? (
                  <ol className="list-inside list-decimal space-y-0.5 text-[var(--bc-muted)]">
                    <li>กดปุ่มแชร์ (ไอคอนสี่เหลี่ยมลูกศรชี้ขึ้น) ด้านล่างของ Safari</li>
                    <li>เลือก &quot;เพิ่มไปยังหน้าจอโฮม&quot; (Add to Home Screen) แล้วกดเพิ่ม</li>
                  </ol>
                ) : (
                  <ol className="list-inside list-decimal space-y-0.5 text-[var(--bc-muted)]">
                    <li>
                      กดไอคอนติดตั้งแอปบนแถบที่อยู่ (ด้านขวาบน) หรือเมนู ⋮ ของเบราว์เซอร์
                    </li>
                    <li>
                      เลือก &quot;ติดตั้ง {siteName}&quot; หรือ &quot;เพิ่มลงในหน้าจอหลัก&quot; แล้วกดยืนยัน
                    </li>
                  </ol>
                )}
              </div>
            )}
          </div>

          {/* 5 Quick Test Users (One-Click Login & Open in New Tab) */}
          {authConfig?.test_users_enabled && (authConfig.test_users?.length ?? 0) > 0 && (
            <div
              data-testid="quick-test-users-box"
              className="mt-3.5 space-y-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)]/70 p-2.5"
            >
              <div>
                <div className="text-xs font-bold text-[var(--bc-text)]">
                  เข้าทดสอบด่วน (คลิกเข้าใช้งานทันที)
                </div>
                <p className="text-[11px] text-[var(--bc-muted)]">
                  คลิกเพื่อเข้าสู่ระบบทันที หรือเปิดแท็บใหม่เพื่อคุยข้ามบัญชี
                </p>
              </div>
              <div className="space-y-1.5">
                {authConfig.test_users!.map((u) => {
                  const formattedBcId = u.bc_id.startsWith("@") ? u.bc_id : `@${u.bc_id}`;
                  return (
                    <div
                      key={u.slot}
                      className="flex items-center gap-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-1.5"
                    >
                      <button
                        type="button"
                        disabled={busy || googleWaiting}
                        data-testid={`quick-test-user-${u.slot}`}
                        onClick={() => void handleQuickTestLogin(u.slot)}
                        className="flex min-h-[40px] min-w-0 flex-1 items-center gap-2 rounded-lg px-1.5 py-1 text-left transition hover:bg-[var(--bc-soft)]/50 disabled:opacity-60"
                      >
                        <UserAvatar name={u.display_name} size={32} />
                        <span className="min-w-0 flex-1">
                          <span className="flex items-center gap-1.5">
                            <span className="truncate text-xs font-bold text-[var(--bc-text)]">
                              {u.display_name}
                            </span>
                            {u.badge && (
                              <span className="truncate rounded-full bg-[var(--bc-soft)] px-1.5 py-0.2 text-[10px] font-semibold text-[var(--bc-deep)]">
                                {u.badge}
                              </span>
                            )}
                          </span>
                          <span className="block truncate text-[11px] text-[var(--bc-muted)]">
                            {formattedBcId} • {u.phone}
                          </span>
                        </span>
                      </button>
                      <a
                        href={`/?test_user=${u.slot}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        data-testid={`quick-test-newtab-${u.slot}`}
                        title={`เปิด ${u.display_name} ในแท็บใหม่`}
                        className="inline-flex min-h-[32px] shrink-0 items-center rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2 py-1 text-[11px] font-semibold text-[var(--bc-primary)] hover:border-[var(--bc-primary)] hover:bg-[var(--bc-soft)]/50"
                      >
                        ↗ แท็บใหม่
                      </a>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          {/* Footer Accordion Links (Recovery & Admin) */}
          <div className="mt-3.5 border-t border-[var(--bc-border)] pt-2.5">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <button
                type="button"
                aria-expanded={showRecovery}
                onClick={() => setShowRecovery((v) => !v)}
                data-testid="login-recovery-toggle"
                className="inline-flex min-h-[32px] items-center gap-1 rounded-lg px-1.5 text-xs font-semibold text-[var(--bc-primary)] hover:bg-[var(--bc-panel)]"
              >
                <ShieldAlert className="h-3.5 w-3.5 shrink-0" />
                <span>เปลี่ยนเบอร์ / กู้คืนบัญชี</span>
                {showRecovery ? (
                  <ChevronUp className="h-3.5 w-3.5 shrink-0" />
                ) : (
                  <ChevronDown className="h-3.5 w-3.5 shrink-0" />
                )}
              </button>

              {authConfig?.admin_bootstrap_enabled && (
                <button
                  type="button"
                  aria-expanded={showBootstrap}
                  onClick={() => setShowBootstrap((v) => !v)}
                  data-testid="toggle-admin-bootstrap-btn"
                  className="inline-flex min-h-[32px] items-center gap-1 rounded-lg px-1.5 text-xs font-semibold text-[var(--bc-ochre)] hover:bg-[var(--bc-panel)]"
                >
                  <KeyRound className="h-3.5 w-3.5 shrink-0" />
                  <span>สำหรับผู้ดูแลระบบ</span>
                  {showBootstrap ? (
                    <ChevronUp className="h-3.5 w-3.5 shrink-0" />
                  ) : (
                    <ChevronDown className="h-3.5 w-3.5 shrink-0" />
                  )}
                </button>
              )}
            </div>

            {showRecovery && (
              <div
                data-testid="login-recovery-panel"
                className="mt-2.5 space-y-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
              >
                <div className="grid grid-cols-2 gap-1.5">
                  <button
                    type="button"
                    data-testid="recovery-tab-change-phone"
                    onClick={() => setRecoveryTab("change_phone")}
                    className={`inline-flex min-h-[34px] items-center justify-center gap-1 rounded-lg border px-2 py-1 text-[11px] font-bold transition ${
                      recoveryTab === "change_phone"
                        ? "border-[var(--bc-primary)] bg-[var(--bc-primary)] text-white"
                        : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-text)]"
                    }`}
                  >
                    <Phone className="h-3 w-3 shrink-0" />
                    <span>เปลี่ยนเบอร์ใหม่</span>
                  </button>
                  <button
                    type="button"
                    data-testid="recovery-tab-change-google"
                    onClick={() => setRecoveryTab("change_google")}
                    className={`inline-flex min-h-[34px] items-center justify-center gap-1 rounded-lg border px-2 py-1 text-[11px] font-bold transition ${
                      recoveryTab === "change_google"
                        ? "border-[var(--bc-primary)] bg-[var(--bc-primary)] text-white"
                        : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-text)]"
                    }`}
                  >
                    <Mail className="h-3 w-3 shrink-0" />
                    <span>เปลี่ยน Gmail ใหม่</span>
                  </button>
                </div>

                {recoveryTab === "change_phone" ? (
                  <form onSubmit={handleSubmitRecoverChangePhone} className="space-y-2">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span className="text-[11px] font-semibold text-[var(--bc-muted)]">
                        1. ยืนยันบัญชีเดิม:
                      </span>
                      <button
                        type="button"
                        onClick={() => setRecPhoneVerifyMethod("google")}
                        className={`rounded-full border px-2.5 py-0.5 text-[10px] font-bold ${
                          recPhoneVerifyMethod === "google"
                            ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-primary)]"
                            : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)]"
                        }`}
                      >
                        ผ่าน Gmail เดิม
                      </button>
                      <button
                        type="button"
                        data-testid="recovery-phone-method-pin"
                        onClick={() => setRecPhoneVerifyMethod("pin_or_code")}
                        className={`rounded-full border px-2.5 py-0.5 text-[10px] font-bold ${
                          recPhoneVerifyMethod === "pin_or_code"
                            ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-primary)]"
                            : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)]"
                        }`}
                      >
                        PIN 6 หลัก / รหัสสำรอง
                      </button>
                    </div>

                    {recPhoneVerifyMethod === "google" ? (
                      <button
                        type="button"
                        disabled={busy || googleWaiting}
                        data-testid="recovery-old-google-btn"
                        onClick={() => handleRecoveryGoogleVerify("old_google")}
                        className="flex min-h-[36px] w-full items-center justify-center gap-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs font-bold text-[var(--bc-text)] hover:border-[var(--bc-primary)] disabled:opacity-60"
                      >
                        <Mail className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                        <span>
                          {recOldGoogle
                            ? `ยืนยันแล้ว: ${recOldGoogle.email}`
                            : "ยืนยันด้วย Gmail เดิม"}
                        </span>
                      </button>
                    ) : (
                      <div className="space-y-1.5">
                        <input
                          type="text"
                          value={recIdentifier}
                          onChange={(e) => setRecIdentifier(e.target.value)}
                          placeholder="เบอร์เดิม อีเมลเดิม หรือ @BC ID"
                          data-testid="recovery-identifier-input"
                          className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                        <input
                          type="text"
                          value={recSecret}
                          onChange={(e) => setRecSecret(e.target.value)}
                          placeholder="PIN 6 หลัก หรือ รหัสสำรอง"
                          data-testid="recovery-secret-input"
                          className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                      </div>
                    )}

                    <div className="space-y-1.5 border-t border-[var(--bc-border)] pt-2">
                      <div className="text-[11px] font-semibold text-[var(--bc-muted)]">
                        2. ยืนยันเบอร์มือถือใหม่ด้วย OTP:
                      </div>
                      <div className="flex items-center gap-1.5">
                        <input
                          type="tel"
                          value={recNewPhone}
                          onChange={(e) => setRecNewPhone(e.target.value)}
                          placeholder="เบอร์มือถือใหม่"
                          data-testid="recovery-new-phone-input"
                          className="min-h-[36px] min-w-0 flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                        <button
                          type="button"
                          disabled={busy}
                          data-testid="recovery-request-new-phone-otp-btn"
                          onClick={() => void handleRequestRecoveryOtp("new_phone")}
                          className="min-h-[36px] shrink-0 rounded-xl border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-2.5 py-1.5 text-[11px] font-bold text-[var(--bc-deep)] disabled:opacity-60"
                        >
                          ส่ง OTP
                        </button>
                      </div>

                      {recNewPhoneChallenge && (
                        <input
                          type="text"
                          inputMode="numeric"
                          value={recNewPhoneOtp}
                          onChange={(e) => setRecNewPhoneOtp(e.target.value)}
                          placeholder={`รหัส OTP เบอร์ใหม่ (Ref: ${recNewPhoneChallenge.ref_code})`}
                          data-testid="recovery-new-phone-otp-input"
                          className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                      )}
                    </div>

                    <label className="flex items-center gap-1.5 text-[11px] text-[var(--bc-text)]">
                      <input
                        type="checkbox"
                        checked={recRevokeOtherSessions}
                        onChange={(e) => setRecRevokeOtherSessions(e.target.checked)}
                        className="accent-[var(--bc-primary)]"
                      />
                      <span>ออกจากระบบทุกเครื่องเก่าอัตโนมัติ (แนะนำ)</span>
                    </label>

                    <button
                      type="submit"
                      disabled={busy || !recNewPhoneChallenge}
                      data-testid="recovery-submit-change-phone-btn"
                      className="flex min-h-[36px] w-full items-center justify-center gap-1.5 rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white hover:brightness-95 disabled:opacity-60"
                    >
                      <CheckCircle2 className="h-3.5 w-3.5 shrink-0" />
                      <span>{busy ? "กำลังกู้คืนบัญชี..." : "ยืนยันเปลี่ยนเบอร์"}</span>
                    </button>
                  </form>
                ) : (
                  <form onSubmit={handleSubmitRecoverChangeGoogle} className="space-y-2">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span className="text-[11px] font-semibold text-[var(--bc-muted)]">
                        1. ยืนยันบัญชีเดิม:
                      </span>
                      <button
                        type="button"
                        onClick={() => setRecGoogleVerifyMethod("phone_otp")}
                        className={`rounded-full border px-2.5 py-0.5 text-[10px] font-bold ${
                          recGoogleVerifyMethod === "phone_otp"
                            ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-primary)]"
                            : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)]"
                        }`}
                      >
                        OTP เบอร์ที่ผูกไว้
                      </button>
                      <button
                        type="button"
                        data-testid="recovery-google-method-pin"
                        onClick={() => setRecGoogleVerifyMethod("pin_or_code")}
                        className={`rounded-full border px-2.5 py-0.5 text-[10px] font-bold ${
                          recGoogleVerifyMethod === "pin_or_code"
                            ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-primary)]"
                            : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)]"
                        }`}
                      >
                        PIN 6 หลัก / รหัสสำรอง
                      </button>
                    </div>

                    {recGoogleVerifyMethod === "phone_otp" ? (
                      <div className="space-y-1.5">
                        <div className="flex items-center gap-1.5">
                          <input
                            type="tel"
                            value={recOldPhone}
                            onChange={(e) => setRecOldPhone(e.target.value)}
                            placeholder="เบอร์มือถือที่ผูกไว้"
                            data-testid="recovery-old-phone-input"
                            className="min-h-[36px] min-w-0 flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                          />
                          <button
                            type="button"
                            disabled={busy}
                            data-testid="recovery-request-old-phone-otp-btn"
                            onClick={() => void handleRequestRecoveryOtp("old_phone")}
                            className="min-h-[36px] shrink-0 rounded-xl border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-2.5 py-1.5 text-[11px] font-bold text-[var(--bc-deep)] disabled:opacity-60"
                          >
                            ส่ง OTP
                          </button>
                        </div>
                        {recOldPhoneChallenge && (
                          <input
                            type="text"
                            inputMode="numeric"
                            value={recOldPhoneOtp}
                            onChange={(e) => setRecOldPhoneOtp(e.target.value)}
                            placeholder={`รหัส OTP เบอร์เดิม (Ref: ${recOldPhoneChallenge.ref_code})`}
                            data-testid="recovery-old-phone-otp-input"
                            className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                          />
                        )}
                      </div>
                    ) : (
                      <div className="space-y-1.5">
                        <input
                          type="text"
                          value={recIdentifier}
                          onChange={(e) => setRecIdentifier(e.target.value)}
                          placeholder="เบอร์เดิม อีเมลเดิม หรือ @BC ID"
                          data-testid="recovery-identifier-input"
                          className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                        <input
                          type="text"
                          value={recSecret}
                          onChange={(e) => setRecSecret(e.target.value)}
                          placeholder="PIN 6 หลัก หรือ รหัสสำรอง"
                          data-testid="recovery-secret-input"
                          className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                      </div>
                    )}

                    <div className="space-y-1.5 border-t border-[var(--bc-border)] pt-2">
                      <div className="text-[11px] font-semibold text-[var(--bc-muted)]">
                        2. ยืนยันบัญชี Gmail ใหม่:
                      </div>
                      <button
                        type="button"
                        disabled={busy || googleWaiting}
                        data-testid="recovery-new-google-btn"
                        onClick={() => handleRecoveryGoogleVerify("new_google")}
                        className="flex min-h-[36px] w-full items-center justify-center gap-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs font-bold text-[var(--bc-text)] hover:border-[var(--bc-primary)] disabled:opacity-60"
                      >
                        <Mail className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                        <span>
                          {recNewGoogle
                            ? `ยืนยัน Gmail ใหม่แล้ว: ${recNewGoogle.email}`
                            : "ยืนยันบัญชี Gmail ใหม่"}
                        </span>
                      </button>
                    </div>

                    <label className="flex items-center gap-1.5 text-[11px] text-[var(--bc-text)]">
                      <input
                        type="checkbox"
                        checked={recRevokeOtherSessions}
                        onChange={(e) => setRecRevokeOtherSessions(e.target.checked)}
                        className="accent-[var(--bc-primary)]"
                      />
                      <span>ออกจากระบบทุกเครื่องเก่าอัตโนมัติ (แนะนำ)</span>
                    </label>

                    <button
                      type="submit"
                      disabled={busy || !recNewGoogle}
                      data-testid="recovery-submit-change-google-btn"
                      className="flex min-h-[36px] w-full items-center justify-center gap-1.5 rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white hover:brightness-95 disabled:opacity-60"
                    >
                      <CheckCircle2 className="h-3.5 w-3.5 shrink-0" />
                      <span>{busy ? "กำลังกู้คืนบัญชี..." : "ยืนยันเปลี่ยน Gmail"}</span>
                    </button>
                  </form>
                )}
              </div>
            )}

            {showBootstrap && authConfig?.admin_bootstrap_enabled && (
              <form
                onSubmit={handleBootstrapAdmin}
                className="mt-2.5 space-y-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
              >
                <div>
                  <label
                    htmlFor="bootstrap-code-field"
                    className="mb-1 block text-[11px] font-semibold text-[var(--bc-text)]"
                  >
                    รหัสผู้ดูแลระบบ
                  </label>
                  <input
                    id="bootstrap-code-field"
                    type="password"
                    required
                    value={bootstrapCode}
                    onChange={(e) => setBootstrapCode(e.target.value)}
                    placeholder="กรอกรหัสลับผู้ดูแลระบบ"
                    data-testid="bootstrap-code-input"
                    className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs text-[var(--bc-text)] outline-none focus:border-[var(--bc-primary)]"
                  />
                </div>
                <div>
                  <label
                    htmlFor="bootstrap-name-field"
                    className="mb-1 block text-[11px] font-semibold text-[var(--bc-text)]"
                  >
                    ชื่อที่แสดง (ไม่บังคับ)
                  </label>
                  <input
                    id="bootstrap-name-field"
                    type="text"
                    value={bootstrapName}
                    onChange={(e) => setBootstrapName(e.target.value)}
                    placeholder="เช่น ลุงจืด"
                    className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs text-[var(--bc-text)] outline-none focus:border-[var(--bc-primary)]"
                  />
                </div>
                <button
                  type="submit"
                  disabled={busy}
                  data-testid="bootstrap-submit-btn"
                  className="flex min-h-[36px] w-full items-center justify-center gap-1.5 rounded-xl bg-[var(--bc-deep)] px-3 py-1.5 text-xs font-bold text-white hover:brightness-95 disabled:opacity-60"
                >
                  <KeyRound className="h-3.5 w-3.5 shrink-0" />
                  <span>{busy ? "กำลังเข้าสู่ระบบ..." : "เข้าสู่ระบบผู้ดูแล"}</span>
                </button>
              </form>
            )}
          </div>
        </section>

        {/* Collapsible SEO / GEO Details below the card */}
        {site === "chat" && (
          <details className="group rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)]/90 px-3.5 py-2.5 text-xs shadow-xs">
            <summary className="flex cursor-pointer list-none items-center justify-between gap-2 font-semibold text-[var(--bc-primary)] [&::-webkit-details-marker]:hidden">
              <span className="inline-flex items-center gap-1.5">
                <Sparkles className="h-3.5 w-3.5 shrink-0" />
                <span>รู้จัก BC Ai Chat</span>
              </span>
              <ChevronDown className="h-3.5 w-3.5 shrink-0 transition-transform group-open:rotate-180" />
            </summary>

            <div className="mt-3 space-y-3 border-t border-[var(--bc-border)] pt-3">
              <p className="leading-relaxed text-[var(--bc-muted)]">
                BC Ai Chat ออกแบบด้วยโทนสีดินเผาบ้านเชียงร่วมสมัย ใช้งานลื่นไหลบนมือถือและคอมพิวเตอร์
                พร้อมผู้ช่วย <strong className="font-semibold text-[var(--bc-primary)]">@bc.ai</strong>{" "}
                โทรเสียงและวิดีโอคอล อัลบั้มรูปถาวร และร้านค้าในแอปเดียว
              </p>

              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <div className="flex items-start gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                  <Video className="mt-0.5 h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
                  <div>
                    <h2 className="text-xs font-bold text-[var(--bc-text)]">
                      โทรเสียง &amp; วิดีโอคอล
                    </h2>
                    <p className="mt-0.5 text-[11px] text-[var(--bc-muted)]">
                      โทร 1-1 และคอลกลุ่มชัดระดับ HD ไม่บังข้อความแชท
                    </p>
                  </div>
                </div>

                <div className="flex items-start gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                  <Store className="mt-0.5 h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
                  <div>
                    <h2 className="text-xs font-bold text-[var(--bc-text)]">ร้านค้า</h2>
                    <p className="mt-0.5 text-[11px] text-[var(--bc-muted)]">
                      ติดตามร้านค้า เก็บคูปองส่วนลด และคุยสอบถามได้ทันที
                    </p>
                  </div>
                </div>

                <div className="flex items-start gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                  <Bot className="mt-0.5 h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
                  <div>
                    <h2 className="text-xs font-bold text-[var(--bc-text)]">ผู้ช่วย AI ประจำแชท</h2>
                    <p className="mt-0.5 text-[11px] text-[var(--bc-muted)]">
                      พิมพ์ @ai ถามได้ทุกเรื่อง ช่วยเกลาข้อความและสรุปนัดหมาย
                    </p>
                  </div>
                </div>

                <div className="flex items-start gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                  <Lock className="mt-0.5 h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
                  <div>
                    <h2 className="text-xs font-bold text-[var(--bc-text)]">
                      ข้อความลับ &amp; สมุดบันทึก
                    </h2>
                    <p className="mt-0.5 text-[11px] text-[var(--bc-muted)]">
                      ล็อกข้อความด้วย PIN 4 หลัก และเก็บโน้ตในสมุดบันทึก BC ถาวร
                    </p>
                  </div>
                </div>
              </div>

              <div className="space-y-1.5 border-t border-[var(--bc-border)] pt-2.5 text-[11px] text-[var(--bc-muted)]">
                <h3 className="flex items-center gap-1.5 text-xs font-bold text-[var(--bc-text)]">
                  <MessageSquareText className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                  <span>คำถามที่พบบ่อย</span>
                </h3>
                <p>
                  <strong className="text-[var(--bc-text)]">เข้าสู่ระบบและเพิ่มเพื่อนได้อย่างไร?</strong>{" "}
                  ใช้เบอร์มือถือรับรหัส OTP หรือบัญชี Google ที่ยืนยันแล้ว จากนั้นเชื่อมเบอร์กับ Gmail
                  ในหน้าตั้งค่าและค้นหาเพื่อนด้วยเบอร์โทร อีเมล หรือ @BC ID ได้ทันที
                </p>
                <p>
                  <strong className="text-[var(--bc-text)]">เรียกผู้ช่วย AI และติดตามร้านค้าได้อย่างไร?</strong>{" "}
                  พิมพ์ <code className="rounded bg-[var(--bc-panel)] px-1">@ai</code> หรือ{" "}
                  <code className="rounded bg-[var(--bc-panel)] px-1">@bc.ai</code> ในห้องแชท
                  และเข้าแท็บ <strong className="text-[var(--bc-text)]">ร้านค้า</strong> เพื่อค้นหาและติดตามร้านค้า
                </p>
              </div>
            </div>
          </details>
        )}
      </main>
    </div>
  );
}
