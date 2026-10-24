#!/bin/bash
# Rolling update/reboot cycle for a Proxmox VE cluster of any size.
#
# Runs on ONE cluster node (from cron). Upgrades packages on every node, then reboots
# the nodes that need it one at a time: HA maintenance mode evacuates the node, the
# guests listed as critical are confirmed healthy elsewhere, the node reboots and
# rejoins, and HA is left to settle before the next node. The node running the script
# goes last and resumes after its own reboot via an @reboot cron entry.
#
# Approach: do the normal case well, and when anything is unclear, stop where it is
# and ask for help. A cycle that fails after changing something blocks later cycles on
# every node until someone runs `clear`.
#
# Site settings live in /etc/cluster-update-cycle.conf; see the example file.

set -uo pipefail
# cron's default PATH lacks /usr/sbin, where ha-manager, qm, reboot and needrestart live.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
# Cluster-wide cycle record. mkdir on /etc/pve is atomic across the cluster (pmxcfs
# orders every write through corosync) and fails on a node without quorum. Not under
# /etc/pve/priv/lock/, where pmxcfs expires entries after about two minutes.
CYCLE_DIR="/etc/pve/priv/cluster-update-cycle.lock"
RECORD="$CYCLE_DIR/record"
MEMBERS="/etc/pve/.members"
PVE_NODES_DIR="/etc/pve/nodes"
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

# Exit 0 = reboot needed, 1 = not needed, 2 = could not tell.
# needrestart is used when it gives a usable answer (KSTA 2/3 = pending kernel,
# UCSTA 2 = obsolete microcode). If it is missing, fails, or prints no kernel status,
# fall back to comparing the running kernel with the newest one installed.
NEEDS_REBOOT_CMD='
[ -f /var/run/reboot-required ] && exit 0
if command -v needrestart >/dev/null 2>&1; then
  out=$(needrestart -b 2>/dev/null)
  if printf "%s\n" "$out" | grep -q "^NEEDRESTART-KSTA: *[0-9]"; then
    printf "%s\n" "$out" | awk -F": " "/^NEEDRESTART-KSTA:/ && \$2 >= 2 { r=1 } /^NEEDRESTART-UCSTA:/ && \$2 == 2 { r=1 } END { exit !r }"
    exit $?
  fi
fi
newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed "s|.*/vmlinuz-||" | sort -V | tail -n1)
[ -n "$newest" ] || exit 2
[ "$newest" != "$(uname -r)" ]
'
node_needs_reboot() { run_on "$1" "$NEEDS_REBOOT_CMD"; }

# Exit 0 = upgrade removes nothing, 3 = it would remove packages (listed on a
# "REMOVE:" line), anything else = could not check.
APT_CHECK_CMD='
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || exit 1
sim=$(apt-get -s -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade 2>&1) || { printf "%s\n" "$sim" | tail -n5; exit 1; }
rm=$(printf "%s\n" "$sim" | awk "/^Remv / { printf \"%s \", \$2 }")
[ -z "$rm" ] && exit 0
echo "REMOVE: $rm"
exit 3
'
# --no-remove makes apt abort rather than remove anything, in case the package set
# changed between the check and the upgrade.
APT_UPGRADE_CMD='
export DEBIAN_FRONTEND=noninteractive
apt-get -y -qq --no-remove -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
'

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

# ---------- cluster-wide cycle record ----------

# The record is a few key=value lines: owner, cycle, status (running|failed), since,
# reason. It exists from the start of a cycle until the cycle succeeds, fails without
# having changed anything, or someone runs `clear`.
record_get() { sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | head -n1; }
write_record() {
  printf 'owner=%s\ncycle=%s\nstatus=%s\nsince=%s\nreason=%s\n' \
    "$SELF_NODE" "$CYCLE_ID" "$1" "$(date -Is)" "${2:-}" > "$RECORD"
}
owns_record() {
  [ "$(record_get owner)" = "$SELF_NODE" ] && [ "$(record_get cycle)" = "$CYCLE_ID" ]
}

