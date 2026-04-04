# Backlog

Items deferred from active development. Each entry describes the problem, why it was deferred, and what needs to happen before it can be picked up.

---

## 1. Coverage Auto-End Session

**Problem:** When all configured skills reach `covered`, the session should end automatically. Current implementation was disabled because:
- The auto-end only checks configured skills (`is_discovered: false`). Discovered skills are ignored — the session would end while the AI is still probing discovered skills.
- Timing issues: the AI gets cut off mid-sentence because coverage state updates lag behind the AI's response generation (1-turn stale).
- The wrap-up injection + kill flow has a two-phase timing problem that needs careful sequencing.

**What needs to happen:**
- Add a configuration for discovered skill probing limits (e.g., max 3 questions per discovered skill).
- Either include discovered skills in the "all covered" check, or cap discovered skill probing so the interview converges naturally.
- Implement the two-phase wrap-up: wait for AI to finish current turn → inject wrap-up → mute candidate → AI delivers closing → kill Gemini.
- The system prompt wrap-up instruction was already updated to not ask follow-up questions ("Thank you for your time — you'll hear back from the team soon.").

**Current state:** `check_coverage_complete` removed from `audio_websocket_middleware.rb`. Session ends only via manual candidate/assessor action or time ceiling.

---

## 2. Vertex AI Migration for Gemini Live

**Problem:** The Gemini Live WebSocket client still uses Google AI Studio (`generativelanguage.googleapis.com`) with an API key. AI Studio models are preview/experimental with no SLA. Vertex AI offers stable model versions.

**Blocked by:** The GCP project (`rakamin-poc`) is not allowlisted for audio output on Vertex AI. The error is: `"You are not allowlisted to request audio output."` Text generation (HttpClient) works fine on Vertex AI, but audio streaming (LiveClient) does not.

**What was done:**
- `googleauth` gem added to Gemfile.
- `Gemini::VertexAuth` helper created (`app/clients/gemini/vertex_auth.rb`) — generates OAuth2 tokens from service account credentials.
- `Gemini::HttpClient` migrated to Vertex AI (working, tested).
- `Gemini::LiveClient` migration code exists on `experiment/remove-vad-config` branch but can't be tested until audio output is enabled.
- Credentials placeholder at `config/vertex_ai_credentials.json`, env vars in `application.yml`.

**What needs to happen:**
- Get audio output allowlisted for the GCP project (requires GCP admin access or Google Cloud support request).
- Once enabled, test the LiveClient on Vertex AI with the stable Gemini Live model.
- If audio output works but transcription quality is bad, fall back to using a separate Flash model for transcription instead of Gemini Live's built-in `inputAudioTranscription`.

---

## 3. Transcription Quality Fallback

**Problem:** Gemini Live's built-in `inputAudioTranscription` can produce low-quality transcripts (missing words, wrong language detection, hallucinated text). This affects coverage analysis accuracy and portfolio generation quality.

**What needs to happen:**
- If Vertex AI stable model doesn't improve transcription quality, implement a separate transcription pipeline:
  - Capture candidate audio chunks in a buffer.
  - After each candidate turn (silence pump triggers VAD), send the buffered audio to a dedicated Flash model for transcription.
  - Use the Flash transcription for coverage analysis and transcript storage, while still using Gemini Live's transcription for real-time display.
- This adds latency to coverage analysis but improves accuracy.

---

## 4. `turnComplete` Dilemma (Simplification)

**Problem:** The current `turnComplete: true` approach for `inject_context` works but requires ~130 lines of guard code (silence pump guards, model_emitting guards, GATE_OPEN_DELAY, etc.). The spec originally intended `turnComplete: false` with no custom VAD config.

**What was tested:** The `experiment/remove-vad-config` branch tested removing `realtimeInputConfig` + reverting to `turnComplete: false` + disabling silence pump. Result: Gemini's default VAD doesn't detect end-of-speech because the browser stops sending audio during silence (20-40s delay before response).

**What needs to happen:**
- When Vertex AI stable model is available, re-test. Stable models may have improved default VAD that handles browser silence gaps.
- If default VAD works, all guard code can be removed (~130 lines), massively simplifying the codebase.
- If not, the current `turnComplete: true` + guards approach stays. It works, it's just complex.

**Reference:** `tech-docs/report/turncomplete-dilemma.md` has the full analysis.

---

## 5. Empty Generation → Gemini Stuck (Edge Case)

**Problem:** Gemini occasionally sends an empty `generationComplete` (0 audio chunks) followed by an empty `turnComplete` (0 chars transcribed), then stops processing candidate audio entirely. The candidate speaks but gets no response until the inactivity watchdog triggers a reconnect after 30 seconds.

**Current mitigation:** The inactivity watchdog detects 30s of no response during silence pumping and forces a reconnect. This works but leaves the candidate in 30s of dead silence.

**What could be done:**
- Add a shorter timeout specifically for the "empty generation" case (e.g., 10s after an empty generationComplete with no subsequent AI response → reconnect). Normal conversation keeps the 30s timeout.
- Reducing the global inactivity timeout risks false positives on long candidate answers (20+ second monologues).

**Why deferred:** Edge case — happens rarely and the existing 30s watchdog handles it. The coverage injection retry fix (checking `inject_context` return value) may reduce frequency since stale coverage state could be a contributing factor.
