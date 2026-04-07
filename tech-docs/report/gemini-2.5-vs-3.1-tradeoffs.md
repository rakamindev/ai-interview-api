# Gemini Live 2.5 vs 3.1 — Tradeoffs Report

**Date:** 2026-04-07
**Status:** Both models tested in production. Each has critical tradeoffs.

---

## Summary

Neither model is perfect. Each solves the other's biggest problem while introducing its own.

| | Gemini 2.5 | Gemini 3.1 |
|---|---|---|
| **Biggest win** | Session resumption works | All protocol issues eliminated |
| **Biggest problem** | Protocol complexity (turnComplete dilemma) | Session resumption broken (>200 token prompt) |

---

## Gemini 2.5 (`gemini-2.5-flash-native-audio-preview-12-2025`)

### How it works

Coverage injection uses `clientContent` with `turnComplete: true`. This requires custom `realtimeInputConfig` (VAD sensitivity settings) and a silence pump to feed Gemini continuous audio frames for end-of-speech detection.

### What works

- **Session resumption** — GoAway fires at ~9 min with fresh token. Reconnection is seamless. Candidate doesn't notice.
- **Proactive reconnect** — fires before the 10-min limit as a safety net. Resumption with stored token works.
- **Audio ring buffer replay** — candidate audio during reconnect gap is captured and replayed.

### Main problem: context bloat → gradual slowdown → stuck

Every coverage injection sends a `clientContent` message with `turnComplete: true`. Gemini treats each one as a full user turn in conversation history. After 10+ candidate turns:

```
Conversation history in Gemini:
  Turn 1:  [candidate audio — real speech]
  Turn 2:  [coverage JSON — injected text]     ← extra turn
  Turn 3:  [AI audio response]
  Turn 4:  [candidate audio — real speech]
  Turn 5:  [coverage JSON — injected text]     ← extra turn
  Turn 6:  [AI audio response]
  ...
  Turn 20: [coverage JSON — injected text]     ← extra turn
  Turn 21: [candidate audio — real speech]
  ← Gemini slows down... context window filling with coverage text
  Turn 30: [coverage JSON — injected text]
  ← Gemini stops responding entirely (30s+ silence)
```

The `contextWindowCompression: { slidingWindow: {} }` should drop old turns, but coverage text turns accumulate faster than they're dropped. The result: Gemini gradually slows down and eventually stops responding.

### Secondary problems (all guarded but add complexity)

These are mitigated by guards, but the guards themselves cause issues:

- **1008 protocol violations** — `clientContent` interleaved with silence pump's `realtimeInput`. Guarded by `@silence_pumping` check. ✓ Fixed.
- **Empty generations** — coverage injection triggers empty AI response (0 audio). Guarded by `@model_emitting_audio`. ✓ Fixed, but adds latency.
- **Dual-voice risk** — AI responds to coverage text during generationComplete flush. Guarded by `!state.model_speaking`. ✓ Fixed.
- **Silent injection drops** — guards skip coverage when pump/model is active. Coverage is retried next turn, but may be stale.

**Total workaround code:** ~130 lines of guards, timers, and state tracking.

### Stuck state

After the context bloats sufficiently, Gemini stops processing audio entirely. The candidate speaks but gets no response for 30+ seconds until the inactivity watchdog forces a reconnect. The reconnect resets the context but the cycle repeats as coverage injections accumulate again.

---

## Gemini 3.1 (`gemini-3.1-flash-live-preview`)

### How it works

Coverage injection uses `realtimeInput.text` — same channel as audio. No `clientContent` mid-conversation (only for initial context seeding). No `turnComplete` flag needed. No custom VAD config needed (silence pump still required for end-of-speech detection).

### What works

- **No 1008 protocol violations** — `realtimeInput.text` + `realtimeInput.audio` don't conflict
- **No turnComplete dilemma** — no `clientContent` mid-conversation
- **No empty generations** — `realtimeInput.text` doesn't trigger AI responses
- **No guards needed** — coverage injection always goes through
- **No context bloat** — `realtimeInput.text` is supplemental, not a conversation turn
- **Faster response time** — adequate, often faster than 2.5
- **Better transcription accuracy** — significantly improved over 2.5
- **No stuck states observed** — no 30s dead silences

### Problems

#### 1. Session resumption broken (CRITICAL)

Confirmed bug: session resumption fails when `systemInstruction` exceeds ~200 tokens. Our system prompt is 500-1000+ tokens. The resumption handshake never completes — always times out after 5 seconds.

