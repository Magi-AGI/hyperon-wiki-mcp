# MCP HTTP Server Operations Guide

## Overview

The Hyperon Wiki MCP HTTP Server provides remote access to the Hyperon Wiki wiki via the Model Context Protocol (MCP). This allows AI assistants (Claude, ChatGPT, etc.) to interact with the wiki through structured tool calls.

## Service Status

### Check Service Status
```bash
sudo systemctl status hyperon-wiki-mcp-http.service
```

### Start/Stop/Restart Service
```bash
sudo systemctl start hyperon-wiki-mcp-http.service
sudo systemctl stop hyperon-wiki-mcp-http.service
sudo systemctl restart hyperon-wiki-mcp-http.service
```

### View Logs
```bash
# Recent logs
sudo journalctl -u hyperon-wiki-mcp-http.service -n 50

# Follow logs in real-time
sudo journalctl -u hyperon-wiki-mcp-http.service -f

# Logs since last hour
sudo journalctl -u hyperon-wiki-mcp-http.service --since "1 hour ago"
```

## Endpoints

### Public HTTPS (via Cloudflare)
- **Base URL**: `https://mcp.hyperon.dev`
- **Health Check**: `https://mcp.hyperon.dev/health`
- **SSE Stream**: `https://mcp.hyperon.dev/sse`
- **MCP Messages**: `https://mcp.hyperon.dev/message` (POST)
- **Server Info**: `https://mcp.hyperon.dev/`

### Local Access (direct)
- **Health Check**: `http://127.0.0.1:3002/health`
- **SSE Stream**: `http://127.0.0.1:3002/sse`
- **MCP Messages**: `http://127.0.0.1:3002/message` (POST)

## Testing

### Quick Health Check
```bash
curl -s https://mcp.hyperon.dev/health | jq
```

### Test SSE Stream (5 seconds)
```bash
timeout 5 curl -N -s https://mcp.hyperon.dev/sse
```

### Test MCP Tools List
```bash
curl -s -X POST https://mcp.hyperon.dev/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq
```

### Test MCP Health Check Tool
```bash
curl -s -X POST https://mcp.hyperon.dev/message \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"health_check","arguments":{"detailed":true}}}' | jq
```

## Architecture

### Component Stack
1. **Cloudflare** → HTTPS termination, DDoS protection
2. **Nginx** (port 80) → Reverse proxy, SSE/WebSocket support
3. **Puma** (port 3002) → Ruby web server
4. **Pure Rack App** (`lib/magi/archive/mcp/rack_app.rb`) → HTTP application
5. **MCP Ruby Gem** (0.4.0) → MCP protocol implementation
6. **Hyperon Wiki API** → Upstream Decko wiki via HTTPS

### Why Pure Rack?

The production server uses a pure Rack implementation instead of Sinatra to avoid Sinatra 4.x's `Rack::Protection::HostAuthorization` middleware, which was blocking legitimate requests with custom `Host` headers from nginx.

**Files:**
- **Production**: `bin/mcp-server-rack-direct` + `lib/magi/archive/mcp/rack_app.rb`
- **Reference**: `lib/magi/archive/mcp/http_app.rb` (Sinatra::Base version)
- **Archived**: `archive/old-server-scripts/` (original implementations with Host header issues)

## Configuration

### Service File
Location: `/etc/systemd/system/hyperon-wiki-mcp-http.service`

