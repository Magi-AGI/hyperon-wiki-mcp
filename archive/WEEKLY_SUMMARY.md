# Weekly Summary Feature

## Overview

The Weekly Summary feature provides automated tools for generating comprehensive weekly work summaries that combine wiki card changes and repository activity. This feature follows the format established by the existing "Weekly Work Summary" cards on the wiki.

## Features

### 1. Get Recent Card Changes

Retrieve all cards updated within a specified time period.

```ruby
require 'magi/archive/mcp'

tools = Magi::Archive::Mcp::Tools.new

# Get cards updated in last 7 days (default)
changes = tools.get_recent_changes

# Get cards updated in last 14 days
changes = tools.get_recent_changes(days: 14)

# Get cards updated in specific date range
changes = tools.get_recent_changes(
  since: "2025-11-25",
  before: "2025-12-02"
)

# Result format
changes.each do |card|
  puts "#{card['name']} - updated #{card['updated_at']}"
end
```

### 2. Scan Git Repositories

Scan all git repositories under a base path for commits made within a time period.

```ruby
# Scan repos in current directory
repo_changes = tools.scan_git_repos(days: 7)

# Scan specific directory
repo_changes = tools.scan_git_repos(
  base_path: "/path/to/projects",
  days: 7
)

# Result format
repo_changes.each do |repo_name, commits|
  puts "#{repo_name}: #{commits.size} commits"
  commits.each do |commit|
    puts "  #{commit['hash']} #{commit['subject']} (#{commit['author']})"
  end
end
```

### 3. Format Weekly Summary

Create formatted markdown content following the standard Weekly Work Summary format.

```ruby
# Basic usage
cards = tools.get_recent_changes(days: 7)
repos = tools.scan_git_repos(days: 7)
markdown = tools.format_weekly_summary(cards, repos)

# With custom title and executive summary
markdown = tools.format_weekly_summary(
  cards,
  repos,
  title: "Weekly Work Summary 2025 12 09",
  executive_summary: "This week focused on MCP API Phase 2.1 completion..."
)

# The generated markdown includes:
# - Executive summary
# - Wiki card updates (grouped by parent)
# - Repository changes (by repo with commit lists)
# - Next steps placeholder
```

### 4. Create Weekly Summary Card

Convenience method that combines all steps: fetches changes, scans repos, formats content, and creates the card.

```ruby
# Create summary for this week
card = tools.create_weekly_summary

# Create summary with custom options
card = tools.create_weekly_summary(
  base_path: "/path/to/repos",
  days: 7,
  date: "2025 12 09",
  executive_summary: "Focused on Phase 2.1 completion and testing...",
  parent: "Home"
)

# Generate content without creating card (for preview)
markdown = tools.create_weekly_summary(create_card: false)
puts markdown
```

## Output Format

The generated weekly summary follows this structure:

```markdown
# Weekly Work Summary 2025 12 09

## Executive Summary

This week saw 15 card updates across the wiki and 42 commits across 3 repositories.

## Wiki Card Updates

### Business Plan

- `Business Plan+Executive Summary` (2025-12-03)
- `Business Plan+Vision` (2025-12-02)

### Technical Documentation

- `Technical Documentation+API Reference` (2025-12-01)

## Repository & Code Changes

### magi-archive

**12 commits**

- `abc123d` Add Phase 2.1 features (Developer, 2025-12-03)
- `def456e` Update validation controller (Developer, 2025-12-02)
- ... and 10 more commits

### magi-archive-mcp

**30 commits**

- `789abcd` Implement weekly summary feature (Developer, 2025-12-03)
- `012efgh` Add comprehensive tests (Developer, 2025-12-02)
- ... and 28 more commits

## Next Steps

- [Add your next steps here]
-
-
```

## Configuration Options

### Time Range Options

- `days`: Number of days to look back (default: 7)
- `since`: Specific start date (overrides `days`)
- `before`: Specific end date (default: now)

### Repository Scanning Options

