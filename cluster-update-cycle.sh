#!/bin/bash
# Rolling update/reboot cycle for a Proxmox VE cluster of any size.
#
# Runs on ONE cluster node (from cron). Upgrades packages on every node, then reboots
# the nodes that need it one at a time: HA maintenance mode evacuates the node, the
# guests listed as critical are confirmed healthy elsewhere, the node reboots and
# rejoins, and HA is left to settle before the next node. The node running the script
# goes last and resumes after its own reboot via an @reboot cron entry.
#
# Site settings live in /etc/cluster-update-cycle.conf; see the example file.

set -uo pipefail

CONF_FILE="${CLUSTER_UPDATE_CYCLE_CONF:-/etc/cluster-update-cycle.conf}"

# Defaults, overridable from the config file.
WEBHOOK_URL=""            # JSON POST target for notifications; empty disables them
CRITICAL_SIDS=()          # e.g. (vm:104): must be healthy on another node before a reboot
CRITICAL_AGENT_PING=1     # also require the QEMU guest agent to answer (VMs only)
PARK_SIDS=()              # HA guests kept shut down for the whole cycle to free memory
NODES=()                  # nodes to manage; empty means every cluster member
EVACUATE_TIMEOUT=900
REBOOT_TIMEOUT=900
HEALTH_TIMEOUT=300
SETTLE_TIMEOUT=900

# shellcheck source=/dev/null
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

STATE_DIR="/var/lib/cluster-update-cycle"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
LOG_FILE="/var/log/cluster-update-cycle.log"
OWNER_FILE="/etc/pve/priv/cluster-update-cycle.owner"
MEMBERS="/etc/pve/.members"
HA_MANAGER_STATUS="/etc/pve/ha/manager_status"
HA_RESOURCES="/etc/pve/ha/resources.cfg"

STATE_VARS="PHASE CYCLE_ID PENDING DONE CURRENT PARKED"

SELF_NODE=$(jq -r '.nodename // empty' "$MEMBERS" 2>/dev/null)
[ -n "$SELF_NODE" ] || SELF_NODE=$(hostname -s)

log() { echo "$(date '+%F %T') $*"; }

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

save_state() {
  local v
  : > "$STATE_FILE.tmp"
  for v in $STATE_VARS; do printf '%s=%q\n' "$v" "${!v}" >> "$STATE_FILE.tmp"; done
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
load_state() {
  PHASE=""; CYCLE_ID=""; PENDING=""; DONE=""; CURRENT=""; PARKED=0
  # shellcheck source=/dev/null
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"
  return 0
}

# ---------- cluster membership / remote execution ----------

cluster_nodes() {
  if [ "${#NODES[@]}" -gt 0 ]; then printf '%s\n' "${NODES[@]}"; else jq -r '.nodelist | keys[]' "$MEMBERS"; fi
}
node_ip() { jq -r --arg n "$1" '.nodelist[$n].ip // empty' "$MEMBERS"; }
node_online() { [ "$(jq -r --arg n "$1" '.nodelist[$n].online // 0' "$MEMBERS")" = 1 ]; }

# run_on <node> <shell-command-string>
# Peers are reached the way PVE itself does it: by address from the member list, with
# the host key the cluster keeps for that node.
run_on() {
  local node="$1" cmd="$2" ip
  if [ "$node" = "$SELF_NODE" ]; then
    bash -c "$cmd" </dev/null
    return
  fi
  ip=$(node_ip "$node")
  [ -n "$ip" ] || { log "ERROR: no address known for node $node"; return 255; }
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
    -o HostKeyAlias="$node" -o UserKnownHostsFile="/etc/pve/nodes/$node/ssh_known_hosts" \
    -o GlobalKnownHostsFile=none "root@$ip" "$cmd"
}

# Exit 0 = reboot needed, 1 = not needed. Uses needrestart where installed (KSTA 2/3 =
# pending kernel, UCSTA 2 = obsolete microcode); otherwise compares the running kernel
# with the newest one installed.
NEEDS_REBOOT_CMD='
[ -f /var/run/reboot-required ] && exit 0
if command -v needrestart >/dev/null 2>&1; then
  needrestart -b 2>/dev/null | awk -F": " "/^NEEDRESTART-KSTA:/ && \$2 >= 2 { r=1 } /^NEEDRESTART-UCSTA:/ && \$2 == 2 { r=1 } END { exit !r }"
  exit $?
fi
newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed "s|.*/vmlinuz-||" | sort -V | tail -n1)
[ -n "$newest" ] && [ "$newest" != "$(uname -r)" ]
'
node_needs_reboot() { run_on "$1" "$NEEDS_REBOOT_CMD"; }

