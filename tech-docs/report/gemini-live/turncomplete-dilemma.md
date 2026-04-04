# The `turnComplete` Dilemma

**Date:** 2026-04-03
**Context:** Audit finding C3 — deferred from implementation because neither option is clean.
**File:** `app/clients/gemini/live_client.rb` line 179

---

## What is this?

Every time we inject hidden context into Gemini (coverage maps, time warnings), we send a `clientContent` message. That message has a `turnComplete` flag that tells Gemini whether the user is "done talking":

```ruby
message = {
  clientContent: {
    turns: [{ role: 'user', parts: [{ text: text }] }],
    turnComplete: true   # <-- this flag
  }
}
```

The PRD spec says `turnComplete: false`. We use `turnComplete: true`. Both options break things — but the root cause may be neither.

---

## Root cause hypothesis: `realtimeInputConfig` was never in the spec

The PRD simulation (02-simulation.md, lines 52-59) shows the exact setup message:

```json
{"setup": {
  "model": "gemini-2.0-flash-live",
  "system_instruction": "<compiled system prompt from N2>",
  "generation_config": {"response_modalities": ["AUDIO"],
    "speech_config": { "voice_config": { "prebuilt_voice_config": { "voice_name": "Puck" } } }
  },
  "input_audio_transcription": {},
  "output_audio_transcription": {},
  "context_window_compression": { "sliding_window": {} },
  "session_resumption": {}
}}
```

**There is no `realtimeInputConfig`. No `automaticActivityDetection`. No sensitivity settings. No `silenceDurationMs`.**

A search across all tech docs (PRDs 01-04, overview, breadboard, slices, simulation, solutions) confirms: **`realtimeInputConfig` and `automaticActivityDetection` appear nowhere in any spec document.** The entire VAD configuration was improvised during implementation.

Our implementation added:

```ruby
realtimeInputConfig: {
  automaticActivityDetection: {
    startOfSpeechSensitivity: 'START_SENSITIVITY_LOW',
    endOfSpeechSensitivity: 'END_SENSITIVITY_HIGH',
    silenceDurationMs: 500
  }
}
```

### Why this matters

When Gemini Live receives no explicit `realtimeInputConfig`, it uses its **default turn management**. The spec author wrote `turnComplete: false` because in the default configuration, it likely works — Gemini treats `clientContent` with `turnComplete: false` as supplemental context without creating a dangling turn.

When we added explicit `automaticActivityDetection` with aggressive sensitivity settings, we changed how Gemini manages turns. The custom VAD may treat `clientContent` text turns differently — creating standalone turns that VAD can't close, which is the dangling turn problem.

### The cascade

This one improvised config change triggered the entire complexity chain:

```
1. Added realtimeInputConfig (not in spec)
   ↓
2. Custom VAD changed how Gemini handles text turns
   ↓
3. turnComplete: false started causing dangling turns (VAD death)
   ↓
4. Switched to turnComplete: true to fix it
   ↓
5. turnComplete: true introduced dual-voice risk
   ↓
6. Added @model_emitting_audio guard → injection silently dropped
7. Added @silence_pumping guard → time warnings lost (C2)
8. Added !state.model_speaking guard → coverage delayed
9. Added GATE_OPEN_DELAY (0.8s) → candidate speech clipped
   ↓
10. Silence pump was needed because custom VAD needs continuous
    silence frames that the browser doesn't send
    ↓
11. Silence pump interleaves realtimeInput with clientContent
    → 1008 protocol violations
    ↓
12. @silence_pumping guard blocks inject_context during pump
    → time warnings permanently lost (pre-C2 fix)
```

**Every improvised mechanism (M1-M4 in the audit report) and every guard traces back to step 1.**

---

## How Gemini's turn system works

Gemini Live maintains a conversation as alternating turns:

```
[user audio turn] → [model audio turn] → [user audio turn] → ...
```

Three message types can create user turns:

| Message type | What it is | How the turn closes |
|---|---|---|
| `realtimeInput` (audio) | PCM audio frames from the mic | Gemini's VAD detects silence and fires `turnComplete` |
| `clientContent` with `turnComplete: true` | Text message, self-closing | Immediately closed — Gemini is free to respond |
| `clientContent` with `turnComplete: false` | Text message, left open | **Never closes** unless followed by `turnComplete: true` or more `realtimeInput` that VAD can close |

The critical detail: **VAD only closes audio turns, not text turns.** A `turnComplete: false` text turn stays open forever unless we explicitly close it. But this behavior may be specific to the custom VAD configuration — **default Gemini may handle this differently.**

---

## Option A: `turnComplete: false` with custom VAD (current problem)

### What happens

1. We send coverage map as `clientContent` with `turnComplete: false`
2. Custom VAD treats it as a standalone open text turn
3. VAD can't close it (it only closes audio turns)
4. The text turn stays open permanently

### The fatal problem: dangling turns

Each injection creates a permanent open turn:

```
Turn 1: [user audio - closed by VAD]         ← normal
Turn 2: [model audio - closed by generation]  ← normal
Turn 3: [user text - NEVER CLOSED]            ← coverage injection #1
Turn 4: [user audio - closed by VAD]          ← normal
Turn 5: [model audio - closed by generation]  ← normal
Turn 6: [user text - NEVER CLOSED]            ← coverage injection #2
...
```

