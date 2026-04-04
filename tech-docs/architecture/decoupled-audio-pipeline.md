# Decoupled Audio Pipeline — Architecture

**Date:** 2026-04-05
**Branch:** `experiment/decoupled-audio-pipeline`
**Status:** Experimental

---

## Why

Gemini Live's integrated audio pipeline has fundamental issues that we cannot fix from our side:

1. **VAD requires silence pump** — browser stops sending audio on silence, but Gemini's VAD needs continuous frames. Our silence pump workaround causes protocol violations (1008) and timing issues.
2. **`turnComplete` dilemma** — coverage injection as `clientContent` conflicts with `realtimeInput` audio. `true` causes empty generations and context bloat. `false` blocks audio processing entirely.
3. **Opaque turn management** — Gemini's internal state becomes "stuck" (ignores audio for 30s+), forcing reconnections that lose conversation context.
4. **Session resumption fragile** — tokens expire during stuck states, causing full reconnects where the AI starts over.

All of these trace back to one root cause: we don't control the audio pipeline. By decoupling STT, text generation, and TTS into separate services, we gain full control.

---

## Architecture

### Current (Gemini Live)

```
Browser ──audio──► Backend ──realtimeInput──► Gemini Live (audio↔audio)
       ◄──audio──          ◄──serverContent──
```

One opaque service handles: VAD, STT, conversation, TTS. We can't control or debug any of it.

### Proposed (Decoupled)

```
Browser ──PCM audio──► Backend
                         │
                         ├──► [1] STT Service (audio → text)
                         │         Google Cloud Speech-to-Text V2
                         │         Built-in endpoint detection (VAD)
                         │
                         ├──► [2] Gemini Flash (text → text)
                         │         Already working via HttpClient + Vertex AI
                         │         Coverage map = part of the prompt (no protocol issues)
                         │
                         └──► [3] TTS Service (text → audio)
                                   Google Cloud TTS
                                   Stream audio chunks back to browser
                         │
       ◄──PCM audio───── Backend
```

### Turn Flow

```
1. Candidate speaks
   → Browser sends PCM audio frames via WebSocket (same as now)
   → Backend forwards to STT streaming session

2. Candidate stops speaking
   → STT's built-in VAD detects end-of-speech
   → STT returns final transcription
   → No silence pump needed — STT handles silence detection natively

3. Backend builds prompt
   → Conversation history (last N turns)
   → Coverage map (inline in prompt — no clientContent/turnComplete issues)
   → System prompt
   → Candidate's transcription
   → Sends to Gemini Flash via HttpClient

4. Gemini Flash responds
   → Returns AI's text response
   → Backend saves to transcript

5. Text-to-speech
   → Backend sends AI text to TTS
   → TTS returns audio (PCM or MP3)
   → Backend streams audio chunks to browser via WebSocket

6. Browser plays audio
   → Same playback mechanism as now
```

---

## Components

### 1. STT Client (`app/clients/stt/google_streaming_client.rb`)

Wraps Google Cloud Speech-to-Text V2 streaming recognition.

**Responsibilities:**
- Open a streaming recognition session
- Accept PCM audio frames from the middleware
- Stream partial transcriptions back (for real-time display)
- Detect end-of-speech (VAD) and return final transcription
- Handle session lifecycle (open/close/reconnect)

**Key config:**
- Language: `id-ID` (Indonesian) — configurable per assessment
- Encoding: LINEAR16, 16kHz (matches browser audio)
- VAD: enabled (automatic endpoint detection)
- Interim results: enabled (for real-time transcription display)

**Interface:**
```ruby
client = STT::GoogleStreamingClient.new(
  language: 'id-ID',
  on_partial: ->(text) { },       # interim transcription
  on_final: ->(text) { },         # final transcription (VAD detected end)
  on_error: ->(error) { }
)
client.start
client.send_audio(pcm_bytes)      # called per frame
client.stop
```

### 2. Conversation Manager (`app/services/conversation/manager.rb`)

Replaces Gemini Live's conversation management. Stateless — builds prompt from DB on each turn.

**Responsibilities:**
- Build the full prompt for each AI turn (system prompt + history + coverage + candidate text)
- Call Gemini Flash via HttpClient
- Parse response
- No turn management complexity — it's just request/response

**Interface:**
```ruby
manager = Conversation::Manager.new(session:)
response_text = manager.generate_response(candidate_text:)
# Returns: "That's interesting. Can you tell me more about..."
```

