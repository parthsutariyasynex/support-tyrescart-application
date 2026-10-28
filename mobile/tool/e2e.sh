#!/usr/bin/env bash
# End-to-end test of the app on a running emulator/phone against a DEVELOPMENT server (never production).
#
#   tool/e2e.sh <device-id> [server]      e.g. tool/e2e.sh emulator-5554 http://localhost:4000
#
# Creates a throwaway workspace with four simulated customer chats (development servers only), then runs
# integration_test/app_test.dart through flutter drive. Screenshots land in build/screenshots/.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=${1:?device id, see flutter devices}
SERVER=${2:-http://localhost:4000}
# The emulator reaches the computer's localhost as 10.0.2.2
APP_SERVER=${APP_SERVER:-${SERVER/localhost/10.0.2.2}}
STAMP=$(date +%s)
EMAIL="mobile-e2e-$STAMP@example.test"
PASSWORD="MobileE2e${STAMP: -4}x"

gql() { curl -sf "$SERVER/graphql" -H 'Content-Type: application/json' ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -d "$1"; }

TOKEN=$(gql "{\"query\":\"mutation R(\$i: RegisterInput!) { register(input: \$i) { token } }\",\"variables\":{\"i\":{\"name\":\"E2E Owner\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"workspaceName\":\"Mobile e2e $STAMP\"}}}" |
  python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["register"]["token"])')

# A teammate to @mention in notes
gql "{\"query\":\"mutation I(\$i: InviteMemberInput!) { inviteMember(input: \$i) { invited } }\",\"variables\":{\"i\":{\"name\":\"Nikhil Shah\",\"email\":\"mobile-e2e-agent-$STAMP@example.test\",\"role\":\"agent\",\"password\":\"$PASSWORD\"}}}" >/dev/null

while IFS='|' read -r WA NAME BODY; do
  gql "{\"query\":\"mutation S(\$i: SimulateIncomingInput) { simulateIncomingMessage(input: \$i) }\",\"variables\":{\"i\":{\"waId\":\"$WA\",\"name\":\"$NAME\",\"body\":\"$BODY\"}}}" >/dev/null
  sleep 1
done <<'CHATS'
971501112233|Ahmed Al Mansoori|Hi, do you have 265/65R17 tyres for a Prado?
971552223344|Priya Nair|Can I book a wheel alignment for tomorrow morning?
919876543210|Rahul Mehta|What is the price for Michelin Pilot Sport 4 225/45R18?
971504445566|Sarah Johnson|My order TC-10422 hasn't arrived yet
CHATS

flutter drive -d "$DEVICE" \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/app_test.dart \
  --dart-define=API_BASE_URL="$APP_SERVER" \
  --dart-define=TEST_EMAIL="$EMAIL" \
  --dart-define=TEST_PASSWORD="$PASSWORD"
