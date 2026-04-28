# frozen_string_literal: true

source 'https://rubygems.org'
gemspec

legion_llm_path = File.expand_path('../../legion-llm', __dir__)
gem 'legion-llm', path: legion_llm_path if Dir.exist?(legion_llm_path)

group :test do
  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop'
  gem 'rubocop-legion'
  gem 'simplecov'
end