After ~10-15 injections (~5 minutes of interview), these block VAD entirely. No more `inputTranscription` or `turnComplete` events fire. The interview is dead.

---

## Option B: `turnComplete: true` with custom VAD (current implementation)

### What happens

1. We send coverage map as `clientContent` with `turnComplete: true`
2. Gemini treats it as a complete user message and may respond
3. Multiple guards prevent the response from causing dual-voice

### Problems requiring guards

**Problem 1 — Dual-voice:** Gemini generates a response to the coverage text while also responding to the candidate's actual speech. Two overlapping audio streams break the frontend.

**Problem 2 — 1008 protocol violation:** Silence pump sends `realtimeInput` frames while coverage injection sends `clientContent` with `turnComplete: true`. Gemini sees "user is sending audio" AND "user is done" simultaneously.

**Problem 3 — Injection blocked:** Guards drop injections during model audio or silence pump. Time warnings can be permanently lost.

### Guard inventory (all exist because of this option)

| Guard | Location | Prevents | Side effect |
|---|---|---|---|
| `!state.model_speaking` | middleware:174 | Dual-voice during generationComplete flush | Coverage delayed until next turn |
| `@model_emitting_audio` | live_client:168 | Second generation during AI audio | Injection silently dropped |
| `@silence_pumping` | live_client:168 | 1008 protocol error | Injection silently dropped |
| `GATE_OPEN_DELAY` (0.8s) | live_client:15 | Echo loop after generation | 0.8s candidate speech suppressed |
| `@model_interrupted` | live_client:527 | Stale turnComplete after interruption | State tracking complexity |

---

## Option F: Remove `realtimeInputConfig`, use `turnComplete: false` (the hypothesis)

**The spec's original design.** Remove the improvised VAD config and revert to `turnComplete: false`.

### What we expect

1. No `realtimeInputConfig` → Gemini uses default turn management
2. Default turn management handles `clientContent` with `turnComplete: false` as supplemental context (not a standalone turn)
3. No dangling turns → no VAD death
4. No `turnComplete: true` → no dual-voice risk → no guards needed
5. Default VAD handles silence detection → no silence pump needed

### What we can remove if this works

| Component | Lines | Why it existed |
|---|---|---|
| Silence pump (`SILENCE_PUMP_*`, `start/stop/schedule_silence_pump`) | ~80 lines in live_client.rb | Custom VAD needed continuous silence frames; browser stops sending after 50ms |
| `@silence_pumping` guard in `inject_context` | 3 lines in live_client.rb | Silence pump interleaved with clientContent caused 1008 |
| `@model_emitting_audio` guard in `inject_context` | 3 lines in live_client.rb | turnComplete: true triggered second generation |
| `!state.model_speaking` guard on coverage injection | 4 lines in middleware | turnComplete: true during generationComplete flush caused dual-voice |
| `GATE_OPEN_DELAY` (0.8s timer) | 10 lines in live_client.rb | Echo prevention made necessary by complex turn interactions |
| `@model_interrupted` tracking | 5 lines in live_client.rb | Stale turnComplete events from interrupted turns |
| Inactivity watchdog | 20 lines in live_client.rb | Detected Gemini lockups caused by turn confusion |
| `model_speaking` server-side audio gate | 8 lines in middleware | Echo prevention (may still be needed — test) |

**Total: ~130 lines of guard/workaround code potentially removable.**

### What we must keep regardless

- Audio ring buffer (for reconnection replay — separate concern)
- Proactive reconnection (for 10-min limit — separate concern)
- Coverage fingerprint dedup (for context window bloat — separate concern)
- Time warning dedup (for redundant injections — separate concern)
- EM.schedule for cache writes (thread safety — separate concern)

### Risks

1. **Default VAD may be too slow.** Without custom sensitivity settings, end-of-speech detection might take 2-3 seconds instead of ~1 second. The interview would feel sluggish.

2. **Default VAD may be too aggressive.** It might fire during natural pauses (200-400ms), cutting off the candidate mid-thought.

3. **Browser silence gap may still be a problem.** Even with default VAD, the browser stops sending audio during silence. If default Gemini VAD also needs continuous frames to detect silence, the same silence pump problem reappears.

4. **turnComplete: false may still dangle with default config.** Our hypothesis could be wrong — maybe it's a Gemini API behavior that's independent of VAD config.

### How to test

The hypothesis can be validated or invalidated in a single test session:

