# frozen_string_literal: true

require 'googleauth'

module Gemini
  # Manages Vertex AI OAuth2 authentication using service account credentials.
  # Tokens are cached and auto-refreshed when expired.
  #
  # Usage:
  #   token = Gemini::VertexAuth.access_token
  #   # => "ya29.c.c0ASRK0G..."
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

      private

      def credentials
        @credentials ||= begin
          creds_path = ENV.fetch('VERTEX_AI_CREDENTIALS')
          Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: File.open(creds_path),
            scope: SCOPE
          )
        end
      end
    end
  end
end
