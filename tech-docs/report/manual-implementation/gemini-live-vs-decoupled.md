# Gemini Live vs Decoupled Pipeline — Comparison

**Date:** 2026-04-05
**Context:** Deciding between native Gemini Live and a decoupled STT + LLM + TTS pipeline for the AI interview system.

---

## How Each Approach Works

### Gemini Live (Native Audio-to-Audio)

A single multimodal model that natively understands and generates audio. No intermediate text representation.

```
Browser ──audio──► Gemini Live ──audio──► Browser
                   (one model, one connection)
                   
                   Internally:
                   Audio → [Neural audio understanding] → [Response generation] → [Neural audio synthesis]
                   All happening in one forward pass, no serialization to text
```

### Decoupled Pipeline (STT + LLM + TTS)

Three separate services chained together, with text as the intermediate representation.

```
Browser ──audio──► STT ──text──► LLM ──text──► TTS ──audio──► Browser
                   (3 services, 3 API calls)
                   
                   Each step is independent:
                   Audio → [Speech recognition] → text → [Text generation] → text → [Speech synthesis] → Audio
```

---

## Latency

| | Gemini Live | Decoupled (REST) | Decoupled (gRPC STT) |
|---|---|---|---|
| STT / Audio understanding | ~0s (native) | 0.5-1s (after speech) | ~0s (during speech) |
| Response generation | ~0.5-1s | 1-2s | 1-2s |
| Audio synthesis | ~0s (native, streaming) | 0.5-1s | 0.5-1s |
| **Total after candidate stops** | **~0.5-1.5s** | **2-3.5s** | **1.5-2.5s** |
| **When stuck/failed** | **30s+ (then reconnect)** | **N/A** | **N/A** |

### Why Gemini Live is faster

1. **No STT step** — processes audio natively as a modality. Like how a bilingual person understands both languages without translating in their head.

2. **Streaming output** — starts sending audio frames while still generating the rest of the sentence. First word arrives ~0.5s after generation starts. The decoupled pipeline waits for the full text before starting TTS.

3. **One network hop** — audio to one server, audio back from the same server. The decoupled pipeline makes 3 separate API calls sequentially.

### Why the decoupled pipeline's latency is acceptable

- **Consistent** — 2-3.5s every time. No variance. No 30s dead silences.
- **Predictable** — if it's going to take 3s, it takes 3s. Not 1.5s sometimes and 35s other times.
- **Improvable** — gRPC streaming STT saves ~1s. Streaming TTS (Phase 3) could save another ~0.5s. Total: ~1.5-2s, approaching Gemini Live's best case.

---

## Reliability

| | Gemini Live | Decoupled |
|---|---|---|
| Connection drops | Frequent (1008, 1000, inactivity) | Rare (stateless HTTP) |
| "Stuck" state (no response) | Common (~30s dead silence) | Never (each call has timeout) |
| Session resumption | Fragile (token expiry, full reconnect) | Not needed (stateless) |
| Recovery from failure | Reconnect cascade, may lose context | Retry individual API call |
| Uptime dependency | One service (Gemini Live) | Three services (STT, LLM, TTS) |

### Gemini Live reliability issues (experienced)

- **1008 protocol violations** — `clientContent` interleaved with `realtimeInput` during silence pump
- **VAD death** — Gemini stops processing audio after 30s, requires reconnect
- **Session resumption failures** — token expires during stuck state, forces full reconnect, AI starts over
- **Empty generations** — Gemini responds to coverage injection with 0 audio, then gets confused
- **Context loss on full reconnect** — text history injection doesn't restore audio context, AI re-asks opening question

### Decoupled reliability advantages

- **Stateless turns** — each turn is an independent HTTP request. No persistent connection to break.
- **Independent failure** — if STT fails, retry STT. If LLM fails, retry LLM. No cascading failures.
- **No session to resume** — conversation history lives in the DB. Every turn loads it fresh.
- **No silence pump** — STT handles silence detection natively. No synthetic audio frames, no protocol interleaving.

---

## Audio Quality

| | Gemini Live | Decoupled |
|---|---|---|
| AI voice naturalness | Very natural (neural synthesis) | Depends on TTS provider (Google TTS Chirp3-HD is good) |
| Voice consistency | Same voice throughout | Same voice throughout |
| Emotional tone | Can vary tone based on context | Flat — TTS doesn't understand conversation context |
| Language support | Good Indonesian support | Good Indonesian support (Google STT/TTS) |
| Transcription accuracy | Variable (sometimes misses words) | Likely better (dedicated STT model) |

### Gemini Live audio advantages

- **Context-aware prosody** — the AI knows it's asking a follow-up question vs wrapping up, and adjusts tone accordingly.
- **Natural hesitation** — can produce "hmm" and "interesting..." naturally as part of generation.
- **Interruption handling** — can detect and respond to candidate interruptions mid-sentence.

### Decoupled audio advantages

- **Better transcription** — dedicated STT models (Google Cloud STT V2) are typically more accurate than Gemini Live's built-in transcription, especially for non-English languages.
- **Voice selection** — can choose from any Google TTS voice. Not limited to Gemini Live's voice options.
- **Controllable** — can adjust speed, pitch, emphasis per assessment.