APT_CMD='
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq &&
apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade &&
apt-get -y -qq autoremove
'
apt_update_node() { run_on "$1" "$APT_CMD"; }

node_boot_id() { run_on "$1" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null; }

is_quorate() { pvecm status 2>/dev/null | grep -q "^Quorate:.*Yes"; }

# Safe to take one node down: every node is up, all expected votes are present, and the
# cluster stays quorate with one vote fewer. Sets REASON on failure.
REASON=""
quorum_allows_reboot() {
  local st expected total quorum n
  st=$(pvecm status 2>/dev/null) || { REASON="pvecm status failed"; return 1; }
  expected=$(awk '/^Expected votes:/ { print $3 }' <<<"$st")
  total=$(awk '/^Total votes:/ { print $3 }' <<<"$st")
  quorum=$(awk '/^Quorum:/ { print $2 }' <<<"$st")
  for n in $(cluster_nodes); do
    node_online "$n" || { REASON="node $n is offline"; return 1; }
  done
  if [ "${total:-0}" -lt "${expected:-1}" ]; then
    REASON="only ${total:-0}/${expected:-?} votes present"; return 1
  fi
  if [ $(( ${total:-0} - 1 )) -lt "${quorum:-99}" ]; then
    REASON="losing one node would break quorum (votes=${total:-0}, quorum=${quorum:-?})"; return 1
  fi
  return 0
}

# ---------- HA manager ----------

# The CRM's own view (pmxcfs). It rejects, rather than queues, requests that involve a
# node it does not consider online, so waits are keyed on this and not on ssh/ping.
ha_in_use() { [ -s "$HA_RESOURCES" ] && grep -q '^[a-z]\+:' "$HA_RESOURCES"; }
ha_node_state() { jq -r --arg n "$1" '.node_status[$n] // empty' "$HA_MANAGER_STATUS" 2>/dev/null; }
ha_service_field() { jq -r --arg s "$1" --arg f "$2" '.service_status[$s][$f] // empty' "$HA_MANAGER_STATUS" 2>/dev/null; }
ha_maintenance() { ha-manager crm-command node-maintenance "$2" "$1"; }

# HA services the CRM still places on <node>, ignoring ones that are not running anyway.
ha_services_on() {
  jq -r --arg n "$1" '.service_status | to_entries[]
    | select(.value.node == $n)
    | select(.value.state | IN("stopped","disabled") | not) | .key' "$HA_MANAGER_STATUS" 2>/dev/null
}
ha_services_in_transition() {
  jq -r '.service_status | to_entries[]
    | select(.value.state | IN("started","stopped","disabled") | not)
    | "\(.key)=\(.value.state)"' "$HA_MANAGER_STATUS" 2>/dev/null
}

wait_for_ha_node_state() {
  local node="$1" want="$2" timeout="${3:-300}" waited=0
  while [ "$(ha_node_state "$node")" != "$want" ]; do
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge "$timeout" ] && { log "ERROR: HA manager reports $node as '$(ha_node_state "$node")', expected '$want', after ${timeout}s"; return 1; }
  done
  return 0
}

# All nodes online for HA and nothing migrating, relocating, frozen or in error. Guests
# evacuated for a reboot are moved back once the node returns; the next step must not
# start while that is still in flight.
wait_for_ha_settled() {
  local waited=0 busy n
  ha_in_use || return 0
  for n in $(cluster_nodes); do wait_for_ha_node_state "$n" online || return 1; done
  sleep 30
  while true; do
    # A failed read of the HA status must not look like "nothing in transition".
    busy=$(ha_services_in_transition) || busy="(HA status unreadable)"
    busy=${busy//$'\n'/ }
    [ -z "$busy" ] && return 0
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge "$SETTLE_TIMEOUT" ] && { log "ERROR: HA services still in transition after ${SETTLE_TIMEOUT}s: $busy"; return 1; }
  done
}

evacuate_node() {
  local node="$1" waited=0 left
  ha_in_use || return 0
  log "Enabling HA maintenance on $node"
  ha_maintenance "$node" enable || return 1
  wait_for_ha_node_state "$node" maintenance 180 || return 1
  while true; do
    # A failed read of the HA status must not look like an empty node.
    left=$(ha_services_on "$node") || left="(HA status unreadable)"
    left=${left//$'\n'/ }
    [ -z "$left" ] && { log "$node holds no active HA services"; return 0; }
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge "$EVACUATE_TIMEOUT" ] && { log "ERROR: HA services still on $node after ${EVACUATE_TIMEOUT}s: $left"; REASON="still on $node: $left"; return 1; }
  done
}

