# frozen_string_literal: true

# WIRING BASELINE -- half permanent invariant, half characterization. The halves are stated
# separately below because they are enforced for different reasons and have different lifetimes.
#
# UPDATED when the dedicated AtomSpace entrypoint landed
# (lib/hyperon/wiki/mcp/server/atomspace_entrypoint.rb). The previous revision recorded that the
# eight tool classes were registered by NO entrypoint and that NO textual reference to the
# registry's seams existed anywhere. The second half of that is now false by design, and the
# trigger it was built to fire did fire: the gate-reference example failed, which is what sent a
# reviewer here instead of letting wiring land unreviewed. It is updated, not worked around.
#
# THE PERMANENT HALF -- the public entrypoints register no AtomSpace tool class. This is not a
# snapshot of current state; it is INTEGRATION.md step 2 (Card 17184, decision 2026-06-08,
# recorded there as an acceptance criterion): the eight tools live in a dedicated toolset and
# never in the public Hyperon Wiki MCP tool list, "not filtered or otherwise". Space-global
# aggregates (space_stats, atom_count_by_type, atom_types) in particular must not reach the
# public surface. If this half fails, something violated the acceptance criterion -- do not
# update it to match, fix the registration.
#
# THE CHARACTERIZATION HALF -- the registry's seams are referenced from exactly one file, the
# dedicated entrypoint, and that file references BOTH the visibility seam and the invocation
# gate. The "both" is the point, per INTEGRATION.md step 3: "Visibility filtering alone is not
# enforcement." A seam reference appearing in a THIRD file is the review trigger now -- most
# importantly in a public dispatch path, which is how the dedicated toolset would quietly become
# a filter on the public one. This half is still DESIGNED TO FAIL when wiring moves or spreads
# (a second dedicated entrypoint, a stdio variant, a mount in rack_app), and that failure is
# still a review trigger rather than a regression.
#
# WHAT THIS IS NOT:
#   - It is NOT authorization coverage. It proves nothing about who may call these tools.
#     spec/server/atomspace_entrypoint_spec.rb is where the list/call authorization behaviour is
#     actually witnessed, against real grant results and a real gate.
#   - It establishes NOTHING about behavioural tool listing, MCP dispatch enforcement,
#     invocation authorization, or Deck-side authorization.
#   - It says nothing about contract scope, grant eligibility, or catalog separation.
#   - A textual reference is not a CALL. That the entrypoint names both seams says nothing about
#     whether it reaches them on every path; the behavioural spec covers that.
#
# METHOD: every check below reads first-party source as TEXT. It never requires or loads an
# entrypoint -- config.ru and bin/mcp-server-rack-direct each construct a live Tools client at
# load -- and it never constructs a client or touches the network.
#
# ANTI-SILENT-PASS: a textual check can pass vacuously if the source it reads changes shape, so
# the scanner refuses rather than guesses. An earlier revision counted brackets in raw source,
# which let a `# ]` comment close the array early: the surviving prefix parsed cleanly and an
# AtomSpace entry after the comment was silently missed. scan_array_region now blanks comment and
# string contents as it walks, and raises UnsupportedSourceShape on any character it cannot
# account for (%w literals, heredocs, interpolation, splats, method calls). The in-memory
# examples below exercise those paths directly.
#
# RESIDUAL LIMITS, stated rather than papered over: aliases, dynamic or indirect registration,
# and a third entrypoint are still invisible to a textual scan. The seam scan matches method
# names across lib/**/*.rb plus the two entrypoints -- including occurrences in comments and
# strings -- and excludes registry.rb entirely because that file defines the methods. It is a
# textual-reference check over selected files, not exhaustive call-site analysis.

