"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ConnectionQuality,
  ConnectionState,
  Room,
  RoomEvent,
  Track,
  VideoPresets,
  VideoQuality,
  type LocalTrackPublication,
  type Participant,
  type RemoteParticipant,
  type RemoteTrack,
  type RemoteTrackPublication,
} from "livekit-client";
import {
  Maximize2,
  Mic,
  MicOff,
  Minimize2,
  Phone,
  PhoneCall,
  PhoneOff,
  SlidersHorizontal,
  LayoutDashboard,
  SwitchCamera,
  Video,
  VideoOff,
  Volume2,
} from "lucide-react";
import { formatCallDuration, resolveLiveKitUrl } from "@/lib/api";
import { computeMosaicLayout, promoteSpeakers } from "@/lib/callMosaic";
import type { CallJoinResponse, CallSession, UserProfile } from "@/lib/types";
import { UserAvatar } from "./StickerArt";

interface CallWorkspaceBarProps {
  currentUser: UserProfile;
  incomingCall: CallSession | null;
  activeJoin: CallJoinResponse | null;
  expanded: boolean;
  onToggleExpanded: (expanded: boolean) => void;
  onAcceptCall: (callId: string) => Promise<void>;
  onDeclineCall: (callId: string) => Promise<void>;
  onHangupCall: (callId: string) => Promise<void>;
}

interface ParticipantTileData {
  identity: string;
  name: string;
  isLocal: boolean;
  isSpeaking: boolean;
  micEnabled: boolean;
  camEnabled: boolean;
  videoTrack: Track | null;
}

function qualitySeverityRank(q: ConnectionQuality): number {
  switch (q) {
    case ConnectionQuality.Lost:
      return 0;
    case ConnectionQuality.Poor:
      return 1;
    case ConnectionQuality.Good:
      return 2;
    case ConnectionQuality.Excellent:
      return 3;
    default:
      return 4;
  }
}

function resolveAdaptiveVideoQuality(
  q: ConnectionQuality,
  remoteCount: number
): VideoQuality {
  switch (q) {
    case ConnectionQuality.Lost:
      return VideoQuality.LOW;
    case ConnectionQuality.Poor:
      return remoteCount >= 2 ? VideoQuality.LOW : VideoQuality.MEDIUM;
    default:
      return VideoQuality.HIGH;
  }
}

function resolveAdaptiveQualityBadge(q: ConnectionQuality): string {
  switch (q) {
    case ConnectionQuality.Lost:
      return "Auto ประหยัดเน็ต";
    case ConnectionQuality.Poor:
      return "Auto SD";
    default:
      return "Auto HD";
  }
}

function VideoTrackView({
  track,
  muted,
  mirror,
}: {
  track: Track;
  muted?: boolean;
  mirror?: boolean;
}) {
  const videoRef = useRef<HTMLVideoElement | null>(null);

  useEffect(() => {
    const el = videoRef.current;
    if (!el) return;
    track.attach(el);
    return () => {
      track.detach(el);
    };
  }, [track]);

  return (
    <video
      ref={videoRef}
      autoPlay
      playsInline
      muted={muted}
      className={`h-full w-full object-cover ${mirror ? "-scale-x-100" : ""}`}
    />
  );
}

function AudioTrackPlayer({ track }: { track: Track }) {
  const audioRef = useRef<HTMLAudioElement | null>(null);

  useEffect(() => {
    const el = audioRef.current;
    if (!el) return;
    track.attach(el);
    return () => {
      track.detach(el);
    };
  }, [track]);

  return <audio ref={audioRef} autoPlay playsInline className="hidden" />;
}

