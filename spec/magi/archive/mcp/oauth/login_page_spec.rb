# frozen_string_literal: true

require "spec_helper"
require "magi/archive/mcp/oauth/login_page"

RSpec.describe Magi::Archive::Mcp::OAuth::LoginPage do
  describe ".render" do
    let(:params) do
      {
        response_type: "code",
        client_id: "test-client-123",
        redirect_uri: "https://example.com/callback",
        code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        code_challenge_method: "S256",
        state: "abc123"
      }
    end

    it "returns a complete HTML page" do
      html = described_class.render(params: params)

      expect(html).to include("<!DOCTYPE html>")
      expect(html).to include("</html>")
      expect(html).to include("Magi Archive")
    end

    it "includes the login form" do
      html = described_class.render(params: params)

      expect(html).to include('type="email"')
      expect(html).to include('type="password"')
      expect(html).to include('method="POST"')
      expect(html).to include('action="/authorize"')
    end

    it "includes OAuth params as hidden fields" do
      html = described_class.render(params: params)

      expect(html).to include('name="response_type" value="code"')
      expect(html).to include('name="client_id" value="test-client-123"')
      expect(html).to include('name="redirect_uri" value="https://example.com/callback"')
      expect(html).to include('name="code_challenge"')
      expect(html).to include('name="state" value="abc123"')
    end

    it "displays client name" do
      html = described_class.render(params: params, client_name: "ChatGPT")

      expect(html).to include("ChatGPT")
      expect(html).to include("is requesting access")
    end

    it "defaults client name to MCP Client" do
      html = described_class.render(params: params)

      expect(html).to include("MCP Client")
    end

    it "displays error message when provided" do
      html = described_class.render(params: params, error: "Invalid credentials")

      expect(html).to include("Invalid credentials")
      expect(html).to include('class="error"')
    end

    it "does not display error block when no error" do
      html = described_class.render(params: params)

      expect(html).not_to include('class="error"')
    end

    it "HTML-escapes client name to prevent XSS" do
      html = described_class.render(params: params, client_name: '<script>alert("xss")</script>')

      expect(html).not_to include("<script>")
      expect(html).to include("&lt;script&gt;")
    end

    it "HTML-escapes error message to prevent XSS" do
      html = described_class.render(params: params, error: '<img onerror="alert(1)">')

      expect(html).not_to include('onerror="alert(1)"')
      expect(html).to include("&lt;img onerror=")
    end

    it "HTML-escapes param values to prevent XSS" do
      xss_params = { client_id: '"><script>alert(1)</script>' }
      html = described_class.render(params: xss_params)

      expect(html).not_to include("<script>alert(1)</script>")
      expect(html).to include("&lt;script&gt;")
    end

    it "omits hidden fields for nil values" do
      sparse_params = { response_type: "code", client_id: "test", redirect_uri: nil }
      html = described_class.render(params: sparse_params)

      expect(html).to include('name="response_type"')
      expect(html).to include('name="client_id"')
      expect(html).not_to include('name="redirect_uri"')
    end
  end

  describe ".escape" do
    it "escapes HTML special characters" do
      expect(described_class.escape('<script>"alert&')).to eq("&lt;script&gt;&quot;alert&amp;")
    end

    it "handles nil gracefully" do
      expect(described_class.escape(nil)).to eq("")
    end
  end

  describe ".build_hidden_fields" do
    it "builds hidden input elements" do
      fields = described_class.build_hidden_fields(foo: "bar", baz: "qux")

      expect(fields).to include('name="foo" value="bar"')
      expect(fields).to include('name="baz" value="qux"')
    end

    it "skips nil values" do
      fields = described_class.build_hidden_fields(foo: "bar", empty: nil)

      expect(fields).to include('name="foo"')
      expect(fields).not_to include('name="empty"')
    end
  end
end
