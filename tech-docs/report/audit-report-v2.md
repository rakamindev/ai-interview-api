# Implementation Audit Report v2

**Date:** 2026-04-03
**Scope:** Full cross-reference of tech docs (PRDs 01-04, overview, breadboard, slices, potential_bugs, gemini_live_limit solution) against current implementation.
**Method:** Line-by-line comparison of spec pseudocode and requirements against live code in `app/channels/`, `app/clients/gemini/`, `app/services/coverage/`, `app/workers/`.

---

## Summary

17 findings across 4 severity tiers. 3 critical issues that directly cause or contribute to active bugs. 5 high-severity reliability risks. 6 medium-severity improvised mechanisms not covered by any PRD. 3 low-severity deviations.

| Severity | Count | Actively causing bugs |
|----------|-------|-----------------------|
| Critical | 3     | Yes                   |
| High     | 5     | Latent / edge-case    |
| Medium   | 6     | Adds complexity       |
| Low      | 3     | No                    |

---

## Critical -- Directly Causing or Contributing to Bugs

### C1. Coverage cache race condition -- stale text injected with fresh digest

**Files:** `audio_websocket_middleware.rb:506-523` (background thread) vs `lines 173-178` (EM thread)

`refresh_coverage_cache` runs in `Thread.new` and writes to shared `ConnectionState` in two steps:

```ruby
# Background thread (refresh_coverage_cache)
state.last_coverage_digest = fingerprint       # step 1 (line 515)
state.cached_coverage_text = injector.injection_text  # step 2 (line 517)
```

The EM thread reads both in `on_input_transcription`:

```ruby
# EM thread (on_input_transcription callback)
current_digest = state.last_coverage_digest           # line 173
# ...
gemini_ref.inject_context(state.cached_coverage_text) # line 177
state.last_injected_digest = current_digest           # line 178
```

**Race scenario:**

