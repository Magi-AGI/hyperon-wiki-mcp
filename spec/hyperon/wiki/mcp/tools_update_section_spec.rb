# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/tools"

RSpec.describe Hyperon::Wiki::Mcp::Tools, "#update_section" do
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
  let(:auth_response) do
    {
      "token" => valid_token,
      "role" => "user",
      "expires_in" => 3600
    }
  end

  before do
    stub_request(:post, "#{base_url}/auth")
      .to_return(
        status: 201,
        body: auth_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  let(:card_name) { "My Card" }
  let(:encoded_name) { "My%20Card" }
  let(:get_url) { "#{base_url}/cards/#{encoded_name}" }
  let(:patch_url) { "#{base_url}/cards/#{encoded_name}" }

  describe "with HTML headings" do
    let(:html_content) do
      "<h2>Introduction</h2>\n<p>Old intro text.</p>\n<h2>Details</h2>\n<p>Detail content here.</p>\n<h2>Conclusion</h2>\n<p>Final thoughts.</p>"
    end

    let(:card_response) do
      {
        "name" => "My Card",
        "content" => html_content,
        "type" => "RichText",
        "id" => 42
      }
    end

    let(:updated_card_response) do
      {
        "name" => "My Card",
        "content" => "updated content",
        "type" => "RichText",
        "id" => 42
      }
    end

    before do
      stub_request(:get, get_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: card_response.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "updates the specified section content" do
      stub_request(:patch, patch_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: updated_card_response.to_json, headers: { "Content-Type" => "application/json" })

      result = tools.update_section(card_name, section: "Introduction", content: "Brand new intro.")

      expect(result["name"]).to eq("My Card")

      # Verify the PATCH was called with correct content structure
      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        # Should contain the heading
        content.include?("<h2>Introduction</h2>") &&
          # Should contain the new content
          content.include?("Brand new intro.") &&
          # Should NOT contain the old content
          !content.include?("Old intro text.") &&
          # Should preserve subsequent sections
          content.include?("<h2>Details</h2>") &&
          content.include?("Detail content here.")
      end)
    end

    it "preserves content after the section" do
      stub_request(:patch, patch_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: updated_card_response.to_json, headers: { "Content-Type" => "application/json" })

      tools.update_section(card_name, section: "Details", content: "New detail text.")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        # Introduction section should be untouched
        content.include?("<h2>Introduction</h2>") &&
          content.include?("Old intro text.") &&
          # Details section should have new content
          content.include?("<h2>Details</h2>") &&
          content.include?("New detail text.") &&
          # Conclusion should be preserved
          content.include?("<h2>Conclusion</h2>") &&
          content.include?("Final thoughts.")
      end)
    end

    it "updates the last section (extends to end of content)" do
      stub_request(:patch, patch_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: updated_card_response.to_json, headers: { "Content-Type" => "application/json" })

      tools.update_section(card_name, section: "Conclusion", content: "New conclusion.")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        content.include?("<h2>Conclusion</h2>") &&
          content.include?("New conclusion.") &&
          !content.include?("Final thoughts.")
      end)
    end
  end

  describe "with Markdown headings" do
    let(:markdown_content) do
      "## Overview\nOld overview content.\n## Background\nSome background info.\n## References\nRef list here."
    end

    let(:card_response) do
      {
        "name" => "My Card",
        "content" => markdown_content,
        "type" => "Markdown",
        "id" => 43
      }
    end

    let(:updated_card_response) do
      {
        "name" => "My Card",
        "content" => "updated",
        "type" => "Markdown",
        "id" => 43
      }
    end

    before do
      stub_request(:get, get_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: card_response.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:patch, patch_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: updated_card_response.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "updates a Markdown section" do
      tools.update_section(card_name, section: "Overview", content: "New overview.")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        content.include?("## Overview") &&
          content.include?("New overview.") &&
          !content.include?("Old overview content.") &&
          content.include?("## Background") &&
          content.include?("Some background info.")
      end)
    end

    it "updates a middle Markdown section" do
      tools.update_section(card_name, section: "Background", content: "Updated background.")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        content.include?("## Overview") &&
          content.include?("Old overview content.") &&
          content.include?("## Background") &&
          content.include?("Updated background.") &&
          !content.include?("Some background info.") &&
          content.include?("## References") &&
          content.include?("Ref list here.")
      end)
    end
  end

  describe "section not found" do
    let(:card_response) do
      {
        "name" => "My Card",
        "content" => "<h2>Introduction</h2>\n<p>Content here.</p>",
        "type" => "RichText",
        "id" => 42
      }
    end

    before do
      stub_request(:get, get_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: card_response.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "raises ValidationError when section is not found" do
      expect do
        tools.update_section(card_name, section: "Nonexistent", content: "anything")
      end.to raise_error(Hyperon::Wiki::Mcp::Client::ValidationError, /Section 'Nonexistent' not found/)
    end
  end

  describe "mixed heading levels" do
    let(:mixed_content) do
      "<h2>Main Section</h2>\n<p>Main content.</p>\n<h3>Subsection A</h3>\n<p>Sub A content.</p>\n<h3>Subsection B</h3>\n<p>Sub B content.</p>\n<h2>Next Main</h2>\n<p>Next main content.</p>"
    end

    let(:card_response) do
      {
        "name" => "My Card",
        "content" => mixed_content,
        "type" => "RichText",
        "id" => 42
      }
    end

    let(:updated_card_response) do
      {
        "name" => "My Card",
        "content" => "updated",
        "type" => "RichText",
        "id" => 42
      }
    end

    before do
      stub_request(:get, get_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: card_response.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:patch, patch_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: updated_card_response.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "replaces h2 section including child h3 subsections up to next h2" do
      tools.update_section(card_name, section: "Main Section", content: "Replaced everything.")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        # Heading preserved
        content.include?("<h2>Main Section</h2>") &&
          # New content present
          content.include?("Replaced everything.") &&
          # Old subsections removed (they were part of the section body)
          !content.include?("Subsection A") &&
          !content.include?("Sub A content.") &&
          !content.include?("Subsection B") &&
          !content.include?("Sub B content.") &&
          # Next h2 section preserved
          content.include?("<h2>Next Main</h2>") &&
          content.include?("Next main content.")
      end)
    end

    it "replaces only a subsection up to the next same-level heading" do
      tools.update_section(card_name, section: "Subsection A", content: "New sub A.")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        # Parent section preserved
        content.include?("<h2>Main Section</h2>") &&
          content.include?("Main content.") &&
          # Updated subsection
          content.include?("<h3>Subsection A</h3>") &&
          content.include?("New sub A.") &&
          !content.include?("Sub A content.") &&
          # Sibling subsection preserved
          content.include?("<h3>Subsection B</h3>") &&
          content.include?("Sub B content.") &&
          # Next main section preserved
          content.include?("<h2>Next Main</h2>")
      end)
    end
  end

  describe "case-insensitive section matching" do
    let(:card_response) do
      {
        "name" => "My Card",
        "content" => "<h2>Introduction</h2>\n<p>Intro content.</p>\n<h2>Details</h2>\n<p>Detail content.</p>",
        "type" => "RichText",
        "id" => 42
      }
    end

    let(:updated_card_response) do
      {
        "name" => "My Card",
        "content" => "updated",
        "type" => "RichText",
        "id" => 42
      }
    end

    before do
      stub_request(:get, get_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: card_response.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:patch, patch_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: updated_card_response.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "matches section headings case-insensitively" do
      result = tools.update_section(card_name, section: "introduction", content: "Updated via lowercase.")

      expect(result["name"]).to eq("My Card")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        content.include?("<h2>Introduction</h2>") &&
          content.include?("Updated via lowercase.") &&
          !content.include?("Intro content.")
      end)
    end

    it "matches with mixed case" do
      result = tools.update_section(card_name, section: "DETAILS", content: "Uppercase match.")

      expect(result["name"]).to eq("My Card")

      expect(WebMock).to(have_requested(:patch, patch_url).with do |req|
        body = JSON.parse(req.body)
        content = body["content"]
        content.include?("<h2>Details</h2>") &&
          content.include?("Uppercase match.")
      end)
    end
  end

  # update_section is the only writer that already holds the full post-image before it
  # PATCHes. The audit therefore has to run against `new_full_content` (what actually goes
  # over the wire and becomes the merge leg), not against the replacement chunk alone --
  # otherwise a marker sitting outside the edited section is silently re-written unrecorded.
  describe "+proposal cards" do
    let(:proposal_name) { "Team+proposal" }
    let(:proposal_url) { "#{base_url}/cards/Team+proposal" }
    let(:proposal_body) { "## Details\nOld detail text." }

    before do
      stub_request(:get, proposal_url)
        .to_return(
          status: 200,
          body: { "name" => proposal_name, "content" => proposal_body, "type" => "Draft", "id" => 77 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:patch, proposal_url)
        .to_return(status: 200, body: { "name" => proposal_name }.to_json)
    end

    context "when the pre-image carries a marker outside the edited section" do
      let(:proposal_body) do
        "Proposal mode: manual-review-packet\n\ncanary-zulu-do-not-log\n\n## Details\nOld detail text."
      end

      it "edits the section without requiring or objecting to the marker" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.not_to raise_error

        expect(WebMock).to have_requested(:patch, proposal_url)
      end

      it "records the marker the outgoing merge payload carries, not just the replacement chunk" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.to output(/proposal_marker_line_in_merge_payload/).to_stderr

        expect(WebMock).to have_requested(:patch, proposal_url)
      end

      it "labels the audit line as update_section" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.to output(/"operation":"update_section"/).to_stderr
      end

      it "reports the pre-image marker count alongside the outgoing one" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.to output(/"marker_lines":1.*"marker_lines_prior":1/).to_stderr
      end

      it "never logs the proposal body it audited" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.not_to output(/canary-zulu-do-not-log/).to_stderr
      end

      it "never logs the matched marker line itself" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.not_to output(/manual-review-packet/).to_stderr
      end
    end

    context "when neither the pre-image nor the replacement carries a marker" do
      it "stays silent" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.not_to output.to_stderr
      end
    end

    context "when the replacement introduces a marker" do
      it "records a section body that writes a marker line into the merge payload" do
        expect do
          tools.update_section(proposal_name,
                               section: "Details",
                               content: "Proposal mode: full-replacement\nNew detail.")
        end.to output(/proposal_marker_line_in_merge_payload/).to_stderr

        expect(WebMock).to have_requested(:patch, proposal_url)
      end

      it "reports a pre-image count of zero" do
        expect do
          tools.update_section(proposal_name,
                               section: "Details",
                               content: "Proposal mode: full-replacement\nNew detail.")
        end.to output(/"marker_lines_prior":0/).to_stderr
      end

      it "records a decorated marker line the same way" do
        expect do
          tools.update_section(proposal_name,
                               section: "Details",
                               content: "**Proposal mode:** diff\nNew detail.")
        end.to output(/proposal_marker_line_in_merge_payload/).to_stderr
      end
    end

    context "when the edit removes the only marker line" do
      let(:proposal_body) { "## Details\nProposal mode: diff\nOld detail text." }

      it "stays silent because the outgoing payload no longer carries one" do
        expect do
          tools.update_section(proposal_name, section: "Details", content: "New detail text.")
        end.not_to output.to_stderr
      end
    end

    context "when the card is not a +proposal card" do
      let(:card_response) do
        {
          "name" => card_name,
          "content" => "Proposal mode: diff\n\n## Details\nOld detail text.",
          "type" => "RichText",
          "id" => 42
        }
      end

      before do
        stub_request(:get, get_url)
          .to_return(status: 200, body: card_response.to_json, headers: { "Content-Type" => "application/json" })
        stub_request(:patch, patch_url)
          .to_return(status: 200, body: { "name" => card_name }.to_json)
      end

      it "stays silent even though the outgoing payload carries a marker line" do
        expect do
          tools.update_section(card_name, section: "Details", content: "New detail text.")
        end.not_to output.to_stderr
      end
    end
  end
end
