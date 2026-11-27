#!/bin/sh
set -eu

HARNESS_NS="${HARNESS_NS:-logs-bench-harness}"
PARSEABLE_NS="${PARSEABLE_NS:-logs-bench-parseable}"
LOKI_NS="${LOKI_NS:-logs-bench-loki}"
VL_NS="${VL_NS:-logs-bench-victorialogs}"
STATE_NS="${STATE_NS:-logs-bench-monitoring}"
STATE_CONFIGMAP="${STATE_CONFIGMAP:-benchmark-nine-run-state}"

RUN_SECONDS="${RUN_SECONDS:-11400}"
BASELINE_SECONDS="${BASELINE_SECONDS:-600}"
SETTLE_SECONDS="${SETTLE_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-15}"

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

patch_state() {
  key="$1"
  value="$2"
  kubectl -n "$STATE_NS" patch configmap "$STATE_CONFIGMAP" --type merge \
    -p "{\"data\":{\"$key\":\"$value\"}}" >/dev/null
}

scale_load_zero() {
  kubectl -n "$HARNESS_NS" scale deployment/writer deployment/querier \
    --replicas=0 >/dev/null
}

scale_engines_zero() {
  kubectl -n "$PARSEABLE_NS" scale statefulset/parseable-standalone \
    --replicas=0 >/dev/null
  kubectl -n "$LOKI_NS" scale statefulset/loki --replicas=0 >/dev/null
  kubectl -n "$VL_NS" scale \
    statefulset/victorialogs-victoria-logs-single-server --replicas=0 >/dev/null
}

fail_sequence() {
  reason="$*"
  log "SEQUENCE FAILED: $reason"
  patch_state status "failed: $reason" || true
  scale_load_zero >/dev/null 2>&1 || true
  exit 1
}

interrupt_sequence() {
  log "sequence interrupted; stopping load and retaining engine data for diagnosis"
  patch_state status "interrupted" || true
  scale_load_zero >/dev/null 2>&1 || true
  exit 130
}

trap interrupt_sequence INT TERM

require_resource() {
  namespace="$1"
  resource="$2"
  kubectl -n "$namespace" get "$resource" >/dev/null 2>&1 ||
    fail_sequence "missing $namespace/$resource"
}

preflight() {
  command -v kubectl >/dev/null 2>&1 ||
    fail_sequence "kubectl is not installed in the controller image"
  command -v jq >/dev/null 2>&1 ||
    fail_sequence "jq is not installed in the controller image"

  require_resource "$HARNESS_NS" deployment/writer
  require_resource "$HARNESS_NS" deployment/querier
  require_resource "$PARSEABLE_NS" statefulset/parseable-standalone
  require_resource "$LOKI_NS" statefulset/loki
  require_resource "$VL_NS" statefulset/victorialogs-victoria-logs-single-server
}

wait_pods_gone() {
  namespace="$1"
  selector="$2"
  attempts=0
  while [ "$attempts" -lt 160 ]; do
    count="$(kubectl -n "$namespace" get pod -l "$selector" -o name 2>/dev/null |
      wc -l | tr -d ' ')"
    [ "$count" = 0 ] && return 0
    attempts=$((attempts + 1))
    sleep "$POLL_SECONDS"
  done
  return 1
}

wait_pvc_gone() {
  namespace="$1"
  name="$2"
  attempts=0
  while [ "$attempts" -lt 80 ]; do
    kubectl -n "$namespace" get pvc "$name" >/dev/null 2>&1 || return 0
    attempts=$((attempts + 1))
    sleep "$POLL_SECONDS"
  done
  return 1
}

pod_ready() {
  namespace="$1"
  selector="$2"
  kubectl -n "$namespace" get pod -l "$selector" \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || true
}

