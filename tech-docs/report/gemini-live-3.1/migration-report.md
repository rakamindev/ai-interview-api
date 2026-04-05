# Gemini 3.1 Flash Live — Migration Report

**Date:** 2026-04-05
**Branch:** `experiment/gemini-3.1-live`
**Model:** `gemini-3.1-flash-live-preview`
**Status:** Experimental — validated, prompt tuning in progress

---

## Result

VAD response time: fast, adequate
Transcription accuracy: significantly improved
Coverage injection via `realtimeInput.text`: works, no 1008
Silence pump with `realtimeInput.audio`: works, no interleaving conflict

**Remaining issues:** AI reads coverage JSON aloud (prompt fix applied, testing), AI wraps up too early (prompt fix applied, testing).

---

## What Changed

### Model

| | Before (2.5) | After (3.1) |
|---|---|---|
| Model ID | `gemini-2.5-flash-native-audio-preview-12-2025` | `gemini-3.1-flash-live-preview` |
| ENV var | `GEMINI_LIVE_MODEL` | Same |

### Audio Format (Breaking Change)

Gemini 3.1 deprecated `mediaChunks`. Audio now sent via `audio` field.

**Before:**
```json
{
  "realtimeInput": {
    "mediaChunks": [{ "mimeType": "audio/pcm;rate=16000", "data": "base64..." }]
  }
}
```

**After:**
```json
{
  "realtimeInput": {
    "audio": { "mimeType": "audio/pcm;rate=16000", "data": "base64..." }
  }
}
```

**File:** `live_client.rb` — `send_audio` and silence pump `start_silence_pump`

### Coverage Injection (Major Change)

Coverage map now injected via `realtimeInput.text` instead of `clientContent`.

**Before:**
```json
{
  "clientContent": {
    "turns": [{ "role": "user", "parts": [{ "text": "coverage JSON" }] }],
    "turnComplete": true
  }
}
```

**After:**
```json
{
  "realtimeInput": {
    "text": "coverage JSON"
  }
}
```

**Why:** In Gemini 3.1, `clientContent` is only for initial context seeding. Mid-conversation text goes via `realtimeInput.text` — same channel as audio, so no interleaving conflicts.

**File:** `live_client.rb` — `inject_context`

### Trigger Opening (Changed)

Opening prompt now sent via `realtimeInput.text` instead of `clientContent`.

**Before:**
```json
{
  "clientContent": {
    "turns": [{ "role": "user", "parts": [{ "text": "" }] }],
    "turnComplete": true
  }
}
```

**After:**
```json
{
  "realtimeInput": {
    "text": "[Start the interview. Greet the candidate and ask your first question.]"
  }
}
```

**File:** `live_client.rb` — `trigger_opening`

### VAD Config (Removed)

Custom `realtimeInputConfig` removed from setup. Gemini 3.1 uses its own defaults.

**Removed:**
```ruby
realtimeInputConfig: {
  automaticActivityDetection: {
    startOfSpeechSensitivity: 'START_SENSITIVITY_LOW',
    endOfSpeechSensitivity: 'END_SENSITIVITY_HIGH',
    silenceDurationMs: 500
  }
}
```

**Note:** Silence pump is still needed — Gemini 3.1's default VAD still doesn't detect end-of-speech when the browser stops sending audio frames.

**File:** `live_client.rb` — `send_setup`

### System Prompt (Updated)

Added explicit instructions for handling `realtimeInput.text` metadata:
- NEVER read coverage JSON aloud
- NEVER acknowledge receiving metadata messages
- Silently use information to guide probing
- Do NOT wrap up while any skill is still uncovered

**File:** `system_prompt_compiler.rb` — `coverage_guidance_section`

### Coverage Map Prefix (Updated)

**Before:** `[COVERAGE MAP — DO NOT SPEAK THIS]`
**After:** `[COVERAGE MAP — INTERNAL SYSTEM DATA — DO NOT READ ALOUD — DO NOT ACKNOWLEDGE]`

**File:** `coverage/map_injector.rb` — `injection_text`

---

## What We Eliminated

