#!/usr/bin/env bash
# Zero-leak Cloudflare Access Service Token minter for cc-mcp.
#
# Creates a dedicated Service Token, writes it to .cf-access.env (chmod 600,
# gitignored) WITHOUT ever printing CF_ACCESS_CLIENT_SECRET to stdout/stderr,
# and scopes the cc-mcp Cloudflare Access Service Auth policy strictly to that
# single token ID (least privilege).
#
# Required env var:
#   CF_API_TOKEN  - Cloudflare API token with ONLY:
#                   - Account -> Access: Service Tokens -> Edit
#                   - Account -> Access: Apps and Policies -> Edit
#
# Optional env vars:
#   TOKEN_NAME     (default: cc-mcp-gateway)
#   TOKEN_DURATION (default: 8760h)
#   OUT_FILE       (default: ./.cf-access.env)

set -euo pipefail

ACCOUNT_ID="ce75b366925251ef9100230d96370e49"
APP_ID="7c981ac8-0337-4cb6-83f2-a9e309cfffc4"
TOKEN_NAME="${TOKEN_NAME:-cc-mcp-gateway}"
TOKEN_DURATION="${TOKEN_DURATION:-8760h}"
OUT_FILE="${OUT_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.cf-access.env}"

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "Error: CF_API_TOKEN is required." >&2
  echo "Create a least-privilege Cloudflare API token with:" >&2
  echo "  - Account -> Access: Service Tokens -> Edit" >&2
  echo "  - Account -> Access: Apps and Policies -> Edit" >&2
  echo "Then run: CF_API_TOKEN=... $0" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }

# Ensure any temp files and the output file are owner-readable only (0600)
umask 077
TMP_RESP="$(mktemp)"
trap 'rm -f "$TMP_RESP"' EXIT

# 1. Mint dedicated Cloudflare Access Service Token
curl -fsS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/access/service_tokens" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$(jq -nc --arg name "$TOKEN_NAME" --arg dur "$TOKEN_DURATION" '{name:$name, duration:$dur}')" \
  > "$TMP_RESP"

if [[ "$(jq -r '.success' "$TMP_RESP")" != "true" ]]; then
  echo "Error: Failed to create service token:" >&2
  jq -r '.errors' "$TMP_RESP" >&2
  exit 1
fi

TOKEN_ID="$(jq -r '.result.id' "$TMP_RESP")"
CLIENT_ID="$(jq -r '.result.client_id' "$TMP_RESP")"
EXPIRES_AT="$(jq -r '.result.expires_at // ""' "$TMP_RESP")"

# 2. Write env/INI file directly from jq without ever echoing client_secret to stdout
{
  echo "# Cloudflare Access Service Token for cc-mcp (chmod 600, gitignored)"
  echo "# Generated at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo 'CF_ACCESS_URL="https://cc.pants.place"'
  echo 'CF_ACCESS_MCP_URL="https://cc.pants.place/mcp"'
  jq -r '.result |
    "CF_ACCESS_TOKEN_ID=\"\(.id)\"\n" +
    "CF_ACCESS_TOKEN_NAME=\"\(.name)\"\n" +
    "CF_ACCESS_CLIENT_ID=\"\(.client_id)\"\n" +
    "CF_ACCESS_CLIENT_SECRET=\"\(.client_secret)\"\n" +
    "CF_ACCESS_EXPIRES_AT=\"\(.expires_at // "")\""' "$TMP_RESP"
} > "$OUT_FILE"
chmod 600 "$OUT_FILE"

# 3. Bind a least-privilege Service Auth policy scoped strictly to this single token ID
POLICY_BODY="$(jq -nc --arg name "CC-Mesh Gateway Token (${TOKEN_NAME})" --arg tid "$TOKEN_ID" '{
  name: $name,
  decision: "non_identity",
  precedence: 1,
  include: [{ service_token: { token_id: $tid } }],
  exclude: [],
  require: []
}')"

POLICY_RESP="$(curl -fsS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$POLICY_BODY")"

if [[ "$(jq -r '.success' <<< "$POLICY_RESP")" != "true" ]]; then
  echo "Warning: Token saved to ${OUT_FILE}, but policy creation failed:" >&2
  jq -r '.errors' <<< "$POLICY_RESP" >&2
  exit 1
fi

POLICY_ID="$(jq -r '.result.id' <<< "$POLICY_RESP")"

# Print ONLY non-secret metadata
echo "Minted least-privilege Cloudflare Access Service Token:"
echo "  File:       ${OUT_FILE} (mode 600)"
echo "  Token ID:   ${TOKEN_ID}"
echo "  Client ID:  ${CLIENT_ID}"
echo "  Expires:    ${EXPIRES_AT}"
echo "  Policy ID:  ${POLICY_ID} (scoped strictly to token_id=${TOKEN_ID} on cc.pants.place)"
echo ""
echo "Note: CF_ACCESS_CLIENT_SECRET was written directly to ${OUT_FILE} and never printed."