**Prompt structure:**
```
[System prompt — same as now]

[Conversation history — last N turns from DB]
[Interviewer]: How do you handle...
[Candidate]: In my experience...
[Interviewer]: Interesting. What about...
[Candidate]: {candidate_text}

[Coverage map — inline, no protocol issues]
{"skills": [...], "priority_next": "..."}

Respond as the interviewer. Keep it short (1-3 sentences).
```

Coverage injection is now just part of the text prompt. No `clientContent`, no `turnComplete`, no guards needed.

### 3. TTS Client (`app/clients/tts/google_client.rb`)

Wraps Google Cloud Text-to-Speech.

**Responsibilities:**
- Accept AI response text
- Return audio bytes (LINEAR16 PCM, 24kHz to match current browser playback)
- Voice selection (configurable per assessment)

**Interface:**
```ruby
client = TTS::GoogleClient.new(
  language: 'id-ID',
  voice: 'id-ID-Chirp3-HD-Charon'  # or configurable
)
audio_bytes = client.synthesize("That's interesting. Can you tell me more about...")
# Returns: raw PCM bytes
```

### 4. Updated AudioWebSocketMiddleware

The middleware orchestration simplifies dramatically.

**What stays:**
- Browser WebSocket handling (same `on :open`, `on :message`, `on :close`)
- Audio frame forwarding (now to STT instead of Gemini)
- `speaker_changed` events to browser
- Transcript saving
- Coverage analysis triggering
- Time ceiling checks
- Session lifecycle

**What goes away:**
- Silence pump (all of it — ~80 lines)
- `inject_context` and all its guards (~30 lines)
- `model_emitting_audio` flag and tracking
- `GATE_OPEN_DELAY` timer
- `turnComplete` handling
- GoAway / session resumption
- Proactive reconnection (no 10-min limit)
- Inactivity watchdog (STT has its own timeout)
- `model_speaking` server-side audio gate (replaced by simple flag)

**Estimated reduction:** ~300 lines removed from middleware + ~400 lines removed from LiveClient.

---

## What Stays Unchanged

- **Frontend** — same audio capture, same WebSocket, same playback. Only change: no `reconnecting` state needed (no Gemini session to reconnect).
- **Coverage analysis** — same CoverageAnalyzerWorker, same StateEngine, same MapInjector.
- **Portfolio generation** — same PortfolioGeneratorWorker, same Gemini Pro.
- **Session management** — same Session model, same EndHandler.
- **Assessment config** — same system prompt compiler.

---

## Latency Comparison

| Step | Gemini Live | Decoupled |
|------|-------------|-----------|
| VAD detection | ~1s (silence pump + silenceDurationMs) | ~0.5-1s (STT built-in) |
| Transcription | Included in above | Included in above (streaming) |
| AI thinking | ~0.5-1s | ~1-2s (Gemini Flash HTTP) |
| Audio synthesis | Included in above | ~0.5-1s (TTS) |
| **Total** | **~1.5-2s** (when working) | **~2-3.5s** |
| **When stuck** | **30s+** (then full reconnect) | **N/A** (never stucks) |

The decoupled pipeline is ~1s slower on average, but eliminates the 30s+ stuck states entirely.

---

## GCP Services Required

All use the existing Vertex AI service account (`config/vertex_ai_credentials.json`):

| Service | Gem | Pricing |
|---------|-----|---------|
| Cloud Speech-to-Text V2 | `google-cloud-speech-v2` | ~$0.006/15s of audio |
| Cloud Text-to-Speech | `google-cloud-text_to_speech` | ~$0.000016/character |
| Gemini Flash (text) | Already implemented | Already paying |

---

## Implementation Order

1. **Add gems** — `google-cloud-speech-v2`, `google-cloud-text_to_speech`
2. **STT client** — streaming audio → text with VAD
3. **TTS client** — text → audio
4. **Conversation Manager** — prompt builder + Gemini Flash call
5. **Update middleware** — replace Gemini Live orchestration with STT → Manager → TTS pipeline
6. **Test end-to-end** — run an interview session

---

## Risks

1. **Latency feel** — 2-3.5s might feel sluggish compared to Gemini Live's 1.5-2s. Mitigated by streaming TTS (start playing audio before full synthesis is done).
2. **Indonesian TTS quality** — Google Cloud TTS Indonesian voices may sound robotic. Need to test voice options.
3. **STT accuracy** — Google Cloud STT V2 Indonesian accuracy may vary. But it's likely better than Gemini Live's built-in transcription (which was already a reported issue).
4. **Cost** — Three separate API calls per turn instead of one. But Gemini Live also charges per-connection-minute, so cost might be similar.
5. **gRPC complexity** — Google Cloud STT streaming uses gRPC, which may be complex to integrate with EventMachine. Fallback: use REST-based recognition (slightly higher latency but simpler).