1. Remove `realtimeInputConfig` from setup message
2. Revert `turnComplete: true` to `turnComplete: false` in `inject_context`
3. Disable silence pump (it shouldn't be needed)
4. Run a 15+ minute interview
5. Observe:
   - Does `inputTranscription` keep firing after 10+ coverage injections? (dangling turns test)
   - Does Gemini detect end-of-speech without the silence pump? (default VAD test)
   - What's the latency from candidate stopping to AI responding? (VAD speed test)
   - Do time warnings get injected successfully? (no guards needed test)
   - Any 1008 protocol errors? (interleaving test)

---

## Implementation plan for hypothesis branch

### Phase 1: Minimal viable test (validate/invalidate hypothesis)

**Goal:** Answer one question — does `turnComplete: false` work without `realtimeInputConfig`?

**Changes:**

1. **Remove `realtimeInputConfig` from setup message** (`live_client.rb` send_setup)
   - Delete the entire `realtimeInputConfig` block (lines 405-410)

2. **Revert `turnComplete: true` to `false`** (`live_client.rb` inject_context)
   - Change line 179: `turnComplete: true` → `turnComplete: false`

3. **Disable silence pump** (`live_client.rb`)
   - Make `schedule_silence_pump` a no-op (return immediately)
   - Don't delete the code yet — we may need it back

4. **Remove `@silence_pumping` from inject_context guard** (`live_client.rb`)
   - Change guard from `@model_emitting_audio || @silence_pumping` to just `@model_emitting_audio`
   - Keep `@model_emitting_audio` as a safety net for Phase 1

5. **No other changes.** Keep all middleware guards, keep GATE_OPEN_DELAY, keep everything else.
   This isolates the test to just the VAD + turnComplete interaction.

**Test checklist:**
- [ ] 15-minute interview completes without inputTx stall
- [ ] Coverage injections visible in Gemini logs (not dangling)
- [ ] End-of-speech detected without silence pump
- [ ] Time warnings injected successfully during candidate silence
- [ ] No 1008 protocol errors
- [ ] AI response latency acceptable (< 3 seconds from candidate stop)

### Phase 2: Remove guards (only if Phase 1 passes)

**Goal:** Strip out the complexity that `turnComplete: true` required.

**Changes:**

1. Remove `!state.model_speaking` guard from coverage injection (middleware)
2. Remove `@model_emitting_audio` guard from `inject_context` (live_client)
3. Remove `GATE_OPEN_DELAY` timer — fire `on_model_turn_complete` immediately on `generationComplete`
4. Remove `@model_interrupted` tracking
5. Remove inactivity watchdog (or reduce to a simpler "no response in 60s" check)
6. Delete silence pump code entirely (schedule, start, stop, check_ready, constants, frame)

**Test checklist:**
- [ ] Full 30-minute interview with no issues
- [ ] Coverage injection works during AI speech (no dual-voice)
- [ ] Time warnings work during silence
- [ ] No echo loops without GATE_OPEN_DELAY
- [ ] Reconnection still works (separate concern, should be unaffected)

### Phase 3: Tune if needed (only if Phase 1 passes but VAD is too slow/fast)

If default VAD latency is unacceptable:

- **Option 3a:** Re-add `realtimeInputConfig` with ONLY `silenceDurationMs` tuning, no sensitivity overrides. Test if `turnComplete: false` still works with mild config.
- **Option 3b:** Add `silenceDurationMs` only if default is too slow (> 2s). Start without it.
- **Option 3c:** If silence pump IS needed even with default VAD (browser silence gap), re-add it but now `turnComplete: false` means the `@silence_pumping` guard isn't needed — no 1008 risk.

---

## Appendix: Current injection points

Every place that calls `inject_context` and would be affected:

| Caller | File | Line | What it injects | When |
|---|---|---|---|---|
| Coverage injection | `audio_websocket_middleware.rb` | 177 | `[COVERAGE MAP — DO NOT SPEAK THIS] {...}` | After candidate turnComplete, before AI responds |
| Time warning (120s) | `audio_websocket_middleware.rb` | 646 | `[TIME CONTROL — DO NOT SPEAK THIS] { "time_warning": true }` | When remaining <= 120s |
| Time warning (60s) | `audio_websocket_middleware.rb` | 642 | `[TIME CONTROL — DO NOT SPEAK THIS] { "wrap_up": true }` | When remaining <= 60s |
| Time ceiling | `audio_websocket_middleware.rb` | 616 | `[TIME CONTROL — DO NOT SPEAK THIS] { "time_warning": true, "wrap_up": true }` | When remaining <= 0 |
| Context restore | `audio_websocket_middleware.rb` | 471 | `[SESSION RESUME] ... Conversation so far: ...` | After full reconnect (no resumption token) |
| Trigger opening | `live_client.rb` | 193 | Empty text (prompts AI to speak first) | On initial connection |

## Appendix: Files changed per phase

### Phase 1 (minimal test)

| File | Changes |
|---|---|
| `app/clients/gemini/live_client.rb` | Remove `realtimeInputConfig` from setup; change `turnComplete: true` → `false`; no-op silence pump; relax inject_context guard |

### Phase 2 (remove guards)

| File | Changes |
|---|---|
| `app/clients/gemini/live_client.rb` | Delete silence pump (~80 lines); delete inactivity watchdog (~20 lines); delete GATE_OPEN_DELAY timer (~10 lines); delete @model_interrupted tracking (~5 lines); simplify inject_context (remove all guards) |
| `app/channels/audio_websocket_middleware.rb` | Remove `!state.model_speaking` guard on coverage injection; remove `model_speaking` audio gate (lines 65-73); simplify on_model_turn_complete (no delay) |