# Atomically claim the cycle. Returns 1 if another node holds it or /etc/pve is not
# writable (no quorum), 2 if we created the lock but could not write the record (the
# lock is removed again, partial record included).
acquire_cycle() {
  mkdir "$CYCLE_DIR" 2>/dev/null || return 1
  write_record running && owns_record && return 0
  rm -f "$RECORD"
  rmdir "$CYCLE_DIR" 2>/dev/null || log "WARN: could not remove $CYCLE_DIR after a failed claim"
  return 2
}
release_cycle() {
  owns_record || return 0
  rm -f "$RECORD" && rmdir "$CYCLE_DIR" 2>/dev/null \
    || log "WARN: could not remove cycle record $CYCLE_DIR"
}

# Before each step that changes something: make sure the record is still ours and
# still running. If someone cleared it, or it cannot be read, stop here.
assert_owner() {
  [ "$(record_get status)" = running ] && owns_record && return 0
  log "FAILED: cycle record no longer belongs to cycle $CYCLE_ID on $SELF_NODE; stopping before $1"
  notify failure "Cycle $CYCLE_ID stopped before $1: the cluster cycle record at $CYCLE_DIR no longer belongs to it (cleared, replaced, or unreadable). Nothing more was changed."
  PHASE=failed; save_state
  exit 1
}

# Called by `start` before anything else. Exits unless no cycle record exists.
check_existing_cycle() {
  local owner cycle status reason
  [ -d "$CYCLE_DIR" ] || return 0
  owner=$(record_get owner); cycle=$(record_get cycle)
  status=$(record_get status); reason=$(record_get reason)

  if [ -z "$status" ]; then
    # Another node may be between mkdir and writing the record. Only complain if the
    # directory has been empty for a while.
    if [ -n "$(find "$CYCLE_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      log "FAILED: $CYCLE_DIR exists with no cycle record"
      notify failure "Cycle lock $CYCLE_DIR exists with no record in it. Check that no cycle is running, then run 'cluster-update-cycle.sh clear'."
      exit 1
    fi
    log "Another node is claiming the cycle; exiting"
    exit 0
  fi

  case "$status" in
    running)
      if [ "$owner" != "$SELF_NODE" ]; then
        log "Node $owner is running cycle $cycle; exiting"
        if ! node_online "$owner" && [ -n "$(find "$RECORD" -mmin +360 2>/dev/null)" ]; then
          CYCLE_ID="$cycle"
          notify failure "Node $owner holds the cycle record for cycle $cycle but has been offline. Check the cluster, then run 'cluster-update-cycle.sh clear --force'."
          exit 1
        fi
        exit 0
      fi
      if [ "$PHASE" = rebooting_self ] && [ "$CYCLE_ID" = "$cycle" ] \
        && [ -n "$(find "$STATE_FILE" -mmin -360 2>/dev/null)" ]; then
        log "Cycle $cycle is waiting for its post-reboot resume; not starting a new one"
        exit 0
      fi
      # Ours, and we hold the local lock, so nothing here is driving it any more.
      CYCLE_ID="$cycle"
      fail "Cycle $cycle was interrupted (phase=${PHASE:-unknown} node=${CURRENT:-none}). Nothing was cleaned up: check for nodes in HA maintenance and stopped parked guests."
      ;;
    failed)
      log "Cycle $cycle (driven by $owner) failed earlier and needs manual attention: $reason"
      # Remind from the node that drove it, or from anyone if that node is gone.
      if [ "$owner" = "$SELF_NODE" ] || ! node_online "$owner"; then
        CYCLE_ID="$cycle"
        notify failure "Not starting: cycle $cycle (driven by $owner) failed and is waiting for manual attention: $reason Run 'cluster-update-cycle.sh clear' once it is sorted out."
      fi
      exit 1
      ;;
    *)
      log "FAILED: unknown cycle record status '$status' in $RECORD"
      notify failure "Cycle record $RECORD has unknown status '$status'. Run 'cluster-update-cycle.sh clear' once checked."
      exit 1
      ;;
  esac
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

# retry <timeout> <command...>: run the command every 5s until it succeeds or the
# timeout passes. The command's own REASON from the last attempt is kept.
retry() {
  local timeout="$1" waited=0; shift
  until "$@"; do
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge "$timeout" ] && return 1
  done
  return 0
}

