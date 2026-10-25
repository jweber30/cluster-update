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
# Site settings live in /etc/pve/priv/cluster-update-cycle.conf (shared by all nodes); see
# the example file.

set -uo pipefail
# cron's default PATH lacks /usr/sbin, where ha-manager, qm, reboot and needrestart live.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The config lives on the cluster filesystem so every node reads the same one; a
# per-node file in /etc is the fallback. CLUSTER_UPDATE_CYCLE_CONF overrides both.
SHARED_CONF="/etc/pve/priv/cluster-update-cycle.conf"
LOCAL_CONF="/etc/cluster-update-cycle.conf"
find_conf() {
  if [ -n "${CLUSTER_UPDATE_CYCLE_CONF:-}" ]; then echo "$CLUSTER_UPDATE_CYCLE_CONF"
  elif [ -r "$SHARED_CONF" ]; then echo "$SHARED_CONF"
  elif [ -r "$LOCAL_CONF" ]; then echo "$LOCAL_CONF"
  else echo "$SHARED_CONF"
  fi
}
CONF_FILE=$(find_conf)

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
MIGRATE_MAX_WAIT=21600    # cap on one evacuation/settle wait while migrations keep running
MIGRATE_ATTEMPTS=2        # failed migration tasks of one guest before giving up
MIN_ROOT_FREE_MB=2048     # free space on / every other node needs before a node is evacuated
MIN_FREE_MEM_MB=1024      # memory each target node keeps free after taking evacuated guests
RELOCATE_SIDS=()          # HA VMs moved by shutdown+start (relocate) instead of live migration

# shellcheck source=/dev/null
load_conf() { CONF_FILE=$(find_conf); [ -r "$CONF_FILE" ] || return 1; . "$CONF_FILE"; }
load_conf

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
HA_RULES="/etc/pve/ha/rules.cfg"

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
echo "REMOVE: ${rm% }"
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
      notify failure "Cycle lock $CYCLE_DIR exists with no record in it. Check that no cycle is running, then run 'cluster-update-cycle.sh clear'." blocked
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
          notify failure "Node $owner holds the cycle record for cycle $cycle but has been offline. Check the cluster, then run 'cluster-update-cycle.sh clear --force'." blocked
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
        notify failure "Not starting: cycle $cycle (driven by $owner) failed and is waiting for manual attention: $reason Run 'cluster-update-cycle.sh clear' once it is sorted out." blocked
      fi
      exit 1
      ;;
    *)
      log "FAILED: unknown cycle record status '$status' in $RECORD"
      notify failure "Cycle record $RECORD has unknown status '$status'. Run 'cluster-update-cycle.sh clear' once checked." blocked
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
ha_sids_in_transition() { local l; l=$(ha_services_in_transition) || return 1; [ -z "$l" ] || sed 's/=.*//' <<<"$l"; }

