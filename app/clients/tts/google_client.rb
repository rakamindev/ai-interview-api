# frozen_string_literal: true

require 'faraday'
require 'base64'
require 'json'

module TTS
  # Google Cloud Text-to-Speech client (REST).
  #
  # Synthesizes text into LINEAR16 PCM audio for playback in the browser.
  #
  # Usage:
  #   client = TTS::GoogleClient.new(language: 'id-ID')
  #   pcm_bytes = client.synthesize("Thank you for sharing that.")
  class GoogleClient
    # Output audio: 24kHz LINEAR16 PCM — matches the browser's playback sample rate
    # (same as what Gemini Live used to send).
    OUTPUT_SAMPLE_RATE = 24_000

    def initialize(language: 'id-ID', voice_name: nil)
      @language = language
      @voice_name = voice_name || default_voice_for(language)
      @connection = build_connection
    end

    # Synthesize text into PCM audio bytes.
    # Returns raw LINEAR16 PCM bytes (24kHz), or nil on error.
    def synthesize(text)
      return nil if text.blank?

      body = {
        input: { text: text },
        voice: {
          languageCode: @language,
          name: @voice_name
        },
        audioConfig: {
          audioEncoding: 'LINEAR16',
          sampleRateHertz: OUTPUT_SAMPLE_RATE
        }
      }

      response = @connection.post(synthesize_url, body.to_json, request_headers)

      parse_response(response)
    rescue Faraday::Error => e
      Rails.logger.error("[TTS::GoogleClient] API error: #{e.class}: #{e.message}")
      nil
    end

    private

    def synthesize_url
      'https://texttospeech.googleapis.com/v1/text:synthesize'
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
        f.options.timeout = 15
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end

    def parse_response(response)
      unless response.success?
        Rails.logger.error("[TTS::GoogleClient] API returned #{response.status}: #{response.body[0..200]}")
        return nil
      end

      data = JSON.parse(response.body)
      audio_base64 = data['audioContent']

      return nil unless audio_base64.present?

      Base64.strict_decode64(audio_base64)
    end

    # Natural-sounding voices per language.
    def default_voice_for(language)
      case language
      when /^id/
        'id-ID-Chirp3-HD-Charon'
      when /^en/
        'en-US-Chirp3-HD-Charon'
      else
        "#{language}-Chirp3-HD-Charon"
      end
    end
  end
end
