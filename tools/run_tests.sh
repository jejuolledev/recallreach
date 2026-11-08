#!/bin/sh
# Runs both test suites inside the running container.
set -e
echo "== Python unit tests (Embedded Python core) =="
docker compose exec -T iris /usr/irissys/bin/irispython -m unittest discover -s /opt/recallreach/python/tests -v
echo "== ObjectScript %UnitTest (approvals, expiry, single use, kill switch, audit) =="
docker compose exec -T iris iris session IRIS -U USER <<'EOS' | grep -E "PASSED|FAILED|Assert|LogMessage" 
do ##class(RecallReach.Tests.ApprovalTest).Run()
halt
EOS
