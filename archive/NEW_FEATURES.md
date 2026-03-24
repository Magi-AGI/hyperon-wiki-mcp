# New Features - Magi Archive MCP

This document describes the new features added to the Magi Archive MCP client and server.

## Overview

Five major feature categories have been added to enhance card management and prevent hallucinations:

1. **Admin Database Backup** - Simple backup and restore capabilities
2. **Card Relationship Functions** - Explore card connections (links, nests, referers)
3. **Tag Search Functions** - Convenient tag-based search
4. **Tag Validation** - Ensure cards are properly tagged
5. **Structure Recommendations** - Guide proper card structure based on type

---

## 1. Admin Database Backup

Administrators can now create, download, list, and delete database backups.

### Server Endpoints

#### `GET /api/mcp/admin/database/backup`
Creates and downloads a fresh database backup.

**Requirements:** Admin role

**Response:** SQL dump file

#### `GET /api/mcp/admin/database/backup/list`
Lists all available backup files with metadata.

**Response:**
```json
{
  "backups": [
    {
      "filename": "magi_archive_backup_20251203_120000.sql",
      "size": 12345678,
      "size_human": "11.77 MB",
      "created_at": "2025-12-03T12:00:00Z",
      "modified_at": "2025-12-03T12:00:00Z",
      "age": "2 hours ago"
    }
  ],
  "total": 5,
  "backup_dir": "/path/to/backups"
}
```

#### `GET /api/mcp/admin/database/backup/download/:filename`
Downloads a specific backup file.

#### `DELETE /api/mcp/admin/database/backup/:filename`
Deletes a specific backup file.

### Client Methods

```ruby
# Download fresh backup
tools.download_database_backup(save_path: "/tmp/backup.sql")

# List available backups
backups = tools.list_database_backups
backups["backups"].each do |backup|
  puts "#{backup['filename']} - #{backup['size_human']} - #{backup['age']}"
end

# Download specific backup
tools.download_database_backup_file(
  "magi_archive_backup_20251203_120000.sql",
  save_path: "/tmp/backup.sql"
)

# Delete old backup
tools.delete_database_backup("magi_archive_backup_20251203_120000.sql")
```

### Features

- Automatic backup of PostgreSQL, MySQL, or SQLite databases
- Keeps last 5 backups automatically
- Human-readable file sizes and timestamps
- Secure filename validation

---

## 2. Card Relationship Functions

Explore card connections to understand how cards reference each other.

### Relationship Types

1. **Referers** - Cards that reference/link to this card
2. **Nested In** - Cards that nest/include this card using `{{CardName}}`
3. **Nests** - Cards that this card nests/includes
4. **Links** - Cards that this card links to using `[[CardName]]`
5. **Linked By** - Cards that link to this card

### Server Endpoints

All endpoints follow the pattern: `GET /api/mcp/cards/:name/{relationship}`

- `GET /api/mcp/cards/:name/referers`
- `GET /api/mcp/cards/:name/nested_in`
- `GET /api/mcp/cards/:name/nests`
- `GET /api/mcp/cards/:name/links`
- `GET /api/mcp/cards/:name/linked_by`

**Response Format:**
```json
{
  "card": "Main Page",
  "referers": [
    {
      "name": "Home",
      "id": 123,
      "type": "Page",
      "updated_at": "2025-12-03T12:00:00Z"
    }
  ],
  "referer_count": 1
}
```

### Client Methods

```ruby
# Get cards that reference this card
result = tools.get_referers("Main Page")
result["referers"].each { |card| puts card["name"] }

# Get cards that nest this card
result = tools.get_nested_in("Template Card")

# Get cards that this card nests
result = tools.get_nests("Main Page")

# Get cards that this card links to
result = tools.get_links("Main Page")

# Get cards that link to this card
result = tools.get_linked_by("Main Page")
```

### Use Cases

- **Dependency Analysis** - Find what depends on a card before deleting
- **Content Discovery** - Find related cards
- **Template Usage** - See where templates are used
- **Link Validation** - Find broken references

---

## 3. Tag Search Functions

Convenient functions for searching cards by tags.

