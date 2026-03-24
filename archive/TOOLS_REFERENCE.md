# MCP Tools Reference

Complete reference for all Magi Archive MCP tools available in Claude Desktop, Claude Code, Codex, and compatible clients.

**Total Tools:** 16

## Core Card Operations (6 tools)

### 1. get_card

Fetch a single card by name from the wiki.

**Parameters:**
- `name` (string, required): Card name
- `with_children` (boolean, optional): Include child cards

**Example:**
```
"Get the card named 'Main Page' from Magi Archive"
"Fetch 'Business Plan+Executive Summary' with its children"
```

**Returns:** Formatted card with name, type, content, URL, and optional children list

---

### 2. search_cards

Search for cards by query, type, or filters with pagination.

**Parameters:**
- `query` (string, optional): Search query (searches card names)
- `type` (string, optional): Filter by card type
- `limit` (integer, optional): Max results (default: 50, max: 100)
- `offset` (integer, optional): Pagination offset (default: 0)

**Example:**
```
"Search Magi Archive for cards about 'Butterfly Galaxii'"
"Find all Article type cards"
"Search for cards updated recently"
```

**Returns:** List of matching cards with pagination info

---

### 3. create_card

Create a new card on the wiki.

**Parameters:**
- `name` (string, required): Card name
- `content` (string, optional): Card content
- `type` (string, optional): Card type (default: "Basic")

**Example:**
```
"Create a card called 'New Species Document'"
"Add a new Article card about quantum physics"
```

**Returns:** Created card confirmation with URL

---

### 4. update_card

Update an existing card's content or type.

**Parameters:**
- `name` (string, required): Card name
- `content` (string, optional): New content
- `type` (string, optional): New type

**Example:**
```
"Update 'Main Page' with new content"
"Change the type of 'My Card' to Article"
```

**Returns:** Updated card confirmation

---

### 5. delete_card

Delete a card from the wiki (admin only).

**Parameters:**
- `name` (string, required): Card name
- `force` (boolean, optional): Force delete even with children (default: false)

**Example:**
```
"Delete the card 'Old Draft'"
"Force delete 'Parent Card' and all children"
```

**Returns:** Deletion confirmation with warning

---

### 6. list_children

List all child cards of a parent card.

**Parameters:**
- `parent_name` (string, required): Parent card name
- `limit` (integer, optional): Max children (default: 50, max: 100)

**Example:**
```
"List children of 'Business Plan'"
"Show all subcards of 'Butterfly Galaxii+Species'"
```

**Returns:** List of child cards with metadata

---

## Tag Operations (2 tools)

### 7. get_tags

Get all tags in the system or tags for a specific card.

**Parameters:**
- `card_name` (string, optional): Card name (omit for all tags)
- `limit` (integer, optional): Max tags for all-tags mode (default: 100, max: 500)

**Example:**
```
"Get all tags in Magi Archive"
"Show tags for 'Main Page'"
"List available tags"
```

**Returns:** List of tags or tags for specific card

---

### 8. search_by_tags

Search for cards by tags with AND or OR logic.

**Parameters:**
- `tags` (array of strings, required): Tags to search for
- `match_mode` (string, optional): "all" (AND) or "any" (OR), default: "all"
- `limit` (integer, optional): Max results (default: 50, max: 100)

**Example:**
```
"Find cards tagged with both 'Species' AND 'Alien'"
"Search for cards with 'Game' OR 'Draft' tags"
"Show all cards tagged 'GM'"
```

**Returns:** List of cards matching tag criteria

---

## Relationships (1 tool)

### 9. get_relationships

Get relationship information for a card.

**Parameters:**
- `card_name` (string, required): Card name
- `relationship_type` (string, required): One of:
  - `referers`: Cards that reference this card
  - `linked_by`: Cards that link to this card
  - `nested_in`: Cards that nest this card
  - `nests`: Cards that this card nests
  - `links`: Cards that this card links to

**Example:**
```
"Show me what cards reference 'Main Page'"
"Find cards that link to 'Business Plan'"
"Get nesting relationships for 'Template Card'"
```

**Returns:** List of related cards

---

## Validation & Recommendations (2 tools)

### 10. validate_card

Validate a card's tags and structure based on its type.

**Parameters:**
- `type` (string, required): Card type
- `tags` (array, optional): Tags to validate
- `name` (string, optional): Card name for naming validation
- `content` (string, optional): Content for content-based suggestions
- `children` (array, optional): Child card names for structure validation

**Example:**
```
"Validate tags for a Species type card with tags ['Game', 'Alien']"
"Check if 'New Article' has correct structure"
```

**Returns:** Validation results with errors and warnings

---

### 11. get_recommendations

Get structure recommendations and improvement suggestions.

**Parameters:**
- `operation` (string, required): One of:
  - `requirements`: Get type requirements
  - `recommend_structure`: Get structure recommendation for new card
  - `suggest_improvements`: Analyze existing card