# units_active <node> <unit...>: every listed systemd unit is active on <node>.
units_active() {
  local node="$1" bad; shift
  bad=$(run_on "$node" "for u in $*; do systemctl is-active --quiet \$u || echo \$u; done") \
    || { REASON="could not reach $node to check its services"; return 1; }
  [ -z "$bad" ] && return 0
  REASON="not active on $node: ${bad//$'\n'/ }"
  return 1
}

# The node's HA agent (LRM) has written its status since <epoch>. It does so every
# few seconds whether or not it runs any services, so a stale timestamp means it is
# hung or not running.
lrm_reported_since() {
  local node="$1" since="$2" ts
  ts=$(jq -r '.timestamp // empty' "$PVE_NODES_DIR/$node/lrm_status" 2>/dev/null)
  ts=${ts%.*}
  [ -n "$ts" ] && [ "$ts" -gt "$since" ] 2>/dev/null && return 0
  REASON="HA agent (LRM) on $node has not reported since its upgrade (last timestamp: ${ts:-none})"
  return 1
}

# Health of <node> right after its packages were upgraded at <epoch>. Package
# scripts restart these daemons, so a broken update shows up here. Sets REASON.
check_node_after_upgrade() {
  local node="$1" since="$2" units="corosync pve-cluster"
  ha_in_use && units="$units pve-ha-lrm pve-ha-crm"
  retry 60 units_active "$node" $units || return 1
  retry 60 quorum_allows_reboot || return 1
  if ha_in_use; then
    retry 120 lrm_reported_since "$node" "$since" || return 1
    wait_for_ha_settled || { REASON="HA did not settle"; return 1; }
  fi
  log "$node healthy after its upgrade"
}