This affects:
- **Proactive reconnect** — always falls through to full reconnect
- **GoAway reconnect** — same, fresh token doesn't help (prompt length is the blocker)
- **Any reconnect** — all become full reconnects

Community reports confirm this is a known issue with the preview model.

**Impact:** Every ~10 minutes, the session fully reconnects. The AI loses all audio context and conversation history. We inject text history via `realtimeInput.text`, but the AI may re-ask the last question or respond to the injected history as if the candidate said it.

#### 2. Coverage data leaks into output transcription (LOW)

`realtimeInput.text` content echoes in `outputTranscription`. The candidate never hears it (audio is fine), but the coverage JSON appears in the transcript text. Mitigated with regex stripping before saving to DB.

#### 3. AI may respond to coverage injection text (MEDIUM)

In some timing scenarios, the AI treats `realtimeInput.text` coverage data as candidate speech and generates a response to it (e.g., `[SISTEM] messages telling the "candidate" to stop sending data`). The candidate doesn't hear this (text-only), but it creates extra entries in the transcript.

#### 4. Flaky audio on opening (LOW)

Occasionally, `trigger_opening` via `realtimeInput.text` produces a text-only response (0 audio chunks). The AI's greeting appears in the transcript but the candidate hears nothing. Restart fixes it. Preview model instability.

---

## Side-by-side Comparison

| Problem | 2.5 | 3.1 |
|---------|-----|-----|
| **Context bloat (main issue)** | Yes — each coverage injection = extra user turn, causes gradual slowdown | No — realtimeInput.text is supplemental, not a turn |
| **Stuck state (30s+ no response)** | Frequent (from context bloat) | Not observed |
| **1008 protocol violations** | Guarded (doesn't happen, but adds code) | No guards needed |
| **Empty generations** | Guarded (doesn't happen, but adds latency) | No |
| **Guard code complexity** | ~130 lines, 5 guards | 0 |
| **Coverage injection reliability** | Flaky (guards skip it, retries next turn) | Reliable (always goes through) |
| **Session resumption** | Works (GoAway + proactive) | Broken (>200 token bug) |
| **Reconnect experience** | Seamless (resumption) | Degraded (full reconnect, AI may re-ask) |
| **Transcription accuracy** | Variable | Significantly better |
| **Response latency** | ~1.5-2s (when not bloated) | Fast (adequate) |
| **Transcript leakage** | None | Coverage JSON in outputTranscription (stripped by regex) |
| **Audio on opening** | Reliable | Occasionally flaky (0 audio) |
| **Model stability** | Preview but mature | Preview, less stable |

---

## Recommendation

### Short-term: Use Gemini 3.1

The protocol issues on 2.5 (1008, stuck states, empty generations) actively degrade interview quality. The 3.1 model eliminates all of them. The resumption bug causes a degraded reconnect experience every ~10 minutes, but:
- Interviews under 10 minutes: zero reconnects
- 30-minute interviews: ~2-3 reconnects with AI re-asking (manageable)
- Transcript leakage: cleaned by regex stripping

### Long-term: Wait for 3.1 stable or resumption fix

Google is aware of the >200 token resumption bug (community reports exist). When fixed:
- Session resumption will work → seamless reconnects
- All 2.5 problems stay eliminated
- Best of both worlds

### Fallback: Gemini 2.5

If 3.1 instability (flaky audio opening, preview model) becomes unacceptable, switch back to 2.5 with all the guards. The `experiment/gemini-2.5-stable` branch preserves this setup.

### Nuclear option: Decoupled pipeline

If both models remain problematic, the decoupled STT + Gemini Flash (text) + TTS pipeline eliminates ALL Gemini Live issues. Blocked by GCP APIs not enabled. Architecture and code ready on `experiment/decoupled-audio-pipeline` branch.

---

## Branch Map

| Branch | Model | Status |
|--------|-------|--------|
| `main` | `gemini-3.1-flash-live-preview` | Active — current production |
| `experiment/gemini-2.5-stable` | `gemini-2.5-flash-native-audio-preview-12-2025` | Preserved — 2.5 with all guards |
| `experiment/decoupled-audio-pipeline` | N/A (STT + Flash + TTS) | Blocked — waiting for GCP APIs |
| `experiment/remove-vad-config` | 2.5 without VAD config | Archived — proved default VAD doesn't work |
