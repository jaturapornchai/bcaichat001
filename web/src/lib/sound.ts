// Synthesized gentle chimes via Web Audio API (no external licensed audio files)

let audioCtx: AudioContext | null = null;

function getAudioContext(): AudioContext | null {
  if (typeof window === "undefined") return null;
  const Ctor =
    window.AudioContext ||
    (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!Ctor) return null;
  if (!audioCtx) {
    audioCtx = new Ctor();
  }
  if (audioCtx.state === "suspended") {
    void audioCtx.resume().catch(() => {});
  }
  return audioCtx;
}

export function playChime(kind: "incoming" | "sent" | "react"): void {
  try {
    const ctx = getAudioContext();
    if (!ctx) return;

    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);

    if (kind === "incoming") {
      osc.type = "sine";
      osc.frequency.setValueAtTime(587.33, now);
      osc.frequency.exponentialRampToValueAtTime(783.99, now + 0.12);
      gain.gain.setValueAtTime(0.05, now);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.24);
      osc.start(now);
      osc.stop(now + 0.25);
    } else if (kind === "sent") {
      osc.type = "triangle";
      osc.frequency.setValueAtTime(523.25, now);
      osc.frequency.exponentialRampToValueAtTime(659.25, now + 0.08);
      gain.gain.setValueAtTime(0.035, now);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.14);
      osc.start(now);
      osc.stop(now + 0.15);
    } else {
      osc.type = "sine";
      osc.frequency.setValueAtTime(698.46, now);
      gain.gain.setValueAtTime(0.03, now);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.1);
      osc.start(now);
      osc.stop(now + 0.11);
    }
  } catch {
    // Ignore autoplay blocks until user gesture
  }
}

let ringtoneTimer: ReturnType<typeof setInterval> | null = null;

function playRingPulse(kind: "incoming" | "outgoing"): void {
  try {
    const ctx = getAudioContext();
    if (!ctx) return;

    const now = ctx.currentTime;
    const tones =
      kind === "incoming"
        ? [
            { freq: 659.25, start: 0, dur: 0.18 },
            { freq: 783.99, start: 0.2, dur: 0.22 },
            { freq: 987.77, start: 0.44, dur: 0.28 },
          ]
        : [{ freq: 440, start: 0, dur: 0.42 }];

    for (const t of tones) {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = "sine";
      osc.frequency.setValueAtTime(t.freq, now + t.start);
      gain.gain.setValueAtTime(0.0001, now + t.start);
      gain.gain.linearRampToValueAtTime(kind === "incoming" ? 0.05 : 0.028, now + t.start + 0.03);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + t.start + t.dur);
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(now + t.start);
      osc.stop(now + t.start + t.dur + 0.02);
    }
  } catch {
    // Ignore autoplay blocks until user gesture
  }
}

export function startRingtone(kind: "incoming" | "outgoing" = "incoming"): void {
  stopRingtone();
  playRingPulse(kind);
  ringtoneTimer = setInterval(() => {
    playRingPulse(kind);
  }, 2200);
}

export function stopRingtone(): void {
  if (ringtoneTimer !== null) {
    clearInterval(ringtoneTimer);
    ringtoneTimer = null;
  }
}

export function playCallConnectTone(): void {
  stopRingtone();
  try {
    const ctx = getAudioContext();
    if (!ctx) return;
    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "triangle";
    osc.frequency.setValueAtTime(523.25, now);
    osc.frequency.exponentialRampToValueAtTime(783.99, now + 0.14);
    gain.gain.setValueAtTime(0.045, now);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.24);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(now);
    osc.stop(now + 0.26);
  } catch {
    // Ignore autoplay blocks until user gesture
  }
}

export function playCallEndTone(): void {
  stopRingtone();
  try {
    const ctx = getAudioContext();
    if (!ctx) return;
    const now = ctx.currentTime;
    [
      { freq: 493.88, start: 0, dur: 0.14 },
      { freq: 349.23, start: 0.16, dur: 0.2 },
    ].forEach((t) => {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = "sine";
      osc.frequency.setValueAtTime(t.freq, now + t.start);
      gain.gain.setValueAtTime(0.04, now + t.start);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + t.start + t.dur);
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(now + t.start);
      osc.stop(now + t.start + t.dur + 0.02);
    });
  } catch {
    // Ignore autoplay blocks until user gesture
  }
}
