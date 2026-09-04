# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "webmock/rspec"
require "hyperon/wiki/mcp/tools"

# Coverage for the +proposal merge-payload audit itself: the marker pattern's breadth,
# the card-name gate (including workbench sidecars), and the audit's standing promises --
# it never raises, never blocks, never mutates content, and never echoes body text.
#
# Deployed WS6 verification established that the merge workbench sends `card.db_content`
# verbatim as the proposal leg and never parses or strips an in-body "Proposal mode:"
# line, so a marker written into a +proposal body is merge payload. The guard records
# that fact; it does not enforce a convention the server does not implement.
RSpec.describe Hyperon::Wiki::Mcp::Tools, "+proposal merge-payload audit" do
  let(:base_url) { "https://test.example.com/api/mcp" }

  before do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["MCP_ROLE"] = "user"
    ENV["DECKO_API_BASE_URL"] = base_url
  end

  after do
    ENV.delete("MCP_API_KEY")
    ENV.delete("MCP_ROLE")
    ENV.delete("DECKO_API_BASE_URL")
  end

  let(:config) { Hyperon::Wiki::Mcp::Config.new }
  let(:client) { Hyperon::Wiki::Mcp::Client.new(config) }
  let(:tools) { described_class.new(client) }

  let(:valid_token) { "test-jwt-token" }

  before do
    stub_request(:post, "#{base_url}/auth")
      .to_return(
        status: 201,
        body: { "token" => valid_token, "role" => "user", "expires_in" => 3600 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # Lines are chomp'd and stripped before the pattern is applied, so the matrix below
  # exercises already-normalized forms. Whitespace tolerance is covered separately.
  describe "PROPOSAL_MARKER_PREFIX_PATTERN" do
    subject(:pattern) { described_class::PROPOSAL_MARKER_PREFIX_PATTERN }

    matching = [
      "Proposal mode: diff",
      "Proposal mode: full-replacement",
      "Proposal mode: <one of diff | full-replacement | manual-review-packet>",
      "proposal mode: diff",
      "PROPOSAL MODE: DIFF",
      "Proposal Mode: diff",
      "Proposal mode :diff",
      "Proposal  mode: diff",
      "**Proposal mode:** diff",
      "*Proposal mode:* diff",
      "_Proposal mode:_ diff",
      "`Proposal mode:` diff",
      "> Proposal mode: diff",
      ">> Proposal mode: diff",
      "- Proposal mode: diff",
      "* Proposal mode: diff",
      "+ Proposal mode: diff",
      "1. Proposal mode: diff",
      "2) Proposal mode: diff",
      "## Proposal mode: diff",
      "| Proposal mode: diff |",
      "[Proposal mode: diff]",
      "<p>Proposal mode: diff</p>",
      "<li>Proposal mode: diff</li>",
      "<strong>Proposal mode:</strong> diff",
      "<p><strong>Proposal mode:</strong> diff</p>",
      "<div class=\"note\">Proposal mode: diff</div>",
      "> **Proposal mode:** diff"
    ]

    matching.each do |line|
      it "matches #{line.inspect}" do
        expect(pattern).to be_match(line)
      end
    end

    # The line-start anchor is what keeps prose out of the audit. Only decoration --
    # never a word -- may precede the marker.
    non_matching = [
      "",
      "   ",
      "Proposal mode",
      "Proposal modes: diff and full-replacement",
      "Proposalmode: diff",
      "See Proposal mode: below for the options.",
      "The Proposal mode: line was removed by the reviewer.",
      "Ask the GM about proposal mode: it changes the merge.",
      "x Proposal mode: diff",
      "note Proposal mode: diff",
      "Mode: diff",
      "Proposed mode: diff",
      "This card documents Proposal mode: semantics."
    ]

    non_matching.each do |line|
      it "does not match #{line.inspect}" do
        expect(pattern).not_to be_match(line)
      end
    end
  end

  describe "card-name gate" do
    subject(:pattern) { described_class::PROPOSAL_NAME_SUFFIX_PATTERN }

    it "matches a proposal card" do
      expect(pattern).to be_match("Team+proposal")
    end

    it "matches case-insensitively" do
      expect(pattern).to be_match("Team+Proposal")
    end

    # The workbench's own sidecars are not the merge leg, so they stay out of the audit.
    ["Team+proposal+merge draft", "Team+proposal+base", "Team+proposal+status", "Team", "Team+draft"].each do |name|
      it "does not match #{name.inspect}" do
        expect(pattern).not_to be_match(name)
      end
    end
  end

  describe "audit behaviour on a write" do
    let(:proposal_name) { "Team+proposal" }
    let(:proposal_url) { "#{base_url}/cards/Team+proposal" }

    before do
      stub_request(:patch, proposal_url)
        .to_return(status: 200, body: { "name" => proposal_name }.to_json)
    end

    it "never raises and never blocks the write" do
      result = nil

      expect do
        result = tools.update_card(proposal_name, content: "Proposal mode: diff\n\nBody text.")
      end.not_to raise_error

      expect(result["name"]).to eq(proposal_name)
      expect(WebMock).to have_requested(:patch, proposal_url)
    end

    it "sends the content through unmodified -- the marker line is neither stripped nor inserted" do
      body = "Proposal mode: diff\n\nBody text."

      tools.update_card(proposal_name, content: body)

      expect(WebMock).to(have_requested(:patch, proposal_url).with do |req|
        JSON.parse(req.body)["content"] == body
      end)
    end

    it "does not require a marker: a marker-less proposal write is silent" do
      expect do
        tools.update_card(proposal_name, content: "An ordinary proposal body with no routing metadata.")
      end.not_to output.to_stderr
    end

    it "stays silent for a sidecar card even when its content carries a marker" do
      sidecar_url = "#{base_url}/cards/Team+proposal+merge%20draft"
      stub_request(:patch, sidecar_url).to_return(status: 200, body: { "name" => "x" }.to_json)

      expect do
        tools.update_card("Team+proposal+merge draft", content: "Proposal mode: diff\n\nBody.")
      end.not_to output.to_stderr
    end

    it "tolerates CRLF and trailing whitespace on the marker line" do
      expect do
        tools.update_card(proposal_name, content: "  Proposal mode: diff  \r\n\r\nBody.")
      end.to output(/proposal_marker_line_in_merge_payload/).to_stderr
    end

    it "counts every marker line in the payload" do
      expect do
        tools.update_card(proposal_name, content: "Proposal mode: diff\nBody.\n**proposal mode:** full-replacement\n")
      end.to output(/"marker_lines":2/).to_stderr
    end

    it "emits a single machine-readable JSON object on stderr" do
      captured = capture_stderr do
        tools.update_card(proposal_name, content: "Proposal mode: diff\n\nBody.")
      end

      parsed = JSON.parse(captured.strip)

      expect(parsed).to include(
        "event" => "proposal_marker_line_in_merge_payload",
        "operation" => "update_card",
        "card" => "Team+proposal",
        "marker_lines" => 1
      )
    end

    it "logs no field beyond the event, operation, card, counts and static detail" do
      captured = capture_stderr do
        tools.update_card(proposal_name, content: "Proposal mode: diff\n\nBody.")
      end

      allowed = %w[event operation card marker_lines marker_lines_prior detail]

      expect(JSON.parse(captured.strip).keys - allowed).to be_empty
    end

    it "never logs the proposal body" do
      expect do
        tools.update_card(proposal_name, content: "Proposal mode: diff\n\ncanary-alpha-do-not-log")
      end.not_to output(/canary-alpha-do-not-log/).to_stderr
    end

    it "never logs the matched marker line" do
      expect do
        tools.update_card(proposal_name, content: "Proposal mode: canary-bravo-do-not-log\n\nBody.")
      end.not_to output(/canary-bravo-do-not-log/).to_stderr
    end

    it "never logs a hash or excerpt of the body" do
      captured = capture_stderr do
        tools.update_card(proposal_name, content: "Proposal mode: diff\n\nSome distinctive body prose.")
      end

      expect(captured).not_to match(/[0-9a-f]{16,}/i)
      expect(captured).not_to include("distinctive")
    end
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
