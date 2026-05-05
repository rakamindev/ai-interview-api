# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.3.2'

gem 'rails', '~> 7.0.8'
gem 'pg', '~> 1.3'
gem 'puma', '~> 5.6'

# Auth
gem 'jwt'
gem 'bcrypt', '~> 3.1.7'

# Multi-tenancy / request scoping
gem 'request_store', '~> 1.5'

# API
gem 'rack-cors'
gem 'rack-attack'

# Environment
gem 'figaro'

# Background jobs
gem 'sidekiq', '~> 7.0'
gem 'redis', '~> 5.0'

# WebSocket
gem 'faye-websocket'

# HTTP client (Gemini REST API)
gem 'faraday', '~> 2.0'
gem 'faraday-retry'

# PDF generation
gem 'matrix' # required by prawn on Ruby >= 3.1
gem 'prawn', '~> 2.4'
gem 'prawn-table', '~> 0.2'

# Misc
gem 'bootsnap', require: false
gem 'kaminari'

group :development, :test do
  gem 'byebug', platforms: [:mri, :mingw, :x64_mingw]
  gem 'rspec-rails', '~> 6.0'
  gem 'factory_bot_rails'
  gem 'faker'
  gem 'pry-rails'
end

group :development do
  gem 'listen', '~> 3.2'
  gem 'rubocop', require: false
  gem 'rubocop-rails', require: false
  gem 'rubocop-rspec', require: false
end

group :test do
  gem 'database_cleaner'
  gem 'timecop'
end
