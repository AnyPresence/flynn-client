# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'flynn_client/version'

Gem::Specification.new do |spec|
  spec.name          = "flynn-client"
  spec.version       = FlynnClient::VERSION
  spec.authors       = ["AnyPresence, Inc."]
  spec.email         = ["sales@anypresence.com"]
  spec.summary       = %q{Ruby gem used for interaction with Flynn PaaS REST API.}
  spec.homepage      = "http://www.anypresence.com"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake"
  spec.add_development_dependency "test-unit"

  spec.add_runtime_dependency "excon", "~> 0.45.4"
  spec.add_runtime_dependency "bundler", "~> 1.5"
end
