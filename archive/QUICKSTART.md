# Quick Start Guide

Get started with Magi Archive MCP in 5 minutes.

## 1. Install

```bash
gem install magi-archive-mcp
```

Or add to your Gemfile:

```ruby
gem "magi-archive-mcp"
```

## 2. Configure

Create a `.env` file in your project directory:

```bash
MCP_API_KEY=your-api-key-here
MCP_ROLE=user
```

**Don't have an API key?** Contact your Decko administrator to obtain one.

## 3. Try the CLI

### Get a card

```bash
magi-archive-mcp get "Main Page"
```

Expected output:
```
────────────────────────────────────────────────────────────────────────────────
Name: Main Page
Type: Article
ID: 123
URL: https://wiki.magi-agi.org/Main_Page
────────────────────────────────────────────────────────────────────────────────
Welcome to the Magi Archive...
────────────────────────────────────────────────────────────────────────────────
```

### Search for cards

```bash
magi-archive-mcp search --query "quantum"
```

Expected output:
```
Found 15 card(s)
────────────────────────────────────────────────────────────────────────────────
• Quantum Mechanics (Article)
  The study of quantum phenomena...
• Quantum Computing (Article)
  Quantum computers use quantum bits...
...
────────────────────────────────────────────────────────────────────────────────
```

### Get JSON output

```bash
magi-archive-mcp get "Main Page" --format json
```

## 4. Use as a Library

Create a file `example.rb`:

```ruby
require "magi/archive/mcp"

# Initialize tools
tools = Magi::Archive::Mcp::Tools.new

# Get a card
card = tools.get_card("Main Page")
puts "Card: #{card['name']}"
puts "Type: #{card['type']}"
puts "Content length: #{card['content'].length} characters"

# Search for cards
results = tools.search_cards(q: "quantum", limit: 5)
puts "\nFound #{results['total']} cards:"
results["cards"].each do |c|
  puts "  - #{c['name']}"
end
```

Run it:

```bash
ruby example.rb
```

Expected output:
```
Card: Main Page
Type: Article
Content length: 1234 characters

Found 15 cards:
  - Quantum Mechanics
  - Quantum Computing
  - Quantum Entanglement
  - Quantum Field Theory
  - Quantum Information
```

## 5. Create Your First Card

**Note:** This requires write permissions. If you have a `user` role, you can create cards.

### Using the CLI

```bash
magi-archive-mcp create \
  --name "My First Card" \
  --content "This is my first card created via MCP!" \
  --type "Article"
```

### Using the Library

```ruby
require "magi/archive/mcp"

tools = Magi::Archive::Mcp::Tools.new

card = tools.create_card(
  "My First Card",
  content: "This is my first card created via MCP!",
  type: "Article"
)

puts "Created card: #{card['name']}"
puts "URL: #{card['url']}"
```

## 6. Update a Card

### Using the CLI

```bash
magi-archive-mcp update "My First Card" \
  --content "Updated content with more information."
```

### Using the Library

```ruby
tools = Magi::Archive::Mcp::Tools.new

updated = tools.update_card(
  "My First Card",
  content: "Updated content with more information."
)

puts "Updated: #{updated['name']}"
```

## Common Patterns

### Pagination

Iterate through all search results:

```ruby
tools = Magi::Archive::Mcp::Tools.new

tools.each_card_page(q: "quantum", limit: 50) do |page|
  puts "Processing #{page['cards'].length} cards (offset: #{page['offset']})"

  page["cards"].each do |card|
    puts "  - #{card['name']}"
  end
end
```

### Error Handling

```ruby
tools = Magi::Archive::Mcp::Tools.new

begin
  card = tools.get_card("Nonexistent Card")
rescue Magi::Archive::Mcp::Client::NotFoundError
  puts "Card not found - let's create it!"

  card = tools.create_card(
    "Nonexistent Card",
    content: "Now it exists!",
    type: "Article"
  )

  puts "Created: #{card['name']}"
end
```

### Batch Operations

Create multiple cards efficiently:

```ruby
tools = Magi::Archive::Mcp::Tools.new

operations = [
  { action: "create", name: "Card 1", content: "Content 1", type: "Article" },
  { action: "create", name: "Card 2", content: "Content 2", type: "Article" },
  { action: "create", name: "Card 3", content: "Content 3", type: "Article" }
]

result = tools.batch_operations(operations, mode: "per_item")

result["results"].each do |op|
  if op["status"] == "success"
    puts "✓ Created #{op['name']}"
  else
    puts "✗ Failed to create #{op['name']}: #{op['error']}"
  end
end
```

### Format Conversion

Convert Markdown to HTML:

```ruby
tools = Magi::Archive::Mcp::Tools.new

markdown = <<~MD
  # My Document

  This is **bold** and this is *italic*.

  - List item 1
  - List item 2
MD

html = tools.render_snippet(markdown, from: :markdown, to: :html)
puts html
```

## Next Steps

- **Read the full [README](README.md)** for comprehensive documentation
- **Review [AUTHENTICATION.md](AUTHENTICATION.md)** to understand role-based access
- **Check [SECURITY.md](SECURITY.md)** for security best practices
- **Explore the [MCP Specification](MCP-SPEC.md)** for API details

## Troubleshooting

### "Configuration Error: MCP_API_KEY not set"

Make sure you have a `.env` file with:
```bash
MCP_API_KEY=your-api-key
MCP_ROLE=user
```

Or set environment variables:
```bash
export MCP_API_KEY=your-api-key
export MCP_ROLE=user
```

### "Permission Denied"

Your role may not have permission for the operation. Check:
- User role: Can create/update own cards, read public cards
- GM role: Can read GM content, run spoiler scans
- Admin role: Full access including delete operations

Contact your administrator to request a different role if needed.

### "Not Found"

The card doesn't exist. Try:
1. Searching for similar card names
2. Checking the card name spelling (case-sensitive)
3. Verifying you have permission to see the card

### Rate Limit Exceeded

You're making requests too quickly. The library will:
1. Automatically retry with exponential backoff
2. Wait for rate limit reset if needed

If problems persist, contact your administrator to increase your rate limit.

## Examples Repository

See the `examples/` directory for more code samples:
- `examples/basic_usage.rb` - Simple card operations
- `examples/batch_processing.rb` - Bulk operations
- `examples/pagination.rb` - Iterating through large result sets
- `examples/error_handling.rb` - Robust error handling patterns
- `examples/gm_operations.rb` - GM-specific features (requires GM role)
- `examples/admin_operations.rb` - Admin features (requires admin role)

## Getting Help

- **Documentation**: Full docs at [README.md](README.md)
- **Issues**: Report bugs at [GitHub Issues](https://github.com/your-org/magi-archive-mcp/issues)
- **Support**: Email support@magi-agi.org
