#!/usr/bin/env bash
# down.sh must refuse to destroy when it cannot reach the cluster (it couldn't see the NLB).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
STUBS=$(mktemp -d); trap 'rm -rf "$STUBS"' EXIT
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/kubectl"      # API unreachable
cat > "$STUBS/terraform" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *destroy*) echo "DESTROY CALLED" >&2; exit 99;;
  *configure_kubectl*) echo ":";;
  *state_bucket*) echo test-bucket;;
  *) echo llm-inference;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/aws"
chmod +x "$STUBS"/*
out=$(PATH="$STUBS:$PATH" LB_TIMEOUT=2 "$HERE/../down.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: down.sh exited 0"; exit 1; }
[[ "$out" != *"DESTROY CALLED"* ]] || { echo "FAIL: destroy ran without cluster access"; exit 1; }
[[ "$out" == *"cannot reach"* ]] || { echo "FAIL: no clear message: $out"; exit 1; }
echo "down unreachable test passed"
