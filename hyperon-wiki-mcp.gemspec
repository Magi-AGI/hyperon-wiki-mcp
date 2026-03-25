# frozen_string_literal: true

require_relative "lib/hyperon/wiki/mcp/version"

Gem::Specification.new do |spec|
  spec.name = "hyperon-wiki-mcp"
  spec.version = Hyperon::Wiki::Mcp::VERSION
  spec.authors = ["Nemquae"]
  spec.email = ["nemquae@gmail.com"]

  spec.summary = "MCP client for secure, role-aware API access to the Hyperon Wiki Decko application"
  spec.description = "Ruby MCP (Model Context Protocol) server providing AI agents with structured JSON API access " \
                     "to wiki.hyperon.dev. Features RS256 JWT authentication with three-role security model " \
                     "(user/gm/admin) and comprehensive card manipulation tools."
  spec.homepage = "https://gitlab.com/the-smithy1/magi/Magi-AGI"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://gitlab.com/the-smithy1/magi/Magi-AGI/-/tree/main/hyperon-wiki-mcp"
  spec.metadata["documentation_uri"] = "https://gitlab.com/the-smithy1/magi/Magi-AGI/-/blob/main/hyperon-wiki-mcp/README-gem.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # Using Dir.glob to work with uncommitted files during development
  spec.files = Dir.glob("{lib,bin}/**/*") + %w[
    README.md LICENSE
    CLAUDE.md AGENTS.md GEMINI.md MCP-SPEC.md
    CHANGELOG.md SECURITY.md AUTHENTICATION.md
  ]
  spec.files = spec.files.reject do |f|
    f == File.basename(__FILE__) ||
      File.directory?(f) ||
      (f.start_with?("bin/") && !f.match?(/bin\/hyperon-wiki-mcp$/))
  end
  spec.bindir = "bin"
  spec.executables = ["hyperon-wiki-mcp"]
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "bcrypt", "~> 3.1"
  spec.add_dependency "dotenv", "~> 2.8"
  spec.add_dependency "http", "~> 5.0"
  spec.add_dependency "jwt", "~> 2.7"
end
