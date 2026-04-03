# Proactive Gemini Live Reconnection with Audio Ring Buffer

## Context

Gemini Live enforces a ~10 minute connection limit. Sometimes it sends a GoAway (graceful), sometimes it hard-closes with `code=1011` (no warning). During a 30-45 minute interview, this happens 3-4 times. The current code handles reconnection reactively, but **audio is lost during the gap** — `send_audio` silently drops frames when `@connected` is false. The gap can be 2-15 seconds, enough to lose an entire candidate sentence.

**Goal:** Make Gemini reconnections invisible to the candidate — zero audio loss, zero UI disruption.

---

## Files to Modify

| File | Action |
|------|--------|
| `app/lib/audio_ring_buffer.rb` | **NEW** — ring buffer class |
| `app/clients/gemini/live_client.rb` | Add `accepting_audio?`, `connected_at`, `on_resumption_token_update` callback |
| `app/channels/audio_websocket_middleware.rb` | Core changes — buffering, proactive reconnect, replay |

---

## Step 1: Create `AudioRingBuffer` (`app/lib/audio_ring_buffer.rb`)

A fixed-size circular buffer storing timestamped PCM chunks. ~30 lines.

- `push(pcm_bytes, timestamp:)` — append chunk, auto-evict oldest when over capacity
- `since(timestamp)` — return all chunks after a given monotonic timestamp
- `bytes_since(timestamp)` — concatenated PCM bytes since timestamp
- `clear` — reset buffer

Design:
- 60 seconds capacity at 32KB/s = ~1.92MB per session
- Uses `Process::CLOCK_MONOTONIC` (immune to wall-clock drift)
- No mutex needed (EM is single-threaded)
- Stores `Struct.new(:timestamp, :data)` chunks in an array, shifts oldest on eviction

---

## Step 2: Add helpers to `Gemini::LiveClient`

**a)** `accepting_audio?` predicate — returns `@connected && @ws && !@superseded`
- Used by middleware to decide whether to forward audio or just buffer

**b)** `attr_reader :connected_at` — set to monotonic timestamp on `setupComplete`
- Used by middleware to know connection age

**c)** `on_resumption_token_update` callback — fires whenever a new resumption token arrives
- Currently tokens are only accessible via `@resumption_token` attr or the `on_go_away` callback
- Middleware needs to cache the latest token proactively (not just on GoAway)

---

## Step 3: Extend `ConnectionState`

Add new fields:

```ruby
attr_accessor :audio_buffer,              # AudioRingBuffer instance
              :proactive_reconnect_timer,  # EM timer reference (cancelable)
              :reconnect_start_at,         # monotonic timestamp when reconnect began
              :latest_resumption_token,    # cached token (avoids DB reads in hot path)
              :reconnecting                # boolean flag for on_ready to distinguish initial vs reconnect
```

Initialize `audio_buffer` in constructor. Others default to `nil`/`false`.

---

## Step 4: Always-on audio buffering

Modify the `browser_ws.on :message` handler (line 56-63):

```
Before: browser audio → gemini_client.send_audio()
After:  browser audio → audio_buffer.push() → gemini_client.send_audio() (if accepting)
```

- Always push to ring buffer (cheap, auto-evicts)
- Only forward to Gemini if `gemini_client&.accepting_audio?`
- During reconnection gap, audio is safely buffered

---

## Step 5: Proactive reconnect timer

New method `schedule_proactive_reconnect(browser_ws, state)`:
- Cancel any existing timer
- Schedule `EM.add_timer(510 + rand(30))` (~8.5-9 min with jitter)
- On fire: call `initiate_proactive_reconnect`

Called from `on_ready` callback after every successful connection.

---

## Step 6: Proactive reconnect initiation

New method `initiate_proactive_reconnect(browser_ws, state)`:

1. Get latest resumption token (from `state.latest_resumption_token` or DB)
2. If no token available, re-schedule and return
3. Record `state.reconnect_start_at = monotonic_now`
4. Set `state.reconnecting = true`
5. Save token to DB
6. Supersede old client
7. Build new gemini client and connect with resumption token

