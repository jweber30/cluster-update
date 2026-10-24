# cluster-update-cycle

Built with Claude Sonnet 5 and Opus 5.5.

Rolling package update and reboot cycle for a Proxmox VE cluster of any size.

Run from cron on one cluster node. It upgrades packages on every node, then reboots
the nodes that need it one at a time: HA maintenance mode evacuates the node, any
guests you've marked critical are confirmed healthy elsewhere, the node reboots and
rejoins, and HA is left to settle before moving to the next node. The node running
the script goes last and resumes after its own reboot via an `@reboot` cron entry.

## Requirements

- Proxmox VE cluster (tested on a cluster; a single standalone node has no HA/quorum
  concerns the script cares about, but it should still run)
- `jq`, `flock`, `pvecm`, `pvesh`, `ha-manager` on the node(s) running the script
  (all present on a standard PVE install)
- Passwordless root SSH between nodes using PVE's own cluster host keys — this is
  already set up by Proxmox cluster join, nothing extra to configure
- Run as root, since `ha-manager`/`pvesh` and `/etc/pve/priv` require it

## Install

```sh
cp cluster-update-cycle.sh /usr/local/sbin/
chmod 750 /usr/local/sbin/cluster-update-cycle.sh

cp cluster-update-cycle.conf.example /etc/cluster-update-cycle.conf
chmod 600 /etc/cluster-update-cycle.conf
# edit /etc/cluster-update-cycle.conf for your site
```

### Cron

```cron
# Kick off a cycle, e.g. weekly
17 3 * * 0 /usr/local/sbin/cluster-update-cycle.sh start

# Resume a cycle after this node reboots itself
@reboot sleep 30 && /usr/local/sbin/cluster-update-cycle.sh resume
```

Both lines are safe to put on every node in the cluster: `start` takes a cluster-wide
lock (`/etc/pve/priv/cluster-update-cycle.owner`) so only one node actually drives a
cycle, and `resume` exits immediately unless this node has a cycle waiting on it.

## Usage

```
cluster-update-cycle.sh start    # begin (or resume) a cycle
cluster-update-cycle.sh resume   # resume after a self-reboot (meant for @reboot)
cluster-update-cycle.sh plan     # read-only: what a cycle started now would do
cluster-update-cycle.sh status   # current cycle state + plan
```

Run `plan` any time to sanity-check your config — it reports quorum safety, which
nodes need a reboot, which HA services would be evacuated from each, and flags any
critical guest that isn't actually HA-managed.

## Configuration

See [cluster-update-cycle.conf.example](cluster-update-cycle.conf.example), installed
to `/etc/cluster-update-cycle.conf` (override the path with
`CLUSTER_UPDATE_CYCLE_CONF`). Keep it `chmod 600` — the webhook URL is a secret.

- `WEBHOOK_URL` — JSON notifications; see below. Empty disables them.
- `CRITICAL_SIDS` — HA guests (e.g. `vm:104`) that must be confirmed running on
  another node, and optionally answering a guest-agent ping, before their current
  node is rebooted.
- `CRITICAL_AGENT_PING` — also require the QEMU guest agent to answer for critical
  VMs. Set `0` if a critical VM has no guest agent.
- `PARK_SIDS` — HA guests shut down for the whole cycle (to free memory on the
  remaining nodes) and started again at the end.
- `NODES` — nodes to manage. Empty means every cluster member.
- `EVACUATE_TIMEOUT`, `REBOOT_TIMEOUT`, `HEALTH_TIMEOUT`, `SETTLE_TIMEOUT` — seconds.

## What it doesn't do

The script's job ends at "node rebooted, HA settled, critical guests healthy." It
does not track or restart whatever non-HA guests happened to be running on a node
before its reboot — that's what each guest's own `onboot` flag is for. Set
`onboot: 1` (in the guest's PVE options) on anything you want to come back up
automatically after a reboot, planned or not.

## Notifications

If `WEBHOOK_URL` is set, the script POSTs a plain JSON body at the start, end, and
on failure of a cycle:

```json
{
  "status": "success",
  "message": "Cluster update cycle complete. cycle=20260101-030000 quorum=OK rebooted=[pve2 pve3] critical:vm:104=running@pve1",
  "cycle_id": "20260101-030000",
  "node": "pve1",
  "time": "2026-01-01T03:17:42-05:00"
}
```

`status` is one of `info`, `success`, or `failure`. This isn't shaped for any one
notification service — it's a generic JSON object, so it works with anything that
can receive a webhook and inspect fields: a Home Assistant `webhook` automation
trigger, Node-RED, n8n, a small receiving script, etc. Services that expect a
specific payload shape (Slack's `{"text": ...}`, Discord's `{"content": ...}`) need
a small transform in between — point `WEBHOOK_URL` at that instead of the service
directly.

## State

Cycle state lives in `/var/lib/cluster-update-cycle/state` and survives across the
self-reboot so `resume` can pick back up. `status` prints it raw alongside the plan.
If a cycle is interrupted (crash, manual abort), the next `start` logs that and
begins a fresh cycle — nodes already confirmed rebooted are detected again via
`pvecm`/kernel version and skipped.

## Safety notes

- A cycle refuses to reboot a node unless the cluster would stay quorate with that
  node removed, and all nodes are online, before every reboot — not just at the
  start.
- If evacuation, a critical-guest check, or HA settling fails partway through, the
  cycle halts without rebooting the affected node and leaves everything else as-is
  for manual review (see the failure notification / log for why).
- Parked guests (`PARK_SIDS`) are only restarted if the rest of the cycle succeeded;
  otherwise they're left stopped and the failure notification says so.
