# frozen_string_literal: true

require "bcrypt"
require "openssl"
require "base64"
require "json"
require "securerandom"

module Hyperon
  module Wiki
    module Mcp
      module OAuth
        # Manages OAuth client credentials stored as Decko cards
        #
        # Each OAuth client is stored as a card named "MCP OAuth Clients+<client_id>"
        # with JSON content containing hashed secret, encrypted password, and metadata.
        #
        # Uses bcrypt for client_secret hashing and AES-256-GCM for Decko password encryption.
        class ClientCards
          class ClientError < StandardError; end

          CARD_PREFIX = "MCP OAuth Clients"

          # @param tools [Hyperon::Wiki::Mcp::Tools] admin Tools instance for Decko API calls
          # @param encryption_key [String] 32-byte AES key (from TokenIssuer#encryption_key)
          def initialize(tools:, encryption_key:)
            @tools = tools
            @encryption_key = encryption_key
          end

          # Create a new OAuth client card on Decko
          #
          # @param client_id [String] UUID client identifier
          # @param client_secret [String] plaintext client secret
          # @param username [String] Decko username
          # @param password [String] Decko password (will be encrypted)
          # @param role [String] user role (user/gm/admin)
          # @param client_name [String] descriptive name (e.g., "Claude.ai")
          # @return [Hash] created card data
          # rubocop:disable Metrics/ParameterLists
          def create_client(client_id:, client_secret:, username:, password:, role:, client_name: "MCP Client")
            # rubocop:enable Metrics/ParameterLists
            secret_hash = BCrypt::Password.create(client_secret)
            encrypted_password, iv = encrypt_password(password)

            content = {
              username: username,
              secret_hash: secret_hash.to_s,
              encrypted_password: Base64.strict_encode64(encrypted_password),
              encryption_iv: Base64.strict_encode64(iv),
              role: role,
              created_at: Time.now.utc.iso8601,
              client_name: client_name
            }

            card_name = "#{CARD_PREFIX}+#{client_id}"
            @tools.create_card(card_name, content: JSON.generate(content), type: "PlainText")
          end

          # Verify OAuth client credentials
          #
          # @param client_id [String] the client ID
          # @param client_secret [String] the client secret to verify
          # @return [Hash] client data with :username, :password, :role
          # @raise [ClientError] if client not found or secret invalid
          # rubocop:disable Metrics/AbcSize
          def verify_client(client_id:, client_secret:)
            card_name = "#{CARD_PREFIX}+#{client_id}"

            begin
              response = @tools.get_card(card_name)
            rescue StandardError => e
              if e.message.include?("404") || e.message.include?("not found")
                raise ClientError,
                      "Client not found: #{client_id}"
              end

              raise ClientError, "Failed to fetch client: #{e.message}"
            end

            card = response["card"] || response
            content = parse_card_content(card["content"])

            # Verify secret against bcrypt hash
            stored_hash = BCrypt::Password.new(content["secret_hash"])
            raise ClientError, "Invalid client credentials" unless stored_hash == client_secret

            # Decrypt Decko password
            decrypted_password = decrypt_password(
              Base64.strict_decode64(content["encrypted_password"]),
              Base64.strict_decode64(content["encryption_iv"])
            )

            {
              username: content["username"],
              password: decrypted_password,
              role: content["role"],
              client_name: content["client_name"]
            }
          end
          # rubocop:enable Metrics/AbcSize

          # Revoke (delete) an OAuth client card
          #
          # @param client_id [String] the client ID to revoke
          # @return [Hash] deletion result
          def revoke_client(client_id:)
            card_name = "#{CARD_PREFIX}+#{client_id}"
            @tools.delete_card(card_name)
          end

          # List all OAuth clients for a given username
          #
          # @param username [String, nil] filter by username (nil for all)
          # @return [Array<Hash>] list of client summaries
          def list_clients(username: nil)
            results = @tools.search_cards(q: CARD_PREFIX, limit: 100)
            cards = results["cards"] || []

            cards.filter_map do |card|
              next unless card["name"]&.start_with?("#{CARD_PREFIX}+")

              content = parse_card_content(card["content"])
              next if username && content["username"] != username

              {
                client_id: card["name"].sub("#{CARD_PREFIX}+", ""),
                username: content["username"],
                role: content["role"],
                client_name: content["client_name"],
                created_at: content["created_at"]
              }
            end
          end

          private

          # Encrypt a password using AES-256-GCM
          #
          # @param plaintext [String] the password to encrypt
          # @return [Array<String, String>] [ciphertext, iv] as binary strings
          def encrypt_password(plaintext)
            cipher = OpenSSL::Cipher.new("aes-256-gcm")
            cipher.encrypt
            cipher.key = @encryption_key
            iv = cipher.random_iv

            ciphertext = cipher.update(plaintext) + cipher.final
            tag = cipher.auth_tag

            # Append auth tag to ciphertext for storage
            [ciphertext + tag, iv]
          end

          # Decrypt a password using AES-256-GCM
          #
          # @param ciphertext_with_tag [String] ciphertext with appended auth tag
          # @param init_vector [String] initialization vector
          # @return [String] decrypted password
          def decrypt_password(ciphertext_with_tag, init_vector)
            decipher = OpenSSL::Cipher.new("aes-256-gcm")
            decipher.decrypt
            decipher.key = @encryption_key
            decipher.iv = init_vector

            # Split auth tag (last 16 bytes) from ciphertext
            tag = ciphertext_with_tag[-16..]
            ciphertext = ciphertext_with_tag[0...-16]

            decipher.auth_tag = tag
            decipher.update(ciphertext) + decipher.final
          rescue OpenSSL::Cipher::CipherError => e
            raise ClientError, "Failed to decrypt password: #{e.message}"
          end

          # Parse JSON content from a card
          def parse_card_content(content)
            JSON.parse(content)
          rescue JSON::ParserError, TypeError
            raise ClientError, "Invalid client card content"
          end
        end
      end
    end
  end
end
