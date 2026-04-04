# frozen_string_literal: true

require 'googleauth'

module Gemini
  # Manages Google Cloud OAuth2 authentication using service account credentials.
  # Used by HttpClient (Vertex AI), STT, and TTS clients.
  # Tokens are cached and auto-refreshed when expired.
  class VertexAuth
    SCOPE = 'https://www.googleapis.com/auth/cloud-platform'

    class << self
      def access_token
        credentials.fetch_access_token!['access_token']
      end

      def project_id
        ENV.fetch('VERTEX_AI_PROJECT_ID')
      end

      def location
        ENV.fetch('VERTEX_AI_LOCATION', 'us-central1')
      end

      def credentials_path
        ENV.fetch('VERTEX_AI_CREDENTIALS')
      end

      private

      def credentials
        @credentials ||= begin
          Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: File.open(credentials_path),
            scope: SCOPE
          )
        end
      end
    end
  end
end