# "Upgraded: a b. Failed on: c. Not upgraded: d e." for failure messages.
upgrade_progress() {
  local failed="$1" upgraded="$2" n rest=""
  for n in $(cluster_nodes); do
    in_list "$n" "$upgraded $failed" || rest="$rest $n"
  done
  upgraded=${upgraded# }; rest=${rest# }
  echo "Upgraded: ${upgraded:-none}. Failed on: $failed. Not upgraded: ${rest:-none}."
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

# wait_guest_status <sid> <status> <timeout>
wait_guest_status() {
  local sid="$1" want="$2" timeout="$3" waited=0
  while [ "$(guest_field "$sid" status)" != "$want" ]; do
    sleep 5; waited=$((waited+5))
    [ "$waited" -ge "$timeout" ] && { log "ERROR: $sid not $want after ${timeout}s (status=$(guest_field "$sid" status))"; return 1; }
  done
  return 0
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
  local sid
  for sid in "${PARK_SIDS[@]}"; do
    log "Parking $sid (HA state -> stopped) for the duration of the cycle"
    ha-manager set "$sid" --state stopped || return 1
    wait_guest_status "$sid" stopped 300 || return 1
  done
}
# Returns non-zero unless every parked guest was set back to started and is running.
unpark_guests() {
  local sid rc=0
  for sid in "${PARK_SIDS[@]}"; do
    log "Unparking $sid (HA state -> started)"
    ha-manager set "$sid" --state started || { log "ERROR: could not set $sid back to started"; rc=1; }
  done
  for sid in "${PARK_SIDS[@]}"; do
    wait_guest_status "$sid" running "$HEALTH_TIMEOUT" || rc=1
  done
  return $rc
}

# ---------- notifications / end states ----------

notify() {
  local status="$1" message="$2" payload
  [ -n "$WEBHOOK_URL" ] || return 0
  [ "$status" = failure ] && [ "${PARKED:-0}" = 1 ] && message="$message Parked guests may still be stopped: ${PARK_SIDS[*]}."
  payload=$(jq -n --arg status "$status" --arg message "$message" \
    --arg cycle "${CYCLE_ID:-none}" --arg node "$SELF_NODE" --arg time "$(date -Is)" \
    '{status:$status, message:$message, cycle_id:$cycle, node:$node, time:$time}')
  curl -fsS -m 15 -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 \
    || log "WARN: webhook notification failed to send (status=$status)"
}

# Failure after the cycle may have changed something: mark the cluster record failed
# and keep it, so no node starts another cycle until someone runs `clear`.
fail() {
  log "FAILED: $*"
  PHASE=failed; save_state
  if owns_record; then
    write_record failed "$*" || log "WARN: could not mark cycle record failed (is /etc/pve writable?)"
  fi
  notify failure "$* Further cycles are blocked until someone runs 'cluster-update-cycle.sh clear'."
  exit 1
}

# Failure before anything was changed: report it and release the record, so the next
# scheduled run simply tries again.
fail_clean() {
  log "FAILED (nothing changed): $*"
  PHASE=failed; save_state
  release_cycle
  notify failure "$* Nothing was changed; the next scheduled run will try again."
  exit 1
}

# Give up on <node> before it was rebooted: let its guests come back, then fail.
abort_node() {
  local node="$1"; shift
  ha_in_use && { ha_maintenance "$node" disable || log "WARN: could not disable HA maintenance on $node"; }
  fail "$*"
}

finish() {
  local q=BAD crit="" sid st ok=1 summary
  is_quorate && q=OK
  [ "$q" = OK ] || ok=0
  wait_for_ha_settled || ok=0
  if [ "${PARKED:-0}" = 1 ]; then
    if [ "$ok" = 1 ]; then
      if unpark_guests; then PARKED=0; save_state; else ok=0; fi
    else
      log "WARN: leaving ${PARK_SIDS[*]} stopped"
    fi
  fi
  for sid in "${CRITICAL_SIDS[@]}"; do
    st=$(guest_field "$sid" status)
    crit="$crit $sid=$st@$(guest_field "$sid" node)"
    [ "$st" = running ] || ok=0
  done
  summary="cycle=$CYCLE_ID quorum=$q rebooted=[${DONE# }]${crit:+ critical:$crit}"
  log "FINISH: $summary"
  [ "$ok" = 1 ] || fail "Cluster update cycle finished with problems. $summary"
  PHASE=done; CURRENT=""; save_state
  release_cycle
  notify success "Cluster update cycle complete. $summary"
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
  [ -n "$before" ] || abort_node "$node" "Could not reach $node just before its reboot; it was NOT rebooted."
  log "Rebooting $node"
  if ! run_on "$node" "nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &"; then
    # The request reported an error. Find out what actually happened before deciding.
    sleep 30
    now=$(node_boot_id "$node")
    if [ "$now" = "$before" ]; then
      abort_node "$node" "The reboot command failed on $node; it is still up and was NOT rebooted."
    elif [ -z "$now" ]; then
      fail "The reboot command to $node reported an error and $node is now unreachable. Left in HA maintenance for manual review."
    fi
    log "WARN: reboot request to $node reported an error, but it has already rebooted; continuing"
  fi
  sleep 20
  while true; do
    now=$(node_boot_id "$node")
    [ -n "$now" ] && [ "$now" != "$before" ] && break
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge "$REBOOT_TIMEOUT" ]; then
      [ "$now" = "$before" ] && fail "Reboot of $node was requested but it never went down within ${REBOOT_TIMEOUT}s. Left in HA maintenance; remaining nodes not rebooted."
      fail "Reboot of $node was requested but it did not come back within ${REBOOT_TIMEOUT}s. Cycle halted; remaining nodes not rebooted."
    fi
  done
  log "$node is back (new boot id)"
  rejoin_node "$node"
}

advance() {
  local node
  if [ "$PARKED" = 0 ] && [ "${#PARK_SIDS[@]}" -gt 0 ]; then
    assert_owner "parking guests"
    if ! park_guests; then
      unpark_guests
      fail "Could not shut down ${PARK_SIDS[*]} before the cycle. Nothing rebooted."
    fi
    PARKED=1; save_state
  fi

  for node in $PENDING; do
    in_list "$node" "$DONE" && continue
    assert_owner "evacuating $node"
    quorum_allows_reboot || fail "Not safe to reboot $node: $REASON. Cycle halted."
    CURRENT="$node"; PHASE="evacuating"; save_state
    evacuate_node "$node" || abort_node "$node" "Could not evacuate $node (${REASON:-HA maintenance failed}); it was NOT rebooted."
    check_critical "$node" || abort_node "$node" "Critical guest not healthy away from $node ($REASON); $node was NOT rebooted."

    if [ "$node" = "$SELF_NODE" ]; then
      log "Rebooting self ($SELF_NODE); will resume via @reboot"
      PHASE="rebooting_self"; save_state
      notify info "Rebooting $SELF_NODE (the node running the update cycle); it will resume afterwards."
      sync
      reboot || abort_node "$node" "The reboot command failed on $SELF_NODE; it was NOT rebooted."
      # A successful reboot stops this script during shutdown. Still being here much
      # later means the reboot never happened.
      sleep 900
      fail "$SELF_NODE accepted the reboot command but was still running 15 minutes later. Left in HA maintenance for manual review."
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
  local n out rc upgraded started
  take_lock || { log "Another cycle is already running here; exiting"; exit 0; }
  load_state
  check_existing_cycle

  CYCLE_ID=$(date +%Y%m%d-%H%M%S)
  PHASE="preflight"; PENDING=""; DONE=""; CURRENT=""; PARKED=0
  save_state
  quorum_allows_reboot || fail_clean "Pre-flight failed: $REASON."
  acquire_cycle
  case $? in
    0) ;;
    1) if [ -d "$CYCLE_DIR" ]; then log "Another node claimed the cycle first; exiting"; exit 0; fi
       fail_clean "Pre-flight failed: cannot create the cycle lock in /etc/pve." ;;
    *) fail_clean "Pre-flight failed: created the cycle lock but could not write its record.$([ -d "$CYCLE_DIR" ] && echo " The lock could not be removed either; run 'cluster-update-cycle.sh clear'.")" ;;
  esac
  PHASE="updating"; save_state
  log "=== Starting update cycle $CYCLE_ID on $SELF_NODE; nodes: $(cluster_nodes | tr '\n' ' ')==="

  # Check every node before upgrading any, so a refusal leaves the cluster unchanged.
  for n in $(cluster_nodes); do
    log "Checking planned package changes on $n"
    out=$(run_on "$n" "$APT_CHECK_CMD" 2>&1); rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    case $rc in
      0) ;;
      3) fail_clean "Upgrade on $n would remove packages: $(sed -n 's/^REMOVE: //p' <<<"$out"). Nothing upgraded on any node." ;;
      *) fail_clean "Could not check planned package changes on $n (rc=$rc). Nothing upgraded on any node." ;;
    esac
  done

  # One node at a time, checking health after each, so a bad cluster or HA package
  # stops at the first node instead of reaching all of them.
  upgraded=""
  for n in $(cluster_nodes); do
    log "Upgrading packages on $n"
    started=$(date +%s)
    run_on "$n" "$APT_UPGRADE_CMD" \
      || fail "Package upgrade failed on $n. $(upgrade_progress "$n" "$upgraded") Nothing rebooted."
    check_node_after_upgrade "$n" "$started" \
      || fail "$n is unhealthy after its package upgrade ($REASON). $(upgrade_progress "$n" "$upgraded") Nothing rebooted."
    upgraded="$upgraded $n"
  done

  # Peers first, self last, so the resume-after-self-reboot path runs at most once.
  for n in $(cluster_nodes | grep -vx "$SELF_NODE") $(cluster_nodes | grep -x "$SELF_NODE"); do
    node_needs_reboot "$n"
    case $? in
      0) PENDING="$PENDING $n" ;;
      1) ;;
      *) fail_clean "Could not determine whether $n needs a reboot. Packages were upgraded but nothing rebooted." ;;
    esac
  done
  PENDING="${PENDING# }"; PHASE="planned"; save_state
  log "Nodes needing a reboot: ${PENDING:-none}"

  if [ -z "$PENDING" ]; then
    PHASE=done; save_state; release_cycle
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
  assert_owner "resuming after the reboot of $SELF_NODE"
  rejoin_node "$SELF_NODE"
  advance
}

