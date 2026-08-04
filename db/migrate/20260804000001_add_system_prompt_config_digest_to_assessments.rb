# frozen_string_literal: true

# The compiled system prompt embeds runtime config (probe minimums, pacing
# ceilings). Storing the digest of those values lets us detect a stored prompt
# that predates a config change and recompile it lazily — otherwise a settings
# change would only reach assessments created afterwards.
class AddSystemPromptConfigDigestToAssessments < ActiveRecord::Migration[7.0]
  def up
    execute "SET search_path TO ai_interview, public"

    add_column :assessments, :system_prompt_config_digest, :string, limit: 64
  end

  def down
    remove_column :assessments, :system_prompt_config_digest
  end
end
