# Decoupled Audio Pipeline — Implementation Report

**Date:** 2026-04-05
**Branch:** `experiment/decoupled-audio-pipeline`
**Status:** Blocked — waiting for GCP admin to enable APIs

---

## Summary

Replaced Gemini Live's integrated audio pipeline (bidirectional WebSocket) with a decoupled architecture: separate STT, text generation (Gemini Flash), and TTS services. This eliminates all Gemini Live protocol issues (VAD, silence pump, turnComplete dilemma, 1008 errors, session resumption failures).

---

## GCP APIs Required (Not Yet Enabled)

| API | Purpose | Enable URL |
|-----|---------|------------|
| Cloud Speech-to-Text | Candidate audio → text | `https://console.cloud.google.com/apis/api/speech.googleapis.com/overview?project=rakamin-poc` |
| Cloud Text-to-Speech | AI response text → audio | `https://console.cloud.google.com/apis/api/texttospeech.googleapis.com/overview?project=rakamin-poc` |

Both use the existing Vertex AI service account (`config/vertex_ai_credentials.json`). No new credentials needed.

---

## New Files

| File | Purpose |
|------|---------|
| `app/clients/stt/google_client.rb` | Google Cloud Speech-to-Text V2 REST client. Buffers PCM audio frames, transcribes on demand when silence is detected. |
| `app/clients/tts/google_client.rb` | Google Cloud Text-to-Speech REST client. Converts AI response text to LINEAR16 PCM audio (24kHz). |
| `app/services/conversation/manager.rb` | Replaces Gemini Live's conversation handling. Builds multi-turn prompts (system prompt + history + coverage map) and calls Gemini Flash via Vertex AI. |
| `app/clients/gemini/vertex_auth.rb` | Google Cloud OAuth2 token helper. Shared by STT, TTS, and Gemini Flash clients. |
| `tech-docs/architecture/decoupled-audio-pipeline.md` | Full architecture document with flow diagrams, latency comparison, and implementation plan. |

## Modified Files

| File | Change |
|------|--------|
| `Gemfile` | Added `googleauth`, `google-cloud-speech-v2`, `google-cloud-text_to_speech` |
| `app/channels/audio_websocket_middleware.rb` | Complete rewrite — 716 lines → 310 lines. Replaced Gemini Live orchestration with STT → Gemini Flash → TTS pipeline. |

---

## What Is No Longer Used

These components exist in the codebase but are NOT used by the new middleware on this branch:

| Component | File | Why Removed |
|-----------|------|-------------|
| `Gemini::LiveClient` | `app/clients/gemini/live_client.rb` | Entire Gemini Live WebSocket client. Replaced by STT + Gemini Flash (HTTP) + TTS. |
| Silence pump | `live_client.rb` lines 250-320 | No longer needed. STT has built-in endpoint detection. Silence detection is now a simple 700ms timer in the middleware. |
| `inject_context` / `turnComplete` | `live_client.rb` lines 160-185 | Coverage map is now inline in the Gemini Flash text prompt. No protocol issues. |
| `realtimeInputConfig` / custom VAD | `live_client.rb` send_setup | STT service handles VAD natively. |
| GoAway / session resumption | `live_client.rb` + middleware | No persistent WebSocket session to resume. Each turn is a stateless HTTP request. |
| Proactive reconnection | middleware lines 405-450 | No 10-minute connection limit. Gemini Flash is HTTP request/response. |
| Audio ring buffer / replay | middleware + `audio_ring_buffer.rb` | No reconnection gaps to replay audio across. |
| Inactivity watchdog | `live_client.rb` lines 324-348 | No persistent connection that can get "stuck." |
| `@model_emitting_audio` flag | `live_client.rb` | No streaming audio from Gemini. TTS returns complete audio. |
| `GATE_OPEN_DELAY` (0.8s timer) | `live_client.rb` line 15 | No echo risk. TTS audio is sent, then mic opens. Sequential, not overlapping. |
| `@model_interrupted` tracking | `live_client.rb` | No interruption handling needed. Turn-taking is explicit (candidate speaks → AI responds). |
| Coverage injection guards | middleware lines 167-182 | Coverage is part of the text prompt to Gemini Flash. No interleaving issues. |
| `full_reconnect_pending` / `restore_conversation_context` | middleware lines 470-525 | No session to reconnect. Conversation history is loaded from DB on every turn. |
| Resumption token persistence | middleware lines 242-260 | No resumption tokens. |

---

## New Audio Flow

```
BEFORE (Gemini Live):
  Browser ──realtimeInput──► Gemini Live (audio↔audio, bidirectional WebSocket)
         ◄──serverContent──   - Opaque VAD, STT, conversation, TTS
                              - 10-min connection limit
                              - Session resumption required
                              - Silence pump required
                              - turnComplete protocol issues

AFTER (Decoupled):
  Browser ──PCM audio──► Middleware
                           │
                           ├──[1] Buffer audio, detect 700ms silence
                           │
                           ├──[2] Google STT (REST) → candidate text
                           │
                           ├──[3] Gemini Flash (HTTP) → AI response text
                           │      (coverage map inline in prompt)
                           │
                           └──[4] Google TTS (REST) → AI audio
                           │
  Browser ◄──PCM audio─── Middleware
```

