# gRPC Streaming STT — Architecture & EM Wiring Plan

**Date:** 2026-04-05
**Status:** Plan only — implement after REST version is validated

---

## REST vs gRPC Latency

gRPC streaming doesn't eliminate latency — it **overlaps** it with the candidate's speech so you don't feel it.

### REST (current implementation)

```
Candidate speaks ──────────────────► Candidate stops (700ms silence)
                                      │
                                      ▼
                               Buffer complete ──► Send to STT ──► Wait ──► Text back
                                                   |─── 0.5-1s latency ───|
                                                                           │
                                                                           ▼
                                                                    Gemini Flash ──► TTS ──► Audio
                                                                    |──── 1.5-2.5s ─────|

Total after candidate stops: ~2-3.5s
```

STT doesn't start until the candidate finishes speaking. The 0.5-1s STT latency is added ON TOP of everything else.

### gRPC Streaming (proposed)

```
Candidate speaks ──────────────────► Candidate stops (VAD from STT)
     │                                │
     ▼ (streaming in real-time)       ▼
     STT processes as audio arrives   Final transcript ready IMMEDIATELY
     Partial: "Saya pernah..."        │
     Partial: "Saya pernah bekerja"   ▼
     Partial: "Saya pernah bekerja di" Gemini Flash ──► TTS ──► Audio
                                       |──── 1.5-2.5s ─────|

Total after candidate stops: ~1.5-2.5s (STT latency = ~0s, already processed)
```

**The key difference:** with gRPC streaming, STT processes audio AS the candidate speaks. By the time they stop talking, the transcript is already complete (or within ~100ms of complete). The 0.5-1s REST latency is eliminated because transcription happened in parallel with speech.

### Latency Summary

| Component | REST | gRPC Streaming |
|-----------|------|----------------|
| STT | 0.5-1s (after speech ends) | ~0s (processed during speech) |
| Gemini Flash | 1-2s | 1-2s (same) |
| TTS | 0.5-1s | 0.5-1s (same) |
| **Total after candidate stops** | **2-3.5s** | **1.5-2.5s** |

gRPC saves ~0.5-1s by eliminating the STT wait. It also gives us **real-time partial transcriptions** (candidate sees their words appear as they speak).

---

## The EventMachine Challenge

gRPC uses its own threading model (gRPC thread pool). EventMachine uses a single-threaded reactor. They can't share threads.

**The problem:**
```
EM Reactor Thread                    gRPC Thread Pool
────────────────                     ─────────────────
Browser WS events                    STT streaming session
Audio frame callbacks                Receives partial transcripts
Timer callbacks                      Receives final transcript
send_json to browser                 Receives VAD events
```

These two worlds need to communicate safely.

**The solution: Thread + EM.schedule bridge**

```
                    ┌─────────────────────────┐
                    │    EM Reactor Thread     │
                    │                         │
  Browser WS ─────►│  on :message            │
                    │    │                    │
                    │    ▼                    │
                    │  audio frame arrives    │
                    │    │                    │
                    │    ▼                    │
                    │  Push to thread-safe    │──────► gRPC Thread
                    │  queue / pipe           │        │
                    │                         │        ▼
                    │                         │   stt_stream.send(audio)
                    │                         │        │
                    │                         │        ▼
                    │                         │   STT processes...
                    │                         │        │
                    │  ◄──── EM.schedule ─────│────────┘
                    │    │                    │   on partial/final result
                    │    ▼                    │
                    │  send_json(browser_ws,  │
                    │    transcription: ...)  │
                    └─────────────────────────┘
```

---

## Implementation Plan

### Component: `STT::GoogleStreamingClient`

