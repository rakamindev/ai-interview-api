# frozen_string_literal: true

require 'faye/websocket'
require 'json'
require 'base64'

module Gemini
  # Manages a persistent WebSocket connection to Gemini Live API.
  # Handles setup, audio streaming, transcription, coverage injection,
  # and GoAway reconnection.
  class LiveClient
    GEMINI_WS_URL = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'

    INACTIVITY_TIMEOUT = 30 # seconds — reconnect if Gemini produces no meaningful response
    GATE_OPEN_DELAY    = 0.8 # seconds after generationComplete before opening mic gate
                             # — lets frontend audio buffer drain so the mic doesn't
                             # pick up the AI's speaker output and create an echo loop

    # The frontend stops sending audio after ~50ms of silence, but Gemini's
    # automatic VAD needs ~1s of continuous silence to detect end-of-speech.
    # When real audio stops arriving, we pump synthetic silent PCM frames so
    # the VAD gets the silence it needs.
    #
    # Timing: during SILENCE_PUMP_DELAY, Gemini receives nothing (VAD paused).
    # The silenceDurationMs counter only starts once silence frames arrive.
    # Total latency from candidate stopping to VAD fire:
    #   SILENCE_PUMP_DELAY (500ms) + silenceDurationMs (1000ms) = ~1.5s
    #
    # 500ms is above typical intra-sentence pauses (200-400ms) so the pump
    # won't cycle on natural speech. At 200ms, the pump fires on every pause,
    # gets cancelled when speech resumes, and Gemini never accumulates enough
    # continuous silence to trigger turnComplete.
    SILENCE_PUMP_DELAY    = 0.5        # wait 500ms after last real audio before pumping
    SILENCE_PUMP_INTERVAL = 0.03      # ~30ms between frames (matches worklet cadence)
    SILENCE_FRAME_SAMPLES = 640       # 40ms at 16kHz — slightly over-sized so EM timer 
                                      # jitter never creates a perceived gap in silence
    SILENCE_FRAME = ("\x00" * (SILENCE_FRAME_SAMPLES * 2)).freeze # 16-bit PCM zeros

    attr_reader :resumption_token, :connected, :connected_at, :inactivity_close, :resumption_failed

    def initialize(
      system_prompt:,
      api_key: nil,
      model: nil,
      voice: 'Puck',
      on_audio: nil,
      on_input_transcription: nil,
      on_output_transcription: nil,
      on_model_turn_complete: nil,
      on_go_away: nil,
      on_close: nil,
      on_error: nil,
      on_ready: nil,
      on_resumption_token_update: nil
    )
      @system_prompt = system_prompt
      @api_key = api_key || ENV.fetch('GEMINI_API_KEY')
      @model = model || ENV.fetch('GEMINI_LIVE_MODEL', 'gemini-2.0-flash-live-001')
      @voice = voice
      @resumption_token = nil
      @connected = false
      @ws = nil
      @input_text_buffer  = +''
      @output_text_buffer = +''
      @last_activity_at = nil
      @inactivity_timer = nil
      @last_audio_forwarded_at = nil
      @silence_pump_timer = nil

      # Callbacks
      @on_audio = on_audio
      @on_input_transcription = on_input_transcription
      @on_output_transcription = on_output_transcription
      @on_model_turn_complete = on_model_turn_complete
      @on_go_away = on_go_away
      @on_close = on_close
      @on_error = on_error
      @on_ready = on_ready
      @on_resumption_token_update = on_resumption_token_update
    end

    # Opens the WebSocket connection to Gemini Live and sends the setup message.
    # If resumption_handle is provided, resumes a previous session.
    def connect(resumption_handle: nil)
      @awaiting_session_resumption = resumption_handle.present?
      @setup_complete = false
      @resumption_received = false

      url = "#{GEMINI_WS_URL}?key=#{@api_key}"

      @ws = Faye::WebSocket::Client.new(url)

      @ws.on :open do |_event|
        send_setup(resumption_handle: resumption_handle)
        Rails.logger.info('[Gemini::LiveClient] WebSocket opened — awaiting setupComplete')
      end

      @ws.on :message do |event|
        handle_message(event.data)
      end

      @ws.on :close do |event|
        @connected = false
        Rails.logger.info("[Gemini::LiveClient] Connection closed: code=#{event.code} reason=#{event.reason} superseded=#{@superseded}")
        # Don't fire on_close for superseded clients — they've already been replaced.
        # Without this guard, the old client's close triggers handle_gemini_close,
        # which starts a second reconnect and creates a duplicate Gemini instance.
        @on_close&.call(code: event.code, reason: event.reason) unless @superseded
      end

      @ws.on :error do |event|
        Rails.logger.error("[Gemini::LiveClient] WebSocket error: #{event.message}")
        @on_error&.call(event.message) unless @superseded
      end

      @ws
    end

    # Sends raw PCM audio bytes to Gemini Live as realtimeInput.
    def send_audio(pcm_bytes)
      return unless @connected && @ws

      ensure_inactivity_watchdog

      @audio_chunks_forwarded = (@audio_chunks_forwarded || 0) + 1
      @audio_bytes_forwarded = (@audio_bytes_forwarded || 0) + pcm_bytes.bytesize
      @last_audio_forwarded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if (@audio_chunks_forwarded % 50).zero?
        Rails.logger.debug(
          "[Gemini::LiveClient] Audio forwarded: #{@audio_chunks_forwarded} chunks (#{@audio_bytes_forwarded}B total)"
        )
      end

      schedule_silence_pump

      message = {
        realtimeInput: {
          mediaChunks: [{
            mimeType: 'audio/pcm;rate=16000',
            data: Base64.strict_encode64(pcm_bytes)
          }]
        }
      }

      @ws.send(message.to_json)
    end

    # Injects hidden context directly into Gemini's conversation flow.
    #
    # EXPERIMENT (experiment/remove-vad-config): Reverted to turnComplete: false.
    # With the custom realtimeInputConfig removed, Gemini's default turn
    # management should treat this as supplemental context — not a standalone
    # turn that needs closing. See tech-docs/report/turncomplete-dilemma.md.
    #
    # Previously used turnComplete: true which prevented dangling turns but
    # introduced dual-voice risk and required 5 guards (model_emitting_audio,
    # silence_pumping, model_speaking, GATE_OPEN_DELAY, model_interrupted).
    #
    # Returns true if the injection was sent, false if it was skipped.
    # Callers that need guaranteed delivery should retry on false.
    def inject_context(text)
      return false unless @connected && @ws

      # EXPERIMENT (experiment/remove-vad-config): @silence_pumping guard removed.
      # With turnComplete: false, clientContent is supplemental context — not a
      # standalone turn. No 1008 risk from interleaving with realtimeInput.
      # Keeping @model_emitting_audio as a safety net for Phase 1.
      if @model_emitting_audio
        Rails.logger.debug("[Gemini::LiveClient] inject_context skipped — model_emitting=#{@model_emitting_audio}")
        return false
      end

      message = {
        clientContent: {
          turns: [{
            role: 'user',
            parts: [{ text: text }]
          }],
          turnComplete: false
        }
      }

      @ws.send(message.to_json)
      true
    end

    # Sends an empty client turn to prompt Gemini to speak first.
    # Called after setupComplete so the AI delivers the opening question
    # without waiting for candidate audio.
    def trigger_opening
      return unless @connected && @ws

      message = {
        clientContent: {
          turns: [{
            role:  'user',
            parts: [{ text: '' }]
          }],
          turnComplete: true
        }
      }

      @ws.send(message.to_json)
    end

    # Returns true if this client is ready to accept audio frames.
    # False when not yet connected, superseded, or after close.
    def accepting_audio?
      @connected && @ws && !@superseded
    end

    # Gracefully closes the connection.
    def close
      @inactivity_timer&.cancel
      @resumption_ready_timer&.cancel
      @gate_timer&.cancel
      stop_silence_pump
      @ws&.close
      @connected = false
    end

    # Silences all callbacks immediately — called before replacing this client
    # with a new one on GoAway reconnect, so buffered audio/events from this
    # client don't bleed into the new session.
    def supersede!
      @superseded = true
      @inactivity_timer&.cancel
      @resumption_ready_timer&.cancel
      @gate_timer&.cancel
      stop_silence_pump
    end

    private

    def activate_connection!
      @connected = true
      Rails.logger.info('[Gemini::LiveClient] Session ready — accepting audio')
      @on_ready&.call
    end

    def record_activity!
      @last_activity_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Each time real audio arrives, (re)schedule a one-shot timer. When the
    # frontend's silence gate stops sending, the timer fires and starts
    # pumping silent PCM frames so Gemini's automatic VAD detects the silence.
    #
    # Uses a fire-once timer + timestamp approach to avoid both:
    #   1. EM reactor churn (33 timer create/cancel per second during speech)
    #   2. Premature pump firing (old debounce could fire up to 250ms early,
    #      within natural intra-sentence pause range, sending spurious silence
    #      that confuses Gemini's VAD)
    def schedule_silence_pump
      # EXPERIMENT (experiment/remove-vad-config): Silence pump disabled.
      # Without custom realtimeInputConfig, Gemini's default VAD should
      # handle silence detection from the browser's audio stream directly.
      # The silence pump was needed because the custom VAD required
      # continuous silence frames that the browser doesn't send.
      # If the experiment fails (Gemini can't detect end-of-speech),
      # re-enable by removing this early return.
      return

      # Always stop the periodic pump if running — real audio arrived, silence must stop.
      if @silence_pumping
        stop_silence_pump
      end

      # Track when real audio last arrived — cheap, no timer allocation.
      @last_real_audio_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Only create one pending timer; it will self-check on fire.
      return if @silence_pump_timer

      @silence_pump_timer = EM::Timer.new(SILENCE_PUMP_DELAY) do
        @silence_pump_timer = nil
        check_silence_pump_ready
      end
    end

    # Called when the silence pump delay timer fires. Checks whether enough
    # real silence has elapsed since the last audio frame; if audio arrived
    # during the timer window, reschedules for the remaining time.
    def check_silence_pump_ready
      return if @silence_pumping || !@connected || !@ws || @superseded || !@last_real_audio_at || @model_emitting_audio

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_real_audio_at
      remaining = SILENCE_PUMP_DELAY - elapsed

      if remaining <= 0.02 # close enough — EM timer precision is ~10ms
        start_silence_pump
      else
        # Audio arrived after timer was created — wait the actual remaining time.
        @silence_pump_timer = EM::Timer.new(remaining) do
          @silence_pump_timer = nil
          check_silence_pump_ready
        end
      end
    end

    def start_silence_pump
      return if @silence_pumping || !@connected || !@ws || @model_emitting_audio

      @silence_pumping = true
      Rails.logger.info('[Gemini::LiveClient] Silence pump started — no real audio for 500ms')

      silence_msg = {
        realtimeInput: {
          mediaChunks: [{
            mimeType: 'audio/pcm;rate=16000',
            data: Base64.strict_encode64(SILENCE_FRAME)
          }]
        }
      }.to_json.freeze

      # Pump indefinitely — stopped by: real audio arriving (schedule_silence_pump),
      # Gemini responding (turnComplete), or connection close/supersede.
      @silence_pump_periodic = EM::PeriodicTimer.new(SILENCE_PUMP_INTERVAL) do
        if !@connected || !@ws || @superseded
          stop_silence_pump
        else
          @ws.send(silence_msg)
        end
      end
    end

    def stop_silence_pump
      @silence_pump_timer&.cancel
      @silence_pump_timer = nil
      @last_real_audio_at = nil
      @silence_pump_periodic&.cancel
      @silence_pump_periodic = nil
      @silence_pumping = false
    end

    # Checks whether Gemini has locked up while the candidate has stopped talking.
    #
    # Only triggers when @silence_pumping is true (candidate finished speaking,
    # pump is actively sending silence). This prevents killing the connection
    # while the candidate is holding the floor for a long monologue — the old
    # check on audio_recently_forwarded would fire after 30s of continuous speech
    # if Gemini's inputTranscription events lagged behind.
    def ensure_inactivity_watchdog
      return if @inactivity_timer || @superseded

      record_activity! unless @last_activity_at
      @inactivity_timer = EM::PeriodicTimer.new(10) do
        next unless @connected && @last_activity_at

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        idle = now - @last_activity_at
        next unless @silence_pumping && idle >= INACTIVITY_TIMEOUT

        Rails.logger.warn("[Gemini::LiveClient] Inactivity detected (#{idle.round(1)}s, silence pumping) — forcing reconnect")
        @inactivity_timer&.cancel
        @inactivity_timer = nil
        @inactivity_close = true
        @ws&.close
      end
    end

    def log_gemini_event(data)
      sc = data['serverContent']
      if sc
        has_audio = sc.dig('modelTurn', 'parts')&.any? { |p| p['inlineData'] }
        has_input_tx = sc.key?('inputTranscription')
        has_output_tx = sc.key?('outputTranscription')
        turn_complete = sc['turnComplete']
        gen_complete = sc['generationComplete']

        interrupted = sc['interrupted']

        # Skip audio-only frames (too noisy)
        return if has_audio && !has_input_tx && !has_output_tx && !turn_complete && !gen_complete && !interrupted

        parts = []
        parts << 'interrupted' if interrupted
        parts << 'audio' if has_audio
        if has_input_tx
          input_tx_text = sc.dig('inputTranscription', 'parts', 0, 'text')
          parts << "inputTx=#{input_tx_text.truncate(50)}" if input_tx_text.present?
        end
        if has_output_tx
          output_tx_text = sc.dig('outputTranscription', 'parts', 0, 'text')
          parts << "outputTx=#{output_tx_text.truncate(50)}" if output_tx_text.present?
        end
        parts << 'turnComplete' if turn_complete
        parts << 'generationComplete' if gen_complete

        Rails.logger.info("[Gemini::LiveClient] Event: #{parts.join(' | ')}") if parts.any?
      end

      Rails.logger.info('[Gemini::LiveClient] Event: setupComplete') if data['setupComplete']
      if data['sessionResumption'] || data['sessionResumptionUpdate']
        Rails.logger.info('[Gemini::LiveClient] Event: resumptionToken updated')
      end
    end

    def send_setup(resumption_handle: nil)
      setup = {
        setup: {
          model: "models/#{@model}",
          generationConfig: {
            responseModalities: ['AUDIO'],
            speechConfig: {
              voiceConfig: {
                prebuiltVoiceConfig: { voiceName: @voice }
              }
            }
          },
          systemInstruction: {
            parts: [{ text: @system_prompt }]
          },
          # realtimeInputConfig REMOVED (experiment/remove-vad-config)
          # The original custom VAD config was never in the spec. Removing it
          # lets Gemini use its default turn management, which may handle
          # turnComplete: false correctly (no dangling turns). See:
          # tech-docs/report/turncomplete-dilemma.md — "Option F"
          inputAudioTranscription: {},
          outputAudioTranscription: {},
          contextWindowCompression: {
            slidingWindow: {}
          },
          sessionResumption: resumption_handle ? { handle: resumption_handle } : {}
        }
      }

      @ws.send(setup.to_json)
    end

    def handle_message(raw_data)
      return if @superseded

      data = JSON.parse(raw_data)

      # Only count meaningful responses as activity for the inactivity watchdog.
      # Token updates (sessionResumption) do NOT count — Gemini sends those even
      # when it has stopped producing audio/transcription (the original stall bug).
      record_activity! if data['serverContent'] || data['setupComplete']

      log_gemini_event(data)

      # Audio response from AI
      if (parts = data.dig('serverContent', 'modelTurn', 'parts'))
        parts.each do |part|
          if (inline = part['inlineData'])
            stop_silence_pump unless @model_emitting_audio  # defensive: ensure pump is off
            @model_emitting_audio = true
            audio_bytes = Base64.strict_decode64(inline['data'])
            @on_audio&.call(audio_bytes)
          end
        end
      end

      # Input transcription — accumulate, fire callback on turnComplete
      if (input_tx = data.dig('serverContent', 'inputTranscription'))
        text = input_tx.dig('parts', 0, 'text') || input_tx['text']
        @input_text_buffer << text.to_s
      end

      # Output transcription — accumulate until generationComplete
      if (output_tx = data.dig('serverContent', 'outputTranscription'))
        text = output_tx.dig('parts', 0, 'text') || output_tx['text']
        @output_text_buffer << text.to_s
      end

      # generationComplete MUST be checked before turnComplete — Gemini sometimes
      # sends both in the same message, and @model_turn_complete must be set first
      # so the turnComplete block below knows whose turn just ended.
      # generationComplete = all AI audio frames have been sent to the browser.
      # But the frontend's speaker may still be playing for 0.5–1.5s (WebSocket
      # latency + audio buffer drain). If we open the audio gate now, the mic
      # picks up the speaker output → Gemini hears its own voice → echo loop.
      #
      # Fix: flush transcription buffers immediately, but delay opening the
      # gate by GATE_OPEN_DELAY so the frontend speaker drains first.
      # The model's subsequent turnComplete falls through to the user's branch
      # as a harmless no-op (pump not running, buffer empty).
      if data.dig('serverContent', 'generationComplete')
        @model_emitting_audio = false

        if @input_text_buffer.present?
          @on_input_transcription&.call(@input_text_buffer.strip)
          @input_text_buffer = +''
        end

        if @output_text_buffer.present?
          @on_output_transcription&.call(@output_text_buffer.strip)
          @output_text_buffer = +''
        end

        # Delay gate opening so frontend audio playback drains and the mic
        # doesn't pick up speaker echo.
        Rails.logger.info("[Gemini::LiveClient] generationComplete — output_emitted=#{@model_emitting_audio} output_buffer=#{@output_text_buffer.length}chars")
        @gate_timer&.cancel
        @gate_timer = EM::Timer.new(GATE_OPEN_DELAY) do
          unless @superseded
            Rails.logger.info('[Gemini::LiveClient] Gate open — firing on_model_turn_complete (speaker_changed:candidate will be sent)')
            @on_model_turn_complete&.call
          end
        end
      end

      # Interrupted fires when the candidate speaks over the model. Open the
      # gate immediately — the candidate is actively speaking, so we need
      # their audio to flow regardless of echo risk.
      if data.dig('serverContent', 'interrupted')
        if @model_emitting_audio
          @model_emitting_audio = false
          @model_interrupted = true
          @gate_timer&.cancel
          Rails.logger.info('[Gemini::LiveClient] Model interrupted — resetting audio gate immediately')
          if @output_text_buffer.present?
            @on_output_transcription&.call(@output_text_buffer.strip)
            @output_text_buffer = +''
          end
          @on_model_turn_complete&.call
        end
      end

      if data.dig('serverContent', 'turnComplete')
        if @model_emitting_audio
          # turnComplete without generationComplete while model was emitting
          # audio — the model was interrupted or generation ended abruptly.
          @model_emitting_audio = false
          Rails.logger.info('[Gemini::LiveClient] Model interrupted — turnComplete without generationComplete')

          if @output_text_buffer.present?
            @on_output_transcription&.call(@output_text_buffer.strip)
            @output_text_buffer = +''
          end

          @on_model_turn_complete&.call
        elsif @model_interrupted
          # Stale post-interruption turnComplete — already handled via `interrupted`.
          @model_interrupted = false
        else
          # User's turn complete (or model's stale turnComplete after
          # generationComplete — harmless no-op since pump is off and buffer empty).
          Rails.logger.info("[Gemini::LiveClient] User turnComplete — input_buffer=#{@input_text_buffer.length}chars silence_pumping=#{@silence_pumping}")
          stop_silence_pump

          if @input_text_buffer.present?
            @on_input_transcription&.call(@input_text_buffer.strip)
            @input_text_buffer = +''
          end
        end
      end

      # Session resumption token update
      if (resumption = data['sessionResumption'] || data.dig('sessionResumptionUpdate'))
        handle = resumption['handle'] || resumption['token'] || resumption['newHandle']
        if handle.present?
          @resumption_token = handle
          @on_resumption_token_update&.call(handle)
        end

        # For resumed sessions, the session isn't fully ready until this
        # handshake completes. Audio sent before this is silently dropped.
        if @awaiting_session_resumption
          if @setup_complete && !@connected
            @awaiting_session_resumption = false
            @resumption_ready_timer&.cancel
            activate_connection!
          else
            # Token arrived before setupComplete — remember it so setupComplete
            # can activate immediately instead of waiting 5s for a second token.
            @resumption_received = true
          end
        end
      end

      # Setup complete — Gemini is ready to receive audio
      if data['setupComplete']
        @setup_complete = true
        @connected_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if @awaiting_session_resumption
          if @resumption_received
            # Token already arrived before setupComplete — activate immediately.
            @awaiting_session_resumption = false
            activate_connection!
          else
            # Resumed session — wait for sessionResumption before accepting audio.
            # Safety timeout: if token doesn't arrive in 5s, force a full reconnect.
            Rails.logger.info('[Gemini::LiveClient] Setup complete — awaiting session resumption handshake')
            @resumption_ready_timer = EM::Timer.new(5) do
              next if @connected || @superseded

              Rails.logger.warn('[Gemini::LiveClient] Session resumption timeout — forcing full reconnect')
              @awaiting_session_resumption = false
              @resumption_failed = true
              @ws&.close
            end
          end
        else
          activate_connection!
        end
      end

      # GoAway signal — need to reconnect
      if data['goAway']
        time_left = data.dig('goAway', 'timeLeft')
        Rails.logger.warn("[Gemini::LiveClient] GoAway received, timeLeft=#{time_left}")
        @on_go_away&.call(time_left: time_left, resumption_token: @resumption_token)
      end
    rescue JSON::ParserError => e
      Rails.logger.error("[Gemini::LiveClient] Failed to parse message: #{e.message}")
    end
  end
end