# ---------- guests ----------

cluster_resources_json() { pvesh get /cluster/resources --type vm --output-format json 2>/dev/null; }
sid_vmid() { echo "${1#*:}"; }
guest_field() {
  cluster_resources_json | jq -r --arg id "$(sid_vmid "$1")" --arg f "$2" '.[] | select((.vmid|tostring) == $id) | .[$f] // empty'
}

# check_guest_healthy <sid> [node-it-must-not-be-on]
check_guest_healthy() {
  local sid="$1" avoid="${2:-}" vmid waited=0 node status
  vmid=$(sid_vmid "$sid")
  while true; do
    node=$(guest_field "$sid" node); status=$(guest_field "$sid" status)
    if [ "$status" = running ] && [ -n "$node" ] && [ "$node" != "$avoid" ]; then
      if [ "${sid%%:*}" != vm ] || [ "$CRITICAL_AGENT_PING" != 1 ] || run_on "$node" "qm agent $vmid ping" 2>/dev/null; then
        log "$sid healthy on $node"
        return 0
      fi
    fi
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge "$HEALTH_TIMEOUT" ] && { log "ERROR: $sid not healthy (node=${node:-?} status=${status:-?})"; REASON="$sid node=${node:-?} status=${status:-?}"; return 1; }
  done
}
check_critical() {
  local sid
  for sid in "${CRITICAL_SIDS[@]}"; do check_guest_healthy "$sid" "${1:-}" || return 1; done
  return 0
}

park_guests() {
  local sid waited
  for sid in "${PARK_SIDS[@]}"; do
    log "Parking $sid (HA state -> stopped) for the duration of the cycle"
    ha-manager set "$sid" --state stopped || return 1
    waited=0
    while [ "$(guest_field "$sid" status)" != stopped ]; do
      sleep 5; waited=$((waited+5))
      [ "$waited" -ge 300 ] && { log "ERROR: $sid did not stop within 300s"; return 1; }
    done
  done
}
unpark_guests() {
  local sid
  for sid in "${PARK_SIDS[@]}"; do
    log "Unparking $sid (HA state -> started)"
    ha-manager set "$sid" --state started || log "WARN: could not set $sid back to started"
  done
}

# ---------- notifications / end states ----------

notify() {
  local status="$1" message="$2" payload
  [ -n "$WEBHOOK_URL" ] || return 0
  [ "$status" = failure ] && [ "${PARKED:-0}" = 1 ] && message="$message Parked guests left stopped: ${PARK_SIDS[*]}."
  payload=$(jq -n --arg status "$status" --arg message "$message" \
    --arg cycle "${CYCLE_ID:-none}" --arg node "$SELF_NODE" --arg time "$(date -Is)" \
    '{status:$status, message:$message, cycle_id:$cycle, node:$node, time:$time}')
  curl -fsS -m 15 -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 \
    || log "WARN: webhook notification failed to send (status=$status)"
}

release_owner() { rm -f "$OWNER_FILE" 2>/dev/null; }

fail() {
  log "FAILED: $*"
  notify failure "$*"
  PHASE=failed; save_state
  release_owner
  exit 1
}

# Give up on <node> before it was rebooted: let its guests come back, then fail.
abort_node() {
  local node="$1"; shift
  ha_in_use && { ha_maintenance "$node" disable || log "WARN: could not disable HA maintenance on $node"; }
  fail "$*"
}

finish() {
  local q=BAD crit="" sid ok=1 summary
  is_quorate && q=OK
  [ "$q" = OK ] || ok=0
  if ! wait_for_ha_settled; then ok=0; fi
  if [ "${PARKED:-0}" = 1 ]; then
    if [ "$ok" = 1 ]; then unpark_guests; PARKED=0; else log "WARN: leaving ${PARK_SIDS[*]} stopped"; fi
  fi
  for sid in "${CRITICAL_SIDS[@]}"; do
    crit="$crit $sid=$(guest_field "$sid" status)@$(guest_field "$sid" node)"
    [ "$(guest_field "$sid" status)" = running ] || ok=0
  done
  summary="cycle=$CYCLE_ID quorum=$q rebooted=[${DONE# }]${crit:+ critical:$crit}"
  log "FINISH: $summary"
  PHASE=done; CURRENT=""; save_state
  release_owner
  if [ "$ok" = 1 ]; then
    notify success "Cluster update cycle complete. $summary"
  else
    notify failure "Cluster update cycle finished with problems. $summary"
  fi
}