configure_writer() {
  profile="$1"
  case "$profile" in
    5k) hosts=125 ;;
    10k) hosts=250 ;;
    15k) hosts=375 ;;
    *) fail_sequence "unknown profile: $profile" ;;
  esac

  args="$(kubectl -n "$HARNESS_NS" get deployment/writer -o json |
    jq -c --arg hosts "$hosts" '
      .spec.template.spec.containers[]
      | select(.name == "writer")
      | .args
      | map(if startswith("-hosts=") then "-hosts=" + $hosts else . end)
    ')"
  [ -n "$args" ] && [ "$args" != "null" ] ||
    fail_sequence "writer container or args not found"

  patch="$(jq -nc --argjson args "$args" '
    {spec: {template: {spec: {containers: [{name: "writer", args: $args}]}}}}
  ')"
  kubectl -n "$HARNESS_NS" patch deployment/writer --type strategic \
    -p "$patch" >/dev/null

  configured="$(kubectl -n "$HARNESS_NS" get deployment/writer -o json |
    jq -r '.spec.template.spec.containers[]
      | select(.name == "writer")
      | .args[]
      | select(startswith("-hosts="))')"
  [ "$configured" = "-hosts=$hosts" ] ||
    fail_sequence "$profile writer cardinality patch did not stick"
  log "$profile writer configured: $hosts hosts x 40 apps"
}

fresh_engines() {
  profile="$1"
  attempt="$2"

  log "$profile attempt $attempt: stopping load and engines"
  patch_state status "$profile attempt $attempt: cleaning disks"
  scale_load_zero
  scale_engines_zero

  wait_pods_gone "$HARNESS_NS" 'app=bench' ||
    fail_sequence "$profile attempt $attempt load pods did not stop"
  wait_pods_gone "$PARSEABLE_NS" 'app.kubernetes.io/name=parseable' ||
    fail_sequence "$profile attempt $attempt Parseable did not stop"
  wait_pods_gone "$LOKI_NS" 'app.kubernetes.io/name=loki' ||
    fail_sequence "$profile attempt $attempt Loki did not stop"
  wait_pods_gone "$VL_NS" 'app.kubernetes.io/instance=victorialogs' ||
    fail_sequence "$profile attempt $attempt VictoriaLogs did not stop"

  log "$profile attempt $attempt: deleting all engine PVCs"
  kubectl -n "$PARSEABLE_NS" delete pvc \
    stage-volume-parseable-standalone-0 \
    data-volume-parseable-standalone-0 \
    --ignore-not-found=true --wait=false >/dev/null
  kubectl -n "$LOKI_NS" delete pvc storage-loki-0 \
    --ignore-not-found=true --wait=false >/dev/null
  kubectl -n "$VL_NS" delete pvc \
    server-volume-victorialogs-victoria-logs-single-server-0 \
    --ignore-not-found=true --wait=false >/dev/null

  wait_pvc_gone "$PARSEABLE_NS" stage-volume-parseable-standalone-0 ||
    fail_sequence "$profile attempt $attempt Parseable staging PVC deletion timed out"
  wait_pvc_gone "$PARSEABLE_NS" data-volume-parseable-standalone-0 ||
    fail_sequence "$profile attempt $attempt Parseable data PVC deletion timed out"
  wait_pvc_gone "$LOKI_NS" storage-loki-0 ||
    fail_sequence "$profile attempt $attempt Loki PVC deletion timed out"
  wait_pvc_gone "$VL_NS" \
    server-volume-victorialogs-victoria-logs-single-server-0 ||
    fail_sequence "$profile attempt $attempt VictoriaLogs PVC deletion timed out"

  log "$profile attempt $attempt: starting engines with new PVCs"
  kubectl -n "$PARSEABLE_NS" scale statefulset/parseable-standalone \
    --replicas=1 >/dev/null
  kubectl -n "$LOKI_NS" scale statefulset/loki --replicas=1 >/dev/null
  kubectl -n "$VL_NS" scale \
    statefulset/victorialogs-victoria-logs-single-server --replicas=1 >/dev/null

  attempts=0
  ready=0
  while [ "$attempts" -lt 120 ]; do
    ready=0
    [ "$(pod_ready "$PARSEABLE_NS" 'app.kubernetes.io/name=parseable')" = True ] &&
      ready=$((ready + 1))
    [ "$(pod_ready "$LOKI_NS" 'app.kubernetes.io/name=loki')" = True ] &&
      ready=$((ready + 1))
    [ "$(pod_ready "$VL_NS" 'app.kubernetes.io/instance=victorialogs')" = True ] &&
      ready=$((ready + 1))
    [ "$ready" -eq 3 ] && break
    attempts=$((attempts + 1))
    sleep "$POLL_SECONDS"
  done
  [ "$ready" -eq 3 ] ||
    fail_sequence "$profile attempt $attempt engines did not become ready"

  log "$profile attempt $attempt: engines ready; waiting ${BASELINE_SECONDS}s for idle baseline"
  patch_state status "$profile attempt $attempt: idle baseline"
  sleep "$BASELINE_SECONDS"
}

