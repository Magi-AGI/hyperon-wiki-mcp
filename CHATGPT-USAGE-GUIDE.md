# ChatGPT Usage Guide for Magi Archive MCP

**Date**: 2025-12-11 (updated 2026-02-11)
**Purpose**: Setup instructions and correct usage patterns for AI agents using the Magi Archive MCP server

---

## Quick Setup: ChatGPT, Claude.ai, and Other Web Platforms

### ChatGPT

1. Go to **Settings** > **Connected Apps** (or the MCP server configuration area)
2. Click **Add MCP Server** (or "Create new app")
3. Enter the server URL: `https://mcp.magi-agi.org`
4. Set authentication to **OAuth**
5. Leave the credential fields **blank** (client ID, client secret, etc.)
6. Click **Save** / **Connect**
7. ChatGPT will redirect you to the **Magi Archive login page**
8. Sign in with your **Decko wiki email and password** (the same credentials you use at `wiki.magi-agi.org`)
9. After signing in, you'll be redirected back and the MCP tools will appear

### Claude.ai

1. Go to your MCP server settings
2. Add server URL: `https://mcp.magi-agi.org`
3. Select **OAuth** for authentication, leave credential fields blank
4. Complete the login flow when redirected to the Magi Archive login page

### How It Works

The server uses **OAuth 2.1 Authorization Code + PKCE** (the standard required by the MCP spec). When you add the server:

- The platform automatically discovers OAuth endpoints via `/.well-known/oauth-authorization-server`
- It registers itself as a client (Dynamic Client Registration)
- It redirects your browser to `/authorize` where you see the Magi Archive login page
- You authenticate with your Decko credentials -- no API keys or secrets needed
- The platform receives a short-lived access token and handles refresh automatically

Your role (user/gm/admin) is determined by your Decko account permissions.

### CLI Tools (Claude Code, Codex, Gemini CLI)

For CLI-based agents, use the stdio transport with environment variables instead:

```bash
MCP_USERNAME=your-decko-email
MCP_PASSWORD=your-decko-password
```