# ---------- the cycle ----------

# Bring <node> back into service after its reboot.
rejoin_node() {
  local node="$1" waited=0
  until node_online "$node" && is_quorate; do
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge 300 ] && fail "$node rebooted but the cluster did not become quorate with it again. Cycle halted for manual review."
  done
  if ha_in_use; then
    ha_maintenance "$node" disable || fail "Could not disable HA maintenance on $node after its reboot."
  fi
  wait_for_ha_settled || fail "HA did not settle after $node rejoined. Cycle halted; remaining nodes not rebooted."
  check_critical || fail "Critical guest unhealthy after $node rejoined ($REASON). Cycle halted; remaining nodes not rebooted."
  node_needs_reboot "$node" && log "WARN: $node still reports a pending reboot after rebooting"
  DONE="$DONE $node"; CURRENT=""; PHASE="node_done"; save_state
  log "$node rebooted and back in service"
}

reboot_peer() {
  local node="$1" before now waited=0
  before=$(node_boot_id "$node")
  [ -n "$before" ] || abort_node "$node" "Could not reach $node just before its reboot. Cycle aborted."
  log "Rebooting $node"
  run_on "$node" "nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" || true
  sleep 20
  while true; do
    now=$(node_boot_id "$node")
    [ -n "$now" ] && [ "$now" != "$before" ] && break
    sleep 10; waited=$((waited+10))
    [ "$waited" -ge "$REBOOT_TIMEOUT" ] && fail "$node did not come back from its reboot within ${REBOOT_TIMEOUT}s. Cycle halted; remaining nodes not rebooted."
  done
  rejoin_node "$node"
}

advance() {
  local node
  if [ "$PARKED" = 0 ] && [ "${#PARK_SIDS[@]}" -gt 0 ]; then
    if ! park_guests; then
      unpark_guests
      fail "Could not shut down ${PARK_SIDS[*]} before the cycle. Nothing rebooted."
    fi
    PARKED=1; save_state
  fi

  for node in $PENDING; do
    in_list "$node" "$DONE" && continue
    quorum_allows_reboot || fail "Not safe to reboot $node: $REASON. Cycle halted."
    CURRENT="$node"; PHASE="evacuating"; save_state
    evacuate_node "$node" || abort_node "$node" "Could not evacuate $node (${REASON:-HA maintenance failed}); it was NOT rebooted."
    check_critical "$node" || abort_node "$node" "Critical guest not healthy away from $node ($REASON); $node was NOT rebooted."

    if [ "$node" = "$SELF_NODE" ]; then
      log "Rebooting self ($SELF_NODE); will resume via @reboot"
      PHASE="rebooting_self"; save_state
      notify info "Rebooting $SELF_NODE (the node running the update cycle); it will resume afterwards."
      sync; reboot
      exit 0
    fi
    reboot_peer "$node"
  done

  finish
}

take_lock() {
  mkdir -p "$STATE_DIR"
  exec 200>"$LOCK_FILE"
  flock -n 200
}

