#!/usr/bin/env bash
# down.sh must refuse to destroy while a LoadBalancer Service exists.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
STUBS=$(mktemp -d); trap 'rm -rf "$STUBS"' EXIT
cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get svc -A"*) echo "LoadBalancer";;   # an NLB-backed Service that never goes away
  *) exit 0;;
esac
STUB
cat > "$STUBS/terraform" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *destroy* ]]; then echo "DESTROY CALLED" >&2; exit 99; fi
echo llm-inference
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/aws"
chmod +x "$STUBS"/*
out=$(PATH="$STUBS:$PATH" LB_TIMEOUT=2 "$HERE/../down.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: down.sh exited 0"; exit 1; }
[[ "$out" != *"DESTROY CALLED"* ]] || { echo "FAIL: destroy ran with LB present"; exit 1; }
[[ "$out" == *"LoadBalancer"* ]] || { echo "FAIL: no clear message: $out"; exit 1; }
echo "down guard test passed"
