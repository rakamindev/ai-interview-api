# frozen_string_literal: true

module Api
  module V1
    # Candidate device check. No JWT — the candidate runs this before joining
    # with only an invite link, so thresholds are served publicly (they are not
    # sensitive) and the tenant is resolved from the request scheme when present.
    class PreflightController < ApiController
      skip_before_action :require_tenant!

      # GET /api/v1/preflight/config
      # Thresholds the frontend enforces during the device check.
      def config
        json_response(preflight: AppConfig.public_values(tenant_id: resolved_tenant_id))
      end

      # POST /api/v1/preflight/speed_test
      # Accepts any payload, discards it, echoes the byte count so the client
      # can compute upload throughput. Also returns the thresholds so a single
      # round trip is enough to decide pass/fail.
      def speed_test
        bytes = request.content_length.to_i

        json_response(
          received_bytes: bytes,
          preflight:      AppConfig.public_values(tenant_id: resolved_tenant_id)
        )
      end

      private

      def resolved_tenant_id
        Current.tenant_id
      rescue StandardError
        nil
      end
    end
  end
end
