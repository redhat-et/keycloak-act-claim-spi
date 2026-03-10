#!/usr/bin/env bash
#
# Test script for the Keycloak act-claim SPI.
# Demonstrates a two-hop token exchange with nested act claims:
#   alice -> agent-service -> document-service
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load environment if env.sh exists
if [[ -f "$SCRIPT_DIR/env.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/env.sh"
fi

# Validate required variables
for var in KEYCLOAK_URL REALM AGENT_CLIENT_ID AGENT_CLIENT_SECRET KC_USERNAME KC_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set. Copy scripts/env.sh.example to scripts/env.sh and fill in values."
        exit 1
    fi
done

TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token"

# Decode a JWT payload with proper base64 padding
decode_jwt() {
    local payload
    payload=$(echo "$1" | cut -d'.' -f2)
    local pad=$(( 4 - ${#payload} % 4 ))
    [[ $pad -ne 4 ]] && payload="${payload}$(printf '=%.0s' $(seq 1 "$pad"))"
    echo "$payload" | base64 -d 2>/dev/null
}

echo "============================================================"
echo " Keycloak act-claim SPI -- token exchange test"
echo "============================================================"
echo ""
echo "Keycloak:  $KEYCLOAK_URL"
echo "Realm:     $REALM"
echo "User:      $KC_USERNAME"
echo "Clients:   $AGENT_CLIENT_ID -> ${DOC_CLIENT_ID:-"(second hop skipped)"}"
echo ""

# ── Step 1: User login ──────────────────────────────────────────
echo "── Step 1: Obtain user token ($KC_USERNAME via $AGENT_CLIENT_ID)"
USER_TOKEN=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=password" \
    -d "client_id=${AGENT_CLIENT_ID}" \
    -d "client_secret=${AGENT_CLIENT_SECRET}" \
    -d "username=${KC_USERNAME}" \
    -d "password=${KC_PASSWORD}" \
    | jq -r '.access_token')

if [[ -z "$USER_TOKEN" || "$USER_TOKEN" == "null" ]]; then
    echo "FAIL: Could not obtain user token. Check credentials."
    exit 1
fi
echo "   preferred_username: $(decode_jwt "$USER_TOKEN" | jq -r '.preferred_username')"
echo "   OK"
echo ""

# ── Step 2: Actor token (agent-service service account) ─────────
echo "── Step 2: Obtain actor token ($AGENT_CLIENT_ID service account)"
AGENT_ACTOR=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=client_credentials" \
    -d "client_id=${AGENT_CLIENT_ID}" \
    -d "client_secret=${AGENT_CLIENT_SECRET}" \
    | jq -r '.access_token')

if [[ -z "$AGENT_ACTOR" || "$AGENT_ACTOR" == "null" ]]; then
    echo "FAIL: Could not obtain actor token."
    exit 1
fi
AGENT_SUB=$(decode_jwt "$AGENT_ACTOR" | jq -r '.sub')
echo "   sub: $AGENT_SUB"
echo "   preferred_username: $(decode_jwt "$AGENT_ACTOR" | jq -r '.preferred_username')"
echo "   OK"
echo ""

# ── Step 3: First-hop token exchange ────────────────────────────
echo "── Step 3: First-hop exchange ($KC_USERNAME + $AGENT_CLIENT_ID actor)"
FIRST_HOP_RESPONSE=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_id=${AGENT_CLIENT_ID}" \
    -d "client_secret=${AGENT_CLIENT_SECRET}" \
    -d "subject_token=${USER_TOKEN}" \
    -d "actor_token=${AGENT_ACTOR}" \
    -d "actor_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token")

FIRST_HOP=$(echo "$FIRST_HOP_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$FIRST_HOP" ]]; then
    echo "FAIL: First-hop exchange failed:"
    echo "$FIRST_HOP_RESPONSE" | jq .
    exit 1
fi

FIRST_ACT=$(decode_jwt "$FIRST_HOP" | jq '.act')
echo "   preferred_username: $(decode_jwt "$FIRST_HOP" | jq -r '.preferred_username')"
echo "   act claim:"
echo "$FIRST_ACT" | jq . | sed 's/^/   /'
echo ""

# Verify first-hop act claim
FIRST_ACT_SUB=$(echo "$FIRST_ACT" | jq -r '.sub // empty')
if [[ "$FIRST_ACT_SUB" == "$AGENT_SUB" ]]; then
    echo "   PASS: act.sub matches $AGENT_CLIENT_ID service account"
else
    echo "   FAIL: act.sub='$FIRST_ACT_SUB' does not match expected '$AGENT_SUB'"
    exit 1
fi
echo ""

# ── Step 4: Second-hop token exchange (optional) ────────────────
if [[ -z "${DOC_CLIENT_ID:-}" || -z "${DOC_CLIENT_SECRET:-}" ]]; then
    echo "── Step 4: Skipped (DOC_CLIENT_ID / DOC_CLIENT_SECRET not set)"
    echo ""
    echo "============================================================"
    echo " RESULT: First-hop act claim verified successfully"
    echo "============================================================"
    exit 0
fi

echo "── Step 4: Obtain actor token ($DOC_CLIENT_ID service account)"
DOC_ACTOR=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=client_credentials" \
    -d "client_id=${DOC_CLIENT_ID}" \
    -d "client_secret=${DOC_CLIENT_SECRET}" \
    | jq -r '.access_token')

if [[ -z "$DOC_ACTOR" || "$DOC_ACTOR" == "null" ]]; then
    echo "FAIL: Could not obtain $DOC_CLIENT_ID actor token."
    exit 1
fi
DOC_SUB=$(decode_jwt "$DOC_ACTOR" | jq -r '.sub')
echo "   sub: $DOC_SUB"
echo "   preferred_username: $(decode_jwt "$DOC_ACTOR" | jq -r '.preferred_username')"
echo "   OK"
echo ""

echo "── Step 5: Second-hop exchange ($DOC_CLIENT_ID actor on first-hop token)"
SECOND_HOP_RESPONSE=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_id=${DOC_CLIENT_ID}" \
    -d "client_secret=${DOC_CLIENT_SECRET}" \
    -d "subject_token=${FIRST_HOP}" \
    -d "actor_token=${DOC_ACTOR}" \
    -d "actor_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token")

SECOND_HOP=$(echo "$SECOND_HOP_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$SECOND_HOP" ]]; then
    echo "   WARN: Second-hop exchange failed (audience or permission issue):"
    echo "$SECOND_HOP_RESPONSE" | jq . | sed 's/^/   /'
    echo ""
    echo "   This is expected if $DOC_CLIENT_ID is not in the first-hop token's"
    echo "   audience. Add an audience mapper to $AGENT_CLIENT_ID that includes"
    echo "   $DOC_CLIENT_ID, or pass audience=$DOC_CLIENT_ID in the first exchange."
    echo ""
    echo "============================================================"
    echo " RESULT: First-hop verified. Second-hop needs audience config."
    echo "============================================================"
    exit 0
fi

SECOND_ACT=$(decode_jwt "$SECOND_HOP" | jq '.act')
echo "   preferred_username: $(decode_jwt "$SECOND_HOP" | jq -r '.preferred_username')"
echo "   act claim (nested):"
echo "$SECOND_ACT" | jq . | sed 's/^/   /'
echo ""

# Verify second-hop nesting
SECOND_ACT_SUB=$(echo "$SECOND_ACT" | jq -r '.sub // empty')
NESTED_ACT_SUB=$(echo "$SECOND_ACT" | jq -r '.act.sub // empty')
PASS=true

if [[ "$SECOND_ACT_SUB" == "$DOC_SUB" ]]; then
    echo "   PASS: act.sub matches $DOC_CLIENT_ID service account"
else
    echo "   FAIL: act.sub='$SECOND_ACT_SUB' does not match expected '$DOC_SUB'"
    PASS=false
fi

if [[ "$NESTED_ACT_SUB" == "$AGENT_SUB" ]]; then
    echo "   PASS: act.act.sub matches $AGENT_CLIENT_ID service account (chain preserved)"
else
    echo "   FAIL: act.act.sub='$NESTED_ACT_SUB' does not match expected '$AGENT_SUB'"
    PASS=false
fi

echo ""
echo "============================================================"
if $PASS; then
    echo " RESULT: Two-hop act claim chaining verified successfully"
else
    echo " RESULT: Some checks failed -- see above"
fi
echo "============================================================"
