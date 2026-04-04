# frozen_string_literal: true

require 'faraday'
require 'base64'
require 'json'

module STT
  # Google Cloud Speech-to-Text V2 client (REST).
  #
  # Buffers audio frames and transcribes on demand (when silence is detected).
  # The middleware handles silence detection and calls `transcribe` when ready.
  #
  # Usage:
  #   client = STT::GoogleClient.new(language: 'id-ID')
  #   client.push_audio(pcm_bytes)   # called per frame during speech
  #   client.push_audio(pcm_bytes)
  #   text = client.transcribe        # called when silence detected
  #   client.clear_buffer              # reset for next turn
  class GoogleClient
    SAMPLE_RATE = 16_000
    ENCODING = 'LINEAR16'

    def initialize(language: 'id-ID')
      @language = language
      @audio_buffer = +''
      @connection = build_connection
    end

    # Buffer a PCM audio frame. Called for each frame during candidate speech.
    def push_audio(pcm_bytes)
      @audio_buffer << pcm_bytes
    end

    # Returns the current buffer size in seconds.
    def buffer_duration_seconds
      # 16-bit PCM at 16kHz = 2 bytes per sample, 16000 samples per second
      @audio_buffer.bytesize / (2.0 * SAMPLE_RATE)
    end

    # Transcribe the buffered audio via Google Cloud STT REST API.
    # Returns the transcribed text, or nil if nothing was recognized.
    def transcribe
      return nil if @audio_buffer.empty?

      audio_base64 = Base64.strict_encode64(@audio_buffer)

      body = {
        config: {
          languageCodes: [@language],
          model: 'long',
          features: {
            enableAutomaticPunctuation: true
          },
          autoDecodingConfig: {}
        },
        content: audio_base64,
        uri: nil
      }.compact

      response = @connection.post(recognize_url, body.to_json, request_headers)

      parse_response(response)
    rescue Faraday::Error => e
      Rails.logger.error("[STT::GoogleClient] API error: #{e.class}: #{e.message}")
      nil
    end

    # Clear the audio buffer for the next turn.
    def clear_buffer
      @audio_buffer = +''
    end

    # Check if there's audio to transcribe.
    def has_audio?
      @audio_buffer.bytesize > 0
    end

    private

    def recognize_url
      project  = Gemini::VertexAuth.project_id
      location = Gemini::VertexAuth.location
      # Use the default recognizer
      "https://#{location}-speech.googleapis.com/v2/projects/#{project}/locations/#{location}/recognizers/_:recognize"
    end

    def request_headers
      token = Gemini::VertexAuth.access_token
      {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{token}"
      }
    end

    def build_connection
      Faraday.new do |f|
        f.request :retry, {
          max: 2,
          interval: 0.5,
          retry_statuses: [429, 500, 502, 503]
        }
        f.options.timeout = 30
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end

    def parse_response(response)
      unless response.success?
        Rails.logger.error("[STT::GoogleClient] API returned #{response.status}: #{response.body[0..200]}")
        return nil
      end

      data = JSON.parse(response.body)
      results = data['results'] || []

      # Combine all result alternatives into one transcription
      text = results.filter_map do |result|
        result.dig('alternatives', 0, 'transcript')
      end.join(' ')

      text.strip.presence
    end
  end
end