Audio from browser continues being buffered during this time.

---

## Step 7: Reconnect-aware `on_ready`

Modify the `on_ready` callback in `build_gemini_client`:

- **If `state.reconnecting`**: replay buffered audio since `reconnect_start_at`, reset flags, do NOT send `session_started` or `trigger_opening`
- **If initial connection**: trigger opening + send `session_started` (existing behavior)
- **Always**: schedule next proactive reconnect

---

## Step 8: Audio replay

New method `replay_buffered_audio(state)`:
- Get chunks from `state.audio_buffer.since(state.reconnect_start_at)`
- Send each chunk to `state.gemini_client.send_audio(chunk.data)` sequentially
- Gemini handles burst/duplicate audio gracefully via its VAD

---

## Step 9: Update existing reconnect handlers

**`handle_go_away`** (line 181):
- Cancel proactive timer
- Record `reconnect_start_at`
- Set `state.reconnecting = true`
- Cache token in `state.latest_resumption_token`
- Remove `send_json(browser_ws, type: 'reconnecting')` — candidate shouldn't notice

**`handle_gemini_close`** (line 201):
- Cancel proactive timer
- Record `reconnect_start_at ||=` (only on first attempt)
- Set `state.reconnecting = true`
- Use `state.latest_resumption_token` as primary token source
- Remove `send_json(browser_ws, type: 'reconnecting')` — candidate shouldn't notice

---

## Step 10: Cleanup

- Cancel proactive timer on browser disconnect (`on :close` handler, line 66)
- Cancel proactive timer + clear buffer on `end_session` (line 231)
- Add `on_resumption_token_update` callback to `build_gemini_client` to keep `state.latest_resumption_token` current

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| No resumption token yet at 8.5min | Re-schedule timer, skip this cycle |
| GoAway arrives during proactive reconnect | Cancel pending, use GoAway's fresher token |
| Hard 1011 during proactive reconnect | Cancel pending, fall into retry logic |
| Buffer replay sends overlapping audio | Gemini VAD handles duplicates gracefully |
| Session ends during reconnect | `end_session` cancels timer and clears buffer |
| Browser disconnects during reconnect | Grace period timer runs, session ends after 120s |

---

## Verification

1. **Unit test `AudioRingBuffer`**: push, eviction, `since()` retrieval, `clear`
2. **Manual test**: Run a 15+ minute interview, verify in logs:
   - `[AudioWS] Proactive reconnect scheduled in Xs`
   - `[AudioWS] Initiating proactive reconnect`
   - `[AudioWS] Gemini reconnected — replaying N chunks`
   - No `reconnecting` messages sent to browser
3. **Transcript check**: Verify no gaps in transcript around reconnection boundaries
4. **Edge case**: Kill Gemini connection manually (simulate 1011), verify buffer replay fills the gap


<!-- Here's a summary of what was implemented across 3 files:

app/lib/audio_ring_buffer.rb — New class. Stores last 60s of PCM audio in a circular buffer with monotonic timestamps. Auto-evicts oldest chunks when full (~1.92MB per session).

app/clients/gemini/live_client.rb — Three additions:

accepting_audio? — lets middleware know if this client can actually receive frames
connected_at — monotonic timestamp set on setupComplete
on_resumption_token_update callback — fires on every token update so the middleware always has the latest token
app/channels/audio_websocket_middleware.rb — Core changes:

Audio is always buffered before forwarding; only forwarded if accepting_audio?
on_ready is now reconnect-aware: replays buffered audio on reconnect, sends session_started only on initial connect
schedule_proactive_reconnect fires at ~8.5-9 min (with jitter) before Gemini's 10-min limit
initiate_proactive_reconnect supersedes the old client, starts the new one, delays closing old by 2s to overlap
replay_buffered_audio sends all buffered chunks since reconnect_start_at to the new connection
GoAway and 1011 close handlers both record gap start time and set reconnecting = true — no more "reconnecting" messages to the browser -->