```ruby
module STT
  class GoogleStreamingClient
    def initialize(language:, on_partial:, on_final:, on_error:)
      @language   = language
      @on_partial = on_partial   # called with interim text (for real-time display)
      @on_final   = on_final     # called with final text (VAD detected end-of-speech)
      @on_error   = on_error
      @audio_queue = Queue.new   # thread-safe queue for audio frames
      @running = false
    end

    # Start the streaming session in a background thread.
    # Returns immediately — audio is consumed from the queue.
    def start
      @running = true
      @stream_thread = Thread.new { run_stream }
    end

    # Push an audio frame (called from EM thread — must be non-blocking).
    def push_audio(pcm_bytes)
      @audio_queue.push(pcm_bytes) if @running
    end

    # Stop the streaming session.
    def stop
      @running = false
      @audio_queue.push(:stop)  # sentinel to unblock the thread
      @stream_thread&.join(5)
    end

    private

    def run_stream
      # Google Cloud STT V2 streaming via gRPC
      client = Google::Cloud::Speech::V2::Speech::Client.new do |config|
        config.credentials = credentials_path
      end

      # The streaming API expects an Enumerator that yields requests.
      # First request: config. Subsequent requests: audio chunks.
      request_enum = Enumerator.new do |yielder|
        # First message: streaming config
        yielder.yield Google::Cloud::Speech::V2::StreamingRecognizeRequest.new(
          recognizer: recognizer_path,
          streaming_config: streaming_config
        )

        # Subsequent messages: audio chunks from the queue
        loop do
          chunk = @audio_queue.pop  # blocks until audio available
          break if chunk == :stop || !@running

          yielder.yield Google::Cloud::Speech::V2::StreamingRecognizeRequest.new(
            audio: chunk
          )
        end
      end

      # Open bidirectional stream
      responses = client.streaming_recognize(request_enum)

      # Process responses (runs in this thread)
      responses.each do |response|
        next unless response.results&.any?

        response.results.each do |result|
          transcript = result.alternatives&.first&.transcript
          next unless transcript.present?

          if result.is_final
            # Final result — VAD detected end of speech
            # Bridge back to EM thread
            EM.schedule { @on_final.call(transcript) }
          else
            # Interim result — real-time partial transcription
            EM.schedule { @on_partial.call(transcript) }
          end
        end
      end
    rescue => e
      EM.schedule { @on_error.call(e.message) }
    end

    def streaming_config
      Google::Cloud::Speech::V2::StreamingRecognitionConfig.new(
        config: Google::Cloud::Speech::V2::RecognitionConfig.new(
          language_codes: [@language],
          model: 'long',
          features: Google::Cloud::Speech::V2::RecognitionFeatures.new(
            enable_automatic_punctuation: true
          ),
          auto_decoding_config: Google::Cloud::Speech::V2::AutoDetectDecodingConfig.new
        ),
        streaming_features: Google::Cloud::Speech::V2::StreamingRecognitionFeatures.new(
          interim_results: true,
          enable_voice_activity_events: true
        )
      )
    end

    def recognizer_path
      project  = Gemini::VertexAuth.project_id
      location = Gemini::VertexAuth.location
      "projects/#{project}/locations/#{location}/recognizers/_"
    end

    def credentials_path
      Gemini::VertexAuth.credentials_path
    end
  end
end
```

### Middleware Wiring (changes from REST version)

```ruby
# In start_session:
state.stt_client = STT::GoogleStreamingClient.new(
  language: language,
  on_partial: lambda { |text|
    # Real-time partial transcription → show in browser immediately
    send_json(browser_ws, type: 'transcription_partial', text: text)
  },
  on_final: lambda { |text|
    # VAD detected end-of-speech → process the turn
    process_candidate_turn(browser_ws, state, text)
  },
  on_error: lambda { |message|
    Rails.logger.error("[AudioWS] STT error: #{message}")
    # Restart the stream
    state.stt_client.stop
    state.stt_client.start
  }
)
state.stt_client.start

# In handle_audio_frame (simplified — no silence timer needed):
def handle_audio_frame(audio_data, browser_ws, state, session_id)
  return if state.model_speaking || state.processing
  state.stt_client.push_audio(audio_data)
end

# process_candidate_turn now receives text directly (no STT call needed):
def process_candidate_turn(browser_ws, state, candidate_text)
  return if state.processing
  state.processing = true
  # ... rest is the same: save transcript, coverage analysis, Gemini Flash, TTS
end
```

