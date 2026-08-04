# frozen_string_literal: true

# Ops access to runtime configuration, including the GLOBAL scope that the API
# deliberately does not expose (a tenant admin must not change every tenant).
#
#   rake app_config:list
#   rake app_config:list[coverage]
#   rake app_config:get[coverage.min_probes_to_advance]
#   rake app_config:set[coverage.min_probes_to_advance,3]           # global
#   rake app_config:set[coverage.min_probes_to_advance,3,12]        # tenant 12
#   rake app_config:reset[coverage.min_probes_to_advance]
namespace :app_config do
  desc 'List settings with their effective values and source'
  task :list, %i[group tenant_id] => :environment do |_t, args|
    rows = AppConfig.describe(tenant_id: args[:tenant_id].presence&.to_i)
    rows = rows.select { |r| r[:group] == args[:group] } if args[:group].present?

    width = rows.map { |r| r[:key].length }.max || 0
    rows.each do |r|
      puts format("%-#{width}s  %-12s  (%s, default %s)", r[:key], r[:value].inspect, r[:source], r[:default].inspect)
    end
  end

  desc 'Print one effective value'
  task :get, %i[key tenant_id] => :environment do |_t, args|
    puts AppConfig.get(args.fetch(:key), tenant_id: args[:tenant_id].presence&.to_i).inspect
  end

  desc 'Set a value (omit tenant_id for the global default)'
  task :set, %i[key value tenant_id] => :environment do |_t, args|
    key       = args.fetch(:key)
    tenant_id = args[:tenant_id].presence&.to_i
    value     = AppConfig.set(key, args.fetch(:value), tenant_id: tenant_id)

    puts "#{key} = #{value.inspect} (#{tenant_id ? "tenant #{tenant_id}" : 'global'})"
    puts "Live within #{AppConfig::CACHE_TTL.to_i}s across all processes."
  end

  desc 'Remove an override so the next level down applies'
  task :reset, %i[key tenant_id] => :environment do |_t, args|
    key       = args.fetch(:key)
    tenant_id = args[:tenant_id].presence&.to_i
    value     = AppConfig.reset(key, tenant_id: tenant_id)

    puts "#{key} reset → #{value.inspect}"
  end
end