- `base_path`: Root directory to scan for git repos (default: current directory)
  - Scans up to 2 levels deep
  - Automatically finds `.git` directories

### Card Creation Options

- `date`: Date string for card name (default: today in "YYYY MM DD" format)
- `executive_summary`: Custom executive summary text
- `parent`: Parent card name (default: "Home")
- `create_card`: Whether to create card or just return content (default: true)

## Examples

### Example 1: Basic Weekly Summary

Create a standard weekly summary for the current week:

```ruby
require 'magi/archive/mcp'

tools = Magi::Archive::Mcp::Tools.new
card = tools.create_weekly_summary

puts "Created: #{card['name']}"
```

### Example 2: Custom Date Range

Create a summary for a specific two-week period:

```ruby
card = tools.create_weekly_summary(
  days: 14,
  date: "2025 12 09",
  executive_summary: "Two-week sprint focusing on MCP API Phase 2.1 completion, comprehensive testing, and documentation updates."
)
```

### Example 3: Preview Before Creating

Generate and review the summary content before creating the card:

```ruby
# Preview the content
content = tools.create_weekly_summary(create_card: false)
puts content

# Review and decide
puts "\nCreate this summary? (y/n)"
response = gets.chomp

if response.downcase == 'y'
  card = tools.create_weekly_summary
  puts "Summary created: #{card['name']}"
end
```

### Example 4: Scan Multiple Project Directories

Create summary scanning a specific project hierarchy:

```ruby
card = tools.create_weekly_summary(
  base_path: "/home/user/projects/magi",
  days: 7,
  executive_summary: "Weekly progress across all Magi AGI projects..."
)
```

### Example 5: Manual Workflow

Build the summary step by step with full control:

```ruby
# Step 1: Get card changes
cards = tools.get_recent_changes(days: 7)
puts "Found #{cards.size} card updates"

# Step 2: Scan repositories
repos = tools.scan_git_repos(
  base_path: "/home/user/projects",
  days: 7
)
puts "Found changes in #{repos.size} repositories"

# Step 3: Format summary
markdown = tools.format_weekly_summary(
  cards,
  repos,
  title: "Custom Summary Title",
  executive_summary: "Custom executive summary..."
)

# Step 4: Create card manually
card = tools.create_card(
  "Weekly Work Summary 2025 12 09",
  content: markdown,
  type: "Basic"
)
```

## Integration with CLI Tools

The weekly summary feature is designed to work seamlessly with LLM CLI tools (Claude, Gemini, Codex):

### Claude CLI

```ruby
# In Claude Code session
tools = Magi::Archive::Mcp::Tools.new

# Get current working directory from Claude context
base_path = ENV['PWD'] || Dir.pwd

# Create summary
summary = tools.create_weekly_summary(
  base_path: base_path,
  create_card: false
)

puts summary
```

### Command-Line Usage

```bash
# From the magi-archive-mcp directory
ruby -r ./lib/magi/archive/mcp -e "
  tools = Magi::Archive::Mcp::Tools.new
  card = tools.create_weekly_summary(
    base_path: ENV['HOME'] + '/projects',
    days: 7
  )
  puts 'Created: ' + card['name']
"
```

## API Reference

### `get_recent_changes(days: 7, since: nil, before: nil, limit: 100)`

Retrieves cards updated within a date range.

**Parameters:**
- `days` (Integer): Number of days to look back (default: 7)
- `since` (Time, String, nil): Specific start date (overrides days)
- `before` (Time, String, nil): Specific end date (default: now)
- `limit` (Integer): Maximum results per page (default: 100)

**Returns:** Array<Hash> - Array of card hashes with metadata

### `scan_git_repos(base_path: nil, days: 7, since: nil)`

Scans git repositories for commits within a time period.

**Parameters:**
- `base_path` (String, nil): Root directory to scan (default: current directory)
- `days` (Integer): Number of days to look back (default: 7)
- `since` (Time, String, nil): Specific start date (overrides days)

**Returns:** Hash - Repository changes grouped by repo name

