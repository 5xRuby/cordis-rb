# frozen_string_literal: true

require_relative 'lib/cordis/version'

Gem::Specification.new do |spec|
  spec.name = 'cordis'
  spec.version = Cordis::VERSION
  spec.authors = ['ryudoawaru']
  spec.email = ['ryudoawaru@gmail.com']

  spec.summary = 'A Ruby port of the Cordis plugin/lifecycle meta-framework'
  spec.description = 'Revertible effects with LIFO disposal, a plugin/fiber lifecycle state machine, ' \
                     'reactive coeffects (service provide/inject), events, and service isolation — ' \
                     'the core mechanisms of Cordis (cordiverse/cordis), reimplemented on the async gem. ' \
                     'Based on the paper "A Programming Paradigm for Spatiotemporal Composability".'
  spec.homepage = 'https://github.com/5xRuby/cordis-rb'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.2' # bare * / & argument forwarding, endless methods

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/releases"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb'] + %w[README.md LICENSE]
  spec.require_paths = ['lib']

  spec.add_dependency 'async', '~> 2.35'
end