# Migration tasks (qmigrate/vzmigrate) for the given sids from the cluster-wide task
# list, one "<vmid> <running|ok|error> <status> <starttime>" line each: every running one, plus
# finished ones that started at or after <epoch>. Fails if the list cannot be read.
migration_tasks_since() {
  local since="$1" ids json; shift
  ids=$(for s in "$@"; do sid_vmid "$s"; done | jq -R . | jq -sc .)
  json=$(pvesh get /cluster/tasks --output-format json 2>/dev/null) || return 1
  jq -r --argjson ids "$ids" --argjson since "$since" '.[]
    | select(.type == "qmigrate" or .type == "vzmigrate")
    | select(.id as $i | $ids | index($i))
    | select(.endtime == null or (.starttime // 0) >= $since)
    | (.status // "") as $st
    | "\(.id)\t\(if .endtime == null then "running"
                 elif ($st == "OK" or ($st | startswith("WARNINGS"))) then "ok"
                 else "error" end)\t\($st)\t\(.starttime // 0)"' <<<"$json"
}

# wait_for_ha_moves <idle-timeout> <list-command...>: wait until the list command
# (which prints HA sids still to move) prints nothing. A large guest can take hours to
# migrate, so time spent while one of those guests has a migration task running does
# not count toward <idle-timeout>; MIGRATE_MAX_WAIT caps the whole wait. HA retries a
# failed migration on its own; after MIGRATE_ATTEMPTS failures of one guest, or a guest
# in HA error state, this gives up. Sets REASON.
wait_for_ha_moves() {
  local idle_limit="$1" since idle=0 total=0 left tasks running failed sid st id msg key seen="" next_note=600
  shift
  since=$(date +%s)
  while true; do
    # A failed read of the HA status must not look like "nothing left".
    left=$("$@") || left="(HA status unreadable)"
    left=${left//$'\n'/ }
    [ -z "$left" ] && return 0
    for sid in $left; do
      st=$(ha_service_field "$sid" state)
      [ "$st" = error ] && { REASON="$sid is in HA error state"; log "ERROR: $REASON"; return 1; }
    done
    running=""; failed=""
    if [ "$left" != "(HA status unreadable)" ] && tasks=$(migration_tasks_since "$since" $left); then
      running=$(awk -F'\t' '$2=="running"{print $1}' <<<"$tasks" | sort -u | tr '\n' ' ')
      failed=$(awk -F'\t' -v max="$MIGRATE_ATTEMPTS" '$2=="error"{n[$1]++; s[$1]=$3}
        END{for (i in n) if (n[i] >= max) printf "%s (%d failed: %s) ", i, n[i], s[i]}' <<<"$tasks")
      while IFS=$'\t' read -r id st msg key; do
        [ "$st" = error ] || continue
        key="$id@$key"
        in_list "$key" "$seen" && continue
        seen="$seen $key"
        log "WARN: migration of guest $id failed: $msg"
      done <<<"$tasks"
    fi
    [ -n "$failed" ] && { REASON="migration failed after $MIGRATE_ATTEMPTS attempts: ${failed% }"; log "ERROR: $REASON"; return 1; }
    sleep 5; total=$((total+5))
    if [ -n "$running" ]; then
      idle=0
      [ "$total" -ge "$next_note" ] && { log "Still migrating guest(s) ${running% } (${total}s so far)"; next_note=$((total+600)); }
    else
      idle=$((idle+5))
    fi
    [ "$idle" -ge "$idle_limit" ] && { REASON="no migration progress for ${idle_limit}s; waiting on: $left"; log "ERROR: $REASON"; return 1; }
    [ "$total" -ge "$MIGRATE_MAX_WAIT" ] && { REASON="still waiting after ${MIGRATE_MAX_WAIT}s: $left"; log "ERROR: $REASON"; return 1; }
  done
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
  local busy n
  ha_in_use || return 0
  for n in $(cluster_nodes); do wait_for_ha_node_state "$n" online || return 1; done
  sleep 30
  wait_for_ha_moves "$SETTLE_TIMEOUT" ha_sids_in_transition && return 0
  busy=$(ha_services_in_transition) || busy="(HA status unreadable)"
  log "ERROR: HA services still in transition: ${busy//$'\n'/ }"
  return 1
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

# ---------- can the other nodes take guests? ----------

# Bytes for a PVE size string such as 8G, 512M, 1.5T or a plain byte count.
size_bytes() {
  awk -v s="$1" 'BEGIN { m = 1; u = toupper(substr(s, length(s)))
    if (u == "K") m = 1024; else if (u == "M") m = 1024^2; else if (u == "G") m = 1024^3; else if (u == "T") m = 1024^4
    if (m > 1) s = substr(s, 1, length(s) - 1)
    printf "%.0f\n", s * m }'
}
gib() { awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1024^3 }'; }

guest_conf() {
  case "${1%%:*}" in
    vm) echo "$PVE_NODES_DIR/$2/qemu-server/$(sid_vmid "$1").conf" ;;
    ct) echo "$PVE_NODES_DIR/$2/lxc/$(sid_vmid "$1").conf" ;;
  esac
}

# Configured memory of <sid> on <node> in MB (PVE's default is 512). Ballooning is
# ignored: a guest may grow to its full size at any time.
guest_memory_mb() {
  local conf; conf=$(guest_conf "$1" "$2")
  [ -r "$conf" ] || { echo 0; return; }
  sed '/^\[/,$d' "$conf" | awk -F': ' '$1 == "memory" { m = $2 } END { print (m == "" ? 512 : m + 0) }'
}

# "<storage> <replicable-bytes> <other-bytes>" per non-shared storage that <sid>'s disks
# on <node> use. Sizes are the configured (provisioned) ones: thin volumes can need
# less, but a migration that runs out of room part-way is far worse than a cautious
# refusal. Volumes marked replicate=0 never have a replica on another node.
guest_local_disks() {
  local sid="$1" node="$2" conf shared
  conf=$(guest_conf "$sid" "$node")
  [ -n "$conf" ] && [ -r "$conf" ] || return 0
  shared=$(pvesh get "/nodes/$node/storage" --output-format json 2>/dev/null \
    | jq -r '.[] | select(.shared == 1) | .storage') || return 1
  awk -F': ' -v shared=" $(echo $shared) " '
    /^\[/ { exit }   # snapshot sections follow the current config
    $1 ~ /^(rootfs|mp[0-9]+|(scsi|virtio|sata|ide)[0-9]+|efidisk0|tpmstate0)$/ {
      v = $2
      if (v ~ /media=cdrom/ || v !~ /^[^,\/]+:/) next
      st = v; sub(/:.*/, "", st)
      if (st == "none" || index(shared, " " st " ")) next
      size = ""; n = split(v, f, ",")
      for (i = 2; i <= n; i++) if (f[i] ~ /^size=/) size = substr(f[i], 6)
      if (size == "") next
      if (v ~ /replicate=0/) other[st] = other[st] " " size; else rep[st] = rep[st] " " size
      seen[st] = 1
    }
    END { for (st in seen) print st "|" rep[st] "|" other[st] }' "$conf" |
  while IFS='|' read -r st reps others; do
    local r=0 o=0 s
    for s in $reps; do r=$(( r + $(size_bytes "$s") )); done
    for s in $others; do o=$(( o + $(size_bytes "$s") )); done
    echo "$st $r $o"
  done
}

# Nodes that hold a replica of <sid>'s disks from <node> (enabled replication jobs).
replication_targets() {
  pvesh get /cluster/replication --output-format json 2>/dev/null | jq -r \
    --arg id "$(sid_vmid "$1")" --arg src "$2" \
    '.[] | select((.guest | tostring) == $id and .source == $src and (.disable // 0) != 1) | .target'
}

# Strict, enabled node-affinity rules for <sid>: "+node" for each node a positive rule
# allows, "-node" for each node a negative rule forbids.
strict_rule_nodes() {
  [ -r "$HA_RULES" ] || return 0
  awk -v sid="$1" '
    function flush(   n, a, i) {
      if (type == "node-affinity" && strict == 1 && !dis && index(res, "," sid ",")) {
        n = split(nodes, a, ",")
        for (i = 1; i <= n; i++) { sub(/:.*/, "", a[i]); print (neg ? "-" : "+") a[i] } }
    }
    /^[a-z-]+: / { flush(); type = $1; sub(/:$/, "", type); res = ""; nodes = ""; strict = 0; dis = 0; neg = 0; next }
    $1 == "resources" { res = "," $2 "," }
    $1 == "nodes" { nodes = $2 }
    $1 == "strict" { strict = $2 }
    $1 == "affinity" { neg = ($2 == "negative") }
    $1 == "disable" { dis = ($2 == "" || $2 != 0) }
    END { flush() }' "$HA_RULES" | sort -u
}

# Nodes HA may move <sid> to when <from> is evacuated.
guest_targets() {
  local sid="$1" from="$2" rules allow n
  rules=$(strict_rule_nodes "$sid")
  allow=$(sed -n 's/^+//p' <<<"$rules")
  for n in $(jq -r '.nodelist | keys[]' "$MEMBERS"); do
    [ "$n" = "$from" ] && continue
    [ -z "$allow" ] || grep -qxF "$n" <<<"$allow" || continue
    grep -qxF -- "-$n" <<<"$rules" && continue
    echo "$n"
  done
}

storage_avail() {
  pvesh get "/nodes/$1/storage" --output-format json 2>/dev/null \
    | jq -r --arg s "$2" '.[] | select(.storage == $s and .active == 1) | .avail // 0' | head -n1
}
node_mem_available_mb() {
  pvesh get "/nodes/$1/status" --output-format json 2>/dev/null \
    | jq -r '(.memory.available // .memory.free // 0) / 1048576 | floor'
}

# Plan where the running HA guests on <node> go: the guests with the fewest allowed
# nodes first, then the largest, each to the
# allowed node with the most memory left that also has room for its local disks (none
# needed where a replica already exists), counting the guests already planned there.
# Fills PLACEMENT[sid]=node. HA makes its own choice when evacuating, so this shows
# that a fitting placement exists, not that HA will pick it; RELOCATE_SIDS guests do
# follow it. Sets REASON.
declare -A PLACEMENT=()
plan_guest_placement() {
  local node="$1" sids order need sid targets disks reps t best bestfree ok memfit store r o d k summary
  local -A mem=() disk=()
  PLACEMENT=()
  sids=$(ha_services_on "$node") || { REASON="HA status unreadable"; return 1; }
  order=$(for sid in $sids; do
      targets=$(guest_targets "$sid" "$node" | tr '\n' ' ')
      echo "$(wc -w <<<"$targets") $(guest_memory_mb "$sid" "$node") $sid $targets"
    done | sort -k1,1n -k2,2nr)
  while read -r _ need sid targets; do
    [ -n "$sid" ] || continue
    [ -n "$targets" ] || { REASON="no node other than $node is allowed to run $sid (HA rules)"; return 1; }
    disks=$(guest_local_disks "$sid" "$node") || { REASON="could not read the storage list of $node"; return 1; }
    reps=" $(replication_targets "$sid" "$node" | tr '\n' ' ') "
    best=""; bestfree=-1; memfit=""
    for t in $targets; do
      [ -n "${mem[$t]+set}" ] || mem[$t]=$(( $(node_mem_available_mb "$t") - MIN_FREE_MEM_MB ))
      [ "${mem[$t]}" -ge "$need" ] || continue
      memfit=1; ok=1
      while read -r store r o; do
        [ -n "$store" ] || continue
        case "$reps" in *" $t "*) d=$o ;; *) d=$(( r + o )) ;; esac
        k="$t/$store"
        [ -n "${disk[$k]+set}" ] || disk[$k]=$(storage_avail "$t" "$store")
        [ "${disk[$k]:-0}" -ge "$d" ] 2>/dev/null || { ok=0; break; }
      done <<<"$disks"
      [ "$ok" = 1 ] && [ "${mem[$t]}" -gt "$bestfree" ] && { best=$t; bestfree=${mem[$t]}; }
    done
    if [ -z "$best" ]; then
      summary=""
      while read -r store r o; do [ -n "$store" ] && summary="$summary, $(gib $(( r + o ))) on $store"; done <<<"$disks"
      if [ -z "$memfit" ]; then
        REASON="not enough memory for $sid (${need} MB) on any node it may move to (${targets% }), counting the other guests from $node and keeping $MIN_FREE_MEM_MB MB free"
      else
        REASON="not enough disk space for $sid (${summary#, }) on any node it may move to with room for its memory (${targets% }), counting the other guests from $node"
      fi
      return 1
    fi
    mem[$best]=$(( mem[$best] - need ))
    while read -r store r o; do
      [ -n "$store" ] || continue
      case "$reps" in *" $best "*) d=$o ;; *) d=$(( r + o )) ;; esac
      disk[$best/$store]=$(( ${disk[$best/$store]:-0} - d ))
    done <<<"$disks"
    PLACEMENT[$sid]=$best
  done <<<"$order"
  return 0
}

