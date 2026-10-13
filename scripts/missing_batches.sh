#!/usr/bin/env bash
# Report (and optionally fix up) which batches of the staged project are missing
# from the server, using MongoDB directly instead of analysis names.
#
# Why: jump_pod_reconcile.rb matches analyses by project name, but analyses are
# named "batch<N>_<type>_<timestamp>" (no project name), so it reports
# complete=0 and a resubmit would duplicate everything. This helper matches by
# batch number only.
#
# A batch counts as DONE when its analysis has >0 data points and a failure rate
# below FAIL_THRESHOLD (default 0.9). Zero-datapoint and mostly-failed analyses
# are listed as BAD (candidates for deletion) and their batches count as missing.
#
# Usage:
#   scripts/missing_batches.sh [PROJECT_NAME]          # report only (read-only)
#   scripts/missing_batches.sh [PROJECT_NAME] --apply  # move DONE batch files to
#       submitted/ and MISSING ones back into the project dir, so
#       `SKIP_COPY=1 ./scripts/submit_from_jump_pod.sh ...` submits only the missing.
#
# PROJECT_NAME defaults to the only directory under REMOTE_ROOT/outputs.
# Env: NAMESPACE, DB_POD_LABEL, MONGO_DB (os_docker), REMOTE_ROOT, FAIL_THRESHOLD,
#      JUMP_POD_LABEL

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
MONGO_DB="${MONGO_DB:-os_docker}"
REMOTE_ROOT="${REMOTE_ROOT:-/mnt/openstudio/bem-to-surrogate}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-0.9}"
JUMP_POD_LABEL="${JUMP_POD_LABEL:-jump-pod}"

PROJECT_NAME=""
APPLY=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    *) PROJECT_NAME="$a" ;;
  esac
done

DB_POD="$(kubectl get pods -n "$NAMESPACE" -o name | grep -E '/db-' | head -1 | cut -d/ -f2)"
JUMP_POD="$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running -o name | grep -E "/${JUMP_POD_LABEL}-" | head -1 | cut -d/ -f2)"
[[ -n "$DB_POD" && -n "$JUMP_POD" ]] || { echo "db pod or jump pod not found in ${NAMESPACE}" >&2; exit 1; }

if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="$(kubectl exec -n "$NAMESPACE" "$JUMP_POD" -- ls "${REMOTE_ROOT}/outputs" | head -1 | tr -d '\r')"
fi
PROJ_DIR="${REMOTE_ROOT}/outputs/${PROJECT_NAME}"
echo "=== Project ${PROJECT_NAME} (${PROJ_DIR}) ===" >&2

# Per analysis: batch number, datapoints, failures. Prints "batch n failed id".
SERVER="$(kubectl exec -n "$NAMESPACE" "$DB_POD" -- sh -c "mongosh --quiet -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --eval '
const d=db.getSiblingDB(\"${MONGO_DB}\");
const c={};
d.data_points.aggregate([{\$group:{_id:\"\$analysis_id\",n:{\$sum:1},f:{\$sum:{\$cond:[{\$eq:[\"\$status_message\",\"datapoint failure\"]},1,0]}}}}],{allowDiskUse:true}).forEach(x=>c[x._id]={n:x.n,f:x.f});
d.analyses.find({},{name:1}).forEach(a=>{const m=(a.name||\"\").match(/batch_?(\\d+)/i);if(!m)return;const s=c[a._id]||{n:0,f:0};print(m[1],s.n,s.f,a._id)})'")"

# Expected batch numbers and their files, from the pod (project dir + submitted/).
FILES="$(kubectl exec -n "$NAMESPACE" "$JUMP_POD" -- bash -c "cd '${PROJ_DIR}' && ls parametric_space*Batch*.json submitted/parametric_space*Batch*.json 2>/dev/null")"

export SERVER FILES FAIL_THRESHOLD
REPORT="$(ruby -e '
th = ENV["FAIL_THRESHOLD"].to_f
done = {}; bad = []; dup = Hash.new(0)
ENV["SERVER"].each_line do |l|
  b, n, f, id = l.split; next unless id
  b, n, f = b.to_i, n.to_i, f.to_i
  dup[b] += 1
  if n > 0 && f.to_f / n < th then done[b] = true else bad << [b, n, f, id] end
end
expected = ENV["FILES"].lines.map { |x| x[/Batch_?(\d+)/i, 1].to_i }.uniq.sort
missing = expected - done.keys
puts "expected=#{expected.size} done=#{(expected & done.keys).size} missing=#{missing.size}"
puts "MISSING=#{missing.join(",")}"
puts "DONE=#{(expected & done.keys).join(",")}"
puts "DUPLICATE_BATCHES=#{dup.select { |_, c| c > 1 }.keys.sort.join(",")}"
bad.sort.each { |b, n, f, id| puts "BAD batch=#{b} datapoints=#{n} failed=#{f} analysis=#{id}" }
')"

echo "$REPORT" | grep -vE '^(MISSING|DONE)='
if [[ "$APPLY" != "1" ]]; then
  echo "(read-only; rerun with --apply to stage only the missing batches)" >&2
  echo "$REPORT" | grep '^MISSING=' | sed 's/^MISSING=/missing batches: /'
  exit 0
fi

MISSING="$(echo "$REPORT" | sed -n 's/^MISSING=//p')"
DONE="$(echo "$REPORT" | sed -n 's/^DONE=//p')"
kubectl exec -n "$NAMESPACE" "$JUMP_POD" -- env MISSING="$MISSING" DONE="$DONE" ruby -rfileutils -e '
d = ARGV[0]; FileUtils.mkdir_p("#{d}/submitted")
miss = ENV["MISSING"].split(",").map(&:to_i); done = ENV["DONE"].split(",").map(&:to_i)
moved_out = moved_in = 0
Dir["#{d}/{parametric_space,measure_space}*Batch*.json"].each do |f|
  n = File.basename(f)[/Batch_?(\d+)/i, 1].to_i
  if done.include?(n) then FileUtils.mv(f, "#{d}/submitted/"); moved_out += 1 end
end
Dir["#{d}/submitted/{parametric_space,measure_space}*Batch*.json"].each do |f|
  n = File.basename(f)[/Batch_?(\d+)/i, 1].to_i
  if miss.include?(n) then FileUtils.mv(f, "#{d}/"); moved_in += 1 end
end
puts "staged: #{moved_out} file(s) -> submitted/, #{moved_in} file(s) restored; to submit: #{Dir["#{d}/parametric_space*Batch*.json"].size}"
' "$PROJ_DIR"