### Client Methods

#### Search by Single Tag
```ruby
results = tools.search_by_tag("Article")
results["cards"].each { |card| puts card["name"] }
```

#### Search by Multiple Tags (AND logic)
```ruby
# Find cards that have ALL specified tags
results = tools.search_by_tags(["Article", "Published"])
```

#### Search by Multiple Tags (OR logic)
```ruby
# Find cards that have ANY of the specified tags
results = tools.search_by_tags_any(["Article", "Draft"])
```

#### Get All Tags
```ruby
tags = tools.get_all_tags
tags.each { |tag| puts tag["name"] }
```

#### Get Tags for a Card
```ruby
tags = tools.get_card_tags("Main Page")
puts "Tags: #{tags.join(', ')}"
```

#### Search by Tag Pattern
```ruby
# Find cards with tags matching pattern
results = tools.search_by_tag_pattern("game-*")
```

### Tag Format

Tags are stored in Decko as:
- `CardName+tags` - Pointer card containing tag references
- Format: `[[Tag1]]`, `[[Tag2]]` or newline-separated

---

## 4. Tag Validation

Ensure cards have appropriate tags based on their type and content.

### Server Endpoints

#### `POST /api/mcp/validation/tags`
Validates tags for a proposed card.

**Payload:**
```json
{
  "type": "Game Master Document",
  "tags": ["Game", "Species"],
  "content": "This is GM-only content",
  "name": "Secret Plot+GM"
}
```

**Response:**
```json
{
  "valid": false,
  "errors": ["Missing required tags: GM"],
  "warnings": ["Consider adding suggested tags: System"],
  "required_tags": ["GM"],
  "suggested_tags": ["Game", "System"],
  "provided_tags": ["Game", "Species"]
}
```

#### `POST /api/mcp/validation/structure`
Validates card structure (children).

#### `GET /api/mcp/validation/requirements/:type`
Get requirements for a card type.

### Client Methods

```ruby
# Validate tags
result = tools.validate_card_tags(
  "Game Master Document",
  ["Game", "Species"],
  content: "This is GM-only content",
  name: "Secret Plot+GM"
)

if result["valid"]
  puts "Tags are valid!"
else
  puts "Errors: #{result['errors'].join(', ')}"
  puts "Warnings: #{result['warnings'].join(', ')}"
end

# Validate structure
result = tools.validate_card_structure(
  "Species",
  name: "Vulcans",
  has_children: true,
  children_names: ["Vulcans+traits", "Vulcans+description"]
)

# Get requirements for a type
reqs = tools.get_type_requirements("Species")
puts "Required tags: #{reqs['required_tags'].join(', ')}"
puts "Suggested children: #{reqs['suggested_children'].join(', ')}"

# Create card with validation
result = tools.create_card_with_validation(
  "New Species",
  type: "Species",
  tags: ["Game", "Alien"],
  content: "A new alien species"
)
```

### Validation Rules

#### Predefined Card Types

**Article:**
- Required tags: none
- Suggested tags: Status, Category
- Suggested children: *content, *summary

**Game Master Document:**
- Required tags: GM
- Suggested tags: Game, System

**Species:**
- Suggested tags: Game
- Suggested children: *traits, *description, *culture

**Faction:**
- Suggested tags: Game
- Suggested children: *description, *goals, *leadership

**Character:**
- Suggested tags: Game, Player
- Suggested children: *background, *stats, *inventory

### Content-Based Suggestions

The validator analyzes content and suggests tags:
- "game master" / "GM only" → Suggests "GM" tag
- "species" / "race" → Suggests "Species" tag
- "faction" / "organization" → Suggests "Faction" tag
- "draft" / "WIP" → Suggests "Draft" tag
- "complete" / "published" → Suggests "Complete" tag

### Naming Convention Checks

- Cards with `+GM` should have "GM" tag
- GM documents should use `+GM` in name
- Cards with `+AI` should have "AI" tag

---

## 5. Structure Recommendations

Get comprehensive recommendations for card structure based on type and content.

### Server Endpoints