---

## Turn Flow (Step by Step)

1. **Candidate speaks** — browser sends PCM frames via WebSocket (unchanged from before)
2. **Silence detected** — middleware detects 700ms of no audio frames, triggers processing
3. **STT** — buffered audio sent to Google Cloud Speech-to-Text → returns transcribed text
4. **Save transcript** — candidate text saved to DB, sent to browser for display
5. **Coverage analysis** — `CoverageAnalyzerWorker` enqueued (async, same as before)
6. **AI generation** — `Conversation::Manager` builds prompt with:
   - System prompt (from assessment)
   - Last 20 transcript turns (from DB)
   - Coverage map (inline JSON, from `Coverage::MapInjector`)
   - Candidate's latest text
   - Sends to Gemini Flash via Vertex AI HTTP API
7. **TTS** — AI response text sent to Google Cloud TTS → returns PCM audio
8. **Audio playback** — PCM audio chunked and sent to browser via WebSocket
9. **Mic opens** — `speaker_changed:candidate` sent, candidate can speak again

---

## What Stays Unchanged

| Component | Why |
|-----------|-----|
| Frontend audio capture (`useAudioCapture.ts`) | Same PCM frames, same WebSocket |
| Frontend audio playback (`useAudioPlayback.ts`) | Same PCM format (24kHz LINEAR16) |
| Frontend WebSocket hook (`useAudioWebSocket.ts`) | Same message types (`speaker_changed`, `transcription`, `session_ended`) |
| Coverage analysis (`CoverageAnalyzerWorker`, `StateEngine`, `MapInjector`) | Same async pipeline, same Gemini Flash model |
| Portfolio generation (`PortfolioGeneratorWorker`) | Runs after session ends, unchanged |
| Session management (`Session`, `EndHandler`, `StartHandler`) | Same lifecycle |
| Assessment config (`SystemPromptCompiler`) | Same system prompt, now sent as `systemInstruction` to Gemini Flash |
| Authentication (`authenticate_and_load`) | Same token/JWT validation |
| Time ceiling (`check_time_ceiling`) | Simplified — no more `inject_context`, just checks elapsed time |

---

## Latency Comparison

| Step | Gemini Live | Decoupled |
|------|-------------|-----------|
| Silence detection | ~1s (silence pump + VAD) | ~0.7s (simple timer) |
| Transcription | Included above | ~0.5-1s (STT REST) |
| AI response | ~0.5-1s | ~1-2s (Gemini Flash HTTP) |
| Audio synthesis | Included above | ~0.5-1s (TTS REST) |
| **Total (normal)** | **~1.5-2s** | **~2.5-4s** |
| **Total (when stuck)** | **30s+ (then reconnect cascade)** | **N/A (never stucks)** |

The decoupled pipeline is ~1-2s slower on average, but eliminates the 30s+ stuck states entirely. No more reconnect cascades, no more "AI asks opening question again," no more protocol violations.

---

## Configuration

| ENV Variable | Purpose | Already Set? |
|---|---|---|
| `VERTEX_AI_CREDENTIALS` | Path to service account JSON | Yes |
| `VERTEX_AI_PROJECT_ID` | GCP project ID | Yes |
| `VERTEX_AI_LOCATION` | GCP region | Yes (`us-central1`) |
| `GEMINI_FLASH_MODEL` | Model for conversation | Yes (`gemini-2.5-flash`) |

Language and voice are configured per assessment via the `language` field on the Assessment model.

---

## Next Steps (After APIs Are Enabled)

1. Enable Cloud Speech-to-Text and Cloud Text-to-Speech APIs on `rakamin-poc` project
2. Test STT client: `STT::GoogleClient.new(language: 'id-ID').transcribe` with sample audio
3. Test TTS client: `TTS::GoogleClient.new(language: 'id-ID').synthesize("Halo")` 
4. Run a full end-to-end interview session
5. Evaluate latency and audio quality
6. If acceptable, merge to main and remove Gemini Live client code

---

## Risks

1. **Latency** — 2.5-4s total might feel sluggish. Mitigated by: streaming TTS in future (start playing audio before full synthesis). Can also upgrade STT to gRPC streaming for lower latency.
2. **Indonesian TTS quality** — Google Cloud TTS Indonesian voices may sound robotic. Need to test available voices and pick the most natural one.
3. **STT accuracy** — Google Cloud STT V2 Indonesian accuracy needs testing. Likely better than Gemini Live's built-in transcription (which was already a reported issue).
4. **Cost** — Three API calls per turn. But Gemini Live charges per-connection-minute, so cost may be similar or lower.