- `type` (string): Card type (for requirements/recommend_structure)
- `name` (string): Card name (for recommend_structure/suggest_improvements)
- `tags` (array, optional): Current tags
- `content` (string, optional): Card content

**Example:**
```
"What are the requirements for a Species card?"
"Recommend structure for a new 'Vulcans' Species card"
"Suggest improvements for 'Main Page'"
```

**Returns:** Requirements, recommendations, or improvement suggestions

---

## Types & Rendering (2 tools)

### 12. get_types

List all card types available in the system.

**Parameters:**
- `limit` (integer, optional): Max types (default: 100, max: 500)

**Example:**
```
"List all card types in Magi Archive"
"Show available card types"
```

**Returns:** List of card types with IDs

---

### 13. render_content

Convert content between HTML and Markdown formats.

**Parameters:**
- `content` (string, required): Content to convert
- `from_format` (string, required): "html" or "markdown"
- `to_format` (string, required): "html" or "markdown"

**Example:**
```
"Convert this HTML to Markdown: <h1>Hello</h1><p>World</p>"
"Render this Markdown as HTML: # Hello\n\nWorld"
```

**Returns:** Converted content with both original and result

---

## Admin Operations (1 tool)

### 14. admin_backup

Manage database backups (admin only).

**Parameters:**
- `operation` (string, required): One of:
  - `download`: Create and download new backup
  - `list`: Show available backups
  - `delete`: Remove a backup file
- `filename` (string): Backup filename (for delete operation)
- `save_path` (string, optional): Local path to save (for download)

**Example:**
```
"Download a database backup"
"List all available backups"
"Delete backup 'magi_archive_backup_20251203_120000.sql'"
```

**Returns:** Backup operation result

---

## Utility Operations (1 tool)

### 15. create_weekly_summary

Generate automated weekly summary combining wiki changes and git activity.

**Parameters:**
- `base_path` (string, optional): Root directory for git repos (default: working directory)
- `days` (integer, optional): Days to look back (default: 7, max: 365)
- `date` (string, optional): Date for card name in 'YYYY MM DD' format
- `executive_summary` (string, optional): Custom summary text
- `create_card` (boolean, optional): Whether to create card or preview (default: true)

**Example:**
```
"Generate a weekly summary for Magi Archive"
"Create a weekly summary for the last 14 days"
"Preview weekly summary without creating the card"
```

**Returns:** Created card or markdown preview

---

## Tool Categories Summary

**By Function:**
- Card Management: 6 tools
- Tags: 2 tools
- Relationships: 1 tool
- Validation: 2 tools
- Types & Rendering: 2 tools
- Admin: 1 tool
- Utilities: 1 tool
- Batch Operations: 1 tool

**By Permission Level:**
- User accessible: 14 tools
- Admin only: 2 tools (delete_card, admin_backup)

**Total: 16 tools**

## Usage Tips

### 1. Chaining Operations

You can combine tools in conversation:

```
User: "Search for Species cards, then get tags for the first result"
AI: [Uses search_cards, then get_tags]
```

### 2. Validation Before Creation

Always validate before creating important cards:

```
User: "Validate my Species card with tags ['Game', 'Alien'] then create it"
AI: [Uses validate_card, reviews results, then create_card]
```

### 3. Weekly Workflow

Typical weekly summary workflow:

```
User: "Generate this week's summary for the Magi AGI project"
AI: [Uses create_weekly_summary with git repo scanning]
```

### 4. Relationship Exploration

Explore wiki structure:

```
User: "Show me the structure: children of 'Business Plan', what links to it, and what it references"
AI: [Uses list_children, get_relationships (linked_by), get_relationships (links)]
```

## Error Handling

All tools return clear error messages:

- **Not Found**: Card doesn't exist
- **Authorization**: Insufficient permissions (need admin/gm role)
- **Validation**: Card data doesn't meet requirements
- **Network**: Connection issues with wiki

## Performance Notes

- **Search operations**: ~200-800ms depending on result size
- **Card fetch**: ~100-500ms
- **Weekly summary**: ~2-5s (scans git repos)
- **Validation**: ~300-600ms (fetches type requirements)

## Rate Limiting

The Decko API enforces rate limits:
- Default: 50 requests per minute per API key
- Automatic retry with exponential backoff
- Tool calls count toward this limit

## Security

- **Role-based access**: user/gm/admin roles enforced
- **GM content filtering**: User role cannot see GM/AI content
- **Admin-only operations**: delete_card, admin_backup
- **Authentication**: All tools require valid credentials

## Future Tools (Planned)

- batch_operations: Bulk create/update operations
- run_query: Safe CQL queries with limits
- upload_attachment: File uploads with role checks

## Resources

- **MCP Server Documentation**: [MCP_SERVER.md](MCP_SERVER.md)
- **Installation Guide**: [README.md](README.md)
- **API Documentation**: [NEW_FEATURES.md](NEW_FEATURES.md)
- **Wiki**: https://wiki.magi-agi.org
