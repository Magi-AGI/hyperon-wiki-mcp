# frozen_string_literal: true

require "open3"
require_relative "client"

module Hyperon
  module Wiki
    module Mcp
      # MCP Tools for Hyperon Wiki operations
      #
      # Provides high-level tools for card retrieval, mutation, and management
      # that align with the MCP (Model Context Protocol) specification.
      #
      # @example Basic usage
      #   tools = Hyperon::Wiki::Mcp::Tools.new
      #   card = tools.get_card("User")
      #   cards = tools.search_cards(q: "game", limit: 10)
      #   children = tools.list_children("Business Plan")
      class Tools
        attr_reader :client

        # Initialize tools with optional client
        #
        # @param client [Client, nil] optional HTTP client (creates new one if nil)
        def initialize(client = nil)
          @client = client || Client.new
        end

        # Get a single card by name
        #
        # Fetches a card with all its metadata, content, and optionally its children.
        #
        # @param name [String] the card name
        # @param with_children [Boolean] include child cards (default: false)
        # @param rendered [Boolean] return fully rendered HTML with inclusions resolved (default: false)
        # @return [Hash] card data with keys: name, content, type, id, url, etc.
        # @raise [Client::NotFoundError] if card doesn't exist
        # @raise [Client::AuthorizationError] if user lacks permission to view card
        #
        # @example
        #   card = tools.get_card("User")
        #   # => { "name" => "User", "content" => "...", "type" => "Cardtype", ... }
        #
        # @example With children
        #   card = tools.get_card("Business Plan", with_children: true)
        #   # => { "name" => "Business Plan", "children" => [...], ... }
        #
        # @example Rendered (all inclusions resolved)
        #   card = tools.get_card("Administrator", rendered: true)
        #   # => { "name" => "Administrator", "content" => "<full rendered HTML>", "rendered" => true }
        def get_card(name, with_children: false, rendered: false)
          params = {}
          params[:with_children] = true if with_children
          params[:rendered] = true if rendered

          client.get("/cards/#{encode_card_name(name)}", **params)
        end

        # Search for cards
        #
        # Search cards by query string, optionally filtered by type.
        # Returns paginated results.
        #
        # @param q [String, nil] search query (substring match, case-insensitive)
        # @param type [String, nil] filter by card type (e.g., "User", "Role")
        # @param search_in [String, nil] where to search: "name" (default), "content", or "both"
        # @param limit [Integer] results per page (default: 50, max: 100)
        # @param offset [Integer] starting offset (default: 0)
        # @return [Hash] with keys: cards (array), total, limit, offset, next_offset
        # @raise [Client::ValidationError] if parameters are invalid
        #
        # @example Search card names only (default, fastest)
        #   results = tools.search_cards(q: "game")
        #   results["cards"].each { |card| puts card["name"] }
        #
        # @example Search card content (slower, more comprehensive)
        #   results = tools.search_cards(q: "neural lace", search_in: "content")
        #
        # @example Search both names and content
        #   results = tools.search_cards(q: "species", search_in: "both")
        #
        # @example Search with type filter
        #   users = tools.search_cards(type: "User", limit: 20)
        #
        # @example Paginated search
        #   page1 = tools.search_cards(q: "plan", limit: 10, offset: 0)
        #   page2 = tools.search_cards(q: "plan", limit: 10, offset: 10)
        def search_cards(q: nil, type: nil, search_in: nil, updated_since: nil, updated_before: nil, limit: 50, offset: 0, include_virtual: false)
          params = { limit: limit, offset: offset }
          params[:q] = q if q
          params[:type] = type if type
          params[:search_in] = search_in if search_in
          params[:updated_since] = updated_since if updated_since
          params[:updated_before] = updated_before if updated_before
          params[:include_virtual] = include_virtual

          client.get("/cards", **params)
        end

        # List all child cards of a parent
        #
        # Gets the children of a compound card (e.g., "Parent+Child" cards).
        # Per MCP-SPEC.md line 38: GET /api/mcp/cards/:name/children
        #
        # @param parent_name [String] the parent card name
        # @param limit [Integer] results per page (default: 50, max: 100)
        # @param offset [Integer] starting offset (default: 0)
        # @param depth [Integer] how many levels deep to fetch (default: 3)
        #   - depth=1: only direct children
        #   - depth=2: children and grandchildren
        #   - depth=3: children, grandchildren, and great-grandchildren
        # @return [Hash] with keys: parent, children (array with nested children), depth, child_count
        # @raise [Client::NotFoundError] if parent card doesn't exist
        #
        # @example
        #   result = tools.list_children("Business Plan")
        #   result["children"].each { |child| puts child["name"] }
        #
        # @example With depth
        #   result = tools.list_children("Games", depth: 2)
        #   # Returns children and grandchildren
        #
        # @example Paginated
        #   page1 = tools.list_children("Game Master", limit: 20, offset: 0)
        def list_children(parent_name, limit: 50, offset: 0, include_virtual: false, depth: 3)
          params = { limit: limit, offset: offset }
          params[:include_virtual] = include_virtual
          params[:depth] = depth if depth && depth > 1

          client.get("/cards/#{encode_card_name(parent_name)}/children", **params)
        end

        # Fetch all cards matching search criteria
        #
        # Automatically handles pagination and returns all matching cards.
        # Use with caution on large result sets.
        # Optionally yields each card to a block for iteration.
        #
        # @param q [String, nil] search query
        # @param type [String, nil] filter by card type
        # @param limit [Integer] maximum total results (default: 50)
        # @param offset [Integer] starting offset (default: 0)
        # @yield [Hash] each card if block given
        # @return [Array<Hash>] array of all matching cards if no block given
        #
        # @example Without block
        #   all_users = tools.fetch_all_cards(type: "User")
        #   puts "Found #{all_users.length} users"
        #
        # @example With block (memory efficient for large sets)
        #   tools.fetch_all_cards(type: "User", limit: 100) do |user|
        #     puts user["name"]
        #   end
        def fetch_all_cards(q: nil, type: nil, limit: 50, offset: 0, &block)
          params = {}
          params[:q] = q if q
          params[:type] = type if type

          # Cap limit at 100 to prevent excessive fetching
          effective_limit = [limit, 100].min

          # When limit is specified, collect only up to that many cards
          cards = []
          each_card_page(**params, limit: effective_limit, offset: offset) do |page|
            page_cards = page["cards"] || []
            remaining = effective_limit - cards.length
            cards.concat(page_cards.take(remaining))
            break if cards.length >= effective_limit
          end

          if block_given?
            cards.each(&block)
          else
            cards
          end
        end

        # Iterate over card search results page by page
        #
        # Yields each page of results to the block. More memory-efficient
        # than fetch_all_cards for large result sets.
        #
        # @param q [String, nil] search query
        # @param type [String, nil] filter by card type
        # @param limit [Integer] page size (default: 50)
        # @param max_pages [Integer, nil] maximum number of pages to fetch (default: unlimited)
        # @yield [Hash] each page response with cards array and metadata
        # @return [Enumerator] if no block given
        #
        # @example
        #   tools.each_card_page(type: "User", limit: 20) do |page|
        #     page["cards"].each { |user| puts user["name"] }
        #   end
        #
        # @example With page limit
        #   tools.each_card_page(type: "User", limit: 20, max_pages: 5) do |page|
        #     puts "Page has #{page['cards'].length} cards"
        #   end
        def each_card_page(q: nil, type: nil, limit: 50, offset: 0, max_pages: nil, &block)
          params = {}
          params[:q] = q if q
          params[:type] = type if type

          page_count = 0
          current_offset = offset
          loop do
            page_data = client.paginated_get("/cards", limit: limit, offset: current_offset, **params)
            items = page_data[:data]

            break if items.nil? || items.empty?

            page_count += 1

            # Yield full page hash with metadata (string keys for compatibility)
            yield({
              "cards" => items,
              "total" => page_data[:total],
              "offset" => page_data[:offset],
              "limit" => page_data[:limit]
            }) if block_given?

            break if max_pages && page_count >= max_pages

            # Move to next page
            current_offset = page_data[:next_offset] || (page_data[:offset] + items.length)
            break if page_data[:next_offset].nil? && items.length < limit
          end
        end

        # Create a new card
        #
        # Creates a card with the specified name, content, and type.
        # Requires appropriate permissions (user role can create basic cards).
        #
        # @param name [String] the card name (required)
        # @param content [String, nil] the card content (optional)
        # @param type [String, nil] the card type (optional, defaults to "RichText")
        # @param metadata [Hash] additional card metadata (optional)
        # @return [Hash] created card data with id, name, url, etc.
        # @raise [Client::ValidationError] if parameters are invalid
        # @raise [Client::AuthorizationError] if user lacks permission
        #
        # @example Simple card
        #   card = tools.create_card("My Note", content: "Some notes here")
        #
        # @example With type
        #   user = tools.create_card("john_doe", type: "User", content: "John's profile")
        #
        # @example Compound card (child)
        #   child = tools.create_card("Parent+Child", content: "Child content")
        def create_card(name, content: nil, type: nil, **metadata)
          payload = { name: name }
          payload[:content] = content if content
          payload[:type] = type if type
          payload.merge!(metadata) if metadata.any?

          client.post("/cards", **payload)
        end

        # Update an existing card
        #
        # Updates card content and/or metadata. Only specified fields are changed.
        #
        # @param name [String] the card name
        # @param content [String, nil] new content (optional)
        # @param type [String, nil] new type (optional)
        # @param metadata [Hash] metadata updates (optional)
        # @return [Hash] updated card data
        # @raise [Client::NotFoundError] if card doesn't exist
        # @raise [Client::AuthorizationError] if user lacks permission
        #
        # @example Update content
        #   tools.update_card("My Note", content: "Updated content")
        #
        # @example Update type
        #   tools.update_card("john_doe", type: "Administrator")
        #
        # @example Update multiple fields
        #   tools.update_card("Profile", content: "New bio", visibility: "public")
        def update_card(name, content: nil, type: nil, **metadata)
          payload = {}
          payload[:content] = content if content
          payload[:type] = type if type
          payload.merge!(metadata) if metadata.any?

          raise ArgumentError, "No update parameters provided" if payload.empty?

          client.patch("/cards/#{encode_card_name(name)}", **payload)
        end

        # Append content to a card
        #
        # Adds content to the end of the card's existing content.
        # Works on any content format (HTML, markdown, wiki links, etc).
        #
        # @param name [String] the card name
        # @param content [String] content to append
        # @param separator [String] separator between existing and new content (default: "")
        # @return [Hash] updated card data
        def append_content(name, content:, separator: "")
          client.patch("/cards/#{encode_card_name(name)}",
                       patch: { mode: "append", content: content, separator: separator })
        end

        # Prepend content to a card
        #
        # Adds content to the beginning of the card's existing content.
        # Works on any content format (HTML, markdown, wiki links, etc).
        #
        # @param name [String] the card name
        # @param content [String] content to prepend
        # @param separator [String] separator between new and existing content (default: "")
        # @return [Hash] updated card data
        def prepend_content(name, content:, separator: "")
          client.patch("/cards/#{encode_card_name(name)}",
                       patch: { mode: "prepend", content: content, separator: separator })
        end

        # Find and replace text in a card's content
        #
        # Performs a literal string find-and-replace on the card's raw stored content.
        # Works on any content format (HTML, markdown, wiki links, etc).
        #
        # @param name [String] the card name
        # @param find [String] the text to find (exact match, not regex)
        # @param replace [String] the replacement text
        # @param occurrence [String] which occurrences to replace: "first" (default), "last", "all"
        # @return [Hash] updated card data
        # @raise [Client::ValidationError] if text not found in card
        def find_and_replace(name, find:, replace:, occurrence: "first")
          client.patch("/cards/#{encode_card_name(name)}",
                       patch: { mode: "find_replace", find: find, replace: replace, occurrence: occurrence })
        end

        # Search within a card's content
        #
        # Searches for text within a card's raw stored content and returns
        # matching excerpts with surrounding context. Useful for finding
        # specific content without fetching the entire card.
        #
        # @param name [String] the card name
        # @param query [String] the text to search for (exact match)
        # @param context_chars [Integer] characters of context around each match (default: 100)
        # @return [Hash] with keys: card, query, match_count, content_length, matches
        def find_in_card(name, query:, context_chars: 100)
          client.get("/cards/#{encode_card_name(name)}/search_content",
                     query: query, context_chars: context_chars)
        end

        # Get the heading outline of a card
        #
        # Returns the heading structure (HTML h1-h6 and Markdown #) without
        # the full content. Useful for understanding card structure before
        # deciding which section to read or update.
        #
        # @param name [String] the card name
        # @return [Hash] with keys: card, type, content_length, headings
        def get_card_outline(name)
          client.get("/cards/#{encode_card_name(name)}/outline")
        end

        # Get statistics about a card without returning full content.
        #
        # Fetches the card and its outline, then computes local stats
        # including word count, character count, section count, link count,
        # image count, and paragraph count.
        #
        # @param name [String] the card name
        # @return [Hash] stats including word_count, char_count, section_count,
        #   paragraph_count, link_count, image_count, type, updated_at
        def get_card_stats(name)
          card = get_card(name)
          content = card["content"].to_s

          # Try to get outline for section count (may fail for some card types)
          section_count = 0
          begin
            outline = get_card_outline(name)
            section_count = (outline["headings"] || []).size
          rescue StandardError
            # outline not available for all card types
          end

          # Compute stats
          word_count = content.split(/\s+/).reject(&:empty?).size
          char_count = content.length

          # Count wiki links [[...]] and markdown links [text](url) and HTML links <a href=...>
          wiki_links = content.scan(/\[\[([^\]]+)\]\]/).size
          md_links = content.scan(/(?<!!)\[([^\]]+)\]\(([^)]+)\)/).size
          html_links = content.scan(/<a\s[^>]*href/i).size
          link_count = wiki_links + md_links + html_links

          # Count images
          md_images = content.scan(/!\[([^\]]*)\]\(([^)]+)\)/).size
          html_images = content.scan(/<img\s/i).size
          image_count = md_images + html_images

          # Paragraph count (non-empty blocks separated by blank lines or <p> tags)
          paragraphs = content.split(/\n\s*\n/).reject { |p| p.strip.empty? }.size
          html_paragraphs = content.scan(/<p[\s>]/i).size
          paragraph_count = [paragraphs, html_paragraphs].max

          {
            "card" => name,
            "type" => card["type"],
            "updated_at" => card["updated_at"],
            "stats" => {
              "word_count" => word_count,
              "char_count" => char_count,
              "section_count" => section_count,
              "paragraph_count" => paragraph_count,
              "link_count" => link_count,
              "image_count" => image_count,
              "wiki_links" => wiki_links,
              "external_links" => md_links + html_links
            }
          }
        end

        # Update content within a specific heading section by name
        #
        # Finds the section by heading text (case-insensitive match), replaces its
        # body content (preserving the heading), and updates the card. The section
        # body extends from after the heading to the next heading at the same or
        # higher level, or the end of the content.
        #
        # This is a composite client-side tool: it fetches the card, parses headings,
        # replaces the section body, and patches the card with the new full content.
        #
        # @param name [String] the card name
        # @param section [String] the heading text to find (e.g., "Introduction")
        # @param content [String] new content for the section body
        # @return [Hash] updated card data
        # @raise [Client::NotFoundError] if card doesn't exist
        # @raise [Client::ValidationError] if section heading not found
        # @raise [Client::AuthorizationError] if user lacks permission
        #
        # @example Update a section
        #   tools.update_section("MyCard", section: "Introduction", content: "New intro text")
        def update_section(name, section:, content:)
          card = get_card(name)
          raw_content = card["content"].to_s

          # Find section boundaries using heading patterns
          headings = parse_headings(raw_content)

          target = headings.find { |h| h[:text].strip.downcase == section.strip.downcase }
          unless target
            raise Client::ValidationError.new(
              "Section '#{section}' not found in card '#{name}'",
              status: 422, error_code: "validation_error"
            )
          end

          # Find end of section (next heading at same or higher level, or end of content)
          target_idx = headings.index(target)
          section_end = raw_content.length
          headings[(target_idx + 1)..].each do |h|
            if h[:level] <= target[:level]
              section_end = h[:position]
              break
            end
          end

          # Build new content: everything before section body + new content + everything after section
          heading_end = target[:heading_end]
          new_full_content = raw_content[0...heading_end] + "\n" + content.strip + "\n" + raw_content[section_end..]

          client.patch("/cards/#{encode_card_name(name)}", content: new_full_content)
        end

        # Submit feedback from an AI agent
        #
        # Appends feedback to the MCP Agent Feedback log card on the wiki.
        # Used by AI agents to report issues, suggest improvements, or
        # log observations during their interactions.
        #
        # @param category [String] feedback category: "bug", "feature_request", "usability", "performance", "other"
        # @param message [String] the feedback message
        # @param tool_name [String, nil] which MCP tool prompted the feedback (optional)
        # @return [Hash] updated card data
        def submit_feedback(category:, message:, tool_name: nil)
          timestamp = Time.now.utc.iso8601
          entry = "\n<p><strong>[#{timestamp}]</strong> "
          entry += "<em>(#{tool_name})</em> " if tool_name
          entry += "<strong>[#{category}]</strong> #{message}</p>"

          append_content("MCP Agent Feedback+log", content: entry, separator: "\n")
        rescue Client::NotFoundError
          # Create the feedback log card if it doesn't exist
          create_card("MCP Agent Feedback+log", content: entry, type: "RichText")
        end

        # Delete a card
        #
        # Permanently deletes a card. This operation cannot be undone.
        # Requires admin role permissions.
        #
        # @param name [String] the card name
        # @param force [Boolean] force deletion even with children (default: false)
        # @return [Hash] deletion confirmation with success status
        # @raise [Client::NotFoundError] if card doesn't exist
        # @raise [Client::AuthorizationError] if user lacks admin permission
        # @raise [Client::ValidationError] if card has children and force=false
        #
        # @example Delete card
        #   tools.delete_card("Obsolete Card")
        #
        # @example Force delete with children
        #   tools.delete_card("Parent Card", force: true)
        def delete_card(name, force: false)
          path = "/cards/#{encode_card_name(name)}"
          path += "?force=true" if force

          client.delete(path)
        end

        # Rename a card (admin only)
        #
        # Changes the name of an existing card. This is an admin-only operation.
        # Requires admin role permissions.
        #
        # @param name [String] current name of the card
        # @param new_name [String] new name for the card
        # @param update_referers [Boolean] whether to update all references to the card (default: true)
        # @return [Hash] rename result with old_name, new_name, status, updated_referers, and updated card data
        #
        # @example Rename a card and update all references
        #   result = tools.rename_card("Old Card Name", "New Card Name")
        #   puts "Renamed '#{result['old_name']}' to '#{result['new_name']}'"
        #   puts "Updated referers: #{result['updated_referers']}"
        #
        # @example Rename without updating references
        #   result = tools.rename_card("Old Card Name", "New Card Name", update_referers: false)
        #
        # @example Error handling
        #   begin
        #     tools.rename_card("NonExistent", "NewName")
        #   rescue => e
        #     puts "Rename failed: #{e.message}"
        #   end
        def rename_card(name, new_name, update_referers: true)
          path = "/cards/#{encode_card_name(name)}/rename"
          client.put(path, new_name: new_name, update_referers: update_referers)
        end

        # Upload a file or image to create or update a card.
        #
        # @param name [String] card name
        # @param type [String] "File" or "Image"
        # @param file_data [String] base64-encoded file content
        # @param filename [String] original filename (e.g., "diagram.png")
        # @return [Hash] card data with file_url and image_urls
        def upload_file(name, type:, file_data:, filename:)
          client.post("/cards/#{encode_card_name(name)}/upload",
                      type: type, file_data: file_data, filename: filename)
        end

        # Create a file or image card from a remote URL.
        #
        # @param name [String] card name
        # @param type [String] "File" or "Image"
        # @param url [String] URL to the file
        # @return [Hash] card data with file_url
        def upload_from_url(name, type:, url:)
          client.post("/cards/#{encode_card_name(name)}/upload",
                      type: type, remote_url: url)
        end

        # Get the download URL for a File or Image card.
        #
        # @param name [String] card name
        # @param size [String, nil] image size variant: "icon", "small", "medium", "large", "original"
        # @return [Hash] with file_url and image_urls keys
        def get_file_url(name, size: nil)
          result = client.get("/cards/#{encode_card_name(name)}/file_url")
          if size && result["image_urls"]
            result["selected_url"] = result["image_urls"][size] || result["file_url"]
          end
          result
        end

        # Get the default content template for a card type
        #
        # Templates are stored in Decko's +*type+*default rule cards.
        # When a new card of a given type is created, it starts with
        # this default content.
        #
        # @param type_name [String] the card type name (e.g., "Article", "Species")
        # @return [Hash] with keys: type, template_card, content, exists
        #
        # @example
        #   template = tools.get_template("Article")
        #   # => { "type" => "Article", "template_card" => "Article+*type+*default",
        #   #      "content" => "...", "exists" => true }
        #
        # @example Non-existent template
        #   template = tools.get_template("Unknown")
        #   # => { "type" => "Unknown", "template_card" => "Unknown+*type+*default",
        #   #      "content" => "", "exists" => false }
        def get_template(type_name)
          template_name = "#{type_name}+*type+*default"
          begin
            card = get_card(template_name)
            {
              "type" => type_name,
              "template_card" => template_name,
              "content" => card["content"].to_s,
              "exists" => true
            }
          rescue Client::NotFoundError
            {
              "type" => type_name,
              "template_card" => template_name,
              "content" => "",
              "exists" => false
            }
          end
        end

        # Set the default content template for a card type
        #
        # Creates or updates the +*type+*default rule card.
        # If the template already exists, it is updated; otherwise a new
        # template card is created.
        #
        # @param type_name [String] the card type name
        # @param content [String] the template content
        # @return [Hash] updated or created template card data
        #
        # @example
        #   tools.set_template("Article", content: "# New Article\n\nWrite content here.")
        def set_template(type_name, content:)
          template_name = "#{type_name}+*type+*default"
          begin
            # Try to update existing template
            client.patch("/cards/#{encode_card_name(template_name)}", content: content)
          rescue Client::NotFoundError
            # Template doesn't exist yet, create it
            client.post("/cards", name: template_name, type: "Basic", content: content)
          end
        end

        # Run spoiler scan job
        #
        # Scans for spoiler terms leaking from GM/AI content to player content.
        # Requires GM or admin role.
        #
        # @param terms_card [String] name of card containing spoiler terms
        # @param results_card [String] name of card to write results to
        # @param scope [String] scope to scan: "player" or "ai" (default: "player")
        # @param limit [Integer] max results (default: 500, max: 1000)
        # @return [Hash] with keys: status, matches, results_card, scope, terms_checked
        #
        # @example
        #   result = tools.spoiler_scan(
        #     terms_card: "SpoilerTerms",
        #     results_card: "ScanResults",
        #     scope: "player"
        #   )
        #   puts "Found #{result['matches']} spoilers"
        def spoiler_scan(terms_card:, results_card:, scope: "player", limit: 500)
          client.post("/jobs/spoiler-scan",
                      terms_card: terms_card,
                      results_card: results_card,
                      scope: scope,
                      limit: limit)
        end

        # List all card types
        #
        # Gets all available card types in the system.
        # Returns paginated results.
        #
        # @param limit [Integer] results per page (default: 50, max: 100)
        # @param offset [Integer] starting offset (default: 0)
        # @return [Hash] with keys: types (array), total, limit, offset, next_offset
        #
        # @example
        #   types = tools.list_types
        #   types["types"].each { |type| puts type["name"] }
        #
        # @example Paginated
        #   page1 = tools.list_types(limit: 20, offset: 0)
        def list_types(limit: 50, offset: 0)
          params = { limit: limit, offset: offset }
          client.get("/types", **params)
        end

        # Get all types
        #
        # Fetches all card types across all pages.
        # Optionally yields each type to a block for iteration.
        #
        # @param limit [Integer] maximum total results (default: 100)
        # @yield [Hash] each type if block given
        # @return [Array<Hash>] array of all card types if no block given
        #
        # @example Without block
        #   all_types = tools.fetch_all_types
        #   puts "Found #{all_types.length} card types"
        #
        # @example With block
        #   tools.fetch_all_types(limit: 50) do |type|
        #     puts type["name"]
        #   end
        def fetch_all_types(limit: 100, &block)
          types = client.fetch_all("/types", limit: limit)

          if block_given?
            types.each(&block)
          else
            types
          end
        end

        # Convert content between HTML and Markdown formats
        #
        # Converts content between HTML and Markdown using the server API.
        # Per MCP-SPEC.md lines 39-40:
        #   - HTML→Markdown: POST /api/mcp/render → returns { markdown:, format: "gfm" }
        #   - Markdown→HTML: POST /api/mcp/render/markdown → returns { html:, format: "html" }
        #
        # @param content [String] the content to convert
        # @param from [Symbol] source format (:html or :markdown)
        # @param to [Symbol] target format (:html or :markdown)
        # @return [Hash] server response with markdown: or html: key
        # @raise [ArgumentError] if from/to formats are invalid or the same
        #
        # @example HTML to Markdown
        #   result = tools.convert_content("<p>Hello <strong>world</strong></p>", from: :html, to: :markdown)
        #   # => { "markdown" => "Hello **world**", "format" => "gfm" }
        #
        # @example Markdown to HTML
        #   result = tools.convert_content("Hello **world**", from: :markdown, to: :html)
        #   # => { "html" => "<p>Hello <strong>world</strong></p>", "format" => "html" }
        def convert_content(content, from:, to:)
          valid_formats = %i[html markdown]
          unless valid_formats.include?(from) && valid_formats.include?(to)
            raise ArgumentError, "Format must be :html or :markdown"
          end

          raise ArgumentError, "Source and target formats cannot be the same" if from == to

          # Route to correct endpoint based on conversion direction
          # Server returns different response keys: markdown: or html:
          endpoint = if from == :html && to == :markdown
                       "/render"
                     elsif from == :markdown && to == :html
                       "/render/markdown"
                     else
                       raise ArgumentError, "Unsupported conversion: #{from} to #{to}"
                     end

          payload = { content: content }

          client.post(endpoint, **payload)
        end

        # Render a snippet of content with optional truncation
        #
        # Truncates long content to a specified length and adds ellipsis.
        # Useful for generating previews or summaries.
        #
        # @param content [String] the content to truncate
        # @param length [Integer] maximum length (default: 100)
        # @return [String] truncated content with ellipsis if needed
        #
        # @example Truncate long content
        #   snippet = tools.render_snippet("A" * 100, length: 20)
        #   # => "AAAAAAAAAAAAAAAAAAAA..."
        #
        # @example Short content unchanged
        #   snippet = tools.render_snippet("Short", length: 50)
        #   # => "Short"
        #
        # @example Handle HTML content
        #   snippet = tools.render_snippet("<p>HTML content</p>", length: 10)
        #   # => "<p>HTML co..."
        def render_snippet(content, length: 100)
          return "" if content.nil? || content.empty?

          if content.length <= length
            content
          else
            content[0...length] + "..."
          end
        end

        # Execute batch operations on multiple cards
        #
        # Performs multiple card operations (create/update) in a single request.
        # Per MCP-SPEC.md line 67: payload uses 'ops' key, not 'operations'
        # Returns individual results for each operation with HTTP 207 Multi-Status.
        # Supports transactional mode where all operations succeed or all fail.
        #
        # @param operations [Array<Hash>] array of operation specs (each with :action, :name, etc.)
        # @param mode [String] execution mode: "per_item" (default) or "transactional"
        # @return [Hash] with keys: results (array of per-operation results), mode
        # @raise [Client::ValidationError] if operations are invalid
        #
        # @example Batch create
        #   ops = [
        #     { action: "create", name: "Card 1", content: "Content 1" },
        #     { action: "create", name: "Card 2", content: "Content 2" }
        #   ]
        #   results = tools.batch_operations(ops)
        #
        # @example Mixed operations
        #   ops = [
        #     { action: "update", name: "Card 1", content: "Updated" },
        #     { action: "create", name: "Card 2", content: "New content" }
        #   ]
        #   results = tools.batch_operations(ops)
        #
        # @example Transactional mode
        #   results = tools.batch_operations(ops, mode: "transactional")
        #   # All succeed or all fail (rollback)
        def batch_operations(operations, mode: "per_item")
          valid_modes = %w[per_item transactional]
          raise ArgumentError, "Mode must be 'per_item' or 'transactional'" unless valid_modes.include?(mode)

          payload = {
            ops: operations,
            mode: mode
          }

          client.post("/cards/batch", **payload)
        end

        # Build operation for creating a child card
        #
        # Convenience helper for building batch operation specs for child cards.
        # Child cards use Decko's compound card naming: "Parent+ChildName"
        #
        # @param parent_name [String] the parent card name
        # @param child_name [String] the child name (will be prefixed with parent+)
        # @param content [String, nil] child card content
        # @param type [String, nil] child card type
        # @return [Hash] operation spec for use with batch_operations
        #
        # @example Create single child
        #   op = tools.build_child_op("Business Plan", "Overview", content: "Summary here")
        #   tools.batch_operations([op])
        #
        # @example Create multiple children
        #   ops = [
        #     tools.build_child_op("Business Plan", "Overview", content: "Summary"),
        #     tools.build_child_op("Business Plan", "Goals", content: "Objectives"),
        #     tools.build_child_op("Business Plan", "Timeline", content: "Schedule")
        #   ]
        #   tools.batch_operations(ops)
        def build_child_op(parent_name, child_name, content: nil, type: nil)
          full_name = "#{parent_name}+#{child_name}"
          op = {
            action: "create",
            name: full_name
          }
          op[:content] = content if content
          op[:type] = type if type
          op
        end

        # === Validation Operations ===

        # Validate tags for a card

        # Search cards by tag
        #
        # Searches for cards that have the specified tag.
        # Tags in Decko are typically stored as pointer cards (CardName+tags).
        #
        # @param tag_name [String] the tag to search for
        # @param limit [Integer] maximum results (default: 50)
        # @param offset [Integer] starting offset (default: 0)
        # @return [Array<Hash>] array of cards matching the tag
        #
        # @example
        #   results = tools.search_by_tag("Article")
        #   results.each { |card| puts card["name"] }
        def search_by_tag(tag_name, limit: 50, offset: 0)
          # Search for cards with +tags subcard containing the tag
          result = search_cards(q: "tags:#{tag_name}", limit: limit, offset: offset)
          result["cards"] || []
        end

        # Search cards by multiple tags (AND logic)
        #
        # Searches for cards that have all of the specified tags.
        #
        # @param tags [Array<String>] tags to search for
        # @param limit [Integer] maximum results (default: 50)
        # @param offset [Integer] starting offset (default: 0)
        # @return [Array<Hash>] array of cards matching all tags
        #
        # @example
        #   results = tools.search_by_tags(["Article", "Published"])
        #   results.each { |card| puts card["name"] }
        def search_by_tags(tags, limit: 50, offset: 0)
          # Search using tag query for each tag (AND logic)
          query = tags.map { |tag| "tags:#{tag}" }.join(" AND ")
          result = search_cards(q: query, limit: limit, offset: offset)
          result["cards"] || []
        end

        # Get all tags used in the system
        #
        # Returns all unique tags across all cards.
        # This fetches cards of type "Tag" or searches for +tags subcards.
        #
        # @param limit [Integer] maximum results (default: 100)
        # @return [Array<Hash>] array of tag cards
        #
        # @example
        #   tags = tools.get_all_tags
        #   tags.each { |tag| puts tag["name"] }
        def get_all_tags(limit: 100)
          # Try to fetch all Tag type cards
          result = search_cards(type: "Tag", limit: limit)
          result["cards"] || []
        rescue Client::APIError
          # Fallback: search for cards ending with +tags
          result = search_cards(q: "*+tags", limit: limit)
          result["cards"] || []
        end

        # Get tags for a specific card
        #
        # Returns the tags associated with the specified card.
        # Looks for a CardName+tags subcard.
        #
        # @param card_name [String] the card name
        # @return [Array<String>] array of tag names
        #
        # @example
        #   tags = tools.get_card_tags("Main Page")
        #   puts "Tags: #{tags.join(', ')}"
        def get_card_tags(card_name)
          tags_card = get_card("#{card_name}+tags")

          # Parse tags from content (usually pointer format)
          content = tags_card["content"] || ""

          # Tags can be in various formats:
          # - [[Tag1]], [[Tag2]]
          # - Simple list with newlines
          parse_tags_from_content(content)
        rescue Client::NotFoundError
          # No tags card exists
          []
        end

        # Search cards by tag pattern
        #
        # Searches for cards with tags matching a pattern.
        #
        # @param pattern [String] tag pattern to match (e.g., "game-*")
        # @param limit [Integer] maximum results (default: 50)
        # @return [Hash] search results with cards array
        #
        # @example
        #   results = tools.search_by_tag_pattern("game-*")
        #   results["cards"].each { |card| puts card["name"] }
        def search_by_tag_pattern(pattern, limit: 50)
          # Search for tags matching pattern
          tag_results = search_cards(q: pattern, type: "Tag", limit: limit)
          tag_names = (tag_results["cards"] || []).map { |c| c["name"] }

          # Search for cards with any of these tags
          return { "cards" => [], "total" => 0 } if tag_names.empty?

          search_by_tags_any(tag_names, limit: limit)
        end

        # Search cards by any of the specified tags (OR logic)
        #
        # Searches for cards that have at least one of the specified tags.
        #
        # @param tags [Array<String>] tags to search for
        # @param limit [Integer] maximum results (default: 50)
        # @return [Array<Hash>] array of cards matching any tag
        #
        # @example
        #   results = tools.search_by_tags_any(["Article", "Draft"])
        #   results.each { |card| puts card["name"] }
        def search_by_tags_any(tags, limit: 50)
          # Search using tag query for any tag (OR logic)
          query = tags.map { |tag| "tags:#{tag}" }.join(" OR ")
          result = search_cards(q: query, limit: limit)
          result["cards"] || []
        end

        # === Card Relationship Operations ===

        # Get cards that reference/link to this card
        #
        # Returns cards that contain references to the specified card.
        # Includes both explicit links [[CardName]] and nests {{CardName}}.
        #
        # @param card_name [String] the card name
        # @return [Array<Hash>] array of cards that reference this card
        # @raise [Client::NotFoundError] if card doesn't exist
        #
        # @example
        #   result = tools.get_referers("Main Page")
        #   result.each { |card| puts card["name"] }
        def get_referers(card_name)
          client.get("/cards/#{encode_card_name(card_name)}/referers")
        end

        # Get cards that nest/include this card
        #
        # Returns cards that include this card using nest syntax {{CardName}}.
        #
        # @param card_name [String] the card name
        # @return [Array<Hash>] array of cards that nest this card
        # @raise [Client::NotFoundError] if card doesn't exist
        #
        # @example
        #   result = tools.get_nested_in("Template Card")
        #   result.each { |card| puts card["name"] }
        def get_nested_in(card_name)
          client.get("/cards/#{encode_card_name(card_name)}/nested_in")
        end

        # Get cards that this card nests/includes
        #
        # Returns cards that are nested in this card using {{CardName}} syntax.
        #
        # @param card_name [String] the card name
        # @return [Array<Hash>] array of cards nested in this card
        # @raise [Client::NotFoundError] if card doesn't exist
        #
        # @example
        #   result = tools.get_nests("Main Page")
        #   result.each { |card| puts card["name"] }
        def get_nests(card_name)
          client.get("/cards/#{encode_card_name(card_name)}/nests")
        end

        # Get cards that this card links to
        #
        # Returns cards that are linked from this card using [[CardName]] syntax.
        #
        # @param card_name [String] the card name
        # @return [Array<Hash>] array of cards this card links to
        # @raise [Client::NotFoundError] if card doesn't exist
        #
        # @example
        #   result = tools.get_links("Main Page")
        #   result.each { |card| puts card["name"] }
        def get_links(card_name)
          client.get("/cards/#{encode_card_name(card_name)}/links")
        end

        # Get cards that link to this card
        #
        # Returns cards that link to this card using [[CardName]] syntax.
        #
        # @param card_name [String] the card name
        # @return [Array<Hash>] array of cards that link to this card
        # @raise [Client::NotFoundError] if card doesn't exist
        #
        # @example
        #   result = tools.get_linked_by("Main Page")
        #   result.each { |card| puts card["name"] }
        def get_linked_by(card_name)
          client.get("/cards/#{encode_card_name(card_name)}/linked_by")
        end

        # === Card History & Restore Operations ===

        # Get card revision history
        #
        # Returns the revision history for a card, including all past
        # creates, updates, and deletes. Each revision includes metadata
        # about who made the change and when.
        #
        # @param name [String] the card name
        # @param limit [Integer] maximum revisions to return (default: 20, max: 100)
        # @return [Hash] with keys: card, revisions (array), total, in_trash
        # @raise [Client::NotFoundError] if card doesn't exist
        # @raise [Client::AuthorizationError] if user lacks permission to view history
        #
        # @example Get recent history
        #   history = tools.get_card_history("My Card")
        #   history["revisions"].each do |rev|
        #     puts "#{rev['acted_at']}: #{rev['action']} by #{rev['actor']}"
        #   end
        #
        # @example Paginate through history
        #   history = tools.get_card_history("My Card", limit: 50)
        #   puts "Total revisions: #{history['total']}"
        def get_card_history(name, limit: 20)
          params = { limit: [limit, 100].min }

          client.get("/cards/#{encode_card_name(name)}/history", **params)
        end

        # Get content from a specific revision
        #
        # Retrieves the full card state at a specific point in time,
        # identified by act_id from the revision history.
        #
        # @param name [String] the card name
        # @param act_id [Integer] the revision act ID
        # @return [Hash] with keys: card, act_id, acted_at, actor, snapshot
        # @raise [Client::NotFoundError] if card or revision doesn't exist
        # @raise [Client::AuthorizationError] if user lacks permission
        #
        # @example Get specific revision content
        #   history = tools.get_card_history("My Card")
        #   old_act = history["revisions"].last["act_id"]
        #   revision = tools.get_revision("My Card", act_id: old_act)
        #   puts "Old content: #{revision['snapshot']['content']}"
        def get_revision(name, act_id:)
          client.get("/cards/#{encode_card_name(name)}/history/#{act_id}")
        end

        # Show differences between card revisions
        #
        # Compares two revisions, or a revision with the current version.
        # Uses a local LCS-based unified diff algorithm.
        #
        # @param name [String] the card name
        # @param from_revision [Integer, nil] act_id of the earlier revision (nil = earliest available)
        # @param to_revision [Integer, nil] act_id of the later revision (nil = current version)
        # @return [Hash] with keys: card, from, to, diff, summary
        # @raise [Client::NotFoundError] if card or revision doesn't exist
        # @raise [Client::AuthorizationError] if user lacks permission
        # @raise [Client::ValidationError] if card has no revision history
        #
        # @example Diff between two specific revisions
        #   result = tools.diff_card("My Card", from_revision: 100, to_revision: 200)
        #   puts result["diff"]
        #
        # @example Diff from a revision to current content
        #   result = tools.diff_card("My Card", from_revision: 100)
        #   puts result["summary"]
        def diff_card(name, from_revision: nil, to_revision: nil)
          # Get the "from" content
          if from_revision
            from_data = get_revision(name, act_id: from_revision)
            from_content = from_data.dig("snapshot", "content").to_s
            from_label = "revision #{from_revision} (#{from_data['acted_at']})"
          else
            # If no from_revision, get the earliest revision from history
            history = get_card_history(name, limit: 1)
            revisions = history["revisions"] || []
            raise Client::ValidationError.new("Card has no revision history") if revisions.empty?

            rev = revisions.last
            from_data = get_revision(name, act_id: rev["act_id"])
            from_content = from_data.dig("snapshot", "content").to_s
            from_label = "revision #{rev['act_id']} (#{from_data['acted_at']})"
          end

          # Get the "to" content
          if to_revision
            to_data = get_revision(name, act_id: to_revision)
            to_content = to_data.dig("snapshot", "content").to_s
            to_label = "revision #{to_revision} (#{to_data['acted_at']})"
          else
            card = get_card(name)
            to_content = card["content"].to_s
            to_label = "current"
          end

          # Compute diff
          diff_lines = compute_unified_diff(from_content, to_content, from_label, to_label)

          # Compute summary stats
          added = diff_lines.count { |l| l.start_with?("+") && !l.start_with?("+++") }
          removed = diff_lines.count { |l| l.start_with?("-") && !l.start_with?("---") }

          {
            "card" => name,
            "from" => from_label,
            "to" => to_label,
            "diff" => diff_lines.join("\n"),
            "summary" => {
              "lines_added" => added,
              "lines_removed" => removed,
              "total_changes" => added + removed
            }
          }
        end

        # Restore a card to a previous state
        #
        # Restores a card to a previous revision or undeletes a trashed card.
        # This operation requires admin role permissions.
        #
        # @param name [String] the card name
        # @param act_id [Integer, nil] revision ID to restore to (optional)
        # @param from_trash [Boolean] restore from trash instead of revision (default: false)
        # @return [Hash] with keys: success, card, restored_from, message
        # @raise [Client::NotFoundError] if card or revision doesn't exist
        # @raise [Client::AuthorizationError] if user lacks admin permission
        # @raise [Client::ValidationError] if neither act_id nor from_trash specified
        #
        # @example Restore to specific revision
        #   result = tools.restore_card("My Card", act_id: 12345)
        #   puts result["message"]
        #
        # @example Restore from trash
        #   result = tools.restore_card("Deleted Card", from_trash: true)
        #   puts "Restored: #{result['card']}"
        def restore_card(name, act_id: nil, from_trash: false)
          payload = {}
          payload[:act_id] = act_id if act_id
          payload[:from_trash] = true if from_trash

          if payload.empty?
            raise ArgumentError, "Must specify either act_id or from_trash: true"
          end

          client.post("/cards/#{encode_card_name(name)}/restore", **payload)
        end

        # List deleted cards in trash
        #
        # Returns cards that have been deleted (moved to trash) but not
        # permanently removed. This operation requires admin role permissions.
        #
        # @param limit [Integer] maximum cards to return (default: 50, max: 100)
        # @param offset [Integer] starting offset for pagination (default: 0)
        # @return [Hash] with keys: cards (array), total
        # @raise [Client::AuthorizationError] if user lacks admin permission
        #
        # @example List trashed cards
        #   trash = tools.list_trash(limit: 20)
        #   trash["cards"].each do |card|
        #     puts "#{card['name']} - deleted at #{card['deleted_at']} by #{card['deleted_by']}"
        #   end
        #
        # @example Check if a specific card is in trash
        #   trash = tools.list_trash(limit: 100)
        #   found = trash["cards"].find { |c| c["name"] == "My Card" }
        #   puts "Card is in trash!" if found
        def list_trash(limit: 50, offset: 0)
          params = { limit: [limit, 100].min, offset: offset }

          client.get("/trash", **params)
        end

        # === Admin Operations ===

        # Download database backup (admin only)
        #
        # Creates and downloads a database backup file.
        # Requires admin role permissions.
        #
        # @param save_path [String, nil] optional local path to save backup file
        # @return [String] backup file content or path if saved
        # @raise [Client::AuthorizationError] if user lacks admin permission
        #
        # @example Download to file
        #   tools.download_database_backup(save_path: "/tmp/backup.sql")
        #
        # @example Get backup content
        #   backup_content = tools.download_database_backup
        def download_database_backup(save_path: nil)
          response = client.get_raw("/admin/database/backup")

          if save_path
            File.write(save_path, response.body.to_s)
            save_path
          else
            response.body.to_s
          end
        end

        # List available database backups (admin only)
        #
        # Returns list of available backup files with metadata.
        # Requires admin role permissions.
        #
        # @return [Hash] with keys: backups (array), total, backup_dir
        # @raise [Client::AuthorizationError] if user lacks admin permission
        #
        # @example
        #   backups = tools.list_database_backups
        #   backups["backups"].each do |backup|
        #     puts "#{backup['filename']} - #{backup['size_human']} - #{backup['age']}"
        #   end
        def list_database_backups
          client.get("/admin/database/backup/list")
        end

        # Download specific database backup file (admin only)
        #
        # Downloads a previously created backup file by filename.
        # Requires admin role permissions.
        #
        # @param filename [String] the backup filename
        # @param save_path [String, nil] optional local path to save backup file
        # @return [String] backup file content or path if saved
        # @raise [Client::AuthorizationError] if user lacks admin permission
        # @raise [Client::NotFoundError] if backup file doesn't exist
        #
        # @example
        #   tools.download_database_backup_file(
        #     "hyperon_wiki_backup_20251203_120000.sql",
        #     save_path: "/tmp/backup.sql"
        #   )
        def download_database_backup_file(filename, save_path: nil)
          response = client.get_raw("/admin/database/backup/download/#{filename}")

          if save_path
            File.write(save_path, response.body.to_s)
            save_path
          else
            response.body.to_s
          end
        end

        # Delete database backup file (admin only)
        #
        # Deletes a specific backup file from the server.
        # Requires admin role permissions.
        #
        # @param filename [String] the backup filename to delete
        # @return [Hash] deletion confirmation
        # @raise [Client::AuthorizationError] if user lacks admin permission
        # @raise [Client::NotFoundError] if backup file doesn't exist
        #
        # @example
        #   tools.delete_database_backup("hyperon_wiki_backup_20251203_120000.sql")
        def delete_database_backup(filename)
          client.delete("/admin/database/backup/#{filename}")
        end

        # Parse tags from content string
        #
        # Extracts tag names from various Decko tag formats:
        # - [[Tag1]], [[Tag2]] (pointer format)
        # - Tag1\nTag2\n (line-separated)
        #
        # @param content [String] the content to parse
        # @return [Array<String>] extracted tag names
        #
        # @example Extract tags from pointer format
        #   tags = tools.parse_tags_from_content("[[tag1]] and [[tag2]]")
        #   # => ["tag1", "tag2"]
        #
        # @example Extract tags from line-separated format
        #   tags = tools.parse_tags_from_content("tag1\ntag2\ntag3")
        #   # => ["tag1", "tag2", "tag3"]
        def parse_tags_from_content(content)
          tags = []

          # Extract [[...]] format only
          content.scan(/\[\[([^\]]+)\]\]/) do |match|
            tags << match[0].strip
          end

          tags.uniq
        end

        # URL-encode card name for safe use in paths
        #
        # Per MCP-SPEC.md line 14: encode spaces and reserved chars, keep + literal
        # Encodes all RFC 3986 reserved characters except + (used for card hierarchy)
        #
        # @param name [String] the card name
        # @return [String] URL-encoded name
        #
        # @example Encode spaces
        #   tools.encode_card_name("Test Card Name")
        #   # => "Test%20Card%20Name"
        #
        # @example Preserve plus for compound cards
        #   tools.encode_card_name("Parent+Child")
        #   # => "Parent+Child"
        #
        # @example Encode special characters
        #   tools.encode_card_name("Test & Special / Characters")
        #   # => "Test%20%26%20Special%20%2F%20Characters"
        # Normalize card name to Decko format (spaces to underscores)
        def normalize_card_name(name)
          name.gsub(" ", "_")
        end

        # Search for cards and replace text in their content
        #
        # This is a convenience method that combines search and batch update operations.
        # It searches for cards containing a pattern, then replaces text across all matches.
        #
        # @param search_pattern [String, Regexp] Text or regex pattern to find in card content
        # @param replace_with [String] Replacement text
        # @param options [Hash] Search and replace options
        # @option options [String] :card_name_pattern Optional pattern to filter card names
        # @option options [String] :type Optional card type filter
        # @option options [Boolean] :regex (false) Treat search_pattern as regex
        # @option options [Boolean] :case_sensitive (true) Case-sensitive search
        # @option options [Integer] :limit (50) Max cards to update in single operation
        # @option options [Boolean] :dry_run (false) Preview changes without applying
        # @option options [String] :mode ("per_item") Batch mode: "per_item" or "transactional"
        #
        # @return [Hash] Results with :preview (dry run) or :updated (actual changes)
        #
        # @example Simple text replacement
        #   results = tools.search_and_replace("old text", "new text")
        #
        # @example Regex replacement with type filter
        #   results = tools.search_and_replace(
        #     /(foo|bar)/,
        #     "baz",
        #     type: "RichText",
        #     regex: true
        #   )
        #
        # @example Dry run to preview changes
        #   preview = tools.search_and_replace(
        #     "deprecated",
        #     "updated",
        #     dry_run: true
        #   )
        def search_and_replace(search_pattern, replace_with, **options)
          # Extract options with defaults
          card_name_pattern = options[:card_name_pattern]
          type = options[:type]
          use_regex = options.fetch(:regex, false)
          case_sensitive = options.fetch(:case_sensitive, true)
          limit = options.fetch(:limit, 50)
          dry_run = options.fetch(:dry_run, false)
          mode = options.fetch(:mode, "per_item")

          # Build search query to find cards with matching content
          search_params = { search_in: "content", limit: limit }
          
          # For regex patterns, we need to fetch cards and filter manually
          # For simple text, we can use the content search
          if use_regex
            # Fetch all cards of specified type and filter in Ruby
            fetch_params = { limit: 100 }
            fetch_params[:type] = type if type
            all_cards = fetch_all_cards(**fetch_params)
            
            regex = case_sensitive ? Regexp.new(search_pattern.to_s) : Regexp.new(search_pattern.to_s, Regexp::IGNORECASE)
            matching_cards = all_cards.select { |card| card["content"] =~ regex }
          else
            # Use server-side content search for simple text patterns
            search_params[:q] = search_pattern
            search_params[:type] = type if type
            search_result = search_cards(**search_params)
            matching_cards = search_result["cards"] || []
          end

          # Filter by card name pattern if provided
          if card_name_pattern
            name_regex = Regexp.new(card_name_pattern)
            matching_cards = matching_cards.select { |card| card["name"] =~ name_regex }
          end

          # Limit results
          matching_cards = matching_cards.take(limit)

          return { preview: [], message: "No matching cards found" } if matching_cards.empty?

          # Prepare replacement operations
          operations = matching_cards.map do |card|
            # Fetch full card content
            full_card_response = get_card(card["name"])
            full_card = full_card_response["card"] || full_card_response
            original_content = full_card["content"] || ""
            
            # Perform replacement
            new_content = if use_regex
                           regex = case_sensitive ? Regexp.new(search_pattern.to_s) : Regexp.new(search_pattern.to_s, Regexp::IGNORECASE)
                           original_content.gsub(regex, replace_with)
                         else
                           if case_sensitive
                             original_content.gsub(search_pattern, replace_with)
                           else
                             original_content.gsub(/#{Regexp.escape(search_pattern)}/i, replace_with)
                           end
                         end

            # Skip if no changes
            next nil if original_content == new_content

            {
              card_name: card["name"],
              original_content: original_content,
              new_content: new_content,
              operation: {
                action: "update",
                name: card["name"],
                content: new_content
              }
            }
          end.compact

          return { preview: [], message: "No changes needed" } if operations.empty?

          # Return preview for dry run
          if dry_run
            return {
              preview: operations.map do |op|
                {
                  card_name: op[:card_name],
                  changes: "Content will be updated (#{op[:original_content].length} → #{op[:new_content].length} chars)"
                }
              end,
              total_cards: operations.size,
              message: "Dry run complete. Use dry_run: false to apply changes."
            }
          end

          # Execute batch update
          batch_ops = operations.map { |op| op[:operation] }
          result = batch_operations(batch_ops, mode: mode)

          {
            updated: operations.map { |op| op[:card_name] },
            total_cards: operations.size,
            batch_result: result
          }
        end

        def encode_card_name(name)
          # Encode all characters except: A-Z a-z 0-9 - _ ~ +
          # Keep + literal for Decko compound cards (e.g., "Parent+Child")
          # NOTE: Periods (.) MUST be encoded as %2E because Rails interprets
          # unencoded periods in URL paths as format separators (e.g., "Dr.Venn"
          # would be parsed as format: "Venn"). This breaks cards like "Dr. Smith".
          #
          # Force UTF-8 encoding before percent-encoding bytes. On Windows,
          # strings may arrive in IBM437/Windows-1252 which produces wrong
          # byte sequences for non-ASCII chars (e.g., ö → %94 instead of %C3%B6).
          utf8_name = name.encode("UTF-8")
          utf8_name.chars.map do |char|
            if char.ascii_only? && char.match?(/[A-Za-z0-9\-_~+]/)
              char
            else
              char.bytes.map { |byte| format("%%%02X", byte) }.join
            end
          end.join
        end

        private

        # Compute a unified diff between two strings
        #
        # Uses an LCS (Longest Common Subsequence) algorithm to produce
        # a unified diff with context lines.
        #
        # @param old_text [String] the original text
        # @param new_text [String] the new text
        # @param old_label [String] label for the old version
        # @param new_label [String] label for the new version
        # @return [Array<String>] diff lines in unified format
        def compute_unified_diff(old_text, new_text, old_label, new_label)
          old_lines = old_text.lines.map(&:chomp)
          new_lines = new_text.lines.map(&:chomp)

          result = ["--- #{old_label}", "+++ #{new_label}"]

          # Simple LCS-based diff
          # Build a table of common subsequences
          lcs = Array.new(old_lines.size + 1) { Array.new(new_lines.size + 1, 0) }
          old_lines.each_with_index do |_, i|
            new_lines.each_with_index do |_, j|
              lcs[i + 1][j + 1] = if old_lines[i] == new_lines[j]
                                     lcs[i][j] + 1
                                   else
                                     [lcs[i][j + 1], lcs[i + 1][j]].max
                                   end
            end
          end

          # Backtrack to find diff
          diff_ops = []
          i = old_lines.size
          j = new_lines.size
          while i.positive? || j.positive?
            if i.positive? && j.positive? && old_lines[i - 1] == new_lines[j - 1]
              diff_ops.unshift([:keep, old_lines[i - 1]])
              i -= 1
              j -= 1
            elsif j.positive? && (i.zero? || lcs[i][j - 1] >= lcs[i - 1][j])
              diff_ops.unshift([:add, new_lines[j - 1]])
              j -= 1
            else
              diff_ops.unshift([:remove, old_lines[i - 1]])
              i -= 1
            end
          end

          # Format as unified diff with context
          context = 3
          chunks = []
          current_chunk = nil

          diff_ops.each_with_index do |op, idx|
            if op[0] != :keep
              # Start or extend a chunk
              start = [idx - context, 0].max
              unless current_chunk
                current_chunk = { start: start, ops: [] }
                # Add leading context
                (start...idx).each { |ci| current_chunk[:ops] << diff_ops[ci] if diff_ops[ci] }
              end
              current_chunk[:ops] << op
              current_chunk[:end_idx] = idx
            elsif current_chunk && idx <= current_chunk[:end_idx] + context
              current_chunk[:ops] << op
            elsif current_chunk
              chunks << current_chunk
              current_chunk = nil
            end
          end
          chunks << current_chunk if current_chunk

          # If no changes
          return result + ["(no differences)"] if chunks.empty?

          chunks.each do |chunk|
            chunk[:ops].each do |op|
              case op[0]
              when :keep then result << " #{op[1]}"
              when :add then result << "+#{op[1]}"
              when :remove then result << "-#{op[1]}"
              end
            end
          end

          result
        end

      public

      # === Weekly Summary Operations ===

      # Get cards updated within a date range
      #
      # Retrieves all cards that have been updated within the specified time period.
      # Useful for generating weekly summaries or tracking recent changes.
      #
      # @param days [Integer] number of days to look back (default: 7)
      # @param since [Time, String, nil] specific start date (overrides days)
      # @param before [Time, String, nil] specific end date (default: now)
      # @param limit [Integer] maximum results per page (default: 100)
      # @param max_cards [Integer] maximum total cards to fetch (default: 5000).
      #   Safety cap to prevent unbounded memory growth.
      # @return [Array<Hash>] array of updated cards with metadata
      #
      # @example Get cards updated in last week
      #   changes = tools.get_recent_changes(days: 7)
      #   changes.each { |card| puts "#{card['name']} - #{card['updated_at']}" }
      #
      # @example Get cards updated in specific date range
      #   changes = tools.get_recent_changes(
      #     since: "2025-11-25",
      #     before: "2025-12-02"
      #   )
      def get_recent_changes(days: 7, since: nil, before: nil, limit: 100, max_cards: 5000)
        since_time = since ? parse_time(since) : (Time.now - (days * 24 * 60 * 60))
        before_time = before ? parse_time(before) : Time.now

        all_cards = []
        offset = 0
        loop_count = 0
        max_loops = [max_cards / [limit, 1].max + 1, 100].min

        loop do
          loop_count += 1
          if loop_count > max_loops
            warn "Pagination safety limit reached (#{max_loops} pages). " \
                 "Returning #{all_cards.size} cards so far."
            break
          end

          result = search_cards(
            updated_since: since_time.utc.iso8601,
            updated_before: before_time.utc.iso8601,
            limit: limit,
            offset: offset
          )

          cards = result["cards"] || []
          break if cards.empty?

          all_cards.concat(cards)

          # Stop if we've collected enough cards
          if all_cards.size >= max_cards
            all_cards = all_cards.first(max_cards)
            break
          end

          offset = result["next_offset"]
          break unless offset
        end

        # Sort by updated_at descending (most recent first)
        all_cards.sort_by { |c| c["updated_at"] || "" }.reverse
      end

      # Scan git repositories for changes
      #
      # Scans all git repositories under the specified base path for commits
      # made within the specified time period. Useful for generating weekly
      # summaries of development activity.
      #
      # @param base_path [String, nil] root directory to scan (default: current directory)
      # @param days [Integer] number of days to look back (default: 7)
      # @param since [Time, String, nil] specific start date (overrides days)
      # @return [Hash] repository changes grouped by repo name
      #
      # @example Scan repos in current directory
      #   changes = tools.scan_git_repos(days: 7)
      #   changes.each do |repo, commits|
      #     puts "#{repo}: #{commits.size} commits"
      #   end
      #
      # @example Scan specific directory
      #   changes = tools.scan_git_repos(
      #     base_path: "/path/to/projects",
      #     days: 7
      #   )
      def scan_git_repos(base_path: nil, days: 7, since: nil)
        # Use WORKING_DIR from environment if base_path not specified
        # Falls back to current directory as last resort
        base_path ||= ENV["WORKING_DIR"] || Dir.pwd

        since_time = since ? parse_time(since) : (Time.now - (days * 24 * 60 * 60))
        since_str = since_time.strftime("%Y-%m-%d")

        repos = find_git_repos(base_path)
        changes = {}

        repos.each do |repo_path|
          repo_name = File.basename(repo_path)
          commits = get_git_commits(repo_path, since: since_str)

          changes[repo_name] = commits unless commits.empty?
        end

        changes
      end

      # Format weekly summary markdown
      #
      # Creates formatted markdown content for a weekly summary card,
      # following the standard Weekly Work Summary format used in the wiki.
      #
      # @param card_changes [Array<Hash>] cards updated during the period
      # @param repo_changes [Hash] repository changes grouped by repo name
      # @param title [String, nil] custom title (default: auto-generated from date)
      # @param executive_summary [String, nil] custom executive summary
      # @return [String] formatted markdown content
      #
      # @example Basic usage
      #   cards = tools.get_recent_changes(days: 7)
      #   repos = tools.scan_git_repos(days: 7)
      #   markdown = tools.format_weekly_summary(cards, repos)
      #
      # @example With custom title and summary
      #   markdown = tools.format_weekly_summary(
      #     cards, repos,
      #     title: "Weekly Work Summary 2025 12 09",
      #     executive_summary: "Focused on MCP API enhancements..."
      #   )
      def format_weekly_summary(card_changes, repo_changes, title: nil, executive_summary: nil)
        date_str = Time.now.strftime("%Y %m %d")
        title ||= "Weekly Work Summary #{date_str}"

        summary = []
        summary << "# #{title}\n\n"

        # Executive Summary
        summary << "## Executive Summary\n\n"
        if executive_summary
          summary << "#{executive_summary}\n\n"
        else
          summary << "This week saw #{card_changes.size} card updates across the wiki"
          summary << " and #{repo_changes.values.sum(&:size)} commits across #{repo_changes.size} repositories.\n\n"
        end

        # Wiki Card Updates
        if card_changes.any?
          summary << "## Wiki Card Updates\n\n"
          summary << format_card_changes(card_changes)
          summary << "\n"
        end

        # Repository Changes
        if repo_changes.any?
          summary << "## Repository & Code Changes\n\n"
          summary << format_repo_changes(repo_changes)
          summary << "\n"
        end

        # Next Steps placeholder
        summary << "## Next Steps\n\n"
        summary << "- [Add your next steps here]\n"
        summary << "- \n"
        summary << "- \n\n"

        summary.join
      end

      # Create weekly summary card
      #
      # Convenience method that combines all steps: fetches recent changes,
      # scans repositories, formats the summary, and creates the card.
      #
      # @param base_path [String, nil] root directory for repo scanning (default: current dir)
      # @param days [Integer] number of days to look back (default: 7)
      # @param date [String, nil] date string for card name (default: today)
      # @param executive_summary [String, nil] custom executive summary
      # @param parent [String] parent card name (default: "Home")
      # @param create_card [Boolean] whether to create the card (default: false, returns markdown for review)
      # @return [Hash, String] created card data if create_card=true, or markdown content for preview if false
      #
      # @example Generate summary for review (default behavior)
      #   markdown = tools.create_weekly_summary
      #   puts markdown  # Review the content first
      #
      # @example Create and post summary directly
      #   card = tools.create_weekly_summary(create_card: true)
      #
      # @example Create summary for specific period
      #   card = tools.create_weekly_summary(
      #     days: 7,
      #     date: "2025 12 09",
      #     executive_summary: "Focused on MCP API Phase 2.1 completion...",
      #     create_card: true  # Explicitly create the card
      #   )
      def create_weekly_summary(base_path: nil, days: 7, date: nil, executive_summary: nil, parent: "Weekly Work Summaries", create_card: false, username: nil)
        # Get username from Decko authentication if not provided
        username ||= client.username || "Unknown User"

        # Get date string for card name
        date_str = date || Time.now.strftime("%Y %m %d")

        # Make this a child of the parent card using "+" notation
        # Format: "Weekly Work Summaries+Weekly Work Summary YYYY MM DD - Username"
        # This matches the existing pattern used for previous summaries
        card_name = "#{parent}+Weekly Work Summary #{date_str} - #{username}"

        # Fetch recent changes (capped at 500 to avoid memory bloat)
        card_changes = get_recent_changes(days: days, max_cards: 500)
        repo_changes = scan_git_repos(base_path: base_path, days: days)

        # Format summary
        content = format_weekly_summary(
          card_changes,
          repo_changes,
          title: "Weekly Work Summary #{date_str} - #{username}",
          executive_summary: executive_summary
        )

        # Return preview with metadata if not creating card
        unless create_card
          return {
            "preview" => true,
            "card_name" => card_name,
            "card_type" => "Markdown",
            "parent" => parent,
            "date" => date_str,
            "username" => username,
            "content" => content,
            "toc_card" => "#{parent}+table-of-contents"
          }
        end

        # Create the card as a child of the parent
        # Use Markdown type to match existing weekly summaries
        card = self.create_card(
          card_name,
          content: content,
          type: "Markdown"
        )

        # Add to table of contents
        update_weekly_summaries_toc(card_name, date_str, username)

        card
      end

      private

      # Parse headings from HTML and Markdown content
      #
      # Supports both HTML headings (<h1>text</h1> through <h6>text</h6>) and
      # Markdown headings (# text through ###### text). Returns an array of
      # heading metadata sorted by position in the content.
      #
      # @param content [String] the raw card content
      # @return [Array<Hash>] array of { level:, text:, position:, heading_end: }
      def parse_headings(content)
        headings = []

        # HTML headings: <h1>text</h1> through <h6>text</h6>
        content.scan(/<h([1-6])[^>]*>(.*?)<\/h\1>/mi) do
          match = Regexp.last_match
          headings << {
            level: match[1].to_i,
            text: match[2].gsub(/<[^>]+>/, "").strip,
            position: match.begin(0),
            heading_end: match.end(0)
          }
        end

        # Markdown headings: # text through ###### text
        content.scan(/^(\#{1,6})\s+(.+)$/) do
          match = Regexp.last_match
          headings << {
            level: match[1].length,
            text: match[2].strip,
            position: match.begin(0),
            heading_end: match.end(0)
          }
        end

        headings.sort_by { |h| h[:position] }
      end

      # Parse time from various formats
      def parse_time(time_input)
        return time_input if time_input.is_a?(Time)

        str = time_input.to_s
        # If it's a date-only string (YYYY-MM-DD), parse as UTC midnight
        # to avoid timezone conversion issues
        if str.match?(/^\d{4}-\d{2}-\d{2}$/)
          Time.parse("#{str} 00:00:00 UTC")
        else
          Time.parse(str).utc
        end
      end

      # Find all git repositories under a path
      def find_git_repos(base_path)
        repos = []

        return repos unless File.directory?(base_path)

        # Check if base_path itself is a git repo
        if File.directory?(File.join(base_path, ".git"))
          repos << base_path
        end

        # Find subdirectories with .git folders (search up to 3 levels deep)
        [1, 2, 3].each do |depth|
          pattern = File.join(base_path, *Array.new(depth, "*"), ".git")
          Dir.glob(pattern).each do |git_dir|
            repos << File.dirname(git_dir)
          end
        end

        repos.uniq
      rescue StandardError => e
        warn "Error finding git repos in #{base_path}: #{e.message}"
        []
      end

      # Get git commits for a repository since a date
      def get_git_commits(repo_path, since:)
        # Use Timeout wrapper with Open3.capture3 for safer command execution
        stdout, stderr, status = Timeout.timeout(30) do
          Open3.capture3(
            "git", "log",
            "--since=#{since}",
            "--pretty=format:%h|%an|%ad|%s",
            "--date=short",
            chdir: repo_path
          )
        end

        # Return empty if command failed
        return [] unless status.success?

        # Parse output into structured commits
        stdout.split("\n").map do |line|
          hash, author, date, subject = line.split("|", 4)
          {
            "hash" => hash,
            "author" => author,
            "date" => date,
            "subject" => subject
          }
        end
      rescue Timeout::Error
        warn "Git log timed out for #{repo_path}. Skipping this repo."
        []
      rescue StandardError => e
        # If we can't read the repo, return empty
        warn "Failed to read git commits from #{repo_path}: #{e.message}"
        []
      end

      # Format card changes for summary
      def format_card_changes(cards)
        lines = []

        # Group by card type or hierarchy level
        grouped = cards.group_by do |card|
          # Group by top-level parent if it's a compound card
          if card["name"].include?("+")
            card["name"].split("+").first
          else
            "Top Level"
          end
        end

        grouped.each do |group, group_cards|
          if group != "Top Level"
            lines << "### #{group}\n\n"
          end

          group_cards.each do |card|
            # Format: `Card Name+Subcard` - brief description
            card_path = "`#{card['name']}`"
            updated = card["updated_at"] ? " (#{format_date(card['updated_at'])})" : ""
            lines << "- #{card_path}#{updated}\n"
          end

          lines << "\n"
        end

        lines.join
      end

      # Format repository changes for summary
      def format_repo_changes(repo_changes)
        lines = []

        repo_changes.each do |repo_name, commits|
          lines << "### #{repo_name}\n\n"
          lines << "**#{commits.size} commit#{commits.size == 1 ? '' : 's'}**\n\n"

          commits.first(10).each do |commit|
            lines << "- `#{commit['hash']}` #{commit['subject']} (#{commit['author']}, #{commit['date']})\n"
          end

          if commits.size > 10
            lines << "- ... and #{commits.size - 10} more commits\n"
          end

          lines << "\n"
        end

        lines.join
      end

      # Format date for display
      def format_date(date_str)
        Time.parse(date_str).strftime("%Y-%m-%d")
      rescue StandardError
        date_str
      end

      # Update the Weekly Work Summaries table of contents
      #
      # Adds a link to a newly created weekly summary to the TOC card.
      # Creates the TOC card if it doesn't exist.
      #
      # @param card_name [String] the full card name (e.g., "Weekly Work Summaries+Weekly Work Summary 2025 12 08 - Nemquae")
      # @param date_str [String] the date string (e.g., "2025 12 08")
      # @param username [String] the username (e.g., "Nemquae")
      def update_weekly_summaries_toc(card_name, date_str, username)
        toc_card_name = "Weekly Work Summaries+table-of-contents"

        # Try to fetch existing TOC
        begin
          toc = get_card(toc_card_name)
          content = toc["content"] || ""
        rescue Client::NotFoundError
          # TOC doesn't exist, create it with HTML ordered list structure
          content = "<ol>\n</ol>"
        end

        # Create display name for the link
        # Format: "Weekly Work Summary YYYY MM DD - Username"
        display_name = "Weekly Work Summary #{date_str} - #{username}"

        # Create the new TOC entry in HTML format
        # Format: <li>[[CardName|DisplayName]]</li>
        new_entry = "<li>[[#{card_name}|#{display_name}]]</li>"

        # Check if this entry already exists
        return if content.include?(new_entry)

        # Insert at the top of the list (most recent first)
        # Find the opening <ol> tag and insert after it
        if content.include?("<ol>")
          # Insert new entry right after <ol> tag
          updated_content = content.sub(/<ol>\s*/i, "<ol>\n#{new_entry}\n")
        else
          # No <ol> tag found, wrap content in a new ordered list
          updated_content = "<ol>\n#{new_entry}\n#{content}</ol>"
        end

        # Update or create the TOC card
        begin
          update_card(toc_card_name, content: updated_content)
        rescue Client::NotFoundError
          # Create the TOC card
          create_card(toc_card_name, content: updated_content, type: "RichText")
        end
      rescue StandardError => e
        # Log error but don't fail the whole operation
        warn "Failed to update TOC: #{e.message}"
      end

      public

      # Get site context information for AI agents
      #
      # Returns structured information about the wiki's hierarchy, organization,
      # and content placement guidelines to help AI agents understand where to
      # find content and where to place new content.
      #
      # @return [Hash] Site context with hierarchy, sections, and guidelines
      #
      # @example Get site context
      #   context = tools.get_site_context
      #   puts context[:hierarchy]
      #   puts context[:guidelines]
      def get_site_context
        {
          wiki_name: "Hyperon Wiki",
          wiki_url: "https://wiki.hyperon.dev",
          description: "Knowledge base for Magi-AGI projects including games, business plans, AI research, and notes",

          hierarchy: {
            "Home" => {
              description: "Main landing page with table of contents",
              sections: [
                "Overview",
                "Weekly Work Summaries",
                "Business Plan",
                "Neoterics",
                "Games",
                "Notes"
              ]
            },
            "Games" => {
              description: "Game projects and worldbuilding",
              games: [
                {
                  name: "Gods Game",
                  path: "Games+Gods Game",
                  description: "Pantheon-based game"
                },
                {
                  name: "Inkling",
                  path: "Games+Inkling",
                  description: "Inkling game project"
                },
                {
                  name: "Ledge Board Game",
                  path: "Games+Ledge Board Game",
                  description: "Board game project"
                },
                {
                  name: "Butterfly Galaxii",
                  path: "Games+Butterfly Galaxii",
                  description: "Primary sci-fi RPG with extensive worldbuilding",
                  sections: [
                    "Preface",
                    "Introduction",
                    "Player Docs (Player+...)",
                    "GM Docs (GM Docs+...)",
                    "AI Docs (AI Docs+...)"
                  ],
                  key_areas: {
                    "Factions" => "Games+Butterfly Galaxii+Player+Factions",
                    "Species" => "Games+Butterfly Galaxii+Player+Species",
                    "Cultures" => "Games+Butterfly Galaxii+Player+Cultures",
                    "Tech" => "Games+Butterfly Galaxii+Player+Tech"
                  }
                }
              ]
            },
            "Business Plan" => {
              description: "Business planning and strategy documents",
              path: "Business Plan"
            },
            "Neoterics" => {
              description: "AI/AGI research and frameworks (MAGUS, MeTTa, OpenPsi)",
              path: "Neoterics"
            },
            "Notes" => {
              description: "General notes and miscellaneous content",
              path: "Notes"
            }
          },

          guidelines: {
            naming_conventions: [
              "Use '+' to create hierarchical card names (e.g., 'Games+Butterfly Galaxii+Player+Species')",
              "Card names are case-sensitive",
              "Use spaces in card names, not underscores (MCP tools handle encoding)",
              "Avoid creating 'virtual cards' - prefer placing content in full hierarchical paths"
            ],

            content_placement: [
              "Place game content under appropriate game (e.g., 'Games+Butterfly Galaxii+...')",
              "Use Player/GM/AI Docs hierarchy within games for role-specific content",
              "Player Docs: publicly visible content for players",
              "GM Docs: game master notes, hidden from players",
              "AI Docs: instructions and context for AI agents",
              "Check for existing '+GM+AI' cards in a section for AI-specific guidance (like CLAUDE.md files)",
              "Business content goes under 'Business Plan'",
              "AI research goes under 'Neoterics'",
              "Miscellaneous content goes under 'Notes'"
            ],

            content_structure: [
              "Major sections should have a '+table-of-contents' child card",
              "Use '+intro' or '+Preface' for introductory content",
              "Keep table-of-contents cards updated when adding new subsections",
              "Use RichText type for most content cards",
              "Use Pointer type for cards that reference other cards",
              "Search cards contain dynamic queries, not static results"
            ],

            special_cards: [
              "Virtual cards: Empty junction cards that exist for naming - actual content is in compound child cards",
              "Pointer cards: Contain references to other cards (use list_children to see them)",
              "Search cards: Content shows query, results are dynamic",
              "+GM+AI cards: Look for these in sections for AI-specific instructions and context",
              "Deleted cards: Marked as trash in database, filtered from normal results. To restore: create new card with same name, then access history tab on wiki to restore previous content (no automated API yet)"
            ],

            best_practices: [
              "IMPORTANT: Before working in a section, check for a '+GM+AI' card (e.g., 'Games+Butterfly Galaxii+GM+AI') - these contain AI-specific instructions similar to CLAUDE.md files",
              "Always search for existing content before creating new cards",
              "Check parent card's +table-of-contents before adding new sections",
              "Use search_cards with search_in: 'both' for comprehensive searches",
              "Virtual cards are usually empty - look for compound child cards with full paths",
              "When in doubt about placement, check the Home+table-of-contents hierarchy",
              "For any major section or game, look for '<Section>+GM+AI' cards that provide context-specific guidance"
            ]
          },

          common_patterns: {
            game_content: "Games+<GameName>+<PlayerGMAI>+<Section>+<Subsection>+<CardName>",
            business: "Business Plan+<Section>+<CardName>",
            research: "Neoterics+<Topic>+<CardName>",
            notes: "Notes+<Category>+<CardName>"
          },

          helpful_cards: [
            "Home+table-of-contents - Main navigation structure",
            "Games+table-of-contents - All game projects",
            "Games+Butterfly Galaxii+table-of-contents - Main RPG structure",
            "Games+Butterfly Galaxii+AI Docs+table-of-contents - AI agent guidance for BG"
          ]
        }
      end

      # Find and retrieve +GM+AI instruction card for a section
      #
      # Checks if a section has a +GM+AI card that contains AI-specific
      # instructions and context (similar to CLAUDE.md files in code repositories).
      #
      # @param section_name [String] the section name (e.g., "Games+Butterfly Galaxii")
      # @return [Hash, nil] the +GM+AI card content if it exists, nil otherwise
      #
      # @example Check for AI instructions in Butterfly Galaxii
      #   instructions = tools.get_ai_instructions("Games+Butterfly Galaxii")
      #   if instructions
      #     puts instructions["content"]
      #   end
      #
      # @example Common patterns
      #   tools.get_ai_instructions("Games+Butterfly Galaxii")  # Main game instructions
      #   tools.get_ai_instructions("Games+Butterfly Galaxii+Player")  # Player section
      #   tools.get_ai_instructions("Business Plan")  # Business plan instructions
      def get_ai_instructions(section_name)
        ai_card_name = "#{section_name}+GM+AI"

        begin
          response = get_card(ai_card_name)
          card = response["card"] || response

          # Return the card if it has meaningful content
          if card && card["content"] && !card["content"].strip.empty?
            card
          else
            nil
          end
        rescue Client::NotFoundError
          # Card doesn't exist - that's ok
          nil
        rescue StandardError => e
          # Log error but don't fail
          warn "Error fetching AI instructions for #{section_name}: #{e.message}"
          nil
        end
      end

      # === Auto-Link Operations ===

      # Analyze card content and suggest or apply wiki links
      #
      # Scans a card's content for terms that match existing card names within
      # the same scope (top 2 left parts of the card name). Suggests or applies
      # wiki links [[CardName]] for discovered terms.
      #
      # This tool is useful for:
      # - Cross-referencing content after writing
      # - Building wiki interconnectedness
      # - Finding related cards that should be linked
      #
      # @param card_name [String] the card to analyze
      # @param mode [String] "suggest" (default) to preview links, "apply" to update card
      # @param dry_run [Boolean] preview changes without saving (default: true)
      # @param scope [String, nil] scope for term matching (default: derived from card name)
      # @param min_term_length [Integer] minimum term length to consider (default: 3)
      # @param include_types [Array<String>, nil] only link to cards of these types
      # @return [Hash] suggestions, preview, and stats
      #
      # @example Suggest links for a card
      #   result = tools.auto_link("Games+Butterfly Galaxii+Player+Species+Araithi")
      #   result["suggestions"].each do |s|
      #     puts "Found '#{s['term']}' -> #{s['matching_card']}"
      #   end
      #
      # @example Preview changes (dry run)
      #   result = tools.auto_link("MyCard", mode: "apply", dry_run: true)
      #   puts result["preview"]  # See what the content would look like
      #
      # @example Apply links to card
      #   result = tools.auto_link("MyCard", mode: "apply", dry_run: false)
      #   puts "Applied #{result['applied']} links"
      def auto_link(card_name, mode: "suggest", dry_run: true, scope: nil, min_term_length: 3, include_types: nil)
        payload = {
          card_name: card_name,
          mode: mode,
          dry_run: dry_run
        }
        payload[:scope] = scope if scope
        payload[:min_term_length] = min_term_length
        payload[:include_types] = include_types if include_types

        client.post("/auto_link", **payload)
      end
    end # class Tools
  end # module Mcp
  end # module Wiki
end # module Hyperon