# Before <node> enters maintenance: every other node is in the cluster, has its PVE
# services running and room on /, has an HA agent that is online and reporting, and
# the HA guests on <node> fit on the other nodes together (plan_guest_placement).
# Sets REASON.
others_ready_for_guests() {
  local node="$1" n free_mb st mode state ts now
  local units="corosync pve-cluster pvedaemon pvestatd"
  ha_in_use && units="$units pve-ha-lrm pve-ha-crm"
  now=$(date +%s)
  for n in $(cluster_nodes); do
    [ "$n" = "$node" ] && continue
    node_online "$n" || { REASON="node $n is offline"; return 1; }
    units_active "$n" $units || return 1
    free_mb=$(run_on "$n" "df -Pm / | awk 'NR == 2 { print \$4 }'") \
      || { REASON="could not reach $n to check its disk space"; return 1; }
    [ "${free_mb:-0}" -ge "$MIN_ROOT_FREE_MB" ] 2>/dev/null \
      || { REASON="only ${free_mb:-?} MB free on / of $n (need $MIN_ROOT_FREE_MB)"; return 1; }
    ha_in_use || continue
    st=$(ha_node_state "$n")
    [ "$st" = online ] || { REASON="HA reports $n as '${st:-unknown}'"; return 1; }
    read -r mode state ts < <(jq -r '"\(.mode // "-") \(.state // "-") \(.timestamp // 0)"' \
      "$PVE_NODES_DIR/$n/lrm_status" 2>/dev/null)
    ts=${ts%.*}
    [ "$mode" = active ] || { REASON="HA agent (LRM) on $n is in mode '${mode:-unknown}'"; return 1; }
    case "$state" in
      active|wait_for_agent_lock) ;;  # the latter is an idle agent, ready for services
      *) REASON="HA agent (LRM) on $n is in state '${state:-unknown}'"; return 1 ;;
    esac
    [ $(( now - ${ts:-0} )) -le 120 ] 2>/dev/null \
      || { REASON="HA agent (LRM) on $n last reported $(( now - ${ts:-0} ))s ago"; return 1; }
  done
  ha_in_use || return 0
  plan_guest_placement "$node"
}