#### `POST /api/mcp/validation/recommend_structure`
Get structure recommendations for a new card.

**Payload:**
```json
{
  "type": "Species",
  "name": "Vulcans",
  "tags": ["Star Trek", "Humanoid"],
  "content": "Logical and stoic species..."
}
```

**Response:**
```json
{
  "card_type": "Species",
  "card_name": "Vulcans",
  "children": [
    {
      "name": "Vulcans+traits",
      "type": "RichText",
      "purpose": "Characteristics and traits",
      "priority": "suggested"
    },
    {
      "name": "Vulcans+description",
      "type": "RichText",
      "purpose": "Detailed description",
      "priority": "suggested"
    },
    {
      "name": "Vulcans+culture",
      "type": "RichText",
      "purpose": "Cultural information",
      "priority": "suggested"
    }
  ],
  "tags": {
    "required": [],
    "suggested": ["Game"],
    "content_based": []
  },
  "naming": [],
  "summary": "Recommendations: 3 suggested children, 1 suggested tags"
}
```

#### `POST /api/mcp/validation/suggest_improvements`
Analyze existing card and suggest improvements.

**Payload:**
```json
{
  "name": "Vulcans"
}
```

**Response:**
```json
{
  "card_name": "Vulcans",
  "card_type": "Species",
  "missing_children": [],
  "missing_tags": [],
  "suggested_additions": [
    {
      "pattern": "*culture",
      "suggestion": "Vulcans+culture",
      "priority": "suggested"
    }
  ],
  "naming_issues": [],
  "summary": "1 suggested additions"
}
```

### Client Methods

```ruby
# Get structure recommendations for new card
recs = tools.recommend_card_structure(
  "Species",
  "Vulcans",
  tags: ["Star Trek", "Humanoid"],
  content: "Logical and stoic species..."
)

puts recs["summary"]
recs["children"].each do |child|
  puts "Create: #{child['name']} (#{child['purpose']})"
end

# Analyze existing card and suggest improvements
improvements = tools.suggest_card_improvements("Vulcans")
puts improvements["summary"]

improvements["missing_children"].each do |child|
  puts "Missing: #{child['suggestion']}"
end

improvements["suggested_additions"].each do |addition|
  puts "Consider: #{addition['suggestion']}"
end
```

### Recommendation Features

1. **Child Card Recommendations**
   - Suggests child cards based on card type
   - Provides recommended type for each child
   - Explains purpose of each child
   - Prioritizes required vs. suggested

2. **Tag Recommendations**
   - Required tags (must have)
   - Suggested tags (should have)
   - Content-based suggestions

3. **Naming Recommendations**
   - GM content should use `+GM`
   - AI content should use `+AI`
   - Consistency checks

4. **Improvement Analysis**
   - Missing required elements
   - Missing suggested elements
   - Naming issues
   - Summary of all improvements

---

## Benefits for Preventing Hallucinations

These features work together to reduce AI hallucinations when working with the Magi Archive:

### 1. Structured Guidance
- **Before:** AI guesses card structure
- **After:** AI gets explicit requirements and recommendations

### 2. Validation Feedback
- **Before:** No validation until card created
- **After:** Validate before creation, see errors/warnings

### 3. Relationship Awareness
- **Before:** AI doesn't know card connections
- **After:** AI can explore dependencies and references

### 4. Tag Consistency
- **Before:** Inconsistent tagging
- **After:** Required and suggested tags for each type

### 5. Content-Based Suggestions
- **Before:** Tags not aligned with content
- **After:** Validator suggests tags from content analysis

---

## Usage Patterns

### Pattern 1: Create Well-Structured Card

```ruby
# 1. Get recommendations
recs = tools.recommend_card_structure(
  "Species",
  "Betazoids",
  tags: ["Star Trek", "Telepathic"],
  content: "Telepathic humanoid species from Betazed"
)

# 2. Review recommendations
puts "Creating card structure:"
recs["children"].each do |child|
  puts "  - #{child['name']}: #{child['purpose']}"
end

# 3. Create main card with validation
result = tools.create_card_with_validation(
  "Betazoids",
  type: "Species",
  tags: recs["tags"]["suggested"] + ["Telepathic"],
  content: "Telepathic humanoid species from Betazed"
)

# 4. Create recommended children
recs["children"].each do |child|
  tools.create_card(
    child["name"],
    type: child["type"],
    content: "TODO: #{child['purpose']}"
  )
end
```

