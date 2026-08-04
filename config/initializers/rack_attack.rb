# frozen_string_literal: true

class Rack::Attack
  # Use Redis for distributed throttle state across pods.
  #
  # Short timeouts and an error handler so a Redis outage degrades to
  # "no rate limiting" instead of hanging every request — throttling is a
  # safety net, not something worth taking the API down for. Without this,
  # an unreachable Redis blocks the candidate's very first request.
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
    url:                ENV.fetch('REDIS_URL', 'redis://localhost:6379/1'),
    connect_timeout:    1,
    read_timeout:       1,
    write_timeout:      1,
    reconnect_attempts: 1,
    error_handler:      lambda { |method:, returning:, exception:|
      Rails.logger.error("[RackAttack] Redis unavailable (#{method}, returning #{returning.inspect}): " \
                         "#{exception.class}: #{exception.message} — failing open")
    }
  )

  # Throttle login attempts: 5 per minute per IP.
  throttle('auth/login', limit: 5, period: 1.minute) do |req|
    req.ip if req.path == '/api/v1/auth/login' && req.post?
  end

  # Throttle candidate-facing endpoints: 30 per minute per IP.
  throttle('candidate/session', limit: 30, period: 1.minute) do |req|
    req.ip if req.path.match?(%r{\A/api/v1/sessions/[^/]+/(candidate|audio_complete)\z})
  end

  # Throttle the unauthenticated preflight endpoints: they move real bytes
  # (speed test payloads), so cap them well above a normal device check —
  # which runs 3 download + 3 upload measurements — but far below abuse.
  # TEMPORARILY DISABLED FOR DIAGNOSIS

  # Return 429 JSON instead of the default plain-text response.
  self.throttled_responder = lambda do |_req|
    [
      429,
      { 'Content-Type' => 'application/json' },
      [{ error: 'Too many requests. Please try again later.' }.to_json]
    ]
  end
end