# Is a start/resume process running on <node>? It holds the local flock for its whole
# run. Returns 0 = no, 1 = yes, 2 = could not tell (node unreachable).
controller_state() {
  run_on "$1" "[ -e '$LOCK_FILE' ] || exit 0; flock -n '$LOCK_FILE' true" 2>/dev/null
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# Remove the cluster cycle record after a failure has been dealt with.
cmd_clear() {
  local force="${1:-}" status cycle owner answer n sid st
  take_lock || { echo "A cycle is running on this node right now; refusing to clear." >&2; exit 1; }
  if [ ! -d "$CYCLE_DIR" ]; then
    echo "No cycle record; nothing to clear."
  else
    echo "-- cycle record ($RECORD) --"
    cat "$RECORD" 2>/dev/null || echo "(empty)"
    status=$(record_get status); cycle=$(record_get cycle); owner=$(record_get owner)
    if [ "$status" = running ]; then
      if [ "$force" != --force ]; then
        echo "The record says this cycle is still running. If you are sure no node is working on it, run: $0 clear --force" >&2
        exit 1
      fi
      # On this node our own flock already proved nothing is running. Elsewhere, ask.
      if [ "$owner" != "$SELF_NODE" ]; then
        controller_state "$owner"
        case $? in
          0) echo "$owner is reachable and no cycle process is running there; clearing." ;;
          1) echo "REFUSING: cluster-update-cycle.sh is running on $owner right now (it holds $LOCK_FILE there). Stop it on $owner first." >&2
             exit 1 ;;
          *) echo "WARNING: could not reach $owner to check whether cycle $cycle is still running there." >&2
             echo "WARNING: if it is (for example, rebooting itself), clearing lets another cycle start alongside it." >&2
             [ -t 0 ] || { echo "Not running on a terminal; refusing. Run clear interactively to confirm." >&2; exit 1; }
             read -r -p "Type the cycle id ($cycle) to clear anyway: " answer
             [ "$answer" = "$cycle" ] || { echo "Not cleared." >&2; exit 1; } ;;
        esac
      fi
    fi
    rm -f "$RECORD"
    rmdir "$CYCLE_DIR" || { echo "Could not remove $CYCLE_DIR (is the cluster quorate?)" >&2; exit 1; }
    log "Cycle record cleared by hand (was: status=${status:-none} cycle=${cycle:-none})" >> "$LOG_FILE"
    echo "Cleared."
  fi
  load_state
  if [ -n "$PHASE" ] && [ "$PHASE" != done ]; then PHASE=cleared; save_state; fi

  # clear does not touch these; list them so they are not forgotten.
  echo "-- leftovers to check --"
  for n in $(cluster_nodes); do
    [ "$(ha_node_state "$n")" = maintenance ] && echo "node $n is still in HA maintenance (ha-manager crm-command node-maintenance disable $n)"
  done
  for sid in "${PARK_SIDS[@]}"; do
    st=$(guest_field "$sid" status)
    [ "$st" = running ] || echo "parked guest $sid is $st (the next cycle starts it again at its end)"
  done
  echo "(done)"
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
    case $rc in
      0) line="reboot NEEDED" ;;
      1) line="no reboot needed" ;;
      2) line="reboot need UNKNOWN (no usable needrestart output or kernel list)" ;;
      *) line="UNREACHABLE (rc=$rc)" ;;
    esac
    echo "-- $n: $line; HA state: $(ha_node_state "$n")"
    echo "   HA services to evacuate: $(ha_services_on "$n" | tr '\n' ' ')"
  done
}

cmd_status() {
  echo "-- cluster cycle record --"
  if [ -d "$CYCLE_DIR" ]; then cat "$RECORD" 2>/dev/null || echo "(lock exists, no record)"; else echo "(none; no cycle running or blocked)"; fi
  echo "-- local state file --"
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
  clear)  cmd_clear "${2:-}" ;;
  plan)   cmd_plan ;;
  status) cmd_status ;;
  *) echo "usage: $0 {start|resume|clear [--force]|plan|status}"; exit 2 ;;
esac
