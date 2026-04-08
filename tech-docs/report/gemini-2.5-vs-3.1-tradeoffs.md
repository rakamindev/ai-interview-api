# Gemini Live 2.5 vs 3.1 — Tradeoffs Report

**Date:** 2026-04-08 (updated)
**Status:** Gemini 3.1 is the active model. Session resumption WORKS (fix applied).

---

## Summary

Gemini 3.1 eliminates all 2.5 protocol issues AND has working session resumption. The main remaining issues are cosmetic (transcript leakage) and minor (occasional flaky audio on opening).

| | Gemini 2.5 | Gemini 3.1 (current) |
|---|---|---|
| **Protocol issues** | Context bloat, 1008, empty generations | None |
| **Session resumption** | Works | Works (after fix) |
| **Transcription accuracy** | Variable | Significantly better |
| **Response latency** | ~1.5-2s (when not bloated) | Fast |
| **Guard code** | ~130 lines, 5 guards | 0 |

---

## Gemini 2.5 (`gemini-2.5-flash-native-audio-preview-12-2025`)

### How it works

Coverage injection uses `clientContent` with `turnComplete: true`. Requires custom `realtimeInputConfig` (VAD sensitivity settings) and a silence pump.

### Main problem: context bloat → gradual slowdown → stuck

Every coverage injection adds a full user turn to Gemini's conversation history. After 10+ turns, the history bloats with coverage JSON, Gemini slows down, and eventually stops responding (30s+ dead silence).

### Secondary problems (all guarded)

- **1008 protocol violations** — `clientContent` interleaved with silence pump. Guarded by `@silence_pumping`.
- **Empty generations** — coverage triggers 0-audio responses. Guarded by `@model_emitting_audio`.
- **Dual-voice risk** — AI responds to coverage during generationComplete flush. Guarded by `!state.model_speaking`.
- **Silent injection drops** — guards skip coverage, retried next turn.

**Total workaround code:** ~130 lines of guards, timers, and state tracking.

---

## Gemini 3.1 (`gemini-3.1-flash-live-preview`)

### How it works

Coverage injection uses `realtimeInput.text` — same channel as audio. No `clientContent` mid-conversation. No `turnComplete` flag needed. Silence pump still required for end-of-speech detection.

### What works

- **No protocol issues** — `realtimeInput.text` + `realtimeInput.audio` don't conflict
- **No context bloat** — `realtimeInput.text` is supplemental, not a conversation turn
- **No guards needed** — coverage injection always goes through
- **Session resumption** — works seamlessly (see fix below)
- **Proactive reconnect** — fires at ~8.5 min, deferred until after current turn
- **Better transcription accuracy** — significantly improved over 2.5
- **Faster response time** — consistently fast

### Session Resumption Fix

**The original problem:** our implementation waited for a "resumption confirmation" message from Gemini after `setupComplete`. This confirmation doesn't exist — session resumption is not a handshake.

**The fix:** activate the connection immediately on `setupComplete`, whether it's a fresh or resumed session. The session is already resumed at that point.

**Key implementation details:**
1. Always include `sessionResumption: {}` in the setup message (enables token generation)
2. Store `newHandle` from `sessionResumptionUpdate` as tokens arrive during conversation
3. On reconnect, pass the stored handle as `sessionResumption: { handle: stored_token }`
4. On `setupComplete`, call `activate_connection!` immediately — no waiting, no timer, no nudge
5. Audio ring buffer replays any audio captured during the brief reconnection gap

**What we removed:** the entire `@awaiting_session_resumption` branch, 5-second timeout timer, nudge logic, `resumption_failed` flag, and `restore_conversation_context` text history injection.

### Proactive Reconnect (Smart Timing)

