#!/usr/bin/env bash
# OPTIONAL live spot check: deploy ONE team's submission into YOUR AWS Academy
# session, inject a failure (re-applies with failure_rate=1), confirm an alarm
# reaches ALARM, then roll back and destroy. Costs a few cents; ~10-15 minutes.
#
# Usage: autograder/spot-check.sh <path-to-cloned-submission> [minutes_to_wait=6]
# Requires: valid Academy credentials (aws sts get-caller-identity), terraform, aws CLI.
# WEEK 1 ONLY as written: it needs a `failure_rate` variable and `api_url` / `alarm_names`
# outputs. For other weeks, deploy by hand and use that lab's scripts/chaos.sh.
#
# SECURITY: this runs the team's Terraform with YOUR credentials, including any
# provisioner "local-exec", "external" data source or third-party provider. Read the
# team's .tf files first; the script lists anything that runs local code and asks you
# to confirm. Run it in a Learner Lab session, never with a real AWS account's keys.
set -euo pipefail
SRC="$(cd "${1:?path to submission}" && pwd)"; WAIT_MIN="${2:-6}"
# Work on a copy, with a local backend forced, so a backend block in the submission
# can't send state (or your credentials' results) somewhere else.
SUB="$(mktemp -d "${TMPDIR:-/tmp}/spot-check.XXXXXX")"
rsync -a --exclude .terraform --exclude '*.tfstate*' --exclude .git "$SRC/" "$SUB/"
cat > "$SUB/terraform/zz_spotcheck_override.tf" <<'EOF'
terraform {
  backend "local" {}
}
EOF
tf(){ terraform -chdir="$SUB/terraform" "$@"; }

risky=$(grep -rnE 'local-exec|"external"|provisioner|source *= *"(git::|github\.com|https?://)' "$SUB/terraform" --include='*.tf' \
        | grep -v zz_spotcheck_override.tf || true)
if [ -n "$risky" ]; then
  echo "This submission runs local code or pulls remote modules:"; echo "$risky"
fi
grep -rhoE 'source *= *"[^"]+"' "$SUB/terraform" --include='*.tf' | sort -u | sed 's/^/  provider\/module /'
read -r -p "Reviewed the team's .tf files and want to deploy them with your credentials? (yes/no) " ok
[ "$ok" = yes ] || { echo "Stopped."; rm -rf "$SUB"; exit 1; }

aws sts get-caller-identity >/dev/null || { echo "No AWS credentials - start the Learner Lab first."; exit 1; }
TEAM="spot$(date +%H%M)"
cleanup(){
  echo "== destroying"
  if tf destroy -auto-approve -input=false -var="team_name=$TEAM" >/dev/null; then
    rm -rf "$SUB"
  else
    echo "!! destroy failed - state is in $SUB/terraform; run terraform destroy there, or clean up in the console"
  fi
}
trap cleanup EXIT
echo "== deploying $SRC as team_name=$TEAM (copy in $SUB)"
tf init -input=false -reconfigure >/dev/null
tf apply -auto-approve -input=false -var="team_name=$TEAM" >/dev/null
URL=$(tf output -raw api_url 2>/dev/null || true)
NAMES=$(tf output -json alarm_names | python3 -c "import json,sys;print(' '.join(json.load(sys.stdin)))")
[ -n "$URL" ] && curl -fsS "${URL}?account_id=1001" >/dev/null && echo "healthy request OK"
echo "== injecting failure"
tf apply -auto-approve -input=false -var="team_name=$TEAM" -var="failure_rate=1" >/dev/null
deadline=$(( $(date +%s) + WAIT_MIN*60 )); fired=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ -n "$URL" ] && for _ in 1 2 3 4 5; do curl -s -o /dev/null "${URL}?account_id=1001"; done
  # shellcheck disable=SC2086  # NAMES is a space-separated list of alarm names
  states=$(aws cloudwatch describe-alarms --alarm-names $NAMES --query 'MetricAlarms[].StateValue' --output text)
  echo "$(date +%H:%M:%S) $states"
  case "$states" in *ALARM*) fired=yes; break;; esac
  sleep 15
done
[ -n "$fired" ] && echo "RESULT: PASS - alarm fired" || echo "RESULT: FAIL - no alarm within ${WAIT_MIN} min"
