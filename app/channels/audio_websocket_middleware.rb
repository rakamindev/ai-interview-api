      # frozen_string_literal: true

      require 'faye/websocket'
      require 'set'

      # Rack middleware that handles WebSocket connections at /ws/sessions/:id/audio.
      # Decoupled audio pipeline: STT → Gemini Flash (text) → TTS.
      #
      # Audio flow:
      #   Browser (16kHz PCM) → STT (Google Cloud Speech-to-Text) → text
      #   text → Gemini Flash (conversation) → AI response text
      #   AI response text → TTS (Google Cloud Text-to-Speech) → audio
      #   audio → Browser (24kHz PCM)
      class AudioWebSocketMiddleware
        AUDIO_PATH_PATTERN = %r{\A/ws/sessions/([^/]+)/audio\z}

        SILENCE_THRESHOLD_MS = 700   # ms of silence before triggering STT
        BROWSER_GRACE_PERIOD = 120   # seconds to keep session alive after browser disconnects

        def initialize(app)
          @app = app
        end

        def call(env)
          path = env['PATH_INFO']
          match = AUDIO_PATH_PATTERN.match(path)

          return @app.call(env) unless match && Faye::WebSocket.websocket?(env)

          session_id = match[1]
          handle_audio_websocket(env, session_id)
        end

        private

        def handle_audio_websocket(env, session_id)
          browser_ws = Faye::WebSocket.new(env, nil, ping: 30)
          state = ConnectionState.new

          browser_ws.on :open do |_event|
            session, error = authenticate_and_load(env, session_id)

            if error
              send_json(browser_ws, type: 'error', code: 'auth_failed', message: error, recoverable: false)
              browser_ws.close
              next
            end

            state.session = session
            start_session(browser_ws, state)
          rescue StandardError => e
            Rails.logger.error("[AudioWS] Exception in on:open: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
            browser_ws.close
          end

          browser_ws.on :message do |event|
            if event.data.is_a?(String) && !event.data.start_with?('{')
              handle_audio_frame(event.data, browser_ws, state, session_id)
            else
              handle_browser_message(event.data, browser_ws, state)
            end
          end

          browser_ws.on :close do |event|
            Rails.logger.info("[AudioWS] Browser disconnected: session=#{session_id} code=#{event.code}")
            state.silence_timer&.cancel
            schedule_graceful_end(state)
          end

          browser_ws.rack_response
        end

        def start_session(browser_ws, state)
          session = state.session

          unless session.assessment.system_prompt.present?
            Rails.logger.warn("[AudioWS] system_prompt missing for assessment #{session.assessment.id} — regenerating")
            Assessments::SystemPromptCompiler.new(session.assessment).call.tap do |prompt|
              session.assessment.update_column(:system_prompt, prompt)
            end
          end

          unless session.assessment.system_prompt.present?
            send_json(browser_ws, type: 'error', code: 'no_system_prompt',
                                  message: 'Assessment configuration is incomplete.', recoverable: false)
            browser_ws.close
            return
          end

          # Activate the session and initialize coverage maps (idempotent)
          Sessions::StartHandler.new(session).call unless session.active?

          state.turn_counter = session.transcript_turns.maximum(:turn_number).to_i

          # Initialize clients
          language = session.assessment.language || 'id-ID'
          state.stt_client = STT::GoogleClient.new(language: language)
          state.tts_client = TTS::GoogleClient.new(language: language)
          state.conversation_manager = Conversation::Manager.new(session)

          # Generate opening question
          state.model_speaking = true
          send_json(browser_ws, type: 'speaker_changed', speaker: 'ai')
          send_json(browser_ws, type: 'session_started', session_id: session.id)

          Rails.logger.info("[AudioWS] Session started — generating opening (session=#{session.id})")

          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              generate_and_speak(browser_ws, state, opening: true)
            end
          end
        end

        def handle_audio_frame(audio_data, browser_ws, state, session_id)
          # Suppress audio while AI is speaking
          if state.model_speaking
            unless state.logged_gate_suppressed
              Rails.logger.debug("[AudioWS] Audio suppressed by model_speaking gate (session=#{session_id})")
              state.logged_gate_suppressed = true
            end
            return
          end

          return if state.processing # don't accept audio while processing STT → LLM → TTS

          # Buffer audio for STT
          state.stt_client&.push_audio(audio_data)
          state.last_audio_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # Reset silence timer — candidate is still speaking
          state.silence_timer&.cancel
          state.silence_timer = EM::Timer.new(SILENCE_THRESHOLD_MS / 1000.0) do
            on_silence_detected(browser_ws, state)
          end
        end

        # Fires when candidate has been silent for SILENCE_THRESHOLD_MS.
        # This replaces Gemini's VAD + silence pump.
        def on_silence_detected(browser_ws, state)
          return unless state.stt_client&.has_audio?
          return if state.processing

          state.processing = true
          duration = state.stt_client.buffer_duration_seconds
          Rails.logger.info("[AudioWS] Silence detected — transcribing #{duration.round(1)}s of audio (session=#{state.session.id})")

          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              process_candidate_turn(browser_ws, state)
            end
          end
        end

        # Full pipeline: STT → save transcript → coverage analysis → Gemini Flash → TTS → browser
        def process_candidate_turn(browser_ws, state)
          session = state.session

          # Step 1: Transcribe
          candidate_text = state.stt_client.transcribe
          state.stt_client.clear_buffer

          unless candidate_text.present?
            Rails.logger.debug('[AudioWS] STT returned empty — ignoring')
            EM.schedule { state.processing = false }
            return
          end

          Rails.logger.info("[AudioWS] STT result: #{candidate_text.truncate(80)}")

          # Step 2: Save candidate transcript + notify browser
          turn_number = state.increment_turn!
          save_transcript_turn(session, turn_number, 'candidate', candidate_text)

          EM.schedule do
            send_json(browser_ws, type: 'transcription', speaker: 'candidate',
                                  text: candidate_text, turn_number: turn_number)
          end

          # Step 3: Trigger coverage analysis (async, doesn't block response)
          CoverageAnalyzerWorker.perform_async(session.id, turn_number)

          # Step 4: Generate AI response + speak it
          EM.schedule do
            state.model_speaking = true
            state.logged_gate_suppressed = false
            send_json(browser_ws, type: 'speaker_changed', speaker: 'ai')
          end

          generate_and_speak(browser_ws, state, candidate_text: candidate_text)

          # Step 5: Check time ceiling
          EM.schedule { check_time_ceiling(session, state, browser_ws) }
        rescue StandardError => e
          Rails.logger.error("[AudioWS] process_candidate_turn failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          EM.schedule do
            state.processing = false
            state.model_speaking = false
            send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
          end
        end

        # Generate AI response text via Gemini Flash, then synthesize and send audio.
        def generate_and_speak(browser_ws, state, candidate_text: nil, opening: false)
          session = state.session
          manager = state.conversation_manager

          # Generate text response
          ai_text = if opening
                      manager.generate_opening
                    else
                      manager.generate_response(candidate_text)
                    end

          Rails.logger.info("[AudioWS] AI response: #{ai_text.truncate(80)} (session=#{session.id})")

          # Save AI transcript
          turn_number = state.increment_turn!
          save_transcript_turn(session, turn_number, 'ai', ai_text)

          EM.schedule do
            send_json(browser_ws, type: 'transcription', speaker: 'ai',
                                  text: ai_text, turn_number: turn_number)
          end

          # Synthesize audio
          audio_bytes = state.tts_client.synthesize(ai_text)

          if audio_bytes.present?
            # Send audio to browser in chunks (matching expected frame size)
            send_audio_to_browser(browser_ws, audio_bytes)
          else
            Rails.logger.error("[AudioWS] TTS returned no audio (session=#{session.id})")
          end

          # Open mic for candidate
          EM.schedule do
            state.model_speaking = false
            state.processing = false
            send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
          end
        rescue StandardError => e
          Rails.logger.error("[AudioWS] generate_and_speak failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          EM.schedule do
            state.model_speaking = false
            state.processing = false
            send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
          end
        end

        # Send PCM audio bytes to the browser in chunks.
        # TTS returns one big buffer — we chunk it to match the browser's expected frame size.
        def send_audio_to_browser(browser_ws, audio_bytes)
          # 24kHz 16-bit PCM, ~30ms frames = 1440 samples * 2 bytes = 2880 bytes per frame
          frame_size = 2880
          offset = 0

          while offset < audio_bytes.bytesize
            chunk = audio_bytes.byteslice(offset, frame_size)
            EM.schedule do
              begin
                browser_ws.send(chunk.bytes)
              rescue StandardError => e
                Rails.logger.error("[AudioWS] Failed to send audio to browser: #{e.message}")
              end
            end
            offset += frame_size
            # Pace at ~30ms intervals so the browser's audio buffer doesn't overflow
            sleep(0.025)
          end
        end

        def handle_browser_message(data, browser_ws, state)
          message = JSON.parse(data)

          case message['type']
          when 'end_session'
            state.silence_timer&.cancel
            state.graceful_end_timer&.cancel
            state.time_ceiling_timer&.cancel
            Sessions::EndHandler.new(state.session).call(reason: 'manual_candidate')
            send_json(browser_ws, type: 'session_ended', reason: 'manual_candidate')
            browser_ws.close
          end
        rescue JSON::ParserError
          # ignore malformed control messages
        end

        def schedule_graceful_end(state)
          return unless state.session

          state.graceful_end_timer = EM::Timer.new(BROWSER_GRACE_PERIOD) do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                next if state.session.reload.ended?

                Rails.logger.info("[AudioWS] Grace period expired — ending session #{state.session.id}")
                Sessions::EndHandler.new(state.session).call(reason: 'error')
              end
            end
          end
        end

        def save_transcript_turn(session, turn_number, speaker, text)
          session.transcript_turns.create!(
            turn_number: turn_number,
            speaker: speaker,
            text: text
          )
        rescue ActiveRecord::RecordNotUnique
          # Duplicate turn — skip silently (idempotent)
        rescue StandardError => e
          Rails.logger.error("[AudioWS] Failed to save transcript turn: #{e.message}")
        end

        def check_time_ceiling(session, state, browser_ws)
          return unless session.started_at && session.assessment.time_limit_min
          return if state.ending_scheduled

          elapsed   = (Time.current - session.started_at).to_i
          limit     = session.assessment.time_limit_min * 60
          remaining = limit - elapsed

          if remaining <= 0
            state.ending_scheduled = true

            # Give AI 60s to wrap up, then force end
            state.time_ceiling_timer = EM::Timer.new(60) do
              Thread.new do
                ActiveRecord::Base.connection_pool.with_connection do
                  next if session.reload.ended?

                  Sessions::EndHandler.new(session).call(reason: 'time_ceiling')
                  EM.schedule do
                    send_json(browser_ws, type: 'session_ended', reason: 'time_ceiling')
                    browser_ws.close rescue nil
                  end
                end
              end
            end
          end
        end

        def authenticate_and_load(env, session_id)
          request = Rack::Request.new(env)

          session = begin
            invite_token = request.params['token']

            if invite_token.present?
              Session.unscoped.find_by(invite_token: invite_token)
            else
              auth_header = env['HTTP_AUTHORIZATION']
              return [nil, 'Missing authorization'] unless auth_header.present?

              token = auth_header.split(' ').last
              payload = JsonWebToken.decode(token)
              tenant_id = Organization.find_by(scheme: payload[:scheme])&.id
              return [nil, 'Invalid tenant'] unless tenant_id

              Session.unscoped.where(tenant_id: tenant_id).find_by(id: session_id)
            end
          rescue StandardError => e
            return [nil, "Authentication failed: #{e.message}"]
          end

          return [nil, 'Session not found'] unless session
          return [nil, 'Session has ended'] if session.ended?
          return [nil, 'Session ID mismatch'] if session.id.to_s != session_id

          [session, nil]
        end

        def send_json(ws, **payload)
          ws.send(payload.to_json)
        rescue StandardError => e
          level = %w[speaker_changed session_started session_ended].include?(payload[:type]) ? :warn : :debug
          Rails.logger.public_send(level, "[AudioWS] Failed to send JSON (type=#{payload[:type]}): #{e.message}")
        end

        # Simple struct to hold per-connection state.
        class ConnectionState
          attr_accessor :session, :stt_client, :tts_client, :conversation_manager,
                        :turn_counter, :model_speaking, :processing,
                        :last_audio_at, :silence_timer,
                        :ending_scheduled, :logged_gate_suppressed,
                        :graceful_end_timer, :time_ceiling_timer,
                        :sent_time_warnings

          def initialize
            @turn_counter = 0
            @model_speaking = false
            @processing = false
            @sent_time_warnings = Set.new
          end

          def increment_turn!
            @turn_counter += 1
          end
        end
      end