export function CallWorkspaceBar({
  currentUser,
  incomingCall,
  activeJoin,
  expanded,
  onToggleExpanded,
  onAcceptCall,
  onDeclineCall,
  onHangupCall,
}: CallWorkspaceBarProps) {
  const roomRef = useRef<Room | null>(null);
  const [connState, setConnState] = useState<ConnectionState>(ConnectionState.Disconnected);
  const [roomErr, setRoomErr] = useState<string | null>(null);
  const [mediaNotice, setMediaNotice] = useState<string | null>(null);
  const [micOn, setMicOn] = useState(false);
  const [camOn, setCamOn] = useState(false);
  const [canPlaybackAudio, setCanPlaybackAudio] = useState(true);
  const [showDevices, setShowDevices] = useState(false);
  const [audioInputs, setAudioInputs] = useState<MediaDeviceInfo[]>([]);
  const [videoInputs, setVideoInputs] = useState<MediaDeviceInfo[]>([]);
  const [selectedMicId, setSelectedMicId] = useState("");
  const [selectedCamId, setSelectedCamId] = useState("");
  const [audioOutputs, setAudioOutputs] = useState<MediaDeviceInfo[]>([]);
  const [selectedSpeakerId, setSelectedSpeakerId] = useState("");
  const [camFacing, setCamFacing] = useState<string | undefined>(undefined);
  const [switchingCam, setSwitchingCam] = useState(false);
  const [elapsedSec, setElapsedSec] = useState(0);
  const [netQuality, setNetQuality] = useState<ConnectionQuality>(ConnectionQuality.Unknown);
  const [tiles, setTiles] = useState<ParticipantTileData[]>([]);
  const [autoArrange, setAutoArrange] = useState(true);
  const [speakerOrder, setSpeakerOrder] = useState<string[]>([]);
  const [mosaicEl, setMosaicEl] = useState<HTMLDivElement | null>(null);
  const [mosaicWidth, setMosaicWidth] = useState(0);
  const lastPromoteAtRef = useRef(0);

  // วิดีโอคอลกลุ่ม: คนที่กำลังพูด (ไม่นับตัวเอง) เลื่อนขึ้นเป็นไทล์แรก เว้นช่วง 1.5 วิ กันสลับถี่
  useEffect(() => {
    const present = tiles.map((t) => t.identity);
    setSpeakerOrder((prev) => promoteSpeakers(prev, present, []));
    const speaking = tiles.filter((t) => t.isSpeaking && !t.isLocal).map((t) => t.identity);
    if (!autoArrange || speaking.length === 0) return;
    const wait = Math.max(0, 1500 - (Date.now() - lastPromoteAtRef.current));
    const timer = window.setTimeout(() => {
      setSpeakerOrder((prev) => {
        const next = promoteSpeakers(prev, present, speaking);
        if (next !== prev) lastPromoteAtRef.current = Date.now();
        return next;
      });
    }, wait);
    return () => window.clearTimeout(timer);
  }, [tiles, autoArrange]);

  useEffect(() => {
    if (!mosaicEl) return;
    const measure = () => setMosaicWidth(Math.max(0, mosaicEl.clientWidth - 16));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(mosaicEl);
    return () => observer.disconnect();
  }, [mosaicEl]);

  const handleBringToFront = (identity: string) => {
    lastPromoteAtRef.current = Date.now();
    setSpeakerOrder((prev) => [identity, ...prev.filter((id) => id !== identity)]);
  };
  const [remoteAudioTracks, setRemoteAudioTracks] = useState<Array<{ sid: string; track: Track }>>([]);
  const [actionBusy, setActionBusy] = useState(false);

  const applyAdaptiveVideoQuality = useCallback((room: Room) => {
    let worst: ConnectionQuality = ConnectionQuality.Unknown;
    let worstRank = qualitySeverityRank(worst);

    const participants: Array<Participant> = [
      room.localParticipant,
      ...Array.from(room.remoteParticipants.values()),
    ];
    for (const p of participants) {
      const q = p.connectionQuality;
      if (!q || q === ConnectionQuality.Unknown) continue;
      const rank = qualitySeverityRank(q);
      if (worst === ConnectionQuality.Unknown || rank < worstRank) {
        worst = q;
        worstRank = rank;
      }
    }

    setNetQuality(worst);
    const targetQuality = resolveAdaptiveVideoQuality(worst, room.remoteParticipants.size);

    room.remoteParticipants.forEach((rp: RemoteParticipant) => {
      rp.videoTrackPublications.forEach((pub: RemoteTrackPublication) => {
        if (pub.isSubscribed) {
          pub.setVideoQuality(targetQuality);
        }
      });
    });
  }, []);

  const syncRoomSnapshot = useCallback((room: Room) => {
    const lp = room.localParticipant;
    const localMicPub = lp.getTrackPublication(Track.Source.Microphone);
    const localCamPub = lp.getTrackPublication(Track.Source.Camera);
    setMicOn(Boolean(localMicPub && !localMicPub.isMuted));
    setCamOn(Boolean(localCamPub && !localCamPub.isMuted && localCamPub.track));
    setCamFacing(localCamPub?.videoTrack?.mediaStreamTrack.getSettings().facingMode);
    setCanPlaybackAudio(room.canPlaybackAudio);

    const nextTiles: ParticipantTileData[] = [
      {
        identity: lp.identity || currentUser.id,
        name: lp.name || currentUser.display_name || "คุณ",
        isLocal: true,
        isSpeaking: lp.isSpeaking,
        micEnabled: Boolean(localMicPub && !localMicPub.isMuted),
        camEnabled: Boolean(localCamPub && !localCamPub.isMuted && localCamPub.track),
        videoTrack:
          localCamPub && !localCamPub.isMuted && localCamPub.track
            ? localCamPub.track
            : null,
      },
    ];

    const nextAudio: Array<{ sid: string; track: Track }> = [];

    room.remoteParticipants.forEach((rp: RemoteParticipant) => {
      const rMic = rp.getTrackPublication(Track.Source.Microphone);
      const rCam = rp.getTrackPublication(Track.Source.Camera);
      const videoTrack =
        rCam && rCam.isSubscribed && rCam.track && !rCam.isMuted ? rCam.track : null;

      nextTiles.push({
        identity: rp.identity,
        name: rp.name || rp.identity,
        isLocal: false,
        isSpeaking: rp.isSpeaking,
        micEnabled: Boolean(rMic && !rMic.isMuted),
        camEnabled: Boolean(videoTrack),
        videoTrack,
      });

      rp.audioTrackPublications.forEach((pub: RemoteTrackPublication) => {
        if (pub.isSubscribed && pub.track) {
          nextAudio.push({ sid: pub.trackSid, track: pub.track });
        }
      });
    });

    setTiles(nextTiles);
    setRemoteAudioTracks(nextAudio);
  }, [currentUser.display_name, currentUser.id]);

  const refreshDevices = useCallback(async () => {
    try {
      const [mics, cams, speakers] = await Promise.all([
        Room.getLocalDevices("audioinput", false).catch(() => [] as MediaDeviceInfo[]),
        Room.getLocalDevices("videoinput", false).catch(() => [] as MediaDeviceInfo[]),
        Room.getLocalDevices("audiooutput", false).catch(() => [] as MediaDeviceInfo[]),
      ]);
      setAudioInputs(mics);
      setVideoInputs(cams);
      setAudioOutputs(speakers);
      const room = roomRef.current;
      if (room) {
        const camTrack = room.localParticipant.getTrackPublication(Track.Source.Camera)?.videoTrack;
        const camId = (await camTrack?.getDeviceId()) ?? room.getActiveDevice("videoinput");
        setSelectedMicId(room.getActiveDevice("audioinput") ?? "");
        setSelectedCamId(camId ?? "");
        setSelectedSpeakerId(room.getActiveDevice("audiooutput") ?? "");
      }
    } catch {
      // Headless or restricted device enumeration
    }
  }, []);

  // Camera labels/ids become available once the camera is on
  useEffect(() => {
    if (camOn) void refreshDevices();
  }, [camOn, refreshDevices]);

  // Active call duration ticker
  useEffect(() => {
    if (!activeJoin?.call) {
      setElapsedSec(0);
      return;
    }
    const call = activeJoin.call;
    if (call.status !== "active") {
      setElapsedSec(call.duration_sec || 0);
      return;
    }
    const baseMs = call.answered_at
      ? Date.parse(call.answered_at)
      : Date.parse(call.started_at);
    const compute = () => {
      if (Number.isNaN(baseMs)) return call.duration_sec || 0;
      return Math.max(0, Math.floor((Date.now() - baseMs) / 1000));
    };
    setElapsedSec(compute());
    const timer = setInterval(() => {
      setElapsedSec(compute());
    }, 1000);
    return () => clearInterval(timer);
  }, [activeJoin]);

  // LiveKit Room connection lifecycle
  const joinKey = activeJoin ? `${activeJoin.call.id}:${activeJoin.token}` : "";

  useEffect(() => {
    if (!activeJoin || !activeJoin.token) {
      setConnState(ConnectionState.Disconnected);
      setNetQuality(ConnectionQuality.Unknown);
      return;
    }

    let disposed = false;
    setRoomErr(null);
    setMediaNotice(null);
    setNetQuality(ConnectionQuality.Unknown);

    const dpr = typeof window !== "undefined" ? window.devicePixelRatio || 1 : 2;
    const effectivePixelDensity = Math.max(2, Math.min(3, dpr));

    const room = new Room({
      adaptiveStream: {
        pixelDensity: effectivePixelDensity,
        pauseVideoInBackground: true,
      },
      dynacast: true,
      videoCaptureDefaults: {
        resolution: VideoPresets.h1080.resolution,
        facingMode: "user",
      },
      publishDefaults: {
        simulcast: true,
        videoEncoding: VideoPresets.h1080.encoding,
        videoSimulcastLayers: [VideoPresets.h360, VideoPresets.h720],
        degradationPreference: "balanced",
      },
    });
    roomRef.current = room;

    const refresh = () => {
      if (!disposed) syncRoomSnapshot(room);
    };

    const refreshAdaptive = () => {
      if (!disposed) {
        applyAdaptiveVideoQuality(room);
        syncRoomSnapshot(room);
      }
    };

    room
      .on(RoomEvent.ConnectionStateChanged, (state: ConnectionState) => {
        if (!disposed) setConnState(state);
        refresh();
      })
      .on(RoomEvent.Connected, () => {
        if (!disposed) setConnState(room.state);
        refreshAdaptive();
      })
      .on(RoomEvent.Disconnected, () => {
        if (!disposed) {
          setConnState(ConnectionState.Disconnected);
          setNetQuality(ConnectionQuality.Unknown);
        }
        refresh();
      })
      .on(RoomEvent.ParticipantConnected, (_p: RemoteParticipant) => refreshAdaptive())
      .on(RoomEvent.ParticipantDisconnected, (_p: RemoteParticipant) => refreshAdaptive())
      .on(RoomEvent.TrackSubscribed, (_t: RemoteTrack, _pub: RemoteTrackPublication) =>
        refreshAdaptive()
      )
      .on(RoomEvent.TrackUnsubscribed, () => refresh())
      .on(RoomEvent.ConnectionQualityChanged, () => {
        if (!disposed) applyAdaptiveVideoQuality(room);
      })
      .on(RoomEvent.LocalTrackPublished, (_pub: LocalTrackPublication) => refresh())
      .on(RoomEvent.LocalTrackUnpublished, () => refresh())
      .on(RoomEvent.TrackMuted, () => refresh())
      .on(RoomEvent.TrackUnmuted, () => refresh())
      .on(RoomEvent.ActiveSpeakersChanged, (_speakers: Participant[]) => refresh())
      .on(RoomEvent.AudioPlaybackStatusChanged, () => refresh())
      .on(RoomEvent.MediaDevicesChanged, () => {
        void refreshDevices();
      })
      .on(RoomEvent.ActiveDeviceChanged, () => {
        void refreshDevices();
      });

    const connectToLiveKit = async () => {
      try {
        setConnState(ConnectionState.Connecting);
        const lkUrl = resolveLiveKitUrl(activeJoin.livekit_url);
        await room.connect(lkUrl, activeJoin.token, { autoSubscribe: true });
        if (disposed) {
          await room.disconnect();
          return;
        }

        applyAdaptiveVideoQuality(room);

        const notices: string[] = [];
        try {
          await room.localParticipant.setMicrophoneEnabled(true);
        } catch {
          notices.push("โหมดรับฟัง (ไม่พบไมโครโฟนหรือไม่ได้อนุญาต)");
        }

        if (activeJoin.call.call_type === "video") {
          try {
            await room.localParticipant.setCameraEnabled(true);
          } catch {
            notices.push("ไม่พบกล้องหรือไม่ได้รับอนุญาต");
          }
        }

        if (!disposed) {
          setMediaNotice(notices.length > 0 ? notices.join(" • ") : null);
          applyAdaptiveVideoQuality(room);
          syncRoomSnapshot(room);
          void refreshDevices();
        }
      } catch (err) {
        if (!disposed) {
          setRoomErr(
            err instanceof Error
              ? err.message
              : "เชื่อมต่อห้องเสียง/วิดีโอ LiveKit ไม่สำเร็จ"
          );
          setConnState(ConnectionState.Disconnected);
        }
      }
    };

    void connectToLiveKit();

    return () => {
      disposed = true;
      roomRef.current = null;
      setTiles([]);
      setRemoteAudioTracks([]);
      void room.disconnect();
    };
  }, [joinKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const handleToggleMic = async () => {
    const room = roomRef.current;
    if (!room) return;
    try {
      await room.localParticipant.setMicrophoneEnabled(!micOn);
      setMediaNotice(null);
      syncRoomSnapshot(room);
    } catch {
      setMediaNotice("อุปกรณ์นี้ไม่มีไมโครโฟนที่เปิดใช้งานได้ (โหมดรับฟัง)");
    }
  };

  const handleToggleCam = async () => {
    const room = roomRef.current;
    if (!room) return;
    try {
      await room.localParticipant.setCameraEnabled(!camOn);
      if (!camOn) onToggleExpanded(true);
      syncRoomSnapshot(room);
    } catch {
      setMediaNotice("อุปกรณ์นี้ไม่พบกล้องที่พร้อมใช้งาน");
    }
  };

  const handleEnablePlayback = async () => {
    const room = roomRef.current;
    if (!room) return;
    try {
      await room.startAudio();
      syncRoomSnapshot(room);
    } catch {
      // Browser audio gesture guard
    }
  };

  const handleSwitchDevice = async (
    kind: "audioinput" | "videoinput" | "audiooutput",
    deviceId: string
  ) => {
    const room = roomRef.current;
    if (!room || !deviceId) return;
    try {
      await room.switchActiveDevice(kind, deviceId, true);
      syncRoomSnapshot(room);
      void refreshDevices();
    } catch {
      setMediaNotice("สลับอุปกรณ์ไม่สำเร็จ");
    }
  };

  // Quick front/back toggle: facingMode on phones, next videoinput on desktops
  const handleSwitchCamera = async () => {
    const room = roomRef.current;
    const camTrack = room?.localParticipant.getTrackPublication(Track.Source.Camera)?.videoTrack;
    if (!room || !camTrack || switchingCam || videoInputs.length < 2) return;
    setSwitchingCam(true);
    try {
      const before = camTrack.mediaStreamTrack.getSettings();
      let switched = false;
      if (before.facingMode === "user" || before.facingMode === "environment") {
        await camTrack.restartTrack({
          facingMode: before.facingMode === "user" ? "environment" : "user",
        });
        switched = camTrack.mediaStreamTrack.getSettings().facingMode !== before.facingMode;
      }
      if (!switched) {
        const currentId = (await camTrack.getDeviceId()) ?? room.getActiveDevice("videoinput");
        const idx = videoInputs.findIndex((d) => d.deviceId === currentId);
        const next = videoInputs[(idx + 1) % videoInputs.length];
        await room.switchActiveDevice("videoinput", next.deviceId, true);
      }
      setMediaNotice(null);
      syncRoomSnapshot(room);
      void refreshDevices();
    } catch {
      setMediaNotice("สลับกล้องไม่สำเร็จ");
    } finally {
      setSwitchingCam(false);
    }
  };

  if (!incomingCall && !activeJoin) {
    return null;
  }

  const showIncomingBanner =
    incomingCall && (!activeJoin || activeJoin.call.id !== incomingCall.id);

  const canPickSpeaker =
    typeof HTMLMediaElement !== "undefined" && "setSinkId" in HTMLMediaElement.prototype;
  const isVideoCall = activeJoin?.call.call_type === "video";
  const canSwitchCamera = isVideoCall && camOn && videoInputs.length > 1;

  const renderDeviceSelector = (darkMode: boolean) => {
    if (!showDevices) return null;
    const rows = [
      {
        kind: "videoinput" as const,
        label: "กล้อง",
        testId: "call-device-select-video",
        Icon: Video,
        devices: videoInputs,
        value: selectedCamId,
        show: isVideoCall,
      },
      {
        kind: "audioinput" as const,
        label: "ไมโครโฟน",
        testId: "call-device-select-audioin",
        Icon: Mic,
        devices: audioInputs,
        value: selectedMicId,
        show: true,
      },
      {
        kind: "audiooutput" as const,
        label: "ลำโพง",
        testId: "call-device-select-audioout",
        Icon: Volume2,
        devices: audioOutputs,
        value: selectedSpeakerId,
        show: canPickSpeaker,
      },
    ].filter((r) => r.show && r.devices.length > 1);
    const iconCls = darkMode
      ? "h-3.5 w-3.5 shrink-0 text-[#D4A373]"
      : "h-3.5 w-3.5 shrink-0 text-[var(--bc-muted)]";
    const textCls = darkMode ? "text-white/90" : "text-[var(--bc-text)]";
    const selectCls = darkMode
      ? "h-8 min-w-0 flex-1 rounded-lg border border-white/20 bg-[#1C1412] px-2 text-[11px] text-white outline-none focus-visible:border-[#D4A373]"
      : "h-8 min-w-0 flex-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 text-[11px] text-[var(--bc-text)] outline-none focus-visible:border-[var(--bc-primary)]";
    return (
      <div
        data-testid="call-devices-tray"
        className={
          darkMode
            ? "grid grid-cols-1 gap-1.5 rounded-xl border border-white/15 bg-black/35 p-2"
            : "mt-2 grid grid-cols-1 gap-1.5 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
        }
      >
        {rows.length === 0 && (
          <p className={`text-[11px] ${darkMode ? "text-white/70" : "text-[var(--bc-muted)]"}`}>
            ไม่มีอุปกรณ์ให้เลือกเพิ่ม
          </p>
        )}
        {rows.map(({ kind, label, testId, Icon, devices, value }) => (
          <label key={kind} className="flex items-center gap-1.5">
            <Icon className={iconCls} />
            <span className={`w-16 shrink-0 text-[11px] font-semibold ${textCls}`}>{label}</span>
            <select
              data-testid={testId}
              value={devices.some((d) => d.deviceId === value) ? value : ""}
              onChange={(e) => void handleSwitchDevice(kind, e.target.value)}
              className={selectCls}
            >
              {!devices.some((d) => d.deviceId === value) && (
                <option value="" disabled>
                  เลือก{label}
                </option>
              )}
              {devices.map((d, i) => (
                <option key={d.deviceId} value={d.deviceId}>
                  {d.label || `${label} ${i + 1}`}
                </option>
              ))}
            </select>
          </label>
        ))}
      </div>
    );
  };

  const mosaicOrder = promoteSpeakers(speakerOrder, tiles.map((t) => t.identity), []);
  const mosaic = computeMosaicLayout(tiles.length, mosaicWidth);
  const mainTile = tiles.find((t) => !t.isLocal) ?? tiles[0] ?? null;
  const pipTile =
    mainTile && tiles.length === 2
      ? tiles.find((t) => t.identity !== mainTile.identity) ?? null
      : null;

  if (expanded) {
    return (
      <div
        data-testid="call-fullscreen-stage"
        className="relative flex min-h-0 flex-1 flex-col justify-between overflow-hidden px-4 py-4 text-white"
        style={{
          background: "linear-gradient(160deg, #1C1412 0%, #3A1510 55%, #681F18 100%)",
        }}
      >
        <div
          aria-hidden="true"
          className="pointer-events-none absolute -top-24 left-1/2 h-72 w-72 -translate-x-1/2 rounded-full bg-[#D4A373]/15 blur-3xl"
        />

        {remoteAudioTracks.map((item) => (
          <AudioTrackPlayer key={item.sid} track={item.track} />
        ))}

        {/* Full-screen Incoming Call Stage */}
        {showIncomingBanner && incomingCall && !activeJoin && (
          <div
            data-testid="incoming-call-banner"
            className="relative z-10 flex min-h-0 flex-1 flex-col justify-between"
          >
            <div className="flex h-9 shrink-0 items-center justify-between gap-2">
              <span className="inline-flex h-7 items-center gap-1.5 rounded-full bg-white/10 px-3 text-xs font-bold text-[#FFDAD5]">
                <PhoneCall className="h-3.5 w-3.5 shrink-0 animate-pulse" />
                <span>
                  สายเรียกเข้า · {incomingCall.call_type === "video" ? "วิดีโอคอล" : "โทรเสียง"}
                </span>
              </span>
              <button
                type="button"
                data-testid="call-minimize-btn"
                onClick={() => onToggleExpanded(false)}
                className="inline-flex h-7 items-center gap-1 rounded-full bg-white/15 px-2.5 text-xs font-semibold text-white transition hover:bg-white/25"
              >
                <Minimize2 className="h-3.5 w-3.5 shrink-0" />
                <span>ย่อจอ</span>
              </button>
            </div>

            <div className="flex flex-1 flex-col items-center justify-center gap-3 px-2 text-center">
              <div className="flex h-36 w-36 items-center justify-center rounded-full border-2 border-[#D4A373]/40 bg-white/5 p-3 shadow-xl">
                <UserAvatar
                  name={incomingCall.initiator_name}
                  avatarUrl={incomingCall.initiator_avatar}
                  size={108}
                />
              </div>
              <h2 className="text-2xl font-bold text-white">{incomingCall.initiator_name}</h2>
              <p className="text-sm text-[#FFDAD5]">
                {incomingCall.call_type === "video"
                  ? "วิดีโอคอล • กดรับสายเพื่อเปิดห้องสนทนา"
                  : "โทรเสียง • กดรับสายเพื่อคุยทันที"}
              </p>
            </div>

            <div className="flex shrink-0 items-center justify-center gap-12 pb-6">
              <div className="flex flex-col items-center gap-1.5">
                <button
                  type="button"
                  disabled={actionBusy}
                  data-testid="decline-call-btn"
                  aria-label="ปฏิเสธ"
                  onClick={async () => {
                    setActionBusy(true);
                    try {
                      await onDeclineCall(incomingCall.id);
                    } finally {
                      setActionBusy(false);
                    }
                  }}
                  className="inline-flex h-16 w-16 items-center justify-center rounded-full bg-red-600 text-white shadow-lg transition hover:bg-red-700 disabled:opacity-60"
                >
                  <PhoneOff className="h-7 w-7" />
                </button>
                <span className="text-xs font-bold text-white/90">ปฏิเสธ</span>
              </div>

              <div className="flex flex-col items-center gap-1.5">
                <button
                  type="button"
                  disabled={actionBusy}
                  data-testid="accept-call-btn"
                  aria-label="รับสาย"
                  onClick={async () => {
                    setActionBusy(true);
                    try {
                      await onAcceptCall(incomingCall.id);
                    } finally {
                      setActionBusy(false);
                    }
                  }}
                  className="inline-flex h-16 w-16 items-center justify-center rounded-full bg-emerald-600 text-white shadow-lg transition hover:bg-emerald-700 disabled:opacity-60"
                >
                  {incomingCall.call_type === "video" ? (
                    <Video className="h-7 w-7" />
                  ) : (
                    <Phone className="h-7 w-7" />
                  )}
                </button>
                <span className="text-xs font-bold text-white/90">รับสาย</span>
              </div>
            </div>
          </div>
        )}

        {/* Full-screen Active Voice / Video Call Stage */}
        {activeJoin && (
          <div
            data-testid="active-call-dock"
            data-conn-state={connState}
            className="relative z-10 flex min-h-0 flex-1 flex-col justify-between gap-3"
          >
            {showIncomingBanner && incomingCall && (
              <div
                data-testid="incoming-call-banner"
                className="flex shrink-0 items-center justify-between gap-2 rounded-xl border border-[#D4A373]/50 bg-black/40 px-2.5 py-1.5"
              >
                <span className="min-w-0 truncate text-xs font-bold text-white">
                  สายเรียกเข้าจาก {incomingCall.initiator_name}
                </span>
                <div className="flex shrink-0 items-center gap-1.5">
                  <button
                    type="button"
                    disabled={actionBusy}
                    data-testid="accept-call-btn"
                    onClick={async () => {
                      setActionBusy(true);
                      try {
                        await onAcceptCall(incomingCall.id);
                      } finally {
                        setActionBusy(false);
                      }
                    }}
                    className="inline-flex h-7 items-center gap-1 rounded-lg bg-emerald-600 px-2.5 text-[11px] font-bold text-white"
                  >
                    <span>รับสาย</span>
                  </button>
                  <button
                    type="button"
                    disabled={actionBusy}
                    data-testid="decline-call-btn"
                    onClick={async () => {
                      setActionBusy(true);
                      try {
                        await onDeclineCall(incomingCall.id);
                      } finally {
                        setActionBusy(false);
                      }
                    }}
                    className="inline-flex h-7 items-center gap-1 rounded-lg bg-red-600 px-2.5 text-[11px] font-bold text-white"
                  >
                    <span>ปฏิเสธ</span>
                  </button>
                </div>
              </div>
            )}

            {/* Top Bar */}
            <div className="flex h-9 shrink-0 items-center justify-between gap-2">
              <div className="flex min-w-0 flex-1 items-center gap-1.5">
                <span
                  className={`inline-flex h-7 shrink-0 items-center gap-1 rounded-full px-2.5 text-xs font-bold ${
                    connState === ConnectionState.Connected
                      ? "bg-emerald-600 text-white"
                      : "bg-white/15 text-white"
                  }`}
                >
                  {activeJoin.call.call_type === "video" ? (
                    <Video className="h-3.5 w-3.5 shrink-0" />
                  ) : (
                    <Phone className="h-3.5 w-3.5 shrink-0" />
                  )}
                  <span>{activeJoin.call.call_type === "video" ? "วิดีโอคอล" : "โทรเสียง"}</span>
                </span>
                <span className="inline-flex h-7 shrink-0 items-center rounded-full bg-[#D4A373]/25 px-2.5 text-[11px] font-bold text-[#FFDAD5]">
                  {activeJoin.call.status === "ringing"
                    ? "กำลังเรียก..."
                    : formatCallDuration(elapsedSec)}
                </span>
                <span className="inline-flex h-7 shrink-0 items-center text-[11px] text-white/80">
                  • {Math.max(1, tiles.length)} คน
                </span>
                {(activeJoin.call.call_type === "video" || camOn) && (
                  <span
                    data-testid="call-quality-badge"
                    className="inline-flex h-7 shrink-0 items-center rounded-full bg-white/15 px-2 text-[11px] font-bold text-[#D4A373]"
                  >
                    {resolveAdaptiveQualityBadge(netQuality)}
                  </span>
                )}
              </div>

              <div className="flex shrink-0 items-center gap-1.5">
                {!canPlaybackAudio && (
                  <button
                    type="button"
                    onClick={() => void handleEnablePlayback()}
                    className="inline-flex h-7 items-center gap-1 rounded-full bg-amber-600 px-2.5 text-[11px] font-semibold text-white hover:bg-amber-700"
                  >
                    <Volume2 className="h-3.5 w-3.5 shrink-0" />
                    <span>เปิดเสียง</span>
                  </button>
                )}
                {tiles.length >= 3 && (
                  <button
                    type="button"
                    data-testid="call-auto-arrange-btn"
                    aria-pressed={autoArrange}
                    onClick={() => setAutoArrange((v) => !v)}
                    title={autoArrange ? "ปิดการเรียงตามคนพูดอัตโนมัติ" : "เปิดการเรียงตามคนพูดอัตโนมัติ"}
                    className={`inline-flex h-7 items-center gap-1 rounded-full border px-2.5 text-xs font-semibold text-white transition ${
                      autoArrange
                        ? "border-[#D4A373] bg-[#D4A373]/30"
                        : "border-transparent bg-white/15 hover:bg-white/25"
                    }`}
                  >
                    <LayoutDashboard className="h-3.5 w-3.5 shrink-0" />
                    <span>{autoArrange ? "เรียงอัตโนมัติ" : "เรียงเอง"}</span>
                  </button>
                )}
                <button
                  type="button"
                  data-testid="call-minimize-btn"
                  onClick={() => onToggleExpanded(false)}
                  title="ย่อจอเพื่อดูแชท"
                  className="inline-flex h-7 items-center gap-1 rounded-full bg-white/15 px-2.5 text-xs font-semibold text-white transition hover:bg-white/25"
                >
                  <Minimize2 className="h-3.5 w-3.5 shrink-0" />
                  <span>ย่อจอ</span>
                </button>
              </div>
            </div>

            {roomErr ? (
              <p
                data-testid="call-room-error"
                className="shrink-0 truncate rounded-lg bg-red-900/60 px-2.5 py-1 text-center text-[11px] font-semibold text-red-100"
              >
                {roomErr}
              </p>
            ) : mediaNotice ? (
              <p className="shrink-0 truncate rounded-lg bg-amber-900/40 px-2.5 py-1 text-center text-[11px] text-amber-200">
                {mediaNotice}
              </p>
            ) : null}

            {renderDeviceSelector(true)}

            {/* Main Video / Voice Stage */}
            <div className="relative min-h-0 flex-1 overflow-hidden rounded-2xl border border-white/15 bg-black/35">
              {tiles.length <= 2 ? (
                <>
                  {mainTile ? (
                    <div
                      data-testid="call-participant-tile"
                      data-participant-id={mainTile.identity}
                      data-has-video={mainTile.videoTrack ? "true" : "false"}
                      className="relative flex h-full w-full items-center justify-center overflow-hidden"
                    >
                      {mainTile.videoTrack ? (
                        <VideoTrackView
                          track={mainTile.videoTrack}
                          muted={mainTile.isLocal}
                          mirror={mainTile.isLocal && camFacing !== "environment"}
                        />
                      ) : (
                        <div className="flex flex-col items-center gap-2.5 p-4 text-center">
                          <div className="flex h-32 w-32 items-center justify-center rounded-full border-2 border-[#D4A373]/40 bg-white/5 p-2">
                            <UserAvatar name={mainTile.name} size={96} />
                          </div>
                          <span className="text-lg font-bold text-white">{mainTile.name}</span>
                          <span className="text-xs text-[#FFDAD5]">
                            {mainTile.isLocal
                              ? "กำลังรอคู่สายรับสาย..."
                              : connState === ConnectionState.Connecting
                                ? "กำลังเชื่อมต่อ..."
                                : "กำลังสนทนาด้วยเสียง"}
                          </span>
                        </div>
                      )}
                      <div className="absolute bottom-3 left-3 inline-flex items-center gap-1 rounded-full bg-black/60 px-2.5 py-1 text-xs font-semibold text-white">
                        <span>{mainTile.isLocal ? `${mainTile.name} (คุณ)` : mainTile.name}</span>
                        {!mainTile.micEnabled && <MicOff className="h-3.5 w-3.5 text-red-300" />}
                      </div>
                    </div>
                  ) : (
                    <div className="flex h-full w-full flex-col items-center justify-center gap-2 p-4 text-center">
                      <span className="text-sm font-bold text-white">
                        {connState === ConnectionState.Connecting
                          ? "กำลังเชื่อมต่อห้องสนทนา..."
                          : "กำลังเตรียมห้องสนทนา..."}
                      </span>
                    </div>
                  )}

                  {pipTile && (
                    <div
                      data-testid="call-participant-tile"
                      data-participant-id={pipTile.identity}
                      data-has-video={pipTile.videoTrack ? "true" : "false"}
                      className="absolute right-3 top-3 z-20 flex h-32 w-24 items-center justify-center overflow-hidden rounded-xl border-2 border-[#D4A373] bg-[#1C1412] shadow-lg"
                    >
                      {pipTile.videoTrack ? (
                        <VideoTrackView
                          track={pipTile.videoTrack}
                          muted={pipTile.isLocal}
                          mirror={pipTile.isLocal && camFacing !== "environment"}
                        />
                      ) : (
                        <div className="flex flex-col items-center gap-1 p-1 text-center">
                          <UserAvatar name={pipTile.name} size={40} />
                          <span className="max-w-[78px] truncate text-[10px] font-semibold text-white">
                            {pipTile.name}
                          </span>
                        </div>
                      )}
                      <div className="absolute bottom-1 left-1 right-1 flex items-center justify-between gap-1 rounded bg-black/65 px-1 py-0.5 text-[9px] font-semibold text-white">
                        <span className="truncate">{pipTile.isLocal ? "คุณ" : pipTile.name}</span>
                        {!pipTile.micEnabled && <MicOff className="h-2.5 w-2.5 text-red-300" />}
                      </div>
                    </div>
                  )}
                </>
              ) : (
                <div
                  ref={setMosaicEl}
                  data-testid="call-mosaic"
                  data-auto-arrange={autoArrange ? "true" : "false"}
                  className="h-full overflow-y-auto p-2"
                >
                  <div className="relative" style={{ height: mosaic.height }}>
                    {tiles.map((tile) => {
                      const rank = mosaicOrder.indexOf(tile.identity);
                      const rect = mosaic.rects[rank];
                      if (!rect) return null;
                      return (
                        <button
                          type="button"
                          key={tile.identity}
                          data-testid="call-participant-tile"
                          data-participant-id={tile.identity}
                          data-has-video={tile.videoTrack ? "true" : "false"}
                          data-rank={rank}
                          onClick={() => handleBringToFront(tile.identity)}
                          title="แตะเพื่อย้ายขึ้นเป็นอันแรก"
                          style={{ left: rect.x, top: rect.y, width: rect.w, height: rect.h }}
                          className={`absolute flex items-center justify-center overflow-hidden rounded-2xl border bg-[#1C1412] transition-all duration-500 ease-out ${
                            tile.isSpeaking
                              ? "border-2 border-[#D4A373] shadow-[0_0_18px_rgba(212,163,115,0.55)]"
                              : "border-white/15"
                          }`}
                        >
                          {tile.videoTrack ? (
                            <VideoTrackView
                              track={tile.videoTrack}
                              muted={tile.isLocal}
                              mirror={tile.isLocal && camFacing !== "environment"}
                            />
                          ) : (
                            <UserAvatar name={tile.name} size={rank === 0 ? 72 : 48} />
                          )}
                          <span className="absolute bottom-1.5 left-1.5 right-1.5 flex items-center justify-between gap-1 rounded-md bg-black/60 px-2 py-0.5 text-[10px] font-semibold text-white">
                            <span className="truncate">
                              {tile.isLocal ? `${tile.name} (คุณ)` : tile.name}
                            </span>
                            {!tile.micEnabled && <MicOff className="h-3 w-3 shrink-0 text-red-300" />}
                          </span>
                        </button>
                      );
                    })}
                  </div>
                </div>
              )}
            </div>

            {/* Bottom Symmetric Controls */}
            <div className="flex shrink-0 items-center justify-around gap-2 rounded-2xl border border-white/15 bg-black/35 px-3 py-3">
              <div className="flex flex-col items-center gap-1">
                <button
                  type="button"
                  data-testid="call-toggle-mic-btn"
                  onClick={() => void handleToggleMic()}
                  title={micOn ? "ปิดไมโครโฟน" : "เปิดไมโครโฟน"}
                  className={`inline-flex h-12 w-12 items-center justify-center rounded-full border transition ${
                    micOn
                      ? "border-white/25 bg-white/15 text-white hover:bg-white/25"
                      : "border-red-400 bg-red-600/80 text-white"
                  }`}
                >
                  {micOn ? <Mic className="h-5 w-5" /> : <MicOff className="h-5 w-5" />}
                </button>
                <span className="text-[11px] font-semibold text-white/90">
                  {micOn ? "ไมค์" : "ปิดไมค์"}
                </span>
              </div>

              <div className="flex flex-col items-center gap-1">
                <button
                  type="button"
                  data-testid="call-toggle-cam-btn"
                  onClick={() => void handleToggleCam()}
                  title={camOn ? "ปิดกล้อง" : "เปิดกล้อง"}
                  className={`inline-flex h-12 w-12 items-center justify-center rounded-full border transition ${
                    camOn
                      ? "border-[#D4A373] bg-[#D4A373]/30 text-white"
                      : "border-white/25 bg-white/15 text-white/80 hover:bg-white/25"
                  }`}
                >
                  {camOn ? <Video className="h-5 w-5" /> : <VideoOff className="h-5 w-5" />}
                </button>
                <span className="text-[11px] font-semibold text-white/90">
                  {camOn ? "กล้อง" : "ปิดกล้อง"}
                </span>
              </div>

              {canSwitchCamera && (
                  <div className="flex flex-col items-center gap-1">
                    <button
                      type="button"
                      data-testid="call-switch-camera-btn"
                      aria-label="สลับกล้องหน้า/หลัง"
                      title="สลับกล้อง"
                      disabled={switchingCam}
                      onClick={() => void handleSwitchCamera()}
                      className="inline-flex h-12 w-12 items-center justify-center rounded-full border border-white/25 bg-white/15 text-white transition hover:bg-white/25 disabled:opacity-60"
                    >
                      <SwitchCamera className="h-5 w-5" />
                    </button>
                    <span className="text-[11px] font-semibold text-white/90">สลับกล้อง</span>
                  </div>
                )}

              <div className="flex flex-col items-center gap-1">
                <button
                  type="button"
                  data-testid="call-devices-btn"
                  aria-label="เลือกอุปกรณ์"
                  aria-expanded={showDevices}
                  onClick={() => setShowDevices((v) => !v)}
                  title="เลือกอุปกรณ์"
                  className={`inline-flex h-12 w-12 items-center justify-center rounded-full border transition ${
                    showDevices
                      ? "border-[#D4A373] bg-[#D4A373]/30 text-white"
                      : "border-white/25 bg-white/15 text-white hover:bg-white/25"
                  }`}
                >
                  <SlidersHorizontal className="h-5 w-5" />
                </button>
                <span className="text-[11px] font-semibold text-white/90">อุปกรณ์</span>
              </div>

              <div className="flex flex-col items-center gap-1">
                <button
                  type="button"
                  disabled={actionBusy}
                  data-testid="hangup-call-btn"
                  onClick={async () => {
                    setActionBusy(true);
                    try {
                      await onHangupCall(activeJoin.call.id);
                    } finally {
                      setActionBusy(false);
                    }
                  }}
                  className="inline-flex h-12 w-12 items-center justify-center rounded-full bg-red-600 text-white shadow-lg transition hover:bg-red-700 disabled:opacity-60"
                >
                  <PhoneOff className="h-5 w-5" />
                </button>
                <span className="text-[11px] font-bold text-red-200">วางสาย</span>
              </div>
            </div>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-1.5 border-b border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-1.5">
      {/* Hidden remote audio elements */}
      {remoteAudioTracks.map((item) => (
        <AudioTrackPlayer key={item.sid} track={item.track} />
      ))}

      {/* Minimized Incoming Call Banner */}
      {showIncomingBanner && incomingCall && (
        <div
          data-testid="incoming-call-banner"
          className="flex flex-wrap items-center justify-between gap-2 rounded-xl border-2 border-[var(--bc-primary)] bg-[var(--bc-card)] px-2.5 py-1.5 shadow-sm"
        >
          <div className="flex min-w-0 items-center gap-2">
            <UserAvatar
              name={incomingCall.initiator_name}
              avatarUrl={incomingCall.initiator_avatar}
              size={32}
            />
            <div className="min-w-0">
              <div className="flex items-center gap-1.5">
                <PhoneCall className="h-3.5 w-3.5 shrink-0 animate-pulse text-[var(--bc-primary)]" />
                <span className="truncate text-xs font-bold text-[var(--bc-text)]">
                  สายเรียกเข้าจาก {incomingCall.initiator_name}
                </span>
              </div>
            </div>
          </div>

          <div className="flex shrink-0 items-center gap-1.5">
            {!activeJoin && (
              <button
                type="button"
                data-testid="call-expand-btn"
                onClick={() => onToggleExpanded(true)}
                className="inline-flex h-8 items-center gap-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 text-xs font-semibold text-[var(--bc-text)]"
              >
                <Maximize2 className="h-3.5 w-3.5 shrink-0" />
                <span>เต็มจอ</span>
              </button>
            )}
            <button
              type="button"
              disabled={actionBusy}
              data-testid="accept-call-btn"
              onClick={async () => {
                setActionBusy(true);
                try {
                  await onAcceptCall(incomingCall.id);
                } finally {
                  setActionBusy(false);
                }
              }}
              className="inline-flex h-8 items-center gap-1 rounded-xl bg-emerald-700 px-3 text-xs font-bold text-white shadow-xs transition hover:bg-emerald-800 disabled:opacity-60"
            >
              {incomingCall.call_type === "video" ? (
                <Video className="h-3.5 w-3.5 shrink-0" />
              ) : (
                <Phone className="h-3.5 w-3.5 shrink-0" />
              )}
              <span>รับสาย</span>
            </button>
            <button
              type="button"
              disabled={actionBusy}
              data-testid="decline-call-btn"
              onClick={async () => {
                setActionBusy(true);
                try {
                  await onDeclineCall(incomingCall.id);
                } finally {
                  setActionBusy(false);
                }
              }}
              className="inline-flex h-8 items-center gap-1 rounded-xl bg-red-600 px-3 text-xs font-bold text-white shadow-xs transition hover:bg-red-700 disabled:opacity-60"
            >
              <PhoneOff className="h-3.5 w-3.5 shrink-0" />
              <span>ปฏิเสธ</span>
            </button>
          </div>
        </div>
      )}

      {/* Minimized Active Call Dock */}
      {activeJoin && (
        <div
          data-testid="active-call-dock"
          data-conn-state={connState}
          className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2 shadow-sm"
        >
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex min-w-0 items-center gap-2">
              <span
                className={`inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-lg text-white ${
                  connState === ConnectionState.Connected
                    ? "bg-emerald-700"
                    : "bg-[var(--bc-primary)]"
                }`}
              >
                {activeJoin.call.call_type === "video" ? (
                  <Video className="h-4 w-4" />
                ) : (
                  <Phone className="h-4 w-4" />
                )}
              </span>

              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-1.5">
                  <span className="text-xs font-bold text-[var(--bc-text)]">
                    {activeJoin.call.call_type === "video" ? "วิดีโอคอล" : "โทรเสียง"}
                  </span>
                  <span className="rounded-full bg-[var(--bc-soft)] px-2 py-0.5 text-[10px] font-bold text-[var(--bc-deep)]">
                    {activeJoin.call.status === "ringing"
                      ? "กำลังเรียก..."
                      : formatCallDuration(elapsedSec)}
                  </span>
                  <span className="text-[11px] text-[var(--bc-muted)]">
                    • {Math.max(1, tiles.length)} คน
                  </span>
                </div>
                {roomErr ? (
                  <p
                    data-testid="call-room-error"
                    className="truncate text-[11px] font-semibold text-red-700"
                  >
                    {roomErr}
                  </p>
                ) : mediaNotice ? (
                  <p className="truncate text-[11px] text-amber-700">{mediaNotice}</p>
                ) : null}
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-1">
              <button
                type="button"
                data-testid="call-expand-btn"
                onClick={() => onToggleExpanded(true)}
                className="inline-flex h-8 items-center gap-1 rounded-lg border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-2 text-[11px] font-bold text-[var(--bc-deep)]"
              >
                <Maximize2 className="h-3.5 w-3.5 shrink-0" />
                <span>เต็มจอ</span>
              </button>

              {!canPlaybackAudio && (
                <button
                  type="button"
                  onClick={() => void handleEnablePlayback()}
                  className="inline-flex h-8 items-center gap-1 rounded-lg bg-amber-600 px-2 text-[11px] font-semibold text-white hover:bg-amber-700"
                >
                  <Volume2 className="h-3.5 w-3.5 shrink-0" />
                  <span>เปิดเสียง</span>
                </button>
              )}

              <button
                type="button"
                data-testid="call-toggle-mic-btn"
                onClick={() => void handleToggleMic()}
                title={micOn ? "ปิดไมโครโฟน" : "เปิดไมโครโฟน"}
                className={`inline-flex h-8 items-center gap-1 rounded-lg border px-2 text-[11px] font-semibold transition ${
                  micOn
                    ? "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)]"
                    : "border-red-300 bg-red-50 text-red-700"
                }`}
              >
                {micOn ? <Mic className="h-3.5 w-3.5" /> : <MicOff className="h-3.5 w-3.5" />}
              </button>

              <button
                type="button"
                data-testid="call-toggle-cam-btn"
                onClick={() => void handleToggleCam()}
                title={camOn ? "ปิดกล้อง" : "เปิดกล้อง"}
                className={`inline-flex h-8 items-center gap-1 rounded-lg border px-2 text-[11px] font-semibold transition ${
                  camOn
                    ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                    : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-muted)]"
                }`}
              >
                {camOn ? <Video className="h-3.5 w-3.5" /> : <VideoOff className="h-3.5 w-3.5" />}
              </button>

              {canSwitchCamera && (
                <button
                  type="button"
                  data-testid="call-switch-camera-btn"
                  aria-label="สลับกล้องหน้า/หลัง"
                  title="สลับกล้อง"
                  disabled={switchingCam}
                  onClick={() => void handleSwitchCamera()}
                  className="inline-flex h-8 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2 text-[11px] font-semibold text-[var(--bc-text)] disabled:opacity-60"
                >
                  <SwitchCamera className="h-3.5 w-3.5" />
                </button>
              )}

              <button
                type="button"
                data-testid="call-devices-btn"
                aria-label="เลือกอุปกรณ์"
                aria-expanded={showDevices}
                onClick={() => setShowDevices((v) => !v)}
                title="เลือกอุปกรณ์"
                className={`inline-flex h-8 items-center gap-1 rounded-lg border px-2 text-[11px] font-semibold ${
                  showDevices
                    ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                    : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-muted)]"
                }`}
              >
                <SlidersHorizontal className="h-3.5 w-3.5" />
              </button>

              <button
                type="button"
                disabled={actionBusy}
                data-testid="hangup-call-btn"
                onClick={async () => {
                  setActionBusy(true);
                  try {
                    await onHangupCall(activeJoin.call.id);
                  } finally {
                    setActionBusy(false);
                  }
                }}
                className="inline-flex h-8 items-center gap-1 rounded-lg bg-red-600 px-2.5 text-[11px] font-bold text-white shadow-xs transition hover:bg-red-700 disabled:opacity-60"
              >
                <PhoneOff className="h-3.5 w-3.5 shrink-0" />
                <span>วางสาย</span>
              </button>
            </div>
          </div>

          {renderDeviceSelector(false)}
        </div>
      )}
    </div>
  );
}
