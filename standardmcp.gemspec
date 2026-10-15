require File.expand_path("../lib/standard_mcp/version", __FILE__)

Gem::Specification.new do |spec|
  spec.name          = "standardmcp"
  spec.version       = StandardMCP::VERSION
  spec.licenses      = ['MIT']
  spec.authors       = ["Ben Ehmke"]
  spec.email         = ["ben.ehmke@jll.com"]
  spec.homepage      = "https://github.com/jello-works/standardmcp"
  spec.summary       = %q{Expose StandardAPI resources as MCP tools}
  spec.description   = %q{StandardMCP exposes StandardAPI controller actions as Model Context Protocol (MCP) tools, dispatching in-process so ACLs, masks, excludes and rendering are reused.}

  spec.required_ruby_version = '>= 3.2'

  spec.extra_rdoc_files = %w(README.md)
  spec.rdoc_options.concat ['--main', 'README.md']

  spec.files         = `git ls-files -- README.md LICENSE CHANGELOG.md {lib,ext}/*`.split("\n")
  spec.test_files    = `git ls-files -- {test}/*`.split("\n")
  spec.require_paths = ["lib", "test"]

  spec.add_runtime_dependency 'standardapi', '>= 9.0.0'
  spec.add_runtime_dependency 'mcp', '~> 1.7'
  spec.add_runtime_dependency 'rails', '>= 8.0.0'

  spec.add_development_dependency 'pg'
  spec.add_development_dependency 'jbuilder'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'minitest-reporters'
  spec.add_development_dependency 'mocha'
  spec.add_development_dependency 'factory_bot'
  spec.add_development_dependency 'faker'
  spec.add_development_dependency 'byebug'
end
