# frozen_string_literal: true

# A session that closes with configured skills still uncovered was recorded as
# 'all_covered' — the only reason the auto-end path had. That made premature
# endings invisible in the data. Give them their own value.
#
# ALTER TYPE ... ADD VALUE cannot run inside a transaction block.
class AddEndedEarlyToEndReason < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    execute "ALTER TYPE ai_interview.end_reason ADD VALUE IF NOT EXISTS 'ended_early'"
  end

  def down
    # Postgres cannot drop a value from an enum. Rows already using it would
    # have to be rewritten first, so this is deliberately a one-way migration.
    raise ActiveRecord::IrreversibleMigration
  end
end
