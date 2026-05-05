# frozen_string_literal: true

require_relative 'lib/legion/extensions/ollama/version'

Gem::Specification.new do |spec|
  spec.name          = 'lex-ollama'
  spec.version       = Legion::Extensions::Ollama::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'LEX Ollama'
  spec.description   = 'Connects LegionIO to Ollama local LLM server'
  spec.homepage      = 'https://github.com/LegionIO/lex-ollama'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/LegionIO/lex-ollama'
  spec.metadata['documentation_uri'] = 'https://github.com/LegionIO/lex-ollama'
  spec.metadata['changelog_uri'] = 'https://github.com/LegionIO/lex-ollama/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/LegionIO/lex-ollama/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'faraday', '>= 2.0'
  spec.add_dependency 'legion-json', '>= 1.2.1'
  spec.add_dependency 'legion-llm', '>= 0.8.32'
  spec.add_dependency 'legion-logging', '>= 1.3.2'
  spec.add_dependency 'legion-settings', '>= 1.3.14'
  spec.add_dependency 'lex-llm', '>= 0.1.6'
  spec.add_dependency 'lex-s3', '>= 0.2'
end