module AtomspaceWiringBaseline
  ROOT = File.expand_path("../../../..", __dir__)

  REGISTRY_RELATIVE_PATH = "lib/hyperon/wiki/mcp/server/tools/atomspace/registry.rb"

  # Production files that construct an MCP::Server tool table.
  ENTRYPOINTS = ["config.ru", "bin/mcp-server-rack-direct"].freeze

  # The only registration entry shape this baseline knows how to read.
  ENTRY_SHAPE = /\AHyperon::Wiki::Mcp::Server::Tools::[A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)*,?\z/

  # Characters that may legitimately appear as code inside a constant-list array. Anything else
  # is refused: guessing is what produced the truncation bug this scanner replaced.
  CODE_CHARS = /[A-Za-z0-9_:,\s]/

  # The registry's two seam families. Kept as separate families rather than one flat list
  # because the assertion below is about BOTH being present in the wiring file: a file that
  # named only the visibility seam would be the exact mistake INTEGRATION.md step 3 warns about.
  #
  # Word-anchored on purpose. An earlier revision matched the bare substring "visible_for",
  # which also matches "visible_for_context" -- so a file referencing only the context-taking
  # seam was indistinguishable from one referencing the array-taking one, and the two have
  # different trust properties (the array-taking pair leaves freshness to the caller).
  VISIBILITY_SEAMS = {
    "visible_for" => /\bvisible_for\b/,
    "visible_for_context" => /\bvisible_for_context\b/
  }.freeze

  GATE_SEAMS = {
    "gate!" => /\bgate!/,
    "gate_for_context!" => /\bgate_for_context!/
  }.freeze

  SEAMS = VISIBILITY_SEAMS.merge(GATE_SEAMS).freeze

  # The one file expected to reach the registry's seams. Any other file appearing in the scan is
  # the review trigger -- especially a public dispatch path.
  WIRING_RELATIVE_PATH = "lib/hyperon/wiki/mcp/server/atomspace_entrypoint.rb"

  # Raised instead of quietly reporting "absent" when source cannot be read as expected.
  class UnsupportedSourceShape < StandardError; end

  module_function

  def read(relative_path)
    path = File.join(ROOT, relative_path)
    unless File.file?(path)
      raise UnsupportedSourceShape, "expected first-party source at #{relative_path}, found no file"
    end

    File.read(path)
  end

  def registry_source
    read(REGISTRY_RELATIVE_PATH)
  end

  # Every occurrence of a pattern, so "exactly one registration array" can be asserted rather
  # than assumed.
  def match_offsets(source, pattern)
    offsets = []
    position = 0
    while (found = source.match(pattern, position))
      offsets << found.begin(0)
      position = found.end(0)
    end
    offsets
  end

  # Blank a single character in the masked copy, preserving newlines so line structure survives.
  def blank!(masked, source, index)
    masked[index] = " " unless source[index] == "\n"
  end

  # Consume a quoted literal, blanking its contents so brackets and hashes inside a string can
  # neither close the array nor start a comment. Returns the index just past the closing quote.
  #
  # rubocop:disable Metrics/CyclomaticComplexity -- the branch count is the escape/interpolation/
  # terminator case analysis itself. Collapsing it to satisfy the metric is how the truncation bug
  # this scanner replaced got in; the cases are each covered by an in-memory example below.
  def blank_string_literal(label, source, masked, quote_index)
    quote = source[quote_index]
    index = quote_index + 1

    while index < source.length
      char = source[index]

      if char == "\\"
        blank!(masked, source, index)
        blank!(masked, source, index + 1) if index + 1 < source.length
        index += 2
        next
      end

      if quote == '"' && char == "#" && source[index + 1] == "{"
        raise UnsupportedSourceShape,
              "#{label}: string interpolation inside the tools array is not something this " \
              "baseline can track; refusing rather than guessing where the array ends"
      end

      return index + 1 if char == quote

      blank!(masked, source, index)
      index += 1
    end

    raise UnsupportedSourceShape, "#{label}: unterminated string literal inside the tools array"
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def refuse_unsupported(label, source, index)
    char = source[index]
    return if char.match?(CODE_CHARS)

    raise UnsupportedSourceShape,
          "#{label}: unexpected #{char.inspect} at offset #{index} inside the tools array; this " \
          "baseline reads only constants, commas, comments and strings, and refuses to guess " \
          "where the array ends"
  end

  # Walk the `tools: [ ... ]` region, returning [close_index, masked_source]. Comment and string
  # contents are blanked as we go, so bracket depth is counted over code only.
  #
  # rubocop:disable Metrics/CyclomaticComplexity -- same reasoning as blank_string_literal: the
  # branches ARE the delimiter case analysis, and merging them is what allowed a comment bracket
  # to truncate extraction silently.
  def scan_array_region(label, source, open_index)
    masked = source.dup
    depth = 0
    index = open_index

    while index < source.length
      case source[index]
      when "["
        depth += 1
        index += 1
      when "]"
        depth -= 1
        return [index, masked] if depth.zero?

        index += 1
      when "#"
        line_end = source.index("\n", index) || source.length
        masked[index...line_end] = " " * (line_end - index)
        index = line_end
      when "'", '"'
        index = blank_string_literal(label, source, masked, index)
      else
        refuse_unsupported(label, source, index)
        index += 1
      end
    end

    raise UnsupportedSourceShape,
          "#{label}: `tools: [` is never closed; cannot read the registration array"
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  # Comment-masked text between the brackets of the single `tools: [ ... ]` argument.
  def tools_array_body(label, source)
    starts = match_offsets(source, /tools:\s*\[/)
    unless starts.size == 1
      raise UnsupportedSourceShape,
            "#{label}: expected exactly one `tools: [` array, found #{starts.size}"
    end

    open_index = source.index("[", starts.first)
    close_index, masked = scan_array_region(label, source, open_index)
    masked[(open_index + 1)...close_index]
  end

  # Registered tool constants, one per meaningful line. Comments are already blanked by the
  # scanner, so anything left that is not a recognized constant is an error -- never a silent
  # "no AtomSpace tools here".
  def entries_from_source(label, source)
    entries = tools_array_body(label, source).each_line.filter_map do |raw_line|
      line = raw_line.strip
      next if line.empty?

      unless line.match?(ENTRY_SHAPE)
        raise UnsupportedSourceShape,
              "#{label}: unrecognized registration entry #{line.inspect}; this baseline only " \
              "reads fully-qualified tool constants, one per line"
      end

      line.delete_suffix(",")
    end

    raise UnsupportedSourceShape, "#{label}: registration array read as empty" if entries.empty?

    entries
  end

  def registered_entries(relative_path)
    entries_from_source(relative_path, read(relative_path))
  end

  # The eight class names, read from the registry's own TOOLS list rather than hardcoded here.
  # This path uses per-line comment masking only; the constant grammar below and the "exactly
  # eight" premise example are its backstops against a mis-read list.
  def registry_tool_names
    masked = registry_source.each_line.map { |line| line.sub(/#.*/, "") }.join
    found = masked.match(/TOOLS\s*=\s*\[(.*?)\]\.freeze/m)
    unless found
      raise UnsupportedSourceShape,
            "#{REGISTRY_RELATIVE_PATH}: no `TOOLS = [ ... ].freeze` list found"
    end

    names = found[1].split(",").map(&:strip).reject(&:empty?)
    names.each do |name|
      unless name.match?(/\A[A-Z][A-Za-z0-9_]*\z/)
        raise UnsupportedSourceShape,
              "#{REGISTRY_RELATIVE_PATH}: unrecognized TOOLS entry #{name.inspect}"
      end
    end
    names
  end

  def atomspace_registrations(entries, tool_names)
    entries.select do |entry|
      entry.include?("Atomspace::") || tool_names.include?(entry.split("::").last)
    end
  end

  # Ruby under lib/, plus the entrypoints, minus the registry that defines the methods.
  def scanned_paths
    lib_files = Dir[File.join(ROOT, "lib/**/*.rb")].map { |path| path.delete_prefix("#{ROOT}/") }
    (lib_files - [REGISTRY_RELATIVE_PATH]) + ENTRYPOINTS
  end

  # Textual references, not call-site analysis: word-anchored regex matches, comments and
  # strings included. Returns { relative_path => [seam names] } so the examples can assert WHICH
  # file references WHICH seam, not merely that the total is non-empty -- "some file somewhere
  # names a seam" is what the previous absence check degenerated to once wiring landed.
  def seam_references
    scanned_paths.each_with_object({}) do |relative_path, found|
      source = read(relative_path)
      named = SEAMS.filter_map { |name, pattern| name if source.match?(pattern) }
      found[relative_path] = named unless named.empty?
    end
  end
end

RSpec.describe "AtomSpace wiring baseline (textual, temporary)" do
  helper = AtomspaceWiringBaseline
  shape_error = AtomspaceWiringBaseline::UnsupportedSourceShape

  describe "premises this baseline depends on" do
    it "still finds a TOOLS list of exactly eight AtomSpace tool classes" do
      expect(helper.registry_tool_names.size).to eq(8)
    end

    it "still finds all four registry seams defined in the registry" do
      source = helper.registry_source
      expect(source).to match(/def\s+visible_for\b/)
      expect(source).to match(/def\s+gate!/)
      expect(source).to match(/def\s+visible_for_context\b/)
      expect(source).to match(/def\s+gate_for_context!/)
    end

    it "still finds the wiring file the seam scan expects" do
      expect(helper.read(AtomspaceWiringBaseline::WIRING_RELATIVE_PATH)).not_to be_empty
    end
  end

  describe "entrypoint registration" do
    AtomspaceWiringBaseline::ENTRYPOINTS.each do |relative_path|
      it "reads a recognizable tools: array in #{relative_path}" do
        expect(helper.registered_entries(relative_path)).not_to be_empty
      end

      it "records that #{relative_path} registers no AtomSpace tool class" do
        registered = helper.atomspace_registrations(
          helper.registered_entries(relative_path), helper.registry_tool_names
        )

        expect(registered).to be_empty,
                              "#{relative_path} now registers #{registered.join(", ")}. If this is " \
                              "deliberate AtomSpace wiring, confirm Registry.gate! is called at " \
                              "invocation before updating this baseline."
      end
    end
  end

  # An absence check that cannot fire is worthless, and one that can be truncated is worse. These
  # run synthetic source through the real extraction path. They read no entrypoint; they do read
  # the registry, because the detector resolves the eight class names from its TOOLS list.
  describe "the extractor and detector (in-memory source)" do
    def array_source(*lines)
      "mcp_server = ::MCP::Server.new(\n  tools: [\n#{lines.join("\n")}\n  ],\n)\n"
    end

    it "detects an AtomSpace entry inserted into an otherwise ordinary array" do
      source = array_source(
        "    Hyperon::Wiki::Mcp::Server::Tools::GetCard,",
        "    Hyperon::Wiki::Mcp::Server::Tools::Atomspace::QueryAtoms"
      )

      entries = helper.entries_from_source("<synthetic>", source)
      expect(helper.atomspace_registrations(entries, helper.registry_tool_names))
        .to eq(["Hyperon::Wiki::Mcp::Server::Tools::Atomspace::QueryAtoms"])
    end

    # The regression that made this rewrite necessary: a bracket in a comment used to close the
    # array early, leaving a prefix that parsed cleanly while the AtomSpace entry vanished.
    it "does not let a bracket in a comment truncate the array" do
      source = array_source(
        "    Hyperon::Wiki::Mcp::Server::Tools::GetCard,",
        "    # ]",
        "    Hyperon::Wiki::Mcp::Server::Tools::Atomspace::QueryAtoms"
      )

      entries = helper.entries_from_source("<synthetic>", source)
      expect(helper.atomspace_registrations(entries, helper.registry_tool_names))
        .to eq(["Hyperon::Wiki::Mcp::Server::Tools::Atomspace::QueryAtoms"])
    end

    it "does not let a bracket inside a string truncate the array" do
      source = array_source(
        "    Hyperon::Wiki::Mcp::Server::Tools::GetCard,",
        '    "]",',
        "    Hyperon::Wiki::Mcp::Server::Tools::Atomspace::SpaceStats"
      )

      expect { helper.entries_from_source("<synthetic>", source) }
        .to raise_error(shape_error, /unrecognized registration entry/)
    end

    it "does not treat a hash inside a string as a comment" do
      source = array_source(
        '    "# Hyperon::Wiki::Mcp::Server::Tools::GetCard",',
        "    Hyperon::Wiki::Mcp::Server::Tools::Atomspace::AtomTypes"
      )

      expect { helper.entries_from_source("<synthetic>", source) }
        .to raise_error(shape_error, /unrecognized registration entry/)
    end

    it "refuses a splat rather than reading the surviving entries" do
      source = array_source(
        "    Hyperon::Wiki::Mcp::Server::Tools::GetCard,",
        "    *Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry::TOOLS"
      )

      expect { helper.entries_from_source("<synthetic>", source) }
        .to raise_error(shape_error, /unexpected "\*"/)
    end

    it "refuses interpolation rather than guessing where the array ends" do
      # Single quotes are deliberate: the synthetic source must carry the literal characters
      # #{...}, not an interpolated value.
      source = array_source('    "#{tool_list}"') # rubocop:disable Lint/InterpolationCheck

      expect { helper.entries_from_source("<synthetic>", source) }
        .to raise_error(shape_error, /interpolation/)
    end

    it "refuses an unclosed array" do
      source = "tools: [\n  Hyperon::Wiki::Mcp::Server::Tools::GetCard,\n"

      expect { helper.entries_from_source("<synthetic>", source) }
        .to raise_error(shape_error, /never closed/)
    end

    it "refuses a source carrying more than one tools: array" do
      source = array_source("    Hyperon::Wiki::Mcp::Server::Tools::GetCard") * 2

      expect { helper.entries_from_source("<synthetic>", source) }
        .to raise_error(shape_error, /exactly one/)
    end

    it "flags an AtomSpace tool registered under some other namespace path" do
      entries = ["Hyperon::Wiki::Mcp::Server::Tools::SpaceStats"]

      expect(helper.atomspace_registrations(entries, helper.registry_tool_names)).to eq(entries)
    end

    it "leaves a purely non-AtomSpace registration alone" do
      source = array_source(
        "    Hyperon::Wiki::Mcp::Server::Tools::GetCard,",
        "    # a comment mentioning Atomspace::QueryAtoms",
        "    Hyperon::Wiki::Mcp::Server::Tools::SearchCards"
      )

      entries = helper.entries_from_source("<synthetic>", source)
      expect(helper.atomspace_registrations(entries, helper.registry_tool_names)).to be_empty
    end
  end

  describe "registry seam references in scanned source" do
    let(:references) { helper.seam_references }

    # The characterization half. Records exactly one wiring file, so a seam reference appearing
    # anywhere else -- above all in a public dispatch path -- fails here and sends a reviewer to
    # this comment instead of landing silently.
    it "records the dedicated entrypoint as the only file referencing a registry seam" do
      expect(references.keys).to eq([AtomspaceWiringBaseline::WIRING_RELATIVE_PATH]), lambda {
        "registry seams are now referenced at: #{references.inspect}. This baseline records only " \
          "#{AtomspaceWiringBaseline::WIRING_RELATIVE_PATH}. If a new file legitimately wires the " \
          "toolset, confirm it reaches the invocation gate and not visibility filtering alone, " \
          "then update this baseline deliberately."
      }
    end

    # INTEGRATION.md step 3, as close as a textual scan can get to it: "Visibility filtering
    # alone is not enforcement." A wiring file naming a visibility seam and no gate seam is the
    # specific half-done wiring that comment exists to catch.
    it "records that the wiring file names both a visibility seam and an invocation gate" do
      named = references.fetch(AtomspaceWiringBaseline::WIRING_RELATIVE_PATH, [])

      expect(named & AtomspaceWiringBaseline::VISIBILITY_SEAMS.keys).not_to be_empty
      expect(named & AtomspaceWiringBaseline::GATE_SEAMS.keys).not_to be_empty, lambda {
        "the wiring file references #{named.inspect} -- a visibility seam with no invocation " \
          "gate is not enforcement."
      }
    end

    # Which seam, not just that one is named. The context-taking pair routes the question
    # through GrantReadResult#authorization_valid_now?, so freshness cannot be dropped; the
    # array-taking pair takes a bare scope list and leaves that judgement to its caller. Wiring
    # that silently moved to the array-taking seams would still satisfy the example above.
    it "records the wiring file as reaching the context-taking seams specifically" do
      named = references.fetch(AtomspaceWiringBaseline::WIRING_RELATIVE_PATH, [])

      expect(named).to include("visible_for_context", "gate_for_context!")
    end
  end

  # The scan itself, exercised against synthetic source. An absence-or-presence check that
  # cannot distinguish the seams it names is worth little, and the word-anchoring below is the
  # specific property the previous substring scan lacked.
  describe "the seam scanner (in-memory source)" do
    it "distinguishes the context-taking seam from its array-taking twin" do
      context_only = "Registry.visible_for_context(context)"
      array_only = "Registry.visible_for(scopes)"

      expect(AtomspaceWiringBaseline::VISIBILITY_SEAMS["visible_for"].match?(context_only)).to be(false)
      expect(AtomspaceWiringBaseline::VISIBILITY_SEAMS["visible_for_context"].match?(context_only)).to be(true)
      expect(AtomspaceWiringBaseline::VISIBILITY_SEAMS["visible_for"].match?(array_only)).to be(true)
      expect(AtomspaceWiringBaseline::VISIBILITY_SEAMS["visible_for_context"].match?(array_only)).to be(false)
    end

    it "distinguishes the context-taking gate from its array-taking twin" do
      expect(AtomspaceWiringBaseline::GATE_SEAMS["gate!"].match?("Registry.gate_for_context!(t, c)")).to be(false)
      expect(AtomspaceWiringBaseline::GATE_SEAMS["gate_for_context!"].match?("Registry.gate_for_context!(t, c)"))
        .to be(true)
      expect(AtomspaceWiringBaseline::GATE_SEAMS["gate!"].match?("Registry.gate!(t, s)")).to be(true)
    end
  end
end
