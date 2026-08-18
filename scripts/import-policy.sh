#!/usr/bin/env bash
# Import the AI Gateway policy onto the ai-gateway API.
# Review scripts/README.md and replace demo-specific values in the policy first.
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-68837237-5a48-41a9-bed4-947f5c277684}"
RG="${RG:-rg-apim-finops-demo}"
APIM="${APIM:-apim-finops-28016}"
API_ID="${API_ID:-ai-gateway}"
POLICY_FILE="${POLICY_FILE:-$(dirname "$0")/../apim/ai-gateway-policy.xml}"

echo "Importing $POLICY_FILE onto $APIM/$API_ID ..."

# The Management REST API expects the policy XML wrapped in a JSON body.
POLICY_XML="$(cat "$POLICY_FILE")"
BODY="$(python3 - "$POLICY_XML" <<'PY'
import json,sys
print(json.dumps({"properties":{"format":"rawxml","value":sys.argv[1]}}))
PY
)"

az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}/apis/${API_ID}/policies/policy?api-version=2022-08-01" \
  --headers "Content-Type=application/json" \
  --body "$BODY"

echo "Done."
