Here's my analysis. The progressive inputTx slowdown has a clear root cause, with a couple of aggravating factors:

Root cause: context window bloat from per-turn coverage injection
Every candidate turn triggers inject_coverage_map (audio_websocket_middleware.rb:155-158), which calls inject_context — creating a full clientContent user turn with turnComplete: true. These accumulate in Gemini's conversation history:

Turn pair	Extra user turns from injections
5th exchange	~5 coverage map turns
15th exchange	~15 coverage map turns
25th exchange	~25+ coverage map turns
Even with contextWindowCompression: { slidingWindow: {} }, Gemini still processes these turns before they slide out. The coverage map payload is the same (or nearly the same) every time — the CoverageAnalyzerWorker runs async in Sidekiq and hasn't finished by the time the injection fires, so every injection just re-sends the previous state. The context grows linearly with conversation length, directly explaining why inputTx gradually slows as the conversation progresses.

Aggravating factor 1: un-deduplicated time ceiling injections
check_time_ceiling is called on both input AND output transcription events (lines 166 and audio_websocket_middleware.rb:185). The remaining <= 60 and remaining <= 120 branches have no deduplication — they inject on every single transcription event during those windows. In the last 2 minutes with active conversation, this can add 10+ additional clientContent turns.

Aggravating factor 2: silence pump timer churn on EM reactor
Every send_audio call (≈33/sec during speech) calls schedule_silence_pump → stop_silence_pump → creates a new EM::Timer. That's 33 timer create/cancel cycles per second on the EM reactor — harmless at low load but adds pressure when Gemini is already slow to respond.

Aggravating factor 3: silence pump sends ~59KB/s of base64 silence
Each SILENCE_FRAME is 1280 bytes raw → ~1800 bytes as JSON+base64. At 33fps that's ~59KB/s of WebSocket traffic pumped into Gemini during every pause. The pump runs continuously until the next turn — not the progressive culprit, but it's significant constant overhead that competes with real audio for Gemini's processing.

---

## Fixes implemented (2026-04-02)

### Fix 1: Diff-based coverage injection — DONE
Skip injection if the coverage map state is identical to the last injection.

**How:** `Coverage::MapInjector#coverage_fingerprint` computes an MD5 of `id:state:probe_count`
for every coverage map. `ConnectionState#last_coverage_digest` stores the last sent fingerprint.
`inject_coverage_map` compares and returns early if unchanged.
`time_remaining_minutes` is intentionally excluded from the fingerprint — time-only changes
don't warrant a re-injection since `check_time_ceiling` handles explicit time warnings separately.

**Files:** `app/services/coverage/map_injector.rb`, `app/channels/audio_websocket_middleware.rb`

---

### Fix 2: Move coverage injection after AI turn (post-Sidekiq) — REVERTED
**Attempted:** Move injection from `on_input_transcription` to `on_model_turn_complete`.

**Regression:** `on_model_turn_complete` fires right as the mic opens. Gemini receives the
`clientContent` injection just as the candidate starts speaking. If Gemini briefly responds
to it (despite system prompt instructions), `on_audio` fires → `model_speaking = true` →
gate closes → candidate audio is suppressed entirely.

**Why it wasn't safe:** The original injection timing (during candidate turn processing while
AI is already responding) meant any spurious audio blended into the ongoing turn. Injecting
after AI completes opens a new turn window where Gemini may respond independently.

**Resolution:** Fix #1 (fingerprint dedup) already solves context bloat on its own. Injection
stays in `on_input_transcription` — it still sends 1-turn-stale data, but only when coverage
actually changed. This matches the spec ("may be 1 turn behind — acceptable").

---

### Fix 3: Deduplicate time ceiling injections — DONE
`check_time_ceiling` was called on every transcription event (both candidate and AI turns),
causing `:warn_120`, `:warn_60`, and `:ceiling` injections to fire repeatedly during their
respective windows.

**How:** Added `sent_time_warnings` (`Set`) to `ConnectionState`. Each tier
(`:warn_120`, `:warn_60`, `:ceiling`) is gated — injected at most once per session.

**File:** `app/channels/audio_websocket_middleware.rb`

---

### Fix 4: Debounce silence pump timer — DONE
`schedule_silence_pump` was called every `send_audio` invocation (~33/sec during speech),
cancelling and recreating an `EM::Timer` each time — ~33 allocations/sec on the EM reactor.

**How:** Added `@silence_pump_timer_at` timestamp. `schedule_silence_pump` skips recreating
the timer if one was scheduled within `SILENCE_PUMP_DELAY / 2` (250ms). Churn drops from
~33/sec to ~4/sec during continuous speech. Worst-case pump start delay increases from
500ms to 750ms — still well above natural intra-sentence pauses.

**File:** `app/clients/gemini/live_client.rb`