---

## Conversation Quality

| | Gemini Live | Decoupled |
|---|---|---|
| Model | gemini-2.5-flash-native-audio (preview) | gemini-2.5-flash (stable) |
| Audio understanding | Hears tone, hesitation, emphasis | Only sees transcribed text |
| Context window | Managed by Gemini (opaque) | Managed by us (last 20 turns from DB) |
| Coverage injection | clientContent protocol (complex, error-prone) | Inline in text prompt (trivial) |
| Multi-turn coherence | Good (when not stuck) | Good (explicit history in prompt) |

### Gemini Live conversation advantages

- **Hears the candidate** — understands hesitation ("um... well...") as uncertainty, long pauses as thinking. Can probe differently based on how confident the candidate sounds.
- **Natural turn-taking** — VAD handles interruptions and overlapping speech.
- **Audio context** — remembers how previous answers sounded, not just what was said.

### Decoupled conversation advantages

- **Stable model** — `gemini-2.5-flash` (stable) vs `gemini-2.5-flash-native-audio-preview` (preview, no SLA).
- **Full control over context** — we decide exactly what goes into the prompt. No opaque context window management.
- **Coverage injection is trivial** — just part of the text prompt. No protocol issues, no guards, no turnComplete dilemma.
- **Debuggable** — can log the exact prompt sent to Gemini Flash. With Gemini Live, we can't see what the model "heard" or how it interpreted the audio.

---

## Development & Maintenance

| | Gemini Live | Decoupled |
|---|---|---|
| Lines of code (middleware) | ~716 lines | ~310 lines |
| Guard/workaround code | ~130 lines | 0 lines |
| Components to understand | Silence pump, VAD config, turnComplete, gates, timers, session resumption, proactive reconnect | STT call, LLM call, TTS call, silence timer |
| Debugging difficulty | High (opaque audio pipeline, async events, EM timers) | Low (sequential HTTP calls, simple logs) |
| Protocol knowledge needed | Gemini Live WebSocket protocol, realtimeInput, clientContent, turnComplete semantics | REST APIs (standard) |
| Dependency on Google internals | High (VAD behavior, turn management, undocumented limits) | Low (standard APIs with documentation) |

---

## Cost

| | Gemini Live | Decoupled |
|---|---|---|
| Billing model | Per-connection-minute | Per-API-call |
| 30-min interview | ~30 connection-minutes | ~60 STT calls + ~60 LLM calls + ~60 TTS calls |
| Idle time cost | Billed (connection alive even during silence) | Not billed (no call during silence) |
| Stuck state cost | Billed (30s of dead connection before reconnect) | N/A |
| Reconnection cost | Double-billed during overlap (old + new connection) | N/A |

Exact pricing depends on usage patterns, but the decoupled pipeline may be **cheaper** because it doesn't bill for idle time or stuck states.

---

## Feature Comparison

| Feature | Gemini Live | Decoupled |
|---------|------------|-----------|
| Real-time partial transcription | Yes (inputTranscription events) | REST: No / gRPC: Yes |
| Candidate interrupts AI | Yes (native) | No (turn-based) |
| AI interrupts candidate | Yes (but usually unwanted) | No |
| Voice activity detection | Built-in (but needs silence pump hack) | STT built-in (native, no hack) |
| Session continuity (reconnect) | Via resumption token (fragile) | Not needed (stateless) |
| Coverage map injection | Complex (clientContent protocol) | Trivial (inline in prompt) |
| Time warning injection | Complex (same protocol issues) | Trivial (inline in prompt) |
| Multi-language | Configured at setup | Configured per STT/TTS client |
| Audio echo prevention | GATE_OPEN_DELAY + model_speaking gate | Sequential flow (AI finishes → mic opens) |

---

## When to Use Which

### Use Gemini Live when:
- Sub-second response latency is critical
- The candidate might interrupt the AI mid-sentence
- Audio nuance (tone, hesitation) is important for assessment
- Google releases a stable Gemini Live model with reliable VAD
- The turnComplete / silence pump issues are resolved by Google

### Use Decoupled Pipeline when:
- Reliability is more important than latency
- 2-3s response time is acceptable
- You need full control over the conversation flow
- You want debuggable, maintainable code
- Coverage injection must work reliably every turn
- The interview should never "get stuck"

---

## Recommendation

**Short-term: Decoupled Pipeline.** The reliability issues with Gemini Live (30s stuck states, 1008 errors, reconnect cascades, context loss) are actively degrading interview quality. A consistent 2-3s response time is better than 1.5s sometimes and 35s other times.

**Long-term: Re-evaluate Gemini Live** when Google releases:
1. A stable (non-preview) native audio model on Vertex AI
2. Improved default VAD that handles browser silence gaps
3. Better `turnComplete: false` support for supplemental context injection

The decoupled architecture is designed to be replaceable — if Gemini Live matures, swapping back is straightforward since the middleware interface (WebSocket messages to browser) stays the same.
