#!/bin/sh
# Live run with your own Anthropic key.
#   cp .env.example .env      # then put your key after ANTHROPIC_API_KEY=
#   ./tools/run_benchmark.sh  # 300 benchmark recalls (or: ./tools/run_benchmark.sh 20)
# The key is read from .env by docker compose and passed to the container environment only.
# This script never prints it. Spend stops at RR_SPEND_CAP_USD (default $5).
# claude-haiku-5-5: estimated $0.001-0.002 per recall (two model turns).
set -e
cd "$(dirname "$0")/.."
N=${1:-300}
PORT=${RR_PORT:-52795}
if [ ! -f .env ] || ! grep -Eq '^ANTHROPIC_API_KEY=.+' .env; then
  echo "No key: put ANTHROPIC_API_KEY=... in .env first (cp .env.example .env)."
  exit 1
fi
echo "== restarting the container with the key from .env (environment only) =="
docker compose up -d
i=0
until curl -fs "http://127.0.0.1:$PORT/recallreach/api/status" 2>/dev/null | grep -q '"mode":"live"'; do
  i=$((i + 1)); [ $i -gt 60 ] && { echo "The app did not come up in live mode."; exit 1; }
  sleep 2
done
echo "== live mode on; sending $N benchmark recalls and the demo recalls to the AI Hub agent =="
docker compose exec -T iris iris session IRIS -U USER <<EOS
do ##class(RecallReach.Core.Bench).Run($N)
do ##class(RecallReach.Core.Bench).Run(50, "featured")
halt
EOS
mkdir -p data/recordings
docker compose cp iris:/opt/recallreach/recordings/. ./data/recordings/
curl -fs "http://127.0.0.1:$PORT/recallreach/api/accuracy?refresh=1" >/dev/null || true
echo "Recorded replies copied to data/recordings/. The Accuracy page now shows the LLM next to the rule-based numbers."
echo "Commit data/recordings/ to replay these replies without a key. Back to replay mode: empty the key in .env, then docker compose up -d."