1. Background thread sets `last_coverage_digest = X` (line 515)
2. Ruby GVL preempts to EM thread
3. EM thread reads `current_digest = X`, sees it differs from `last_injected_digest`
4. EM thread injects **OLD** `cached_coverage_text` (step 2 hasn't run yet)
5. EM thread sets `last_injected_digest = X`
6. Background thread resumes, sets `cached_coverage_text` to the correct text for digest X
7. Next turn: `last_coverage_digest == last_injected_digest == X` -- **fresh text is never injected**

**Impact:** A genuine coverage update is permanently skipped. The AI continues steering based on stale coverage data for the remainder of the session.

**Fix:** Move both assignments into an `EM.schedule` block so they execute atomically on the reactor thread:

```ruby
text = injector.injection_text
fp   = injector.coverage_fingerprint
EM.schedule do
  state.last_coverage_digest = fp
  state.cached_coverage_text = text
end
```

---

### C2. Time warning injection silently lost when silence pump is active

**Files:** `audio_websocket_middleware.rb:581-611` + `live_client.rb:166`

When `check_time_ceiling` fires:

```ruby
state.sent_time_warnings.add(:ceiling)              # line 582 -- marks as "sent"
gemini_client.inject_context('[TIME CONTROL...]')   # line 583 -- but may be DROPPED
```

`inject_context` (`live_client.rb:166`) returns early if `@silence_pumping` is true:

```ruby
if @model_emitting_audio || @silence_pumping
  # silently returns -- injection lost
  return
end
```

The `sent_time_warnings` Set already contains `:ceiling` (added at line 582 _before_ the inject call), so it will **never retry**. Same bug affects `:warn_60` and `:warn_120`.

**When this happens:** Candidate pauses for >500ms during a time warning window. The silence pump starts, time warning fires, injection is dropped.

**Impact:** AI never receives wrap-up signal. The session only ends via the hard 60s forced timeout, without the AI's natural wrap-up. The candidate experience degrades -- the session cuts off abruptly instead of concluding gracefully.

**Fix:** Either (a) check inject_context return value and retry, or (b) move the `sent_time_warnings.add` to after a successful injection:

```ruby
# Option A: make inject_context return success/failure
def inject_context(text)
  return false if @model_emitting_audio || @silence_pumping
  # ... send ...
  true
end

# Then in check_time_ceiling:
unless state.sent_time_warnings.include?(:ceiling)
  if gemini_client.inject_context('[TIME CONTROL...]')
    state.sent_time_warnings.add(:ceiling)
  end
end
```

---

### C3. `turnComplete: true` contradicts PRD spec

**PRD 04-reference.md Section 5** specifies:

```js
turnComplete: false // not a new conversation turn -- supplemental context
```

**Implementation** (`live_client.rb:177`) uses `turnComplete: true`.

**Why it was changed:** Comment at `live_client.rb:150-155` explains that `turnComplete: false` creates "dangling text turns" -- Gemini opens a text turn that its VAD can never close (VAD only closes audio turns). These accumulate and eventually block VAD entirely -- the root cause of the original inputTx stall.

**Problem with current approach:** `turnComplete: true` tells Gemini "the user is done talking," which can trigger a **new generation** on top of any current one. This is the root mechanism behind the dual-voice bug. Multiple guards exist to mitigate it (`!state.model_speaking` in middleware, `@model_emitting_audio || @silence_pumping` in LiveClient), but they add complexity and create their own issues (C2 above).

**Neither option is clean.** Potential alternative: queue injection text and flush it _inside_ the next real audio `realtimeInput` message -- Gemini sees real audio immediately after the text, so VAD treats the text as part of an ongoing user turn rather than a standalone prompt.

---

## High -- Reliability / Data Leakage Risks

### H1. Duplicate auto-end race between middleware and worker

Two independent code paths call `Sessions::EndHandler` for coverage-complete auto-end:

| Path | Location | Process | Closes Gemini? | Notifies browser? |
|------|----------|---------|----------------|-------------------|
| `check_coverage_complete` | `audio_websocket_middleware.rb:537-569` | EM thread (via Thread.new) | Yes | Yes |
| `check_session_end_conditions` | `coverage_analyzer_worker.rb:98-108` | Sidekiq worker | **No** | **No** |

`EndHandler` is idempotent (checks `ended?`), so the DB state is safe. But if the worker wins the race:

1. Session is marked `ended` in DB
2. Gemini WebSocket stays open -- audio keeps flowing
3. Browser never receives `session_ended` -- candidate stays in the session
4. The middleware's `check_coverage_complete` thread later finds `session.reload.ended?` -> exits -> **browser is never notified**

Additionally, the middleware's `ending_scheduled` flag is set via `EM.schedule` (line 551), which is **deferred** -- it won't execute until after the current EM callback returns. If two `on_output_transcription` callbacks arrive in the same reactor tick, both pass the `state.ending_scheduled` guard and spawn separate ending threads.

**Fix:** Remove `check_session_end_conditions` from the worker. Let the middleware own session lifecycle -- it's the only component with access to both the Gemini client and the browser WebSocket. Also set `state.ending_scheduled = true` synchronously on the EM thread _before_ spawning the Thread.

---

### H2. Proactive reconnect during AI speech leaves browser mic muted

**File:** `audio_websocket_middleware.rb:421`

In `initiate_proactive_reconnect`:

```ruby
state.model_speaking = false  # but NO speaker_changed:candidate sent to browser!
```

Same issue in `handle_go_away` (line 302):

```ruby
state.model_speaking = false  # also no browser notification
```

Compare with `handle_gemini_close` (lines 335-339) which correctly sends `speaker_changed:candidate` when the model was speaking during an unexpected close.

**Scenario:**
1. AI is mid-sentence, `state.model_speaking = true`
2. Proactive reconnect fires at 8.5 min mark
3. `state.model_speaking = false` -- but browser never gets `speaker_changed:candidate`
4. New Gemini connection established, `on_ready` fires -- no `speaker_changed` sent during reconnection path
5. Frontend still thinks AI is speaking -> **mic stays muted indefinitely**

The candidate must refresh the page to recover.

**Fix:** Send `speaker_changed:candidate` to the browser when resetting `model_speaking` during reconnection:

```ruby
if state.model_speaking
  state.model_speaking = false
  send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
end
```

---

### H3. `Thread.new { sleep() }` instead of EM timers

Three locations use `Thread.new { sleep(N) }` for delayed actions:

| Location | Sleep duration | Action after sleep |
|----------|---------------|-------------------|
| `schedule_graceful_end` (line 485) | 120s | End session |
| `check_time_ceiling` (line 588) | 60s | Force-close session |
| `check_coverage_complete` (line 544) | 5s | End session |

**Problems:**
- Threads cannot be cancelled if the session ends during the sleep -- the thread wakes up and acts on stale context (mitigated by `session.reload.ended?` checks, but wasteful)
- Orphan threads accumulate under high concurrency
- `schedule_graceful_end` holds a Ruby thread for **2 full minutes** doing nothing
- Each thread grabs an `ActiveRecord::Base.connection_pool.with_connection`, competing with actual work for the limited pool (typically 5-10 connections)

**Fix:** Replace with `EM.add_timer(N)` -- cancellable, zero-cost while waiting, runs on the reactor thread where `state` access is safe.

---

### H4. Redis subscription thread leak in `CoverageWebSocketMiddleware`

**File:** `coverage_websocket_middleware.rb`

Creates a `Thread.new` with blocking `redis.subscribe` on every assessor WebSocket connection. When the WebSocket closes (`on :close`), **nothing unsubscribes or kills the thread**.

The thread blocks indefinitely on Redis until the next message triggers a failed `ws.send`, which then calls `redis.unsubscribe`. If no more coverage updates arrive after the assessor disconnects, the thread hangs forever.

**Impact:** Orphan threads proportional to the number of assessor sessions that ended without a subsequent coverage update.

**Fix:** Track the `Thread` and `Redis` instance in connection state; call `redis.unsubscribe` in the `on :close` handler.

---

### H5. Redis connection created per publish (no pooling)

**File:** `coverage_analyzer_worker.rb:73`

```ruby
redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1'))
redis.publish("coverage:#{session.id}", payload)
# no redis.close -- connection leaks
```

A **new** Redis connection is created on every coverage update publication, with no `.close` call and no connection pooling. Same pattern in `Sessions::StartHandler` and `Sessions::EndHandler`.

**Impact:** Over a 45-minute interview with frequent turns (one publish per candidate turn), this leaks dozens of Redis connections per session.

**Fix:** Use a shared Redis instance or connection pool (`ConnectionPool`, `Sidekiq.redis`, or a Rails initializer).

---

## Medium -- Improvised Mechanisms (Not in Any PRD)

These mechanisms were built to work around Gemini Live's real-time audio behavior. None appear in any tech doc. Each adds complexity and potential failure mode surface area.

### M1. Silence pump subsystem

**~80 lines** in `live_client.rb:252-322`.

**Why it exists:** The browser stops sending PCM frames during silence, but Gemini's automatic VAD needs ~500ms-1s of continuous silence frames to detect end-of-speech. Without the pump, Gemini never fires `turnComplete` after a candidate finishes speaking.

**What it does:** After 500ms of no real audio (`SILENCE_PUMP_DELAY`), pumps synthetic zero-PCM frames at 30ms intervals (~59KB/s base64 over WebSocket) until real audio resumes, the model responds, or the connection closes.

**Complexity introduced:**
- `@silence_pumping` flag gates `inject_context` (see C2)
- `schedule_silence_pump` / `check_silence_pump_ready` / `start_silence_pump` / `stop_silence_pump` -- 4 tightly coupled methods
- Interacts with inactivity watchdog (M4), model_speaking gate (M3), turnComplete handling

**Documentation mismatch:** Comment at `live_client.rb:27` says `silenceDurationMs (1000ms)` but the actual config at line 406 says `silenceDurationMs: 500`. Total VAD latency is ~1.0s (500ms pump delay + 500ms silence duration), not ~1.5s as the comment states.

---

### M2. `GATE_OPEN_DELAY` (0.8s post-generation mic suppression)

**File:** `live_client.rb:15-17, 486-491`

**Why it exists:** `generationComplete` fires when all AI audio frames have been sent to the browser. But the frontend speaker may still be playing for 0.5-1.5s (WebSocket latency + audio buffer drain). If the audio gate opens immediately, the mic picks up the AI's speaker output -> Gemini hears its own voice -> echo loop.

**What it does:** Delays `on_model_turn_complete` callback by 0.8s after `generationComplete`.

**Trade-off:** Adds 0.8s of dead time after every AI turn where the candidate's speech is suppressed. Fast-responding candidates lose the beginning of their answer. PRD 04-reference.md says "Do NOT buffer audio -- stream in real-time."

---

### M3. `model_speaking` server-side audio gate

**File:** `audio_websocket_middleware.rb:65-73`

**Why it exists:** Prevents echo feedback where Gemini hears its own audio output through the browser mic, causing it to interrupt itself and loop.

**What it does:** Suppresses all candidate audio frames while `state.model_speaking = true`.

**Conflict with PRD:** PRD 04-reference.md Section 3 specifies `echoCancellation: true` on the browser mic stream. If browser echo cancellation works correctly, this server-side gate should be unnecessary. The gate masks potential frontend audio issues and creates the dependency chain that enables H2.

---

### M4. Inactivity watchdog (30s timeout)

**File:** `live_client.rb:331-348`

**Why it exists:** Detects when Gemini has locked up -- silence pump is active (candidate finished speaking) but Gemini produces no transcription or audio for 30s. Forces a reconnect.

**What it does:** Periodic 10s check. Only fires when `@silence_pumping` is true AND last activity >30s ago. `sessionResumptionUpdate` tokens intentionally don't count as activity.

**Concern:** Depends entirely on M1 (silence pump). If the pump has issues, the watchdog may fire inappropriately or fail to fire.

---

### M5. `advance_stale_partials` auto-promotion

**File:** `coverage_analyzer_worker.rb:86-96`

**Why it exists:** Once a skill's transcript turns slide out of the analyzer's 6-turn context window, Gemini Flash can never see those turns again and will never promote the skill.

**What it does:** Auto-promotes skills in `partial` state with `probe_count >= 4` that weren't touched in the current analysis run.

**Problem:** Bypasses N7's LLM judgment entirely. PRD 01-first-principles.md's confidence test says: _"Can I defend an L1-L5 rating with 2 specific transcript quotes?"_ That's an LLM judgment call, not a count threshold. A skill discussed 4 times with consistently vague answers shouldn't be marked `covered`.

**Possible alternative:** Expand the analyzer's context window for `partial` skills -- include their specific turns regardless of recency.

---

### M6. Full reconnect with transcript context restoration

**File:** `audio_websocket_middleware.rb:452-480`

**Spec says** (PRD 04-reference.md, Error Handling table): "Token validation error on reconnect -> Session cannot be resumed. Mark session failed, end_reason error."

**Implementation instead:** When resumption token fails, injects last 12 transcript turns as text context into a fresh Gemini session and continues the interview.

**Trade-off:** More resilient than spec requires, but Gemini has text-only context without audio history. The AI's behavior may be subtly different (it read the transcript but didn't hear the candidate's tone, pace, or hesitation).

---

## Low -- Minor Deviations

### L1. VAD sensitivity configuration values

`silenceDurationMs: 500`, `startOfSpeechSensitivity: 'START_SENSITIVITY_LOW'`, `endOfSpeechSensitivity: 'END_SENSITIVITY_HIGH'`

PRD specifies using `automaticActivityDetection` but doesn't prescribe specific sub-settings. These values interact with the silence pump: the 500ms `silenceDurationMs` equals `SILENCE_PUMP_DELAY`, meaning the pump starts exactly when Gemini would need to start counting silence -- any EM timer jitter means the VAD either fires too early or too late.

---

### L2. Audio ring buffer contradicts spec

**PRD 04-reference.md Section 3:** "Do NOT buffer audio -- stream in real-time to minimize latency"

**Implementation** (`audio_websocket_middleware.rb:64`): ALL audio is pushed into `AudioRingBuffer` before forwarding.

The buffer was added for reconnection replay per `gemini_live_limit.md`. Audio IS still streamed in real-time (buffer is additive, not blocking), so latency impact is minimal. But it contradicts the letter of the spec.

---

### L3. `check_coverage_complete` runs on every AI turn (unnecessary)

Called from `on_output_transcription` (line 218), spawning a `Thread.new` with a DB query after every AI response. Coverage only changes after N7 runs (triggered by **candidate** turns). Running this after AI turns is unnecessary -- the DB will always show the same state as the previous check.

This also contributes to the race condition described in H1. Removing this call would eliminate both the unnecessary DB queries and the race.

---

## Dependency Map

Several improvised mechanisms chain together. A bug in any one cascades.

```
Browser audio --> model_speaking gate (M3) --> Gemini Live
                                                  |
                                         silence pump (M1)
                                           |            |
                                inject_context      inactivity
                                guard (C2)          watchdog (M4)
                                   |                    |
                           coverage/time            force reconnect
                           injection lost               |
                                                  GATE_OPEN_DELAY (M2)
                                                        |
                                                  speaker_changed
                                                        |
                                                  mic muted state (H2)
```

If M3 holds the gate open too long -> M1 starts pumping -> C2 blocks injection -> coverage map stale -> AI doesn't steer properly -> interview quality degrades silently.

---

## Recommended Fix Priority

| Priority | Finding | Effort | Impact |
|----------|---------|--------|--------|
| 1 | C1 -- EM.schedule for coverage cache writes | Small | Eliminates data race, prevents permanently skipped updates |
| 2 | C2 -- Retry or queue time warning injections | Small | Prevents lost wrap-up signals |
| 3 | H1 -- Remove worker auto-end, set ending_scheduled synchronously | Small | Prevents silent session hang + duplicate ends |
| 4 | H2 -- Send speaker_changed on GoAway/proactive reconnect | Small | Prevents indefinitely muted mic |
| 5 | H3 -- Replace Thread.new+sleep with EM.add_timer | Small | Eliminates thread leaks, fixes state access safety |
| 6 | H4 -- Redis unsubscribe on WS close | Small | Prevents thread leak |
| 7 | H5 -- Pool Redis connections | Small | Prevents connection leak |
| 8 | C3 -- Solve turnComplete dilemma | Medium | Fixes dual-voice root cause |
| 9 | M5 -- Replace auto-promotion with expanded context | Medium | Improves coverage accuracy |
| 10 | L3 -- Remove check_coverage_complete from AI turns | Small | Reduces unnecessary DB queries |

---

## Appendix: Improvised vs Spec'd Feature Matrix

| Feature | In PRD? | In breadboard? | In solutions doc? | In potential_bugs? | Status |
|---------|---------|----------------|--------------------|--------------------|--------|
| Coverage injection (B6) | Yes | Yes | -- | Yes (fixes) | Implemented with deviations (C3) |
| Silence pump | No | No | No | Mentioned as factor | Improvised (M1) |
| GATE_OPEN_DELAY | No | No | No | No | Improvised (M2) |
| model_speaking gate | No | No | No | No | Improvised (M3) |
| Inactivity watchdog | No | No | No | No | Improvised (M4) |
| Stale partial auto-advance | No | No | No | No | Improvised (M5) |
| Full reconnect context restore | No | No | Partial | No | Improvised (M6) |
| Proactive reconnect | No | No | Yes | No | Implemented per solution doc |
| Audio ring buffer | No (contradicts) | No | Yes | No | Implemented per solution doc |
| Diff-based coverage dedup | No | No | No | Yes (fix) | Implemented per bug fix |
| Time warning dedup | No | No | No | Yes (fix) | Implemented per bug fix |
| Silence pump debounce | No | No | No | Yes (fix) | Implemented per bug fix |
