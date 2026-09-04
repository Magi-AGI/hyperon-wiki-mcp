# frozen_string_literal: true

# Registry invariant for MCP tool annotations.
#
# `readOnlyHint` and `destructiveHint` are the only signals a client has for deciding
# whether a tool may be auto-approved. A wrapper that mutates the wiki while advertising
# read_only_hint: true silently defeats that gate, so the ratified matrix below is asserted
# for EVERY exposed tool -- unchanged ones included -- and the total is pinned at 48 so a
# newly added or removed wrapper cannot slip past unannotated.
#
# Pure class-level introspection: the tool files are required directly (never bin/mcp-server,
# which constructs a live authenticated Tools client at load), so nothing here touches the
# network, credentials, or wiki state.

module ToolAnnotationMatrix
  TOOLS_DIR = File.expand_path("../../../../lib/hyperon/wiki/mcp/server/tools", __dir__)

  Dir[File.join(TOOLS_DIR, "*.rb")].each { |path| require path }
  require File.join(TOOLS_DIR, "atomspace/registry")

  # tool_name => [read_only_hint, destructive_hint]
  RATIFIED = {
    # --- Read-only wiki reads (22) ---
    "diff_card" => [true, false],
    "fetch" => [true, false],
    "find_in_card" => [true, false],
    "get_card" => [true, false],
    "get_card_history" => [true, false],
    "get_card_outline" => [true, false],
    "get_card_stats" => [true, false],
    "get_file_url" => [true, false],
    "get_relationships" => [true, false],
    "get_revision" => [true, false],
    "get_site_context" => [true, false],
    "get_tags" => [true, false],
    "get_types" => [true, false],
    "health_check" => [true, false],
    "list_children" => [true, false],
    "list_trash" => [true, false],
    "render_content" => [true, false],
    "run_query" => [true, false],
    "search" => [true, false],
    "search_by_tags" => [true, false],
    "search_cards" => [true, false],
    "suggest_tags" => [true, false],

    # --- Additive writes: add new state, never overwrite existing content (4) ---
    "append_content" => [false, false],
    "create_card" => [false, false],
    "prepend_content" => [false, false],
    "submit_feedback" => [false, false],

    # --- Destructive writes: overwrite, replace, move, or remove existing state (14) ---
    "admin_backup" => [false, true],
    "auto_link" => [false, true],
    "batch_cards" => [false, true],
    "create_weekly_summary" => [false, true],
    "delete_card" => [false, true],
    "find_and_replace" => [false, true],
    "rename_card" => [false, true],
    "restore_card" => [false, true],
    "spoiler_scan" => [false, true],
    "template_card" => [false, true],
    "update_card" => [false, true],
    "update_section" => [false, true],
    "upload_file" => [false, true],
    "upload_from_url" => [false, true],

    # --- AtomSpace read toolset (8) ---
    "atom_count_by_type" => [true, false],
    "atom_types" => [true, false],
    "get_card_atom" => [true, false],
    "get_card_provenance" => [true, false],
    "list_atoms_by_type" => [true, false],
    "list_references" => [true, false],
    "query_atoms" => [true, false],
    "space_stats" => [true, false]
  }.freeze

  namespace = Hyperon::Wiki::Mcp::Server::Tools
  EXPOSED = (
    namespace.constants.map { |const| namespace.const_get(const) }
             .select { |const| const.is_a?(Class) && const < MCP::Tool } +
    namespace::Atomspace::Registry::TOOLS.to_a
  ).uniq.sort_by(&:tool_name).freeze
end

RSpec.describe "MCP server tool annotations" do
  let(:exposed) { ToolAnnotationMatrix::EXPOSED }

  it "exposes exactly 48 tool classes" do
    expect(exposed.size).to eq(48)
  end

  it "covers every exposed tool in the ratified matrix, and nothing else" do
    expect(exposed.map(&:tool_name)).to match_array(ToolAnnotationMatrix::RATIFIED.keys)
  end

  it "declares annotations on every exposed tool" do
    expect(exposed.reject(&:annotations).map(&:tool_name)).to be_empty
  end

  ToolAnnotationMatrix::RATIFIED.each do |tool_name, (read_only, destructive)|
    it "annotates #{tool_name} as read_only_hint: #{read_only}, destructive_hint: #{destructive}" do
      tool = exposed.find { |klass| klass.tool_name == tool_name }
      expect(tool).not_to be_nil, "no exposed tool class named #{tool_name}"

      actual = [tool.annotations.read_only_hint, tool.annotations.destructive_hint]
      expect(actual).to eq([read_only, destructive])
    end
  end
end