See the [Authentication and Roles](#authentication-and-roles) section below for details.

---

## Executive Summary

This guide documents the correct usage patterns for the Magi Archive MCP server, based on lessons learned from ChatGPT's initial integration. Most early issues stemmed from **misunderstanding the MCP architecture and Decko's card model**, not from actual bugs.

**Key Principle**: The MCP server is a **thin middleware client** that forwards requests to the upstream Decko wiki. It does not control card structure, naming, or deletion behavior - Decko does.

---

## Critical Corrections

### 1. There Are No "Namespaces" in the MCP Server

**What ChatGPT Saw**:
```
/Magi Archive/link_6938b176...
/Magi Archive/link_693a28d0...
```

**Reality**:
- These are **ChatGPT client-side tool instance IDs**, not server namespaces
- There is **only one** production endpoint: `https://wiki.magi-agi.org/api/mcp`
- All tool instances connect to the same underlying Decko wiki
- Differences between "instances" are due to client-side routing or timing, not the server

**Correct Behavior**:
- Treat all Magi Archive tool instances as connections to the same backend
- Don't expect different results from different "instances"
- Report actual HTTP requests/responses, not tool instance IDs

---

### 2. Card Names: Spaces and Underscores Are Equivalent for Lookups

**Empirically Verified Behavior** (tested 2025-12-11):
```ruby
# Decko treats these as THE SAME card:
get_card(name: "Major Factions")      # Returns card ID 2212
get_card(name: "Major_Factions")      # Returns SAME card ID 2212
```

**How Decko Handles Spaces vs Underscores**:
- **Lookups are normalized**: Decko treats spaces and underscores as equivalent when finding cards
- **Canonical names are preserved**: The name used during card creation becomes the canonical name
- **API responses return canonical names**: Even if you query with underscores, the response shows the canonical form (which may use spaces)

**Example - What Actually Happens**:
```ruby
# Create a card with spaces:
create_card(name: "My Test Card", content: "...", type: "RichText")
# → Creates card with canonical name "My Test Card"

# Query with underscores:
card = get_card(name: "My_Test_Card")
# → Returns the same card, but response shows canonical name "My Test Card"

# Query with spaces:
card = get_card(name: "My Test Card")
# → Returns the same card with canonical name "My Test Card"
```

**Important Decko Naming Rules**:
- **Case-sensitive**: `"Main Page"` ≠ `"main page"`
- **Spaces ≈ Underscores**: Treated as equivalent during lookup, but canonical form preserved
- **Hyphens are distinct**: `"Test-Card"` ≠ `"Test Card"` ≠ `"Test_Card"` (hyphens are NOT normalized)
- **Hierarchies use `+`**: `Parent+Child+Grandchild` (the `+` is part of the card name)

**Best Practice - Always Use Canonical Names**:
While Decko allows querying with either spaces or underscores, you should **always use the canonical name returned by the API** to ensure consistency:

```ruby
# Step 1: Search for a card
results = search_cards(query: "Eclipser")

# Step 2: Extract the canonical name from results
card_name = results["cards"][0]["name"]
# e.g., "Games+Butterfly Galaxii+Player+Factions+Major Factions+Eclipser Mercenaries"
# ^ This is the canonical form with spaces

# Step 3: Use that canonical name for subsequent operations
card = get_card(name: card_name)  # Uses canonical name
update_card(name: card_name, content: "...")  # Uses canonical name
```

**Why This Matters**:
1. **Consistency**: Using canonical names ensures your code always references cards the same way
2. **Readability**: Canonical names match what users see in the wiki UI
3. **Debugging**: Easier to trace operations when names match exactly
4. **Future-proofing**: If Decko's normalization behavior changes, canonical names will still work

---

### 3. Card Deletion Cascades Are Intentional

**What Happened**:
- ChatGPT deleted `Itzaltzen` (root culture card)
- All child cards like `Itzaltzen+Overview`, `Itzaltzen+History` also disappeared

**Reality**:
- This is **intentional Decko behavior**, not a bug
- Cards with `+` hierarchy are **part of their parent's namespace**
- Deleting `Parent` may delete `Parent+Child` (depends on Decko configuration)
- This maintains **data consistency** in the wiki

**Why MCP Allows This**:
- The `delete_card` tool is **admin-only** for this exact reason
- The MCP server enforces role-based access control
- Decko decides what to delete based on its internal rules

**Correct Behavior**:
1. **Never delete cards** unless explicitly authorized by the user
2. **Always use `list_children` first** to see what would be affected
3. **Show the user** what will be deleted before proceeding
4. **Only proceed** with explicit, informed consent
5. Understand that child deletion is **not a bug** - it's by design

**Example - Correct Deletion Pattern**:
```ruby
# Step 1: Show user what will be affected
parent_name = "Major Factions+Eclipser Mercenaries"
children = list_children(parent_name: parent_name)

# Step 2: Display to user
puts "Deleting '#{parent_name}' will also delete:"
children["children"].each { |c| puts "  - #{c['name']}" }

# Step 3: Only proceed with explicit consent
# User: "Yes, delete everything"
delete_card(name: parent_name)  # Admin-only operation
```

---

### 4. Use `list_children` Instead of `with_children`

**Wrong Pattern**:
```ruby
# Don't rely on this for discovering children:
card = get_card(name: "Parent Card", with_children: true)
```

**Why It Fails**:
- Decko has **virtual cards** - cards created on-demand that don't exist as database records
- Inclusions like `{{+intro}}` create **nests**, not structural children
- The `with_children` parameter only returns **actual database-stored child cards**

**Correct Pattern**:
```ruby
# Use the dedicated tool for finding children:
children = list_children(parent_name: "Parent Card")

# This explicitly queries for child relationships
# Returns structured child card data
```

**Example**:
```ruby
# Find all children of a faction card
parent = "Games+Butterfly Galaxii+Player+Factions+Major Factions+Eclipser Mercenaries"
result = list_children(parent_name: parent)

# result["children"] will include:
# - "...+Combat Doctrine"
# - "...+AI" (if you have GM/admin role)
# - "...+GM" (if you have GM/admin role)
```

---

### 5. Treat 404 Errors Cautiously

**Wrong Assumption**:
```ruby
# Card returns 404, so it doesn't exist - let's create it:
create_card(name: "Games+Butterfly Galaxii+Player+Factions+Major Factions+Eclipser Mercenaries+AI", ...)
```

**Reality - Two Possible Causes of 404**:
1. **Card genuinely doesn't exist**
2. **Card exists but you lack permission to see it** (security feature)

**Why Decko Does This**:
- Returning `403 Forbidden` would **leak information** about card existence
- `404 Not Found` maintains **security through obscurity**
- This is **intentional**, not a bug

**Correct Behavior**:
1. **Don't assume** 404 means "doesn't exist"
2. For `+AI` and `+GM` cards, 404 **likely means permission-locked**
3. **Never recreate** cards on 404 without user confirmation
4. Check your authentication role first

**Example - Correct 404 Handling**:
```ruby
begin
  card = get_card(name: "Some Card+GM")
rescue NotFoundError
  # Don't immediately assume it's missing!
  # Could be:
  # A) Card doesn't exist
  # B) Card exists but requires GM/admin role

  # If this is a +GM or +AI card and you're using 'user' role:
  puts "Card not found. This might be a permission issue - are you using the correct role?"

  # Don't automatically create it:
  # create_card(...)  # WRONG - might overwrite existing GM content
end
```

---

### 6. The Search → Fetch → Get Pattern

**Wrong Pattern (ChatGPT's Original Approach)**:
```ruby
# Search returns results with "name" field
results = search_cards(query: "Eclipser")
card_id = results["cards"][0]["id"]  # Extract ID

# Then try to use that ID with fetch or get_card
card = fetch(id: card_id)  # FAILS - fetch doesn't accept 'id'
```

**Correct Pattern**:
```ruby
# Step 1: Search
results = search_cards(query: "Eclipser")

# Step 2: Extract the NAME (not id)
card_name = results["cards"][0]["name"]

# Step 3: Use name with get_card
card = get_card(name: card_name)  # Always succeeds

# Or use the simplified 'fetch' tool (if available):
card = fetch(name: card_name)
```

**Why This Matters**:
- `search_cards` returns the **canonical name** field
- `get_card` and `fetch` accept the **name** parameter (not `id`)
- IDs are internal database identifiers - names are the API's canonical identifiers

---

## Recommended Testing Protocol

For AI agents validating correct MCP usage:

### Test 1: Search → Get Card (Exact Name Match)
```ruby
# Verify the search → get_card pattern works
results = search_cards(query: "Eclipser")
name = results["cards"][0]["name"]
card = get_card(name: name)

# Expected: Success (no errors)
# Validates: Name extraction and exact matching
```

### Test 2: Child Discovery
```ruby
# Verify list_children returns actual children
parent = "Games+Butterfly Galaxii+Player+Factions+Major Factions"
children = list_children(parent_name: parent)

# Expected: Array of child cards
# Validates: Child relationships work correctly
```

### Test 3: Permission vs Not Found
```ruby
# Test 404 behavior for GM-locked content
begin
  # Try accessing a +GM card with 'user' role
  card = get_card(name: "Some Card+GM")  # Authenticated as 'user'
rescue NotFoundError => e
  # Expected: 404 (card exists but user lacks permission)
  # Validates: Security behavior
end

# Now try with 'gm' or 'admin' role
card = get_card(name: "Some Card+GM")  # Authenticated as 'gm'
# Expected: Success
# Validates: Role-based access control
```

### Test 4: Space/Underscore Normalization
```ruby
# Create a card with spaces
create_card(name: "Test Card", content: "Created with spaces")

# Fetch using underscores (should return the same card)
card1 = get_card(name: "Test_Card")
card2 = get_card(name: "Test Card")

# Expected: Both return same card ID, canonical name is "Test Card"
# Validates: Decko normalizes spaces/underscores during lookup
# Validates: API returns canonical name regardless of query variation

# Clean up
delete_card(name: "Test Card")
```

### Test 5: Deletion Cascade
```ruby
# Create parent and child
create_card(name: "TestParent", content: "Parent")
create_card(name: "TestParent+Child", content: "Child")

# List children before deletion
children_before = list_children(parent_name: "TestParent")
# Expected: 1 child

# Delete parent
delete_card(name: "TestParent")  # Admin-only

# Try to get child (should fail)
begin
  get_card(name: "TestParent+Child")
rescue NotFoundError
  # Expected: Child was deleted with parent
  # Validates: Cascade deletion works as designed
end
```

---

## Tool Reference

### Primary Tools

#### `search_cards` - Find Cards by Query
```ruby
search_cards(
  query: "search term",           # Search in names and/or content
  search_in: "name",              # Options: "name", "content", "both"
  type: "Article",                # Optional: filter by card type
  limit: 50,                      # Max results (default 50, max 100)
  offset: 0                       # Pagination offset
)
```

**Returns**:
```ruby
{
  "cards" => [
    {
      "name" => "Full+Card+Name",  # USE THIS for get_card
      "id" => 123,                  # Internal DB ID (don't use for API)
      "type" => "Article",
      "content" => "...",
      "updated_at" => "2025-12-11T..."
    }
  ],
  "total" => 42,
  "limit" => 50,
  "offset" => 0
}
```

#### `get_card` - Fetch Single Card
```ruby
get_card(
  name: "Full+Card+Name",         # EXACT name from search_cards
  with_children: false            # Don't rely on this - use list_children
)
```

**Returns**:
```ruby
{
  "name" => "Full+Card+Name",
  "content" => "Card content...",
  "type" => "Article",
  "id" => 123,
  "updated_at" => "2025-12-11T...",
  "created_at" => "2025-12-10T..."
}
```

#### `list_children` - Get Child Cards
```ruby
list_children(
  parent_name: "Parent+Card+Name",  # Full parent name
  limit: 50                         # Max children to return
)
```

**Returns**:
```ruby
{
  "parent" => "Parent+Card+Name",
  "children" => [
    {
      "name" => "Parent+Card+Name+Child1",
      "content" => "...",
      "type" => "RichText"
    }
  ],
  "child_count" => 5
}
```

#### `create_card` - Create New Card
```ruby
create_card(
  name: "New+Card+Name",            # Full hierarchical name
  content: "Card content",          # HTML or plain text
  type: "Article"                   # Card type (use get_types to list)
)
```

**Role Requirements**: `user`, `gm`, or `admin`

#### `update_card` - Modify Existing Card
```ruby
update_card(
  name: "Existing+Card+Name",       # Exact current name
  content: "New content",           # Optional: new content
  type: "RichText"                  # Optional: new type
)
```

**Role Requirements**: `user`, `gm`, or `admin`

#### `delete_card` - Remove Card (⚠️ Dangerous)
```ruby
delete_card(
  name: "Card+To+Delete",           # Will cascade to children!
  force: false                      # Force delete even with children
)
```

**Role Requirements**: `admin` only
**WARNING**: Deletes all `Card+To+Delete+*` children!

---

## Authentication and Roles

### Three Role Levels

1. **User Role** (`role: "user"`):
   - Read player-visible content
   - Create and update cards
   - Cannot see `+GM` or `+AI` cards
   - Cannot delete cards

2. **GM Role** (`role: "gm"`):
   - All user permissions
   - Read `+GM` and `+AI` cards
   - Cannot delete cards

3. **Admin Role** (`role: "admin"`):
   - All GM permissions
   - Delete and rename cards
   - Access admin tools (backup, etc.)

### How to Authenticate

**Option 1: API Key**
```ruby
# Set environment variables:
MCP_API_KEY=your-api-key-here
MCP_ROLE=admin  # or 'user', 'gm'
```

**Option 2: Username/Password**
```ruby
# Set environment variables:
MCP_USERNAME=your-username
MCP_PASSWORD=your-password
MCP_ROLE=admin  # Auto-determined if not specified
```

---

## Common Mistakes and Corrections

### ❌ Mistake 1: Not Using Canonical Names from API Responses
```ruby
# ⚠️ WORKS BUT NOT RECOMMENDED:
search_result = "Major Factions"  # API returned this canonical name
card = get_card(name: "Major_Factions")  # Works due to normalization, but inconsistent
```

**Why This Is Problematic:**
While Decko normalizes spaces/underscores during lookup (so this technically works), you're creating inconsistency:
- The API returned `"Major Factions"` (canonical form)
- Your code uses `"Major_Factions"` (non-canonical form)
- Log files and error messages will show different names for the same card
- Other developers may be confused by the mismatch

**✅ Correct**:
```ruby
search_result = "Major Factions"  # API returned canonical name
card = get_card(name: "Major Factions")  # Use exact canonical name
```

**Best Practice:** Always use the exact name string returned by the API, even though normalization would allow variations.

### ❌ Mistake 2: Using IDs Instead of Names
```ruby
# WRONG:
results = search_cards(query: "...")
id = results["cards"][0]["id"]
card = get_card(id: id)  # FAILS - get_card uses 'name' parameter
```

**✅ Correct**:
```ruby
results = search_cards(query: "...")
name = results["cards"][0]["name"]
card = get_card(name: name)
```

### ❌ Mistake 3: Recreating Cards on 404
```ruby
# WRONG:
begin
  card = get_card(name: "SomeCard+GM")
rescue NotFoundError
  create_card(name: "SomeCard+GM", ...)  # Might overwrite existing GM content!
end
```

**✅ Correct**:
```ruby
begin
  card = get_card(name: "SomeCard+GM")
rescue NotFoundError
  puts "Card not found - could be permission issue if this is GM content"
  # Ask user for confirmation before creating
end
```

### ❌ Mistake 4: Deleting Without Checking Children
```ruby
# WRONG:
delete_card(name: "Culture Name")  # Deletes all children without warning!
```

**✅ Correct**:
```ruby
# First, check what will be deleted:
children = list_children(parent_name: "Culture Name")
puts "This will delete #{children['child_count']} children:"
children["children"].each { |c| puts "  - #{c['name']}" }

# Only proceed with explicit consent:
delete_card(name: "Culture Name") if user_confirms?
```

### ❌ Mistake 5: Expecting Namespace Separation
```ruby
# WRONG assumption:
# "The /Magi Archive/link_XXX namespace has different cards than /Magi Archive/link_YYY"
```

**✅ Correct understanding**:
```ruby
# All tool instances connect to the same wiki:
# There is only ONE Magi Archive with ONE set of cards
# The link_XXX suffixes are client-side tool IDs, not server namespaces
```

---

## Error Handling Reference

### Common Errors and Their Meanings

| Error | HTTP Code | Likely Cause | Correct Action |
|-------|-----------|--------------|----------------|
| `NotFoundError` | 404 | Card doesn't exist OR you lack permission | Check role, don't auto-create |
| `AuthorizationError` | 403 | Role lacks permission for operation | Use higher role (gm/admin) |
| `AuthenticationError` | 401 | Invalid API key or expired token | Check credentials |
| `ValidationError` | 422 | Invalid parameters (e.g., missing name) | Fix request parameters |
| `InternalError` | 500 | Server error | Report to admin, don't retry |

---

## Quick Reference Checklist

Before using the Magi Archive MCP, remember:

- [ ] There is **only one** MCP endpoint (no namespaces)
- [ ] Card names: **spaces ≈ underscores** (Decko normalizes), but **always use canonical names** from API
- [ ] Use `search_cards` → extract **name** → `get_card(name: ...)`
- [ ] Use `list_children` for finding children (not `with_children`)
- [ ] Check `list_children` **before deleting** (cascades are intentional)
- [ ] Treat 404 cautiously (might be permission denial)
- [ ] Always use exact canonical names returned by the API (don't manually normalize)
- [ ] Authenticate with appropriate role for your task
- [ ] Only delete with admin role and user consent

---

## For Developers Debugging the MCP Service

If you're testing the MCP server/connector itself (not just usage patterns):

### High-Value Test Cases

1. **Verify search → get_card name consistency**:
   ```bash
   # Search should return names that get_card accepts
   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/search_cards \
     -H "Authorization: Bearer $TOKEN" \
     -d '{"query": "Eclipser"}'
   # Extract "name" from response

   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/get_card \
     -H "Authorization: Bearer $TOKEN" \
     -d '{"name": "<exact name from search>"}'
   # Should succeed
   ```

2. **Verify list_children returns all children including GM content**:
   ```bash
   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/list_children \
     -H "Authorization: Bearer $GM_TOKEN" \
     -d '{"parent_name": "Games+Butterfly Galaxii+Player+Factions+Major Factions+Eclipser Mercenaries"}'
   # Should include +AI, +GM children
   ```

3. **Verify 404 vs 403 for permission-locked cards**:
   ```bash
   # Try with user role:
   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/get_card \
     -H "Authorization: Bearer $USER_TOKEN" \
     -d '{"name": "Some Card+GM"}'
   # Should return 404 (security through obscurity)

   # Try with GM role:
   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/get_card \
     -H "Authorization: Bearer $GM_TOKEN" \
     -d '{"name": "Some Card+GM"}'
   # Should return 200 with content
   ```

4. **Verify deletion cascades work**:
   ```bash
   # Create test parent and child
   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/create_card \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -d '{"name": "TestParent", "content": "Parent"}'

   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/create_card \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -d '{"name": "TestParent+Child", "content": "Child"}'

   # Delete parent
   curl -X DELETE https://wiki.magi-agi.org/api/mcp/tools/delete_card \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -d '{"name": "TestParent"}'

   # Verify child is also deleted
   curl -X POST https://wiki.magi-agi.org/api/mcp/tools/get_card \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     -d '{"name": "TestParent+Child"}'
   # Should return 404
   ```

---

## Conclusion

The Magi Archive MCP server is **working correctly** according to the Decko wiki's design. Most reported issues were due to:

1. Misunderstanding the architecture (no namespaces)
2. Misunderstanding Decko's card model (exact names, cascade deletion)
3. Client-side routing or caching issues
4. Intentional security behaviors (hiding forbidden cards)

By following the patterns in this guide, AI agents can successfully interact with the Magi Archive MCP server and avoid the pitfalls encountered in early integration testing.

---

**Prepared by**: Claude (Magi Archive MCP Developer)
**Date**: 2025-12-11
**Based on**: ChatGPT integration lessons learned
**Version**: 1.0
