# frozen_string_literal: true

module Coverage
  # Validates coverage state transitions and enforces hard rules.
  # All transitions are forward-only and probe_count gated.
  class StateEngine
    STATES = %w[not_yet initiated partial covered].freeze

    VALID_TRANSITIONS = {
      'not_yet'   => %w[initiated],
      'initiated' => %w[partial],
      'partial'   => %w[covered],
      'covered'   => []
    }.freeze

    # Returns true if a transition from `from` to `to` is valid given probe_count.
    #
    # Two separate gates: leaving `initiated` needs min_probes, and reaching
    # `covered` needs the (higher) min_probes_to_cover — a skill must be probed
    # deeply before it can be declared done, not merely twice.
    #
    # Both default to the runtime config (coverage.* group).
    def self.valid_transition?(from:, to:, probe_count:, min_probes: nil, min_probes_to_cover: nil)
      return false unless VALID_TRANSITIONS[from]&.include?(to)

      min_probes ||= AppConfig.get('coverage.min_probes_to_advance')

      case to
      when 'partial'
        probe_count >= min_probes
      when 'covered'
        # Never let the cover gate fall below the advance gate, whatever the config says.
        min_cover = min_probes_to_cover || AppConfig.get('coverage.min_probes_to_cover')
        probe_count >= [min_cover, min_probes].max
      else
        true
      end
    end

    # Given a proposed update from N7, returns the safe state to apply.
    #
    # Advancement is capped at max_advance states per call (default 1). The
    # analyzer runs once per candidate turn, so a skill cannot skip from
    # `initiated` straight to `covered` on a single answer — it must sit at
    # `partial` for at least one turn, which is the only point at which the
    # interviewer is told to go deeper on it.
    #
    # Walking forward one step at a time (rather than rejecting a multi-step
    # proposal outright) also keeps the state from getting stuck when Flash
    # proposes a state several steps ahead.
    def self.resolve_state(current_state:, proposed_state:, probe_count:,
                           min_probes: nil, min_probes_to_cover: nil, max_advance: nil)
      return current_state if current_state == proposed_state

      min_probes  ||= AppConfig.get('coverage.min_probes_to_advance')
      max_advance ||= AppConfig.get('coverage.max_state_advance_per_turn')

      current_idx  = STATES.index(current_state) || 0
      proposed_idx = STATES.index(proposed_state)

      # Unknown proposed state — don't change
      return current_state unless proposed_idx && proposed_idx > current_idx

      target_idx = [proposed_idx, current_idx + max_advance].min

      # Walk forward one step at a time
      result = current_state
      (current_idx + 1).upto(target_idx) do |i|
        candidate = STATES[i]
        break unless valid_transition?(from: result, to: candidate, probe_count: probe_count,
                                       min_probes: min_probes, min_probes_to_cover: min_probes_to_cover)

        result = candidate
      end

      result
    end
  end
end