writer_pod() {
  kubectl -n "$HARNESS_NS" get pod -l 'role=writer' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

wait_writer_ready() {
  attempts=0
  while [ "$attempts" -lt 80 ]; do
    pod="$(writer_pod)"
    if [ -n "$pod" ]; then
      ready="$(kubectl -n "$HARNESS_NS" get pod "$pod" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || true)"
      [ "$ready" = True ] && return 0
    fi
    attempts=$((attempts + 1))
    sleep "$POLL_SECONDS"
  done
  return 1
}

run_attempt() {
  profile="$1"
  attempt="$2"
  prefix="${profile}_attempt_${attempt}"

  configure_writer "$profile"
  fresh_engines "$profile" "$attempt"

  log "$profile attempt $attempt: starting querier and writer"
  patch_state current_run "$profile attempt $attempt"
  kubectl -n "$HARNESS_NS" scale deployment/querier --replicas=1 >/dev/null
  kubectl -n "$HARNESS_NS" scale deployment/writer --replicas=1 >/dev/null
  wait_writer_ready ||
    fail_sequence "$profile attempt $attempt writer did not become ready"

  start_epoch="$(date +%s)"
  expected_end=$((start_epoch + RUN_SECONDS))
  patch_state "${prefix}_start_epoch" "$start_epoch"
  patch_state status "$profile attempt $attempt: running"
  log "$profile attempt $attempt: 150k/s to 510k/s; expected end epoch=$expected_end"

  last_stage=-1
  while :; do
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    stage=$((elapsed / 600))
    [ "$stage" -gt 18 ] && stage=18
    if [ "$stage" -gt "$last_stage" ]; then
      last_stage="$stage"
      target=$((150000 + stage * 20000))
      log "$profile attempt $attempt: stage=$stage target=$target"
    fi

    pod="$(writer_pod)"
    [ -n "$pod" ] ||
      fail_sequence "$profile attempt $attempt writer disappeared"

    restarts="$(kubectl -n "$HARNESS_NS" get pod "$pod" \
      -o jsonpath='{.status.containerStatuses[0].restartCount}' \
      2>/dev/null || echo 0)"
    if [ "$restarts" -gt 0 ]; then
      exit_code="$(kubectl -n "$HARNESS_NS" get pod "$pod" \
        -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' \
        2>/dev/null || true)"
      fail_sequence "$profile attempt $attempt writer restarted (exit=${exit_code:-unknown})"
    fi

    [ "$now" -ge "$expected_end" ] && break
    sleep "$POLL_SECONDS"
  done

  kubectl -n "$HARNESS_NS" scale deployment/writer --replicas=0 >/dev/null
  end_epoch="$(date +%s)"
  patch_state "${prefix}_end_epoch" "$end_epoch"
  patch_state "${prefix}_outcome" complete
  patch_state status "$profile attempt $attempt: settling metrics"
  log "$profile attempt $attempt: complete; retaining ${SETTLE_SECONDS}s of settled metrics"
  sleep "$SETTLE_SECONDS"
}

kubectl -n "$STATE_NS" delete configmap "$STATE_CONFIGMAP" \
  --ignore-not-found >/dev/null
kubectl -n "$STATE_NS" create configmap "$STATE_CONFIGMAP" \
  --from-literal=status=initializing >/dev/null

preflight
patch_state sequence_id "$(date -u '+%Y%m%dT%H%M%SZ')"
patch_state sequence_start_epoch "$(date +%s)"
patch_state planned_runs '5k-1,5k-2,5k-3,10k-1,10k-2,10k-3,15k-1,15k-2,15k-3'
patch_state completed_runs '0/9'
patch_state status 'starting fresh nine-run sequence'

completed=0
for profile in 5k 10k 15k; do
  for attempt in 1 2 3; do
    run_attempt "$profile" "$attempt"
    completed=$((completed + 1))
    patch_state completed_runs "$completed/9"
  done
done

log "all nine attempts complete; scaling down load and engines"
scale_load_zero
scale_engines_zero
patch_state sequence_end_epoch "$(date +%s)"
patch_state current_run none
patch_state status 'complete; 9/9 attempts finished; engines scaled down; monitoring running'
log "sequence complete"

