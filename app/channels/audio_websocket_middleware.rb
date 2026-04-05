      # frozen_string_literal: true

      require 'faye/websocket'
      require 'set'

      # Rack middleware that handles WebSocket connections at /ws/sessions/:id/audio.
      # Acts as a bidirectional proxy between the browser (PCM audio) and Gemini Live API.
      #
      # Audio flow:
      #   Browser (16kHz PCM) → this middleware → Gemini Live
      #   Gemini Live (24kHz PCM) → this middleware → Browser
      #
      # Audio is buffered in a ring buffer for reconnection replay.
      class AudioWebSocketMiddleware
        AUDIO_PATH_PATTERN = %r{\A/ws/sessions/([^/]+)/audio\z}

        MAX_RECONNECT_ATTEMPTS = 3
        RECONNECT_BACKOFF = [1, 2, 4].freeze
        BROWSER_GRACE_PERIOD = 120       # seconds to keep Gemini alive after browser disconnects
        PROACTIVE_RECONNECT_AFTER = 510  # seconds (~8.5 min) — reconnect before Gemini's 10-min limit
        PROACTIVE_RECONNECT_JITTER = 30  # randomise to avoid thundering herd across concurrent sessions
        AUDIO_BUFFER_SECONDS = 60        # ring buffer capacity per session

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
              browser_ws.send({ type: 'error', code: 'auth_failed', message: error, recoverable: false }.to_json)
              browser_ws.close
              next
            end

            state.session = session
            connect_to_gemini(browser_ws, state)
          rescue StandardError => e
            Rails.logger.error("[AudioWS] Exception in on:open: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
            browser_ws.close
          end

          browser_ws.on :message do |event|
            if event.data.is_a?(String) && !event.data.start_with?('{')
              # Binary frames are raw PCM audio — always buffer, forward only when Gemini is ready.
              # During reconnection gaps the frame stays in the buffer and gets replayed after reconnect.
              state.audio_buffer.push(event.data)
              if state.model_speaking
                # Server-side audio gate: suppress mic audio while the model is
                # speaking. This prevents speaker echo from reaching Gemini's VAD,
                # which would cause it to interrupt itself and loop.
                unless state.logged_gate_suppressed
                  Rails.logger.warn("[AudioWS] Audio suppressed by model_speaking gate (session=#{session_id})")
                  state.logged_gate_suppressed = true
                end
                next
              elsif state.gemini_client&.accepting_audio?
                state.logged_gate_suppressed = false
                state.gemini_client.send_audio(event.data)
              else
                # Log once per gap to avoid spam (~33 chunks/s during reconnection)
                unless state.logged_not_ready
                  Rails.logger.warn("[AudioWS] Audio received but Gemini not ready — buffering (accepting=#{state.gemini_client&.accepting_audio?} connected=#{state.gemini_client&.connected})")
                  state.logged_not_ready = true
                end
              end
            else
              # JSON control messages (e.g., end signal from browser)
              handle_browser_message(event.data, browser_ws, state)
            end
          end

          browser_ws.on :close do |event|
            Rails.logger.info("[AudioWS] Browser disconnected: session=#{session_id} code=#{event.code}")
            state.browser_disconnected_at = Time.current
            state.proactive_reconnect_timer&.cancel

            # Keep Gemini alive for grace period (candidate may reconnect via page refresh)
            schedule_graceful_end(browser_ws, state)
          end

          browser_ws.rack_response
        end

        def connect_to_gemini(browser_ws, state)
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

          # Pre-compute coverage cache so the first candidate turn has context
          # to inject immediately (no stale/empty cache on turn 1).
          injector = Coverage::MapInjector.new(session)
          state.cached_coverage_text = injector.injection_text
          state.last_coverage_digest = injector.coverage_fingerprint

          build_gemini_client(browser_ws, state)
          state.gemini_client.connect(resumption_handle: session.gemini_resumption_token.presence)
        end

        def build_gemini_client(browser_ws, state)
          session = state.session

          state.gemini_client = Gemini::LiveClient.new(
            system_prompt: session.assessment.system_prompt,

            on_audio: lambda { |pcm_bytes|
              # Signal model-speaking on the first audio frame of a turn so the
              # frontend mutes the mic immediately, preventing speaker feedback.
              unless state.model_speaking
                state.model_speaking = true
                state.ai_audio_chunks = 0
                Rails.logger.info('[AudioWS] AI audio started — sending speaker_changed:ai')
                send_json(browser_ws, type: 'speaker_changed', speaker: 'ai')
              end

              state.ai_audio_chunks = (state.ai_audio_chunks || 0) + 1

              # Forward Gemini audio to browser immediately — no buffering
              begin
                browser_ws.send(pcm_bytes.bytes)
              rescue StandardError => e
                Rails.logger.error("[AudioWS] Failed to send audio to browser: #{e.class}: #{e.message}")
              end
            },

            # Fires once per complete candidate turn (accumulated full sentence)
            on_input_transcription: lambda { |text|
              next unless text.present?

              turn_number = state.increment_turn!
              gemini_ref  = state.gemini_client

              # Inject coverage map via realtimeInput.text.
              # On Gemini 3.1, this can be sent anytime — no guards needed.
              # No dual-voice risk, no 1008, no empty generations.
              current_digest = state.last_coverage_digest
              if state.cached_coverage_text.present? &&
                 current_digest != state.last_injected_digest
                gemini_ref.inject_context(state.cached_coverage_text)
                state.last_injected_digest = current_digest
                Rails.logger.debug("[AudioWS] Coverage injected (digest=#{current_digest&.slice(0, 8)})")
              end

              # Push DB writes off the EM thread so we don't stall audio forwarding.
              # Also refresh the coverage cache for the NEXT turn.
              Thread.new do
                ActiveRecord::Base.connection_pool.with_connection do
                  save_transcript_turn(session, turn_number, 'candidate', text)
                  CoverageAnalyzerWorker.perform_async(session.id, turn_number)
                  refresh_coverage_cache(session, state)
                end
              end

              # Notify browser immediately (no DB dependency)
              send_json(browser_ws, type: 'transcription', speaker: 'candidate',
                                    text: text, turn_number: turn_number)

              check_time_ceiling(session, state, browser_ws)
            },

            on_output_transcription: lambda { |text|
              next unless text.present?

              # Strip coverage/time metadata that leaks into output transcription.
              # Gemini 3.1's realtimeInput.text content echoes in outputTranscription.
              text = text.gsub(/\[COVERAGE_MAP\].*?\[\/COVERAGE_MAP\]/m, '').strip
              text = text.gsub(/\{[^}]*"skills"\s*:.*?"time_remaining_minutes"\s*:\s*\d+\s*\}/m, '').strip
              text = text.gsub(/\[TIME CONTROL[^\]]*\][^\n]*/m, '').strip
              text = text.gsub(/\[Start the interview[^\]]*\]/m, '').strip
              next unless text.present?

              turn_number = state.increment_turn!

              Thread.new do
                ActiveRecord::Base.connection_pool.with_connection do
                  save_transcript_turn(session, turn_number, 'ai', text)
                end
              end

              send_json(browser_ws, type: 'transcription', speaker: 'ai',
                                    text: text, turn_number: turn_number)

              # Check time ceiling after AI turn too — so the session ends even if
              # the candidate stops talking after the AI's closing statement.
              check_time_ceiling(session, state, browser_ws)

              # Auto-end disabled — session ends when candidate clicks "End Interview"
              # or time ceiling is reached. Coverage-based auto-end is in backlog.
            },

            # Fires after the model's turnComplete — all audio frames have been sent,
            # so it's safe to tell the frontend to unmute the mic.
            on_model_turn_complete: lambda {
              Rails.logger.info("[AudioWS] Model turn complete — ai_audio_chunks=#{state.ai_audio_chunks || 0} sending speaker_changed:candidate")
              state.model_speaking = false
              state.ai_audio_chunks = 0

              send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
            },

            on_go_away: lambda { |time_left:, resumption_token:|
              handle_go_away(browser_ws, state, resumption_token)
            },

            on_close: lambda { |code:, reason:|
              handle_gemini_close(browser_ws, state, code: code, reason: reason)
            },

            on_error: lambda { |message|
              Rails.logger.error("[AudioWS] Gemini error: session=#{session.id} #{message}")
            },

            on_resumption_token_update: lambda { |token|
              state.latest_resumption_token = token

              # Debounce DB writes — Gemini rotates the token every turn, but we only
              # need it persisted as crash-recovery. Write at most once per 60 seconds.
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              next if state.last_token_persisted_at && (now - state.last_token_persisted_at) < 60

              state.last_token_persisted_at = now
              Thread.new do
                ActiveRecord::Base.connection_pool.with_connection do
                  session.update_column(:gemini_resumption_token, token)
                end
              end
            },

            on_ready: lambda {
              state.logged_not_ready = false
              if state.reconnecting
                Rails.logger.info("[AudioWS] Gemini reconnected for session #{session.id}")
                if state.full_reconnect_pending
                  state.full_reconnect_pending = false
                  restore_conversation_context(browser_ws, state)
                else
                  replay_buffered_audio(state)
                end
                state.reconnect_start_at = nil
                state.reconnecting = false
                state.reconnect_attempts = 0
              else
                Rails.logger.info("[AudioWS] Gemini ready — sending session_started for session #{session.id}")
                unless session.gemini_resumption_token.present?
                  # Gate candidate audio BEFORE trigger_opening so the browser's
                  # mic input doesn't reach Gemini and interrupt the AI's opening
                  # response before it produces any audio. Without this, the
                  # realtimeInput frames cause Gemini to abort generation → empty
                  # generationComplete → no AI response at all.
                  state.model_speaking = true
                  send_json(browser_ws, type: 'speaker_changed', speaker: 'ai')
                  state.gemini_client.trigger_opening
                end
                send_json(browser_ws, type: 'session_started', session_id: session.id)
              end

              schedule_proactive_reconnect(browser_ws, state)
            }
          )
        end

        # Handles Gemini GoAway — transparent reconnection using resumption token.
        # Audio is buffered during the gap and replayed once the new connection is ready.
        def handle_go_away(browser_ws, state, resumption_token)
          session = state.session
          return unless resumption_token.present?

          Rails.logger.info("[AudioWS] GoAway received for session #{session.id} — reconnecting")

          state.proactive_reconnect_timer&.cancel
          state.reconnect_start_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          state.reconnecting = true

          # Notify browser if AI was speaking so frontend unmutes mic (H2 fix).
          # Without this, the frontend stays in "ai speaking" state and the
          # candidate's mic remains muted after reconnection completes.
          if state.model_speaking
            state.model_speaking = false
            send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
          end

          state.latest_resumption_token = resumption_token

          session.update_column(:gemini_resumption_token, resumption_token)

          old_client = state.gemini_client
          old_client&.supersede!

          build_gemini_client(browser_ws, state)
          state.gemini_client.connect(resumption_handle: resumption_token)
          old_client&.close
        end

        # Handles unexpected Gemini WebSocket close (not GoAway).
        # Audio is buffered during the gap and replayed once the new connection is ready.
        def handle_gemini_close(browser_ws, state, code:, reason:)
          # Normal close (code=1000) is intentional (e.g., gemini_client.close) —
          # don't retry. But inactivity_close and resumption_failed are error cases
          # that happen to use code=1000; those DO need retry.
          return if code == 1000 && !state.gemini_client&.inactivity_close && !state.gemini_client&.resumption_failed

          state.proactive_reconnect_timer&.cancel
          state.reconnect_attempts ||= 0

          if state.reconnect_attempts < MAX_RECONNECT_ATTEMPTS
            backoff = RECONNECT_BACKOFF[state.reconnect_attempts] || 4
            state.reconnect_attempts += 1
            # Record gap start only once — subsequent retries keep the original timestamp
            # so the full gap is replayed even across multiple backoff attempts.
            state.reconnect_start_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
            state.reconnecting = true

            Rails.logger.warn("[AudioWS] Gemini closed unexpectedly (code=#{code}) — retry #{state.reconnect_attempts}/#{MAX_RECONNECT_ATTEMPTS} in #{backoff}s")
            if state.model_speaking
              state.model_speaking = false
              # Unmute the browser mic — AI was speaking when the connection dropped.
              # Without this, the browser stays muted and sends no audio to the new session.
              send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
            end

            # If resumption failed, the token is stale — clear it so the next
            # retry does a fresh connect instead of looping through the same timeout.
            resumption_failed = state.gemini_client&.resumption_failed
            if resumption_failed
              state.latest_resumption_token = nil
              state.session.update_column(:gemini_resumption_token, nil)
              # Mark that the next reconnect is a fresh Gemini session (no history).
              # on_ready will inject transcript context instead of replaying audio.
              state.full_reconnect_pending = true
            end

            expected_client = state.gemini_client
            EM.add_timer(backoff) do
              # Skip if another reconnection already replaced this client, or the session ended
              next unless state.gemini_client.equal?(expected_client)
              next if state.session.ended?

              state.gemini_client&.supersede!
              build_gemini_client(browser_ws, state)
              token = resumption_failed ? nil : (state.latest_resumption_token || state.session.gemini_resumption_token.presence)
              state.gemini_client.connect(resumption_handle: token, seed_history: resumption_failed)
            end
          else
            Rails.logger.error("[AudioWS] Gemini reconnection failed after #{MAX_RECONNECT_ATTEMPTS} attempts")
            Sessions::EndHandler.new(state.session).call(reason: 'error')
            send_json(browser_ws, type: 'session_ended', reason: 'error',
                                  message: 'The session encountered a problem. Please contact the interviewer.')

            browser_ws.close
          end
        end

        def handle_browser_message(data, browser_ws, state)
          message = JSON.parse(data)

          case message['type']
          when 'end_session'
            state.proactive_reconnect_timer&.cancel
            state.graceful_end_timer&.cancel
            state.time_ceiling_timer&.cancel
            state.coverage_end_timer&.cancel
            state.audio_buffer.clear
            Sessions::EndHandler.new(state.session).call(reason: 'manual_candidate')
            send_json(browser_ws, type: 'session_ended', reason: 'manual_candidate')
            state.gemini_client&.close
            browser_ws.close
          end
        rescue JSON::ParserError
          # ignore malformed control messages
        end

        # Schedules a proactive Gemini reconnect ~8.5 minutes into the current connection,
        # before Gemini's 10-minute hard limit can cause a disruptive 1011 close.
        def schedule_proactive_reconnect(browser_ws, state)
          state.proactive_reconnect_timer&.cancel
          delay = PROACTIVE_RECONNECT_AFTER + rand(PROACTIVE_RECONNECT_JITTER)
          state.proactive_reconnect_timer = EM::Timer.new(delay) do
            initiate_proactive_reconnect(browser_ws, state)
          end
          Rails.logger.info("[AudioWS] Proactive reconnect scheduled in #{delay}s for session #{state.session.id}")
        end

        # Starts a new Gemini connection while the old one is still live, then swaps
        # them in on_ready. Audio buffered during the brief overlap is replayed.
        def initiate_proactive_reconnect(browser_ws, state)
          if state.reconnecting
            Rails.logger.info("[AudioWS] Proactive reconnect skipped — already reconnecting (session #{state.session.id})")
            return
          end

          token = state.latest_resumption_token || state.session.gemini_resumption_token.presence

          unless token.present?
            sid = state.session.id
            Rails.logger.warn("[AudioWS] Proactive reconnect: no token yet, rescheduling (session #{sid})")
            schedule_proactive_reconnect(browser_ws, state)
            return
          end

          Rails.logger.info("[AudioWS] Initiating proactive reconnect for session #{state.session.id}")
          state.reconnect_start_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          state.reconnecting = true

          # Notify browser if AI was speaking so frontend unmutes mic (H2 fix).
          if state.model_speaking
            state.model_speaking = false
            send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
          end

          state.session.update_column(:gemini_resumption_token, token)

          old_client = state.gemini_client
          old_client&.supersede!
          build_gemini_client(browser_ws, state)
          state.gemini_client.connect(resumption_handle: token)
          # Close old client after new one is set up to avoid any gap
          EM.add_timer(2) { old_client&.close }
        end

        # Replays buffered audio chunks captured since reconnect_start_at to the
        # new Gemini connection. Gemini's VAD handles any brief overlap gracefully.
        def replay_buffered_audio(state)
          return unless state.reconnect_start_at

          chunks = state.audio_buffer.since(state.reconnect_start_at)
          return if chunks.empty?

          total = chunks.sum { |c| c.data.bytesize }
          Rails.logger.info("[AudioWS] Replaying #{chunks.size} audio chunks (#{total}B) for session #{state.session.id}")
          # Pace replay at ~30ms intervals (matching audio worklet frame size) to avoid
          # overwhelming Gemini's WebSocket buffer with a burst and confusing its VAD.
          chunks.each_with_index do |chunk, i|
            EM.add_timer(i * 0.03) { state.gemini_client&.send_audio(chunk.data) }
          end
        end

        # On a full reconnect (resumption token expired/failed), Gemini has no
        # conversation history. Seed it via clientContent (Gemini 3.1 historyConfig).
        # This is the proper way to restore context — Gemini treats these as
        # actual conversation history, not as new user input.
        def restore_conversation_context(browser_ws, state)
          session = state.session
          gemini  = state.gemini_client

          state.model_speaking = true
          send_json(browser_ws, type: 'speaker_changed', speaker: 'ai')

          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              turns = session.transcript_turns.ordered.last(12)

              if turns.any?
                last_speaker = turns.last.speaker
                history_turns = turns.map do |t|
                  { role: t.speaker == 'ai' ? 'model' : 'user', text: t.text }
                end

                sid = session.id
                Rails.logger.info("[AudioWS] Seeding #{turns.size} history turns for full reconnect (session=#{sid}, last=#{last_speaker})")

                EM.schedule do
                  gemini&.seed_conversation_history(history_turns)

                  if last_speaker == 'ai'
                    # AI already asked — open mic for candidate
                    state.model_speaking = false
                    send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
                  end
                  # If last speaker was candidate, Gemini will respond naturally
                  # after processing the seeded history (model_speaking stays true
                  # until on_model_turn_complete fires).
                end
              else
                sid = session.id
                Rails.logger.info("[AudioWS] Full reconnect with no transcript (session=#{sid})")
                EM.schedule { gemini&.trigger_opening }
              end
            end
          rescue StandardError => e
            Rails.logger.error("[AudioWS] restore_conversation_context failed: #{e.class}: #{e.message}")
            EM.schedule do
              state.model_speaking = false
              send_json(browser_ws, type: 'speaker_changed', speaker: 'candidate')
            end
          end
        end

        # H3 fix: EM.add_timer instead of Thread.new+sleep. The timer is
        # cancellable (e.g., if the session ends during the grace period) and
        # doesn't hold a Ruby thread for 2 minutes doing nothing.
        def schedule_graceful_end(browser_ws, state)
          return unless state.session

          state.graceful_end_timer = EM::Timer.new(BROWSER_GRACE_PERIOD) do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                next if state.session.reload.ended?

                Rails.logger.info("[AudioWS] Grace period expired — ending session #{state.session.id}")
                Sessions::EndHandler.new(state.session).call(reason: 'error')
                EM.schedule { state.gemini_client&.close }
              end
            end
          end
        end

        # Refreshes the cached coverage text for the next turn.
        # Called from a background thread after each candidate turn.
        # The cached text is injected synchronously on the EM thread in
        # on_input_transcription to avoid the race where a delayed injection
        # triggers a second Gemini response.
        def refresh_coverage_cache(session, state)
          started  = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
          injector = Coverage::MapInjector.new(session)

          fingerprint = injector.coverage_fingerprint
          if state.last_coverage_digest == fingerprint
            Rails.logger.debug("[AudioWS] Coverage unchanged — cache still valid (session=#{session.id})")
            return
          end

          # Compute the full text while still on the background thread (DB query + serialization).
          text    = injector.injection_text
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started

          # Assign both values atomically on the EM thread so on_input_transcription
          # never sees a new digest paired with stale text. Without this, a GVL preemption
          # between the two assignments lets the EM thread inject old text under the new
          # digest — and the fresh text is then permanently skipped (C1 in audit report).
          EM.schedule do
            state.last_coverage_digest = fingerprint
            state.cached_coverage_text = text
          end

          Rails.logger.warn("[AudioWS] Coverage cache refresh slow: #{elapsed}ms (session=#{session.id})") if elapsed > 50
          Rails.logger.debug("[AudioWS] Coverage cache refreshed in #{elapsed}ms")
        rescue StandardError => e
          Rails.logger.error("[AudioWS] Coverage cache refresh failed: #{e.message}")
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

          gemini_client = state.gemini_client
          elapsed   = (Time.current - session.started_at).to_i
          limit     = session.assessment.time_limit_min * 60
          remaining = limit - elapsed

          if remaining <= 0
            # Only mark :ceiling as sent if inject_context actually delivered it.
            # If the silence pump is active, inject_context returns false and the
            # warning will be retried on the next transcription event (C2 fix).
            unless state.sent_time_warnings.include?(:ceiling)
              if gemini_client.inject_context('[TIME CONTROL — DO NOT SPEAK THIS] { "time_warning": true, "wrap_up": true }')
                state.sent_time_warnings.add(:ceiling)
              end
            end

            state.ending_scheduled = true

            # H3 fix: EM timer instead of Thread.new+sleep — cancellable and
            # doesn't hold a thread for 60s. Thread.new only lives as long as
            # the DB call takes.
            state.time_ceiling_timer = EM::Timer.new(60) do
              Thread.new do
                ActiveRecord::Base.connection_pool.with_connection do
                  next if session.reload.ended?

                  Sessions::EndHandler.new(session).call(reason: 'time_ceiling')
                  EM.schedule do
                    send_json(browser_ws, type: 'session_ended', reason: 'time_ceiling')
                    gemini_client&.close
                    begin
                      browser_ws.close
                    rescue StandardError
                      nil
                    end
                  end
                end
              end
            end
          elsif remaining <= 60 && !state.sent_time_warnings.include?(:warn_60)
            if gemini_client.inject_context('[TIME CONTROL — DO NOT SPEAK THIS] { "wrap_up": true }')
              state.sent_time_warnings.add(:warn_60)
            end
          elsif remaining <= 120 && !state.sent_time_warnings.include?(:warn_120)
            if gemini_client.inject_context('[TIME CONTROL — DO NOT SPEAK THIS] { "time_warning": true }')
              state.sent_time_warnings.add(:warn_120)
            end
          end
        end

        def authenticate_and_load(env, session_id)
          request = Rack::Request.new(env)

          session = begin
            invite_token = request.params['token']

            if invite_token.present?
              # Candidate using invite token
              Session.unscoped.find_by(invite_token: invite_token)
            else
              # Assessor using JWT
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
          # Log speaker_changed / session_ended failures at WARN — these are
          # critical for frontend state and silent delivery failures cause the
          # mic to stay muted (the exact symptom we debug most often).
          level = %w[speaker_changed session_started session_ended].include?(payload[:type]) ? :warn : :debug
          Rails.logger.public_send(level, "[AudioWS] Failed to send JSON (type=#{payload[:type]}): #{e.message}")
        end

        # Simple struct to hold per-connection state across callbacks.
        class ConnectionState
          attr_accessor :session, :gemini_client, :turn_counter,
                        :reconnect_attempts, :browser_disconnected_at,
                        :audio_buffer, :proactive_reconnect_timer,
                        :reconnect_start_at, :latest_resumption_token,
                        :reconnecting, :last_token_persisted_at,
                        :ending_scheduled, :logged_not_ready,
                        :model_speaking, :last_coverage_digest,
                        :sent_time_warnings, :ai_audio_chunks,
                        :cached_coverage_text, :last_injected_digest,
                        :logged_gate_suppressed, :full_reconnect_pending,
                        :graceful_end_timer, :time_ceiling_timer,
                        :coverage_end_timer

          def initialize
            @turn_counter = 0
            @reconnect_attempts = 0
            @reconnecting = false
            @model_speaking = false
            @sent_time_warnings = Set.new
            @audio_buffer = AudioRingBuffer.new(capacity_seconds: AudioWebSocketMiddleware::AUDIO_BUFFER_SECONDS)
          end

          def increment_turn!
            @turn_counter += 1
          end
        end
      end