# failback is off for <sid> in resources.cfg (it defaults to on).
failback_off() {
  awk -v sid="$1" '/^[a-z]+: / { cur = $1 $2; next } cur == sid && $1 == "failback" { v = $2 }
    END { exit !(v == "0") }' "$HA_RESOURCES" 2>/dev/null
}
sid_not_started_on() {
  [ "$(ha_service_field "$1" node)" = "$2" ] && [ "$(ha_service_field "$1" state)" = started ] || echo "$1"
}

# Move the RELOCATE_SIDS guests on <node> to their planned node with HA's relocate
# (shut down, move, start) before maintenance would live-migrate them. Needs a fresh
# PLACEMENT for <node>. Sets REASON.
relocate_guests() {
  local node="$1" sid t
  for sid in "${RELOCATE_SIDS[@]}"; do
    [ "$(ha_service_field "$sid" node)" = "$node" ] || continue
    [ "$(ha_service_field "$sid" state)" = started ] || continue
    t=${PLACEMENT[$sid]:-}
    [ -n "$t" ] || { REASON="no target planned for $sid"; return 1; }
    failback_off "$sid" || log "WARN: $sid has failback on; HA may live-migrate it back to a higher-priority node"
    log "Relocating $sid from $node to $t (shut down, move, start)"
    ha-manager crm-command relocate "$sid" "$t" || { REASON="relocate request for $sid failed"; return 1; }
    wait_for_ha_moves "$EVACUATE_TIMEOUT" sid_not_started_on "$sid" "$t" || return 1
    wait_guest_status "$sid" running "$HEALTH_TIMEOUT" || { REASON="$sid not running after its relocation to $t"; return 1; }
    log "$sid running on $t"
  done
  return 0
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
  local node="$1"
  ha_in_use || return 0
  log "Enabling HA maintenance on $node"
  ha_maintenance "$node" enable || return 1
  wait_for_ha_node_state "$node" maintenance 180 || return 1
  wait_for_ha_moves "$EVACUATE_TIMEOUT" ha_services_on "$node" || return 1
  log "$node holds no active HA services"
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

# notify <info|success|failure> <message> [event]
# Sends the webhook (if configured) and records a task in the PVE task list, both
# best effort. <event> is one of start, reboot, result (the default) or blocked.
notify() {
  local status="$1" message="$2" event="${3:-result}" payload url
  [ "$status" = failure ] && [ "${PARKED:-0}" = 1 ] && message="$message Parked guests may still be stopped: ${PARK_SIDS[*]}."
  if [ -n "$WEBHOOK_URL" ]; then
    payload=$(jq -n --arg status "$status" --arg event "$event" --arg message "$message" \
      --arg cycle "${CYCLE_ID:-none}" --arg node "$SELF_NODE" --arg time "$(date -Is)" \
      '{status:$status, event:$event, message:$message, cycle_id:$cycle, node:$node, time:$time}')
    # The URL goes in through a curl config on stdin, not the command line, so it
    # doesn't show up in ps.
    url=${WEBHOOK_URL//\\/\\\\}; url=${url//\"/\\\"}
    curl -fsS -m 15 -X POST -H "Content-Type: application/json" -d "$payload" -K - \
      <<<"url = \"$url\"" >/dev/null 2>&1 \
      || log "WARN: webhook notification failed to send (status=$status)"
  fi
  record_task "$status" "$event" "$message"
}

# This cycle's lines from the log, from its "Starting update cycle" line onward (at
# most 500), or the last 50 lines if that isn't in the log.
cycle_log_excerpt() {
  echo "Full log: $LOG_FILE on $SELF_NODE, also in Node > System > Syslog (tag cluster-update-cycle)."
  echo
  sleep 1   # output reaches the file through tee; let the latest lines land
  awk -v m="Starting update cycle ${CYCLE_ID:-none} " '
    index($0, m) { n = 0; found = 1 }
    { buf[n++] = $0 }
    END { s = n - (found ? 500 : 50); if (s < 0) s = 0; for (i = s; i < n; i++) print buf[i] }
  ' "$LOG_FILE" 2>/dev/null
}

# Record a short task (type cluster-update-<event>) in the PVE task list via the
# helper, if it is installed. A failure here is only logged.
record_task() {
  local status="$1" event="$2" message="$3" helper excerpt="" rc
  helper=$(command -v cluster-update-cycle-task) || return 0
  if [ "$event" = result ]; then
    excerpt=$(mktemp) && cycle_log_excerpt > "$excerpt"
  fi
  "$helper" "$([ "$status" = failure ] && echo error || echo ok)" "$event" "${CYCLE_ID:-none}" \
    "$message" ${excerpt:+"$excerpt"} >/dev/null 2>&1
  rc=$?
  [ -n "$excerpt" ] && rm -f "$excerpt"
  [ "$rc" = 0 ] || log "WARN: could not record a task in the PVE task list (helper rc=$rc)"
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
  notify failure "$* The cycle stopped before reboot orchestration. The next scheduled run may retry."
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
    retry 120 others_ready_for_guests "$node" || fail "Not safe to evacuate $node: $REASON. Cycle halted; $node was NOT put into maintenance."
    relocate_guests "$node" || fail "Could not relocate guests off $node ($REASON). Cycle halted; $node was NOT put into maintenance."
    CURRENT="$node"; PHASE="evacuating"; save_state
    evacuate_node "$node" || abort_node "$node" "Could not evacuate $node (${REASON:-HA maintenance failed}); it was NOT rebooted."
    check_critical "$node" || abort_node "$node" "Critical guest not healthy away from $node ($REASON); $node was NOT rebooted."

    if [ "$node" = "$SELF_NODE" ]; then
      log "Rebooting self ($SELF_NODE); will resume via @reboot"
      PHASE="rebooting_self"; save_state
      notify info "Rebooting $SELF_NODE (the node running the update cycle); it will resume afterwards." reboot
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
  notify info "Starting cluster update cycle $CYCLE_ID on $SELF_NODE (nodes: $(cluster_nodes | tr '\n' ' ' | sed 's/ $//'))." start

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
  echo "self: $SELF_NODE    config: $CONF_FILE$([ -r "$CONF_FILE" ] || echo ' (NOT FOUND: start/resume would stop; showing defaults)')"
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
  for sid in "${RELOCATE_SIDS[@]}"; do
    line="relocated (shutdown+start) instead of live-migrated: $sid"
    failback_off "$sid" || line="$line  WARNING: failback is on, so HA may live-migrate it back"
    echo "$line"
  done
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
    if others_ready_for_guests "$n"; then
      line=""; for sid in "${!PLACEMENT[@]}"; do line="$line $sid->${PLACEMENT[$sid]}"; done
      echo "   other nodes ready to take its guests; a fitting placement:${line:- (nothing to move)}"
    else
      echo "   NOT ready to evacuate: $REASON"
    fi
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

# Send all output (ours, apt's, everything) to the log file and the journal, which
# is what Node > System > Syslog shows. tee -p keeps writing the file even if the
# journal side goes away.
log_to_file_and_journal() {
  mkdir -p "$STATE_DIR"
  if command -v systemd-cat >/dev/null 2>&1; then
    exec > >(tee -p -a "$LOG_FILE" | systemd-cat -t cluster-update-cycle) 2>&1
  else
    exec >>"$LOG_FILE" 2>&1
  fi
}

# Running with built-in defaults would mean no notifications, no critical guests and
# no relocations, so a cycle never starts without its config. Right after a boot the
# cluster filesystem may not be mounted yet, hence the wait.
require_conf() {
  local waited=0
  until [ -r "$CONF_FILE" ]; do
    if [ "$waited" -ge 300 ]; then
      log "FAILED (nothing changed): no config file found ($SHARED_CONF, $LOCAL_CONF); not running without one"
      record_task failure config "No config file found ($SHARED_CONF or $LOCAL_CONF); the cycle did not run."
      exit 1
    fi
    [ "$waited" = 0 ] && log "Waiting for the config file ($SHARED_CONF or $LOCAL_CONF)"
    sleep 10; waited=$((waited+10))
    load_conf
  done
}

case "${1:-}" in
  start)  log_to_file_and_journal; require_conf; cmd_start ;;
  resume) log_to_file_and_journal; require_conf; cmd_resume ;;
  clear)  cmd_clear "${2:-}" ;;
  plan)   cmd_plan ;;
  status) cmd_status ;;
  *) echo "usage: $0 {start|resume|clear [--force]|plan|status}"; exit 2 ;;
esac