```ini
[Unit]
Description=Hyperon Wiki MCP HTTP Server
After=network.target
Requires=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/hyperon-wiki-mcp
Environment="RAILS_ENV=production"
EnvironmentFile=/home/ubuntu/hyperon-wiki-mcp/.env.production
ExecStart=/home/ubuntu/.rbenv/shims/ruby /home/ubuntu/hyperon-wiki-mcp/bin/mcp-server-rack-direct
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Environment Variables
Location: `/home/ubuntu/hyperon-wiki-mcp/.env.production`

Required variables:
- `DECKO_API_BASE_URL` - Hyperon Wiki API endpoint
- `MCP_API_USERNAME` - Admin username
- `MCP_API_PASSWORD` - Admin password

### Nginx Configuration
Location: `/etc/nginx/sites-available/mcp-magi-agi`

Key settings:
- Listens on port 80 (Cloudflare handles HTTPS)
- Proxy passes to `127.0.0.1:3002`
- Host header rewritten to `127.0.0.1:3002`
- SSE/WebSocket support enabled
- 600-second timeouts for long operations

## Troubleshooting

### Service Won't Start
1. Check environment file exists:
   ```bash
   ls -la /home/ubuntu/hyperon-wiki-mcp/.env.production
   ```

2. Check Ruby/rbenv is available:
   ```bash
   /home/ubuntu/.rbenv/shims/ruby --version
   ```

3. Test script manually:
   ```bash
   cd /home/ubuntu/hyperon-wiki-mcp
   /home/ubuntu/.rbenv/shims/ruby bin/mcp-server-rack-direct
   ```

### "Host not permitted" Errors
This was the original issue that led to the pure Rack implementation. If you see this:
1. Verify you're using `bin/mcp-server-rack-direct` (not the old `mcp-server-http`)
2. Check nginx is rewriting Host header to `127.0.0.1:3002`
3. Ensure `lib/magi/archive/mcp/rack_app.rb` has no Rack::Protection middleware

### Connection Timeouts
- SSE connections can idle up to 600 seconds
- Check nginx timeout settings in `/etc/nginx/sites-available/mcp-magi-agi`
- Verify Cloudflare proxy settings aren't timing out

### High Memory Usage
Normal memory usage: ~50-60MB

If consistently higher:
1. Check for memory leaks in recent code changes
2. Restart service: `sudo systemctl restart hyperon-wiki-mcp-http.service`
3. Monitor with: `ps aux | grep mcp-server`

## Maintenance

### Updating Code
```bash
cd /home/ubuntu/hyperon-wiki-mcp
git pull origin feature/mcp-specifications
bundle install
sudo systemctl restart hyperon-wiki-mcp-http.service
```

### Rotating Credentials
1. Update `.env.production` with new credentials
2. Restart service: `sudo systemctl restart hyperon-wiki-mcp-http.service`
3. Test health endpoint to verify: `curl -s https://mcp.hyperon.dev/health`

### Checking Disk Space
```bash
df -h /
du -sh /home/ubuntu/hyperon-wiki-mcp
```

## Monitoring

### Key Metrics
- **Response Time**: Health check should respond < 200ms
- **Memory**: Should stay under 100MB
- **CPU**: Should average < 5% (spikes during requests are normal)
- **Uptime**: Should match system uptime (auto-restart on crash)

### Quick Status Check Script
```bash
#!/bin/bash
echo "=== MCP Server Status ==="
systemctl is-active hyperon-wiki-mcp-http.service
echo ""
echo "=== Health Check ==="
curl -s https://mcp.hyperon.dev/health | jq
echo ""
echo "=== Process Info ==="
ps aux | grep mcp-server-rack-direct | grep -v grep
echo ""
echo "=== Recent Errors ==="
sudo journalctl -u hyperon-wiki-mcp-http.service --since "1 hour ago" | grep -i error | tail -5
```

## Security Notes

- Service runs as `ubuntu` user (non-root)
- Binds to `127.0.0.1:3002` only (not exposed to internet directly)
- All public access goes through nginx → Cloudflare
- Authentication handled by upstream Hyperon Wiki API (JWT tokens)
- No local security middleware (pure Rack app)

## Available MCP Tools

The server exposes 20 MCP tools for wiki interaction:

**Core Operations:**
- `get_card`, `search_cards`, `create_card`, `update_card`, `delete_card`, `list_children`

**Tags & Discovery:**
- `get_tags`, `search_by_tags`, `suggest_tags`

**Relationships:**
- `get_relationships`

**Validation & Recommendations:**
- `validate_card`, `get_recommendations`, `get_types`

**Content Rendering:**
- `render_content`

**Admin Operations:**
- `admin_backup`, `spoiler_scan`

**Advanced Operations:**
- `batch_cards`, `run_query`

**Utilities:**
- `health_check`, `create_weekly_summary`

Full tool schemas available at: `https://mcp.hyperon.dev/message` (POST with `tools/list` method)

## Support

For issues or questions:
- Check logs: `sudo journalctl -u hyperon-wiki-mcp-http.service -n 100`
- Test upstream wiki: `curl -s https://wiki.hyperon.dev/health`
- Verify nginx: `sudo nginx -t && sudo systemctl status nginx`
