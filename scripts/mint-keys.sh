#!/usr/bin/env bash
# mint-keys.sh — provision per-team virtual keys with MODEL ACLs + BUDGETS.
# This is the API-management layer of the demo: who may call which model, at what cap.
# Usage: MASTER=sk-... ./scripts/mint-keys.sh
set -euo pipefail

GW="${GW_URL:-http://localhost:4000}"
MASTER="${MASTER:?set MASTER to the LITELLM_MASTER_KEY from .env}"

mint() { # $1=key_alias  $2=models(json array)  $3=max_budget(usd)  $4=team-ish note
  curl -sf -X POST "$GW/key/generate" \
    -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
    -d "{\"key_alias\": \"$1\", \"models\": $2, \"max_budget\": $3, \"metadata\": {\"note\": \"$4\"}}" \
  | jq -r '.key'
}

echo "research   (claude+local,  \$50/mo): $(mint research   '["company-ai","company-claude"]' 50 'full access tier')"
echo "restricted (local only,    \$10/mo): $(mint restricted '["company-ai"]'               10 'restricted data stays local')"
echo "app-invoice(claude only,   \$25/mo): $(mint app-invoice '["company-claude"]'           25 'workflow service account')"
echo
echo "Verify:  curl -s $GW/key/list -H \"Authorization: Bearer $MASTER\" | jq '.keys[] | {key_alias, models, max_budget}'"
echo "Audit:   each key's spend lands in LiteLLM's SpendLogs (Postgres) — see README's control narrative."