| Problem | Root Cause | Status in 3.1 |
|---------|-----------|----------------|
| **1008 protocol violation** | `clientContent` interleaved with `realtimeInput` during silence pump | **ELIMINATED** — coverage injection now uses `realtimeInput.text`, same channel as audio |
| **turnComplete dilemma** | `true` = empty generations + context bloat; `false` = dangling turns + VAD death | **ELIMINATED** — no `clientContent` mid-conversation, no `turnComplete` flag needed |
| **Empty generations (0 audio)** | Coverage injection with `turnComplete: true` triggered empty AI responses | **ELIMINATED** — `realtimeInput.text` doesn't trigger responses |
| **Coverage injection guards** | 5 guards needed to prevent dual-voice, 1008, echo | **ELIMINATED** — `realtimeInput.text` "can be sent continuously without interruption" |
| **Context bloat from coverage** | Each `clientContent` injection added a user turn to conversation history | **ELIMINATED** — `realtimeInput.text` is supplemental, not a conversation turn |
| **`@model_emitting_audio` guard** | Blocked injection during AI speech to prevent second response | **ELIMINATED** — no guard needed |
| **`@silence_pumping` guard** | Blocked injection during silence pump to prevent 1008 | **ELIMINATED** — same channel, no conflict |
| **`!state.model_speaking` guard** | Blocked injection during generationComplete flush | **ELIMINATED** — no dual-voice risk |
| **GATE_OPEN_DELAY (0.8s)** | Delayed mic opening to prevent echo from coverage response | **ELIMINATED** — no coverage response to echo |
| **Coverage injection return value bug** | Middleware didn't check if injection was skipped | **ELIMINATED** — injection never skipped (no guards) |
| **Custom `realtimeInputConfig`** | Improvised VAD config that caused the entire cascade | **ELIMINATED** — using 3.1 defaults |

## What We Still Need

| Component | Status | Why |
|-----------|--------|-----|
| **Silence pump** | Still needed | Browser stops sending audio during silence. Gemini 3.1 default VAD still needs continuous frames. |
| **Session resumption** | Still needed | 10-min connection limit still applies. GoAway + resumption token still required. |
| **Proactive reconnect** | Still needed | Same 10-min limit. |
| **Inactivity watchdog** | Still needed | Safety net for stuck states (though less likely with 3.1). |
| **Audio ring buffer** | Still needed | For reconnection replay. |
| **Coverage fingerprint dedup** | Still needed | Prevent redundant injections. |
| **Time ceiling** | Still needed | Session time limit enforcement. |

## What's No Longer Used

These exist in the code but are NOT needed on Gemini 3.1:

| Component | File:Line | Why Obsolete |
|-----------|-----------|-------------|
| `@silence_pumping` guard in `inject_context` | `live_client.rb` | `realtimeInput.text` doesn't conflict with `realtimeInput.audio` |
| `@model_emitting_audio` guard in `inject_context` | `live_client.rb` | Text can be sent during model generation |
| `GATE_OPEN_DELAY` timer | `live_client.rb` | No coverage-triggered empty generations |
| `turn_complete:` parameter on `inject_context` | `live_client.rb` | No `turnComplete` flag used anymore |
| `clientContent` for mid-conversation | `live_client.rb` | Only for initial context seeding in 3.1 |
| `!state.model_speaking` guard on coverage | `middleware.rb` | Injection never triggers a response |
| Empty generation skip logic | `live_client.rb` | No empty generations from coverage |

---

## Performance Comparison

| Metric | 2.5 (main branch) | 3.1 (this branch) |
|--------|--------------------|--------------------|
| Response latency | ~1.5-2s (when working) | Fast (comparable or better) |
| Stuck state (30s+) | Frequent | Not observed yet |
| Transcription accuracy | Variable, sometimes misses words | Significantly improved |
| 1008 errors | Occasional (coverage + silence pump) | None |
| Empty generations | Occasional (coverage injection) | None |
| Coverage injection reliability | Flaky (guards skip it) | 100% (no guards) |

---

## Files Changed

| File | Change |
|------|--------|
| `app/clients/gemini/live_client.rb` | Model default, `send_audio` format, `inject_context` → `realtimeInput.text`, `trigger_opening` → `realtimeInput.text`, removed `realtimeInputConfig`, silence pump re-enabled with new audio format |
| `app/services/assessments/system_prompt_compiler.rb` | Coverage guidance: metadata handling instructions, wrap-up rules |
| `app/services/coverage/map_injector.rb` | Coverage prefix updated |
| `config/application.yml` | `GEMINI_LIVE_MODEL` updated |

---

## Risks

1. **Preview model** — `gemini-3.1-flash-live-preview` is not stable. No SLA. Google may change behavior.
2. **AI reads metadata aloud** — `realtimeInput.text` is treated as user input. Prompt instructions must prevent the AI from reading it. Initial fix applied, needs testing.
3. **AI wraps up too early** — prompt compliance for coverage-based probing needs validation.
4. **AI Studio only** — no Vertex AI availability confirmed. Same API key auth as before.
5. **Silence pump still required** — default VAD doesn't handle browser silence gaps. The pump now uses `realtimeInput.audio` format (not `mediaChunks`).

---

## Next Steps

1. Test prompt fix — verify AI stops reading coverage JSON aloud
2. Test wrap-up rules — verify AI keeps probing until all skills covered
3. Run full 30-minute interview session
4. If stable, consider merging to main (with feature flag for model selection)
5. Monitor for Vertex AI availability of 3.1 model