cmd_start() {
  local n owner
  take_lock || { log "Another cycle is already running here; exiting"; exit 0; }
  load_state
  if [ -n "$PHASE" ] && [ "$PHASE" != done ] && [ "$PHASE" != failed ]; then
    if [ "$PHASE" = rebooting_self ] && [ -n "$(find "$STATE_FILE" -mmin -360 2>/dev/null)" ]; then
      log "Cycle $CYCLE_ID is waiting for its post-reboot resume; not starting a new one"
      exit 0
    fi
    log "Previous cycle ($CYCLE_ID) was interrupted at phase=$PHASE node=${CURRENT:-none}; starting over"
    [ -n "$CURRENT" ] && ha_in_use && ha_maintenance "$CURRENT" disable
  fi

  # Only one node may drive a cycle, even if the cron entry ends up on several.
  if [ -f "$OWNER_FILE" ] && [ -n "$(find "$OWNER_FILE" -mmin -720 2>/dev/null)" ]; then
    owner=$(cut -d' ' -f1 "$OWNER_FILE")
    [ "$owner" != "$SELF_NODE" ] && { log "Node $owner is running a cycle; exiting"; exit 0; }
  fi

  CYCLE_ID=$(date +%Y%m%d-%H%M%S)
  # PARKED is carried over: guests a failed cycle left stopped are restarted by this one.
  PHASE="updating"; PENDING=""; DONE=""; CURRENT=""
  save_state
  log "=== Starting update cycle $CYCLE_ID on $SELF_NODE; nodes: $(cluster_nodes | tr '\n' ' ')==="

  quorum_allows_reboot || fail "Pre-flight failed: $REASON. Nothing updated or rebooted."
  echo "$SELF_NODE $CYCLE_ID" > "$OWNER_FILE" || fail "Pre-flight failed: cannot write to /etc/pve. Nothing updated or rebooted."

  for n in $(cluster_nodes); do
    log "Upgrading packages on $n"
    apt_update_node "$n" || fail "Package upgrade failed on $n. Cycle aborted, nothing rebooted."
  done
  # Upgrading the HA packages restarts the HA daemons and briefly freezes services.
  wait_for_ha_settled || fail "HA did not settle after package upgrades. Nothing rebooted."

  # Peers first, self last, so the resume-after-self-reboot path runs at most once.
  for n in $(cluster_nodes | grep -vx "$SELF_NODE") $(cluster_nodes | grep -x "$SELF_NODE"); do
    node_needs_reboot "$n"
    case $? in
      0) PENDING="$PENDING $n" ;;
      1) ;;
      *) fail "Could not determine whether $n needs a reboot. Nothing rebooted." ;;
    esac
  done
  PENDING="${PENDING# }"; PHASE="planned"; save_state
  log "Nodes needing a reboot: ${PENDING:-none}"

  if [ -z "$PENDING" ]; then
    if [ "$PARKED" = 1 ]; then unpark_guests; PARKED=0; fi
    PHASE=done; save_state; release_owner
    notify success "Cluster update cycle complete. Packages upgraded on all nodes; no reboot required (cycle=$CYCLE_ID)."
    return
  fi
  advance
}

cmd_resume() {
  local waited=0
  [ -f "$STATE_FILE" ] || exit 0
  load_state
  [ "$PHASE" = rebooting_self ] || exit 0
  take_lock || { log "Lock busy on resume; exiting"; exit 0; }
  log "Resuming cycle $CYCLE_ID after self-reboot"
  until is_quorate; do
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge 300 ] && fail "$SELF_NODE rebooted but did not regain quorum. Cycle halted for manual review."
  done
  rejoin_node "$SELF_NODE"
  advance
}

# Read-only: what a cycle started now would do.
cmd_plan() {
  local n sid rc line
  echo "self: $SELF_NODE    config: $CONF_FILE$([ -r "$CONF_FILE" ] || echo ' (not found, using defaults)')"
  echo "nodes: $(cluster_nodes | tr '\n' ' ')"
  if quorum_allows_reboot; then echo "quorum: OK to take one node down"; else echo "quorum: NOT safe - $REASON"; fi
  if ha_in_use; then
    echo "HA: in use; transitions in progress: $(ha_services_in_transition | tr '\n' ' ')"
  else
    echo "HA: no HA resources configured; nodes are rebooted without evacuation"
  fi
  for sid in "${CRITICAL_SIDS[@]}"; do
    line="critical $sid: $(guest_field "$sid" status)@$(guest_field "$sid" node)"
    [ -n "$(ha_service_field "$sid" state)" ] || line="$line  WARNING: not HA-managed, cannot be moved off its node"
    echo "$line"
  done
  [ "${#PARK_SIDS[@]}" -gt 0 ] && echo "parked during a cycle: ${PARK_SIDS[*]}"
  for n in $(cluster_nodes | grep -vx "$SELF_NODE") $(cluster_nodes | grep -x "$SELF_NODE"); do
    node_needs_reboot "$n"; rc=$?
    case $rc in 0) line="reboot NEEDED" ;; 1) line="no reboot needed" ;; *) line="UNREACHABLE (rc=$rc)" ;; esac
    echo "-- $n: $line; HA state: $(ha_node_state "$n")"
    echo "   HA services to evacuate: $(ha_services_on "$n" | tr '\n' ' ')"
  done
}

cmd_status() {
  echo "-- state file --"
  if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo "(no cycle state; idle)"; fi
  echo "-- plan --"
  cmd_plan
}

for tool in jq flock pvecm pvesh ha-manager; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 2; }
done

case "${1:-}" in
  start)  mkdir -p "$STATE_DIR"; exec >>"$LOG_FILE" 2>&1; cmd_start ;;
  resume) mkdir -p "$STATE_DIR"; exec >>"$LOG_FILE" 2>&1; cmd_resume ;;
  plan)   cmd_plan ;;
  status) cmd_status ;;
  *) echo "usage: $0 {start|resume|plan|status}"; exit 2 ;;
esac
