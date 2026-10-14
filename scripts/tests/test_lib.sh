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

# require_pushed: Argo deploys origin/$GITOPS_REVISION, so HEAD must be on that branch
write_git_stub() {  # $1 = exit code of `merge-base --is-ancestor`, $2 = current branch
  cat > "$STUBS/git" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"fetch --quiet origin") exit 0;;
  *"merge-base --is-ancestor HEAD origin/main") exit $1;;
  *"rev-parse --abbrev-ref HEAD") echo $2;;
  *) exit 1;;
esac
STUB
  chmod +x "$STUBS/git"
}
write_git_stub 1 main
check "require_pushed fails when HEAD not on origin/main" "! (require_pushed) >/dev/null 2>&1"
write_git_stub 0 main
check "require_pushed passes when HEAD on origin/main" "(require_pushed) >/dev/null 2>&1"
write_git_stub 0 feat/x
check "require_on_revision_branch fails off main" "! (require_on_revision_branch) >/dev/null 2>&1"
write_git_stub 0 main
check "require_on_revision_branch passes on main" "(require_on_revision_branch) >/dev/null 2>&1"

# lb_service_count must fail (not report 0) when the cluster is unreachable
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/kubectl"; chmod +x "$STUBS/kubectl"
check "lb_service_count fails when kubectl fails" "! (lb_service_count) >/dev/null 2>&1"

# restore_root_sync re-enables automated sync that a partial 'make down' disabled
cat > "$STUBS/kubectl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$STUBS/kubectl.log"
STUB
chmod +x "$STUBS/kubectl"
check "restore_root_sync patches automated policy" \
  "restore_root_sync >/dev/null 2>&1 && grep -q 'patch application root.*automated' '$STUBS/kubectl.log'"

echo "lib tests: $pass passed, $failed failed"; [ "$failed" -eq 0 ]