### Key Differences from REST

| Aspect | REST | gRPC Streaming |
|--------|------|----------------|
| Silence detection | 700ms timer in middleware | Google STT's built-in VAD (`enable_voice_activity_events`) |
| When STT runs | After silence detected (batch) | Continuously during speech (streaming) |
| Partial transcriptions | Not available | Real-time via `interim_results: true` |
| Audio buffering | In `STT::GoogleClient` (`push_audio` → `@audio_buffer`) | In `Queue` — consumed by gRPC thread immediately |
| STT latency after speech | 0.5-1s (REST round-trip) | ~0s (already processed) |
| Thread model | Thread.new per turn (short-lived) | One long-lived gRPC thread per session |
| Complexity | Simple (Faraday POST) | Medium (gRPC bidirectional stream, thread bridge, Queue) |

---

## EM ↔ gRPC Thread Safety

### Rules

1. **EM thread → gRPC thread:** Use `Queue#push` (thread-safe). Never call gRPC methods directly from EM.
2. **gRPC thread → EM thread:** Use `EM.schedule { ... }` (thread-safe). Never touch `browser_ws`, `state`, or `send_json` directly from the gRPC thread.
3. **Shared state:** `state.processing` and `state.model_speaking` are read from both threads. Since Ruby's GIL makes boolean reads/writes atomic, this is safe for flags. For complex state, use `EM.schedule`.

### Lifecycle

```
Session starts
  │
  ▼
stt_client.start
  │ → spawns gRPC thread
  │ → opens streaming session to Google STT
  │ → gRPC thread blocks on @audio_queue.pop (waiting for audio)
  │
  ▼
Candidate speaks
  │ → EM receives audio frame via browser WS
  │ → EM calls stt_client.push_audio(pcm_bytes)
  │ → Audio pushed to Queue
  │ → gRPC thread unblocks, sends audio to Google STT
  │ → Google STT returns partial transcript
  │ → gRPC thread calls EM.schedule { on_partial.call(text) }
  │ → EM sends partial transcription to browser
  │
  ▼
Candidate stops speaking
  │ → Google STT VAD detects end-of-speech
  │ → Google STT returns final transcript (is_final: true)
  │ → gRPC thread calls EM.schedule { on_final.call(text) }
  │ → EM processes the turn (Gemini Flash → TTS → audio)
  │
  ▼
Session ends
  │ → stt_client.stop
  │ → pushes :stop sentinel to Queue
  │ → gRPC thread unblocks, exits loop, thread joins
```

---

## Google STT Streaming Limits

| Limit | Value |
|-------|-------|
| Max stream duration | 5 minutes (then must reconnect) |
| Max audio per stream | 10 minutes |
| Interim results | Available (set `interim_results: true`) |
| VAD events | Available (set `enable_voice_activity_events: true`) |

**5-minute stream limit:** unlike Gemini Live's 10-minute limit, Google STT streams max out at 5 minutes. We'd need to cycle the stream every ~4.5 minutes (similar to the proactive reconnect pattern, but much simpler since there's no conversation state to preserve — just close and reopen the stream).

---

## Migration Path

```
Phase 1 (current): REST STT + REST TTS
  - Simple, works, ~2.5-3.5s latency
  - No real-time partial transcriptions
  - Validate the decoupled architecture works end-to-end

Phase 2: gRPC Streaming STT + REST TTS
  - ~1.5-2.5s latency (saves ~1s)
  - Real-time partial transcriptions
  - Google STT VAD replaces our 700ms timer
  - Same TTS (REST is fine — TTS latency is small)

Phase 3 (optional): gRPC Streaming STT + Streaming TTS
  - Start playing TTS audio before full synthesis completes
  - Could save another ~0.3-0.5s
  - More complex (chunked audio delivery)
```

Each phase is backward-compatible. The middleware interface stays the same — only the STT client implementation changes.
