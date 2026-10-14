#!/usr/bin/env bash
# Unit tests for scripts/lib.sh using stub commands on PATH.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib.sh
source "$HERE/../lib.sh"
STUBS=$(mktemp -d); trap 'rm -rf "$STUBS"' EXIT
export PATH="$STUBS:$PATH"
pass=0; failed=0
check() { if eval "$2"; then pass=$((pass+1)); else echo "FAIL: $1"; failed=$((failed+1)); fi; }

# poll: succeeds when the command eventually passes, fails on timeout
n_file=$(mktemp); echo 0 > "$n_file"
flaky() { local n; n=$(<"$n_file"); echo $((n+1)) > "$n_file"; [ "$n" -ge 2 ]; }
check "poll succeeds after retries" "poll 5 0 'flaky' flaky >/dev/null 2>&1"
check "poll times out" "! poll 1 0 'never' false >/dev/null 2>&1"

# router_strategy parses the router container args
cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
echo '--host 0.0.0.0 --routing-logic prefixaware --session-key x-session-id'
STUB
chmod +x "$STUBS/kubectl"
# shellcheck disable=SC2016  # single quotes intended: check() evals the string
check "router_strategy extracts value" '[ "$(router_strategy)" = prefixaware ]'

# require_pushed: fails when HEAD is not on any remote branch
cat > "$STUBS/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"fetch --quiet origin") exit 0;;
  *"rev-parse HEAD") echo aaa;;
  *"branch -r --contains aaa") echo "";;
esac
STUB
chmod +x "$STUBS/git"
check "require_pushed fails on unpushed HEAD" "! (require_pushed) >/dev/null 2>&1"

echo "lib tests: $pass passed, $failed failed"; [ "$failed" -eq 0 ]
