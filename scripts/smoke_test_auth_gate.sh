#!/usr/bin/env bash
# Deployment smoke test for the MCP auth gate (2026-06-14 incident regression).
#
# The hosted MCP server must REJECT unauthenticated requests — an anonymous
# caller must not be able to read restricted/GM content. This catches the whole
# class of failure end-to-end, including causes a unit test can't see (e.g. an
# nginx `proxy_set_header Host 127.0.0.1:3002` that trips the localhost bypass).
#
# Run after every MCP/nginx deploy, or on a schedule as a monitor:
#   scripts/smoke_test_auth_gate.sh
#   BASE_URL=https://dev-mcp.magi-agi.org scripts/smoke_test_auth_gate.sh
#   BASE_URL=https://mcp.hyperon.dev RESTRICTED_CARD="Some+Restricted+Card" scripts/smoke_test_auth_gate.sh
set -u

BASE="${BASE_URL:-https://mcp.hyperon.dev}"
CARD="${RESTRICTED_CARD:-Games+Butterfly Galaxii+GM Docs}"
fail=0

echo "Auth-gate smoke test against: $BASE"

# 1) A no-token MCP request must be rejected (HTTP 401).
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
echo "  no-token tools/list -> HTTP $code"
if [ "$code" != "401" ]; then
  echo "  FAIL: unauthenticated request was NOT rejected (expected 401)"
  fail=1
fi

# 2) A no-token read of a restricted card must be denied (defense in depth: even
#    if the gate is bypassed, the default identity must not be privileged).
resp=$(curl -s -X POST "$BASE" -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_card\",\"arguments\":{\"name\":\"$CARD\"}}}")
if echo "$resp" | grep -qiE "Authentication required|permission_denied|Permission Denied"; then
  echo "  no-token restricted read -> denied (ok)"
else
  echo "  FAIL: no-token read of restricted card '$CARD' was NOT denied:"
  echo "    $(echo "$resp" | head -c 200)"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: MCP auth gate is enforced."
else
  echo "SECURITY REGRESSION DETECTED — unauthenticated access is possible."
fi
exit "$fail"
