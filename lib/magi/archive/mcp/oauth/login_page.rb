# frozen_string_literal: true

require "cgi"

module Magi
  module Archive
    module Mcp
      module OAuth
        # Renders the browser-based login page for the OAuth Authorization Code flow.
        #
        # When an AI platform (ChatGPT, Claude.ai) redirects the user to /authorize,
        # this module generates the HTML login form where the user enters their
        # Decko email and password. All OAuth parameters are passed through as
        # hidden form fields.
        module LoginPage
          module_function

          # Render the login page HTML
          #
          # @param params [Hash] OAuth parameters to pass through as hidden fields
          # @param error [String, nil] error message to display
          # @param client_name [String] name of the requesting client
          # @return [String] complete HTML page
          def render(params:, error: nil, client_name: "MCP Client")
            hidden_fields = build_hidden_fields(params)
            error_html = error ? error_block(escape(error)) : ""
            client_display = escape(client_name)

            PAGE_TEMPLATE
              .sub("{{CLIENT_NAME}}", client_display)
              .sub("{{ERROR_BLOCK}}", error_html)
              .sub("{{HIDDEN_FIELDS}}", hidden_fields)
          end

          # HTML-escape a string to prevent XSS
          #
          # @param str [String] the string to escape
          # @return [String] escaped string
          def escape(str)
            CGI.escapeHTML(str.to_s)
          end

          # Build hidden input fields from OAuth params
          #
          # @param params [Hash] key-value pairs
          # @return [String] HTML hidden input elements
          def build_hidden_fields(params)
            params.map do |key, value|
              next if value.nil? || value.to_s.empty?

              %(<input type="hidden" name="#{escape(key.to_s)}" value="#{escape(value.to_s)}">)
            end.compact.join("\n            ")
          end

          # Generate error display block
          #
          # @param message [String] already-escaped error message
          # @return [String] HTML error block
          def error_block(message)
            %(<div class="error">#{message}</div>)
          end

          PAGE_TEMPLATE = <<~HTML
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
              <title>Sign in - Magi Archive</title>
              <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                  background: #0a0a0f;
                  color: #e0e0e0;
                  min-height: 100vh;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                }
                .container {
                  background: #1a1a2e;
                  border: 1px solid #2a2a4a;
                  border-radius: 12px;
                  padding: 2.5rem;
                  width: 100%;
                  max-width: 400px;
                  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
                }
                .logo {
                  text-align: center;
                  margin-bottom: 1.5rem;
                }
                .logo h1 {
                  font-size: 1.5rem;
                  color: #7b68ee;
                  font-weight: 600;
                }
                .logo p {
                  color: #888;
                  font-size: 0.875rem;
                  margin-top: 0.5rem;
                }
                .client-info {
                  background: #16213e;
                  border: 1px solid #2a2a4a;
                  border-radius: 8px;
                  padding: 0.75rem 1rem;
                  margin-bottom: 1.5rem;
                  font-size: 0.875rem;
                  color: #aaa;
                  text-align: center;
                }
                .client-info strong { color: #c0c0c0; }
                label {
                  display: block;
                  margin-bottom: 0.375rem;
                  font-size: 0.875rem;
                  color: #aaa;
                }
                input[type="email"], input[type="password"] {
                  width: 100%;
                  padding: 0.75rem;
                  background: #0f0f1a;
                  border: 1px solid #2a2a4a;
                  border-radius: 6px;
                  color: #e0e0e0;
                  font-size: 1rem;
                  margin-bottom: 1rem;
                  transition: border-color 0.2s;
                }
                input[type="email"]:focus, input[type="password"]:focus {
                  outline: none;
                  border-color: #7b68ee;
                }
                button {
                  width: 100%;
                  padding: 0.75rem;
                  background: #7b68ee;
                  color: white;
                  border: none;
                  border-radius: 6px;
                  font-size: 1rem;
                  font-weight: 500;
                  cursor: pointer;
                  transition: background 0.2s;
                }
                button:hover { background: #6a5acd; }
                .error {
                  background: #2d1b1b;
                  border: 1px solid #5a2a2a;
                  color: #ff6b6b;
                  padding: 0.75rem;
                  border-radius: 6px;
                  margin-bottom: 1rem;
                  font-size: 0.875rem;
                }
                .footer {
                  text-align: center;
                  margin-top: 1.5rem;
                  font-size: 0.75rem;
                  color: #555;
                }
              </style>
            </head>
            <body>
              <div class="container">
                <div class="logo">
                  <h1>Magi Archive</h1>
                  <p>Sign in to authorize access</p>
                </div>
                <div class="client-info">
                  <strong>{{CLIENT_NAME}}</strong> is requesting access to your account.
                </div>
                {{ERROR_BLOCK}}
                <form method="POST" action="/authorize">
                  <label for="email">Email</label>
                  <input type="email" id="email" name="email" required autocomplete="email" autofocus>
                  <label for="password">Password</label>
                  <input type="password" id="password" name="password" required autocomplete="current-password">
                  {{HIDDEN_FIELDS}}
                  <button type="submit">Sign in and authorize</button>
                </form>
                <div class="footer">
                  Powered by Magi Archive MCP Server
                </div>
              </div>
            </body>
            </html>
          HTML
        end
      end
    end
  end
end
