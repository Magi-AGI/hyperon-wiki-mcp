# frozen_string_literal: true

require "json-schema"
require "pathname"
require "mcp"

# Fix Windows cross-drive bug in MCP gem's schema validation.
#
# The MCP gem's validate_schema! converts the metaschema path to a file:// URI,
# which strips the Windows drive letter (C:/Users/... -> file:///Users/...).
# When json-schema resolves this URI back to a path, it expands against the
# current working drive (E:), producing E:/Users/... which doesn't match the
# gem's actual location on C:. This causes ReadFailed/ReadRefused on Windows
# when CWD is on a different drive than the Ruby gem installation.
#
# Skip validation on Windows — tool schemas are static and known-correct.
# The $ref check is preserved since it doesn't depend on file I/O.
if Gem.win_platform?
  module MCP
    class Tool
      class Schema
        private

        def validate_schema!
          # Only preserve the $ref check (no file I/O needed)
          check_for_refs! if respond_to?(:check_for_refs!, true)
        end
      end
    end
  end
end