### `format_weekly_summary(card_changes, repo_changes, title: nil, executive_summary: nil)`

Formats weekly summary markdown content.

**Parameters:**
- `card_changes` (Array<Hash>): Cards updated during the period
- `repo_changes` (Hash): Repository changes grouped by repo name
- `title` (String, nil): Custom title (default: auto-generated)
- `executive_summary` (String, nil): Custom executive summary

**Returns:** String - Formatted markdown content

### `create_weekly_summary(base_path: nil, days: 7, date: nil, executive_summary: nil, parent: "Home", create_card: true)`

Creates a complete weekly summary card.

**Parameters:**
- `base_path` (String, nil): Root directory for repo scanning
- `days` (Integer): Number of days to look back (default: 7)
- `date` (String, nil): Date string for card name (default: today)
- `executive_summary` (String, nil): Custom executive summary
- `parent` (String): Parent card name (default: "Home")
- `create_card` (Boolean): Whether to create card (default: true)

**Returns:** Hash or String - Created card data or markdown if create_card is false

## Limitations and Considerations

### Repository Scanning

- Scans up to 2 directory levels deep to avoid excessive filesystem traversal
- Requires git to be installed and accessible via PATH
- Only includes repositories with at least one commit in the time period
- Limited to 10 commits per repository in the formatted output (shows overflow count)

### Card Changes

- Uses the wiki's existing `updated_at` timestamps
- Automatically handles pagination for large result sets
- Filters based on user role (respects GM/AI content restrictions)
- Groups cards by top-level parent for readability

### Performance

- Large repositories with many commits may take longer to scan
- Card searches with very large result sets are paginated automatically
- Consider using specific date ranges for better performance

### Error Handling

- Gracefully handles repositories that can't be accessed
- Continues if some repositories fail to scan
- Returns empty arrays for inaccessible repos rather than failing

## Testing

Comprehensive tests are provided in `spec/magi/archive/mcp/tools_weekly_summary_spec.rb`:

```bash
# Run weekly summary tests
bundle exec rspec spec/magi/archive/mcp/tools_weekly_summary_spec.rb

# Run with documentation format
bundle exec rspec spec/magi/archive/mcp/tools_weekly_summary_spec.rb --format documentation
```

Test coverage includes:
- Recent card changes retrieval
- Git repository scanning
- Markdown formatting
- Full workflow integration
- Error handling and edge cases
- Private helper methods

## Troubleshooting

### Issue: No repositories found

**Cause:** Git repos not in expected location or not within scan depth

**Solution:** Specify explicit `base_path` pointing to parent directory of repos

### Issue: Missing commits

**Cause:** Date range may be too narrow or commits not yet pushed

**Solution:** Verify date range and check local commits with `git log`

### Issue: Card creation fails

**Cause:** Authentication or permission issues

**Solution:** Verify API credentials and user role permissions

### Issue: Empty card changes

**Cause:** No cards updated in the specified time period

**Solution:** Adjust `days` parameter or verify wiki activity

## Future Enhancements

Potential improvements for future versions:

1. **Deeper repository scanning** - Configurable depth limit
2. **Branch filtering** - Scan specific branches only
3. **Author filtering** - Filter commits by author
4. **Card type filtering** - Focus on specific card types
5. **Section customization** - User-defined section templates
6. **Automatic linking** - Add summary link to parent card
7. **Email/Slack notifications** - Automated distribution
8. **Trend analysis** - Compare with previous weeks
9. **Contribution metrics** - Author statistics
10. **Interactive mode** - Guided summary creation with prompts

## Related Documentation

- [NEW_FEATURES.md](NEW_FEATURES.md) - Phase 2.1 features overview
- [README.md](README.md) - Main project documentation
- [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) - Implementation details
- [TESTING_SUMMARY.md](TESTING_SUMMARY.md) - Testing coverage

## Version History

- **Version 1.0** (2025-12-03): Initial implementation
  - Basic weekly summary generation
  - Card change tracking
  - Repository scanning
  - Markdown formatting
  - Comprehensive tests