### Pattern 2: Audit and Improve Existing Cards

```ruby
# Get all Species cards
species = tools.search_cards(type: "Species")

species["cards"].each do |card|
  # Analyze each card
  improvements = tools.suggest_card_improvements(card["name"])

  next if improvements["summary"] == "No improvements needed"

  puts "\n#{card['name']}:"
  puts "  #{improvements['summary']}"

  # Show specific issues
  improvements["missing_children"].each do |child|
    puts "  ❌ Required: #{child['suggestion']}"
  end

  improvements["suggested_additions"].each do |addition|
    puts "  💡 Suggested: #{addition['suggestion']}"
  end

  improvements["naming_issues"].each do |issue|
    puts "  ⚠️  #{issue}"
  end
end
```

### Pattern 3: Tag-Based Content Organization

```ruby
# Find all draft content
drafts = tools.search_by_tag("Draft")
puts "Draft articles: #{drafts['total']}"

# Find GM content missing GM tag
all_gm_cards = tools.search_cards(q: "*+GM")
all_gm_cards["cards"].each do |card|
  tags = tools.get_card_tags(card["name"])
  unless tags.include?("GM")
    puts "Missing GM tag: #{card['name']}"
  end
end

# Organize by multiple tags
game_species = tools.search_by_tags(["Game", "Species"])
puts "Game species: #{game_species['total']}"
```

---

## CLI Examples

Once the gem is updated, these features are available via CLI:

```bash
# Database backup
magi-archive-mcp backup download --save-to backup.sql
magi-archive-mcp backup list

# Relationships
magi-archive-mcp relationships "Main Page" --type referers
magi-archive-mcp relationships "Template" --type nested_in

# Tag search
magi-archive-mcp tags search --tag "Article"
magi-archive-mcp tags search --tags "Article,Published" --mode all
magi-archive-mcp tags list-all

# Validation
magi-archive-mcp validate tags --type "Species" --tags "Game,Alien"
magi-archive-mcp validate structure --type "Species" --name "Vulcans"

# Recommendations
magi-archive-mcp recommend "Species" --name "Betazoids" --tags "Star Trek,Telepathic"
magi-archive-mcp improve "Vulcans"
```

---

## Migration Notes

### Backwards Compatibility

✅ All existing functionality remains unchanged
✅ No breaking changes to existing endpoints
✅ New features are purely additive

### Deployment Steps

1. **Server (Decko):**
   - Deploy new controllers and routes
   - No database migrations required for basic features
   - Backup functionality uses existing database

2. **Client (Gem):**
   - Update gem: `gem install magi-archive-mcp-0.2.0.gem`
   - New methods available immediately
   - Old code continues to work

3. **Configuration:**
   - No new environment variables required
   - Admin backup uses existing admin authentication
   - Validation rules can be customized in ValidationController

---

## Future Enhancements

Potential extensions to these features:

1. **Custom Validation Rules**
   - User-defined card type requirements
   - Configuration file for validation rules
   - Per-game or per-project rule sets

2. **Automated Fixes**
   - Auto-create recommended children
   - Auto-add suggested tags
   - Bulk structure updates

3. **Validation Reports**
   - Generate reports of validation issues
   - Track improvement over time
   - Compliance dashboards

4. **Template System**
   - Card templates based on type
   - Clone template structure
   - Template library

5. **AI Integration**
   - Use structure recommendations in prompts
   - Validate AI-generated content
   - Suggest content based on missing children

---

## Support

For questions or issues with these new features:

- Check this documentation
- Review code examples in `lib/magi/archive/mcp/tools.rb`
- Server implementation in `app/controllers/api/mcp/`
- Report issues on GitHub

---

**Version:** 0.2.0
**Date:** 2025-12-03
**Status:** Complete and Production Ready