The proactive reconnect fires at ~8.5 minutes (before Gemini's 10-min connection limit). To avoid cutting off the candidate mid-speech:

1. Timer fires → checks if conversation is active
2. If AI is speaking or candidate hasn't finished → sets `reconnect_after_turn = true`
3. After AI's response finishes (`on_model_turn_complete`) → initiates reconnect
4. Reconnect happens in the gap between AI response and candidate's next speech
5. No audio is lost — candidate's full speech is processed before reconnection

Without this, the old approach would supersede the Gemini client mid-speech, killing the silence pump before VAD could fire, causing the candidate's audio to be lost.

### Remaining Issues (cosmetic)

#### 1. Coverage data leaks into output transcription (LOW)

`realtimeInput.text` content echoes in `outputTranscription`. The candidate never hears it (audio is fine). Mitigated with regex stripping before saving to DB. The regex catches all JSON variants including partial fragments.

#### 2. Occasional flaky audio on opening (LOW)

Sometimes `trigger_opening` via `realtimeInput.text` produces 0 audio chunks. The greeting appears in transcript but candidate hears nothing. On empty generation, the gate opens immediately so the session isn't stuck. Restart fixes it. Preview model instability.

---

## Side-by-side Comparison

| Problem | 2.5 | 3.1 |
|---------|-----|-----|
| **Context bloat** | Yes — each injection = extra turn, causes slowdown | No — realtimeInput.text is supplemental |
| **Stuck state (30s+ no response)** | Frequent (from context bloat) | Not observed |
| **Guard code complexity** | ~130 lines, 5 guards | 0 |
| **Coverage injection reliability** | Flaky (guards skip it) | Reliable (always goes through) |
| **Session resumption** | Works | Works (after fix) |
| **Reconnect experience** | Seamless | Seamless (with smart timing) |
| **Transcription accuracy** | Variable | Significantly better |
| **Response latency** | ~1.5-2s (when not bloated) | Fast |
| **Transcript leakage** | None | Coverage JSON stripped by regex |
| **Audio on opening** | Reliable | Occasionally flaky (preview) |

---

## Audio Format Changes (3.1 Breaking)

Gemini 3.1 deprecated `mediaChunks`. Audio sent via `audio` field:

```json
// Before (2.5):
{ "realtimeInput": { "mediaChunks": [{ "mimeType": "audio/pcm;rate=16000", "data": "..." }] } }

// After (3.1):
{ "realtimeInput": { "audio": { "mimeType": "audio/pcm;rate=16000", "data": "..." } } }
```

---

## What Was Tested and Didn't Work

| Experiment | Result |
|------------|--------|
| 2.5 + no custom VAD config + silence pump | Default VAD doesn't detect speech at all |
| 2.5 + no custom VAD config + no silence pump | 20-40s delay, no end-of-speech detection |
| 3.1 + `turnComplete: false` for coverage | 1008 protocol violation (open text turn + realtimeInput audio) |
| 3.1 + coverage injection in `on_model_turn_complete` | Dual response (AI responds to coverage as user input) |
| 3.1 + coverage injection with first audio frame | Dual response (same issue, different timing) |
| 3.1 + `clientContent` for history seeding | `trigger_opening` stops working (historyConfig blocks it) |
| 3.1 + compact system prompt (110 tokens) | Resumption still fails (not a token count issue) |
| 3.1 + minimal system prompt (10 tokens) | Resumption still fails |
| 3.1 + nudge with silence frame after setup | Resumption still fails |
| 3.1 + nudge with `clientContent` after setup | 1007 invalid argument |
| 3.1 + close old connection before new | Resumption still fails |
| Decoupled pipeline (STT + Flash + TTS) | Blocked — GCP APIs not enabled |

**Root cause of all resumption failures:** our code waited for a `sessionResumptionUpdate` confirmation after setup. This event never comes because resumption is not a handshake — the session is already resumed on `setupComplete`.

---

## Recommendation

**Use Gemini 3.1** — it has no protocol issues, working session resumption, better transcription, and no guard code. The only remaining issues are cosmetic (transcript regex stripping).

**Keep 2.5 branch as fallback** (`experiment/gemini-2.5-stable`) in case 3.1 preview becomes too unstable.

---

## Branch Map

| Branch | Model | Status |
|--------|-------|--------|
| `main` | `gemini-3.1-flash-live-preview` | Active — production |
| `experiment/gemini-3.1-live` | Same | Development branch (merge into main) |
| `experiment/gemini-2.5-stable` | `gemini-2.5-flash-native-audio-preview-12-2025` | Fallback — 2.5 with all guards |
| `experiment/decoupled-audio-pipeline` | STT + Flash + TTS | Blocked — waiting for GCP APIs |
| `experiment/remove-vad-config` | 2.5 without VAD | Archived |
