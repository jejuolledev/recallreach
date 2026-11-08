#!/bin/sh
# Live accuracy run (needs ANTHROPIC_API_KEY in .env). Default 300 recalls,
# stops at RR_SPEND_CAP_USD (default $5). claude-haiku-5-5 costs about $0.0004 per recall.
N=${1:-300}
docker compose exec -T iris iris session IRIS -U USER <<EOS
do ##class(RecallReach.Core.Bench).Run($N)
halt
EOS
docker compose cp iris:/opt/recallreach/recordings/. ./data/recordings/
echo "Recorded replies copied to data/recordings/ (commit them to replay without a key)."
