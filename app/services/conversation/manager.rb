# frozen_string_literal: true

module Conversation
  # Manages AI conversation for the decoupled audio pipeline.
  # Replaces Gemini Live's integrated conversation handling.
  #
  # Builds a multi-turn prompt from conversation history + coverage map,
  # sends to Gemini Flash (text), and returns the AI's response text.
  #
  # Usage:
  #   manager = Conversation::Manager.new(session)
  #   response = manager.generate_response("I used caching to improve performance.")
  #   # => "Interesting approach. How did you handle cache invalidation?"
  class Manager
    HISTORY_TURNS = 20  # last N transcript turns to include
    MODEL = ENV.fetch('GEMINI_FLASH_MODEL', 'gemini-2.5-flash')

    def initialize(session)
      @session = session
      @system_prompt = session.assessment.system_prompt
    end

    # Generate the AI interviewer's next response given the candidate's latest text.
    # Returns the response text string.
    def generate_response(candidate_text)
      contents = build_contents(candidate_text)

      body = {
        systemInstruction: { parts: [{ text: @system_prompt }] },
        contents: contents,
        generationConfig: {
          temperature: 0.7,
          maxOutputTokens: 300  # keep responses short (1-3 sentences)
        }
      }

      response = connection.post(generate_url, body.to_json, request_headers)
      parse_response(response)
    end

    # Generate the opening question (no candidate text yet).
    def generate_opening
      body = {
        systemInstruction: { parts: [{ text: @system_prompt }] },
        contents: [
          { role: 'user', parts: [{ text: '[Interview starting. Greet the candidate and ask your first question.]' }] }
        ],
        generationConfig: {
          temperature: 0.7,
          maxOutputTokens: 500
        }
      }

      response = connection.post(generate_url, body.to_json, request_headers)
      parse_response(response)
    end

    private

    def build_contents(candidate_text)
      contents = []

      # Load conversation history from DB
      turns = @session.transcript_turns.ordered.last(HISTORY_TURNS)
      turns.each do |turn|
        role = turn.speaker == 'ai' ? 'model' : 'user'
        contents << { role: role, parts: [{ text: turn.text }] }
      end

      # Append the candidate's latest turn + coverage map as context
      coverage_text = build_coverage_context
      user_text = candidate_text
      user_text = "#{candidate_text}\n\n#{coverage_text}" if coverage_text.present?

      contents << { role: 'user', parts: [{ text: user_text }] }

      # Gemini requires alternating roles — merge consecutive same-role turns
      merge_consecutive_roles(contents)
    end

    def build_coverage_context
      injector = Coverage::MapInjector.new(@session)
      injector.injection_text
    rescue StandardError => e
      Rails.logger.error("[Conversation::Manager] Coverage context failed: #{e.message}")
      nil
    end

    # Gemini API requires alternating user/model roles.
    # If consecutive turns have the same role, merge their text.
    def merge_consecutive_roles(contents)
      return contents if contents.empty?

      merged = [contents.first]
      contents[1..].each do |turn|
        if merged.last[:role] == turn[:role]
          # Merge text into previous turn
          existing_text = merged.last[:parts].first[:text]
          new_text = turn[:parts].first[:text]
          merged.last[:parts] = [{ text: "#{existing_text}\n\n#{new_text}" }]
        else
          merged << turn
        end
      end
      merged
    end

    def generate_url
      location   = Gemini::VertexAuth.location
      project_id = Gemini::VertexAuth.project_id
      "https://#{location}-aiplatform.googleapis.com/v1/projects/#{project_id}" \
        "/locations/#{location}/publishers/google/models/#{MODEL}:generateContent"
    end

    def request_headers
      token = Gemini::VertexAuth.access_token
      {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{token}"
      }
    end

    def connection
      @connection ||= Faraday.new do |f|
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
        Rails.logger.error("[Conversation::Manager] API returned #{response.status}: #{response.body[0..300]}")
        raise "Gemini Flash API error: #{response.status}"
      end

      data = JSON.parse(response.body)
      text = data.dig('candidates', 0, 'content', 'parts', 0, 'text')

      raise 'No content in Gemini response' unless text.present?

      text.strip
    end
  end
end
