# frozen_string_literal: true

require 'digest'

module Coverage
  # Builds the coverage map JSON payload for injection into Gemini Live context.
  # Called synchronously before each AI response — must be < 50ms.
  class MapInjector
    def initialize(session)
      @session = session
    end

    # Returns a fingerprint of coverage state only (excludes time_remaining so
    # a pure clock tick doesn't trigger a redundant re-injection).
    #
    # The wrap-up hold IS included: once every skill is covered the analyzer
    # freezes them, so nothing else in this digest can ever change again. Without
    # the flag the cache would never refresh and the session would never notice
    # that the hold has expired.
    def coverage_fingerprint
      maps = @session.coverage_maps.order(:id)
      parts = maps.map { |m| "#{m.id}:#{m.state}:#{m.probe_count}" }
      parts << "hold:#{wrap_up_held?}"
      Digest::MD5.hexdigest(parts.join(','))
    end

    # Returns the formatted injection string to send via realtimeInput.text.
    def injection_text
      maps = @session.coverage_maps.includes(:session)
      configured = maps.configured.order(:id)
      discovered = maps.discovered.order(:id)

      remaining_min  = time_remaining_minutes
      skills_left    = skills_remaining(configured)
      avg_min        = avg_minutes_per_remaining_skill(remaining_min, skills_left)

      payload = {
        skills:                          configured.map { |m| skill_json(m) },
        discovered:                      discovered.map { |m| skill_json(m) },
        time_remaining_minutes:          remaining_min,
        skills_remaining:                skills_left,
        avg_minutes_per_remaining_skill: avg_min,
        pacing:                          pacing_bucket(avg_min),
        priority_next:                   priority_next(configured)
      }

      # Every skill is covered but the interview is far from its time limit —
      # tell the interviewer to deepen the thinnest skill instead of closing.
      if wrap_up_held?
        payload[:wrap_up_blocked] = true
        payload[:deepen_next]     = thinnest_skill_id(configured)
      end

      Rails.logger.info("[MapInjector] Coverage map: skills_remaining=#{skills_left} avg_min=#{avg_min} pacing=#{pacing_bucket(avg_min)} priority_next=#{payload[:priority_next]} wrap_up_blocked=#{wrap_up_held?}")

      "[COVERAGE_MAP]\n#{payload.to_json}\n[/COVERAGE_MAP]"
    end

    # Returns true when every configured skill is covered AND no discovered
    # skill is still in initiated state. Used by the audio middleware to decide
    # when it is safe to inject a wrap-up signal and end the session.
    def all_covered?
      maps       = @session.coverage_maps
      configured = maps.configured
      discovered = maps.discovered

      return false if configured.empty?
      return false unless configured.all? { |m| m.state == 'covered' }
      return false if discovered.any? { |m| m.state == 'initiated' }
      return false if wrap_up_held?

      true
    end

    # True when coverage is complete but too little of the time limit has been
    # used for closing to be credible. Prevents a 45-minute interview from
    # ending in 15 because the analyzer was generous.
    #
    # Only meaningful once every configured skill is covered — callers check
    # coverage first, and coverage_fingerprint only needs the flag in that case.
    def wrap_up_held?
      return @wrap_up_held unless @wrap_up_held.nil?

      @wrap_up_held = compute_wrap_up_held
    end

    private

    def compute_wrap_up_held
      ratio = AppConfig.get('session.min_elapsed_ratio_before_wrap_up', tenant_id: @session.tenant_id)
      return false if ratio <= 0
      return false unless @session.started_at && @session.assessment.time_limit_min

      # Only holds while coverage is otherwise complete — an unfinished agenda
      # already keeps the session open on its own.
      configured = @session.coverage_maps.configured
      return false if configured.empty?
      return false unless configured.all? { |m| m.state == 'covered' }

      elapsed  = (Time.current - @session.started_at).to_i
      required = @session.assessment.time_limit_min * 60 * ratio

      elapsed < required
    end

    # Weakest-evidence skill: fewest probes, oldest first on a tie.
    def thinnest_skill_id(configured_maps)
      best = configured_maps.min_by { |m| [m.probe_count, m.id] }
      return nil unless best

      best.skill_id || best.skill_label.downcase.gsub(/\s+/, '-')
    end

    def skill_json(map)
      {
        id:          map.skill_id || map.skill_label.downcase.gsub(/\s+/, '-'),
        label:       map.skill_label,
        state:       map.state,
        probe_count: map.probe_count
      }
    end

    def skills_remaining(configured_maps)
      configured_maps.count { |m| m.state != 'covered' }
    end

    def avg_minutes_per_remaining_skill(remaining_min, skills_left)
      return nil unless remaining_min
      return remaining_min if skills_left.zero?

      (remaining_min.to_f / skills_left).round(1)
    end

    def pacing_bucket(avg_min)
      return nil unless avg_min

      if avg_min >= pacing_threshold('ahead')       then 'ahead'
      elsif avg_min >= pacing_threshold('on_track') then 'on_track'
      elsif avg_min >= pacing_threshold('behind')   then 'behind'
      else                                               'critical'
      end
    end

    # Cached per instance — pacing is recomputed several times per injection.
    def pacing_threshold(bucket)
      @pacing_thresholds ||= {}
      @pacing_thresholds[bucket] ||=
        AppConfig.get("pacing.#{bucket}_min_minutes", tenant_id: @session.tenant_id)
    end

    def time_remaining_minutes
      return nil unless @session.started_at && @session.assessment.time_limit_min

      elapsed_seconds = (Time.current - @session.started_at).to_i
      limit_seconds   = @session.assessment.time_limit_min * 60
      remaining       = limit_seconds - elapsed_seconds

      [(remaining / 60.0).ceil, 0].max
    end

    # Returns the skill_id/label of the highest-priority uncovered skill.
    # Priority: not_yet > initiated > partial > discovered > covered
    def priority_next(configured_maps)
      priority_order = %w[not_yet initiated partial covered]

      best = configured_maps
             .reject { |m| m.state == 'covered' }
             .min_by { |m| priority_order.index(m.state) || 999 }

      return nil unless best

      best.skill_id || best.skill_label.downcase.gsub(/\s+/, '-')
    end
  end
end
