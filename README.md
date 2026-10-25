# cluster-update-cycle

> **Work in progress.** This is a concept I run on my own three-node homelab
> cluster. It hasn't been tested widely, so read it before you trust it with yours.
> Feedback, issues and suggestions are welcome.

Built with Claude Sonnet 5 and Opus 5.5.

Rolling package update and reboot cycle for a Proxmox VE cluster of any size.

Run from cron (on every node; one of them drives each cycle). It upgrades packages on every node, then reboots
the nodes that need it one at a time: HA maintenance mode evacuates the node, any
guests you've marked critical are confirmed healthy elsewhere, the node reboots and
rejoins, and HA is left to settle before moving to the next node. The node running
the script goes last and resumes after its own reboot via an `@reboot` cron entry.

## Requirements

- Proxmox VE cluster (tested on a cluster; a single standalone node has no HA/quorum, so the quorum_allows_reboot() check will fail)
- `jq`, `flock`, `pvecm`, `pvesh`, `ha-manager` on every node that may run the script.
  All but `jq` come with PVE; `jq` isn't always installed (`apt install jq`).
- Optional: `needrestart` for more precise reboot detection. Without it, the script
  compares the running kernel with the newest installed one.
- Passwordless root SSH between nodes using PVE's own cluster host keys — this is
  already set up by Proxmox cluster join, nothing extra to configure
- Run as root, since `ha-manager`/`pvesh` and `/etc/pve/priv` require it

## Install

```sh
cp cluster-update-cycle.sh cluster-update-cycle-task /usr/local/sbin/
chmod 750 /usr/local/sbin/cluster-update-cycle.sh /usr/local/sbin/cluster-update-cycle-task

cp cluster-update-cycle.conf.example /etc/cluster-update-cycle.conf
chmod 600 /etc/cluster-update-cycle.conf
# edit /etc/cluster-update-cycle.conf for your site
```

### Cron

As `/etc/cron.d/cluster-update-cycle` on each node:

```cron
# Kick off a cycle: Sundays at 04:00
0 4 * * 0 root /usr/local/sbin/cluster-update-cycle.sh start

# Resume a cycle after this node reboots itself
@reboot root sleep 30 && /usr/local/sbin/cluster-update-cycle.sh resume
```

Both lines are safe to put on every node in the cluster, even firing in the same
minute: `start` claims the cycle by creating `/etc/pve/priv/cluster-update-cycle.lock`,
which only one node can do (pmxcfs orders all writes cluster-wide, and refuses them on
a node without quorum). The other nodes see it and exit. `resume` exits immediately
unless this node has a cycle waiting on it.

### Scheduling and supervision

Schedule cycles shortly before a time when an administrator will be around to check
the cluster and fix problems. Package upgrades restart services, and rolling reboots
temporarily reduce cluster capacity. The cycle runs unattended, but that doesn't
make it risk-free.

- **How often.** Weekly is a reasonable default for many homelabs. For urgent
  security updates, run `cluster-update-cycle.sh start` by hand; it works at any
  time.
- **Supervise the first run.** After installing or changing the config, run `plan`
  on each node, then run `start` by hand and watch
  `/var/log/cluster-update-cycle.log` on that node.
- **Make sure notifications reach you.** A failure you never hear about is the worst
  outcome. Send a sample payload to the webhook with `curl` and confirm it arrives
  somewhere you'll see it.
- **Avoid backup windows.** A guest being backed up by `vzdump` is locked and can't
  be migrated, so evacuation times out and the cycle stops. That fails safely, but
  it needlessly costs you a week. Leave a margin after your longest backup job.
- **Use the same timezone on every node.** Cron uses local time.
- **Major PVE upgrades (e.g. 8 → 9)** are a manual job. Comment out the cron line
  while you do one. The removal check usually catches a half-switched repository,
  but don't rely on it.

Cron entries don't need staggering for correctness; the lock handles that. You can
still stagger them by a few minutes to give a preferred node the first chance to
take the lock. Then you know which node's log to read. This is an operational
preference, not a safety requirement.

Keep the `@reboot` resume entry on every node that can start a cycle. Watch for
failure notifications, and make sure someone has looked into a failed cycle before
its record is cleared. The log is on the node that drove the cycle (the `owner` in
`status`).

## Usage

```
cluster-update-cycle.sh start          # begin a cycle (no-op if one is running or blocked)
cluster-update-cycle.sh resume         # resume after a self-reboot (meant for @reboot)
cluster-update-cycle.sh clear          # unblock cycles after you've dealt with a failure
cluster-update-cycle.sh clear --force  # also clear a record that still says "running"
cluster-update-cycle.sh plan           # read-only: what a cycle started now would do
cluster-update-cycle.sh status         # cycle record, local state + plan
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
  `EVACUATE_TIMEOUT` and `SETTLE_TIMEOUT` count only time with no migration task
  running for the guests still waiting to move, so a large VM can take as long as it
  needs, up to `MIGRATE_MAX_WAIT` (default 21600, i.e. 6 hours).
- `MIGRATE_ATTEMPTS` — HA retries a failed migration by itself; after this many
  failed migration tasks for one guest (default 2) the cycle stops. Each failure is
  logged with the task's error. A guest in HA `error` state stops it at once.

## What it doesn't do

The script's job ends at "node rebooted, HA settled, critical guests healthy." It
does not track or restart whatever non-HA guests happened to be running on a node
before its reboot — that's what each guest's own `onboot` flag is for. Set
`onboot: 1` (in the guest's PVE options) on anything you want to come back up
automatically after a reboot, planned or not.

## Notifications

Every event goes to up to three places, all on a best-effort basis: a failure to
notify is logged and never stops a cycle.

### Syslog

The output of `start` and `resume` (the script's own lines and apt's) goes to
`/var/log/cluster-update-cycle.log` and to the systemd journal, tagged
`cluster-update-cycle`. The journal is what **Node → System → Syslog** shows in the
PVE GUI. From a shell:

```sh
journalctl -t cluster-update-cycle --since today
```

### Task list

If `cluster-update-cycle-task` is installed (in `/usr/local/sbin`, like the script), each event also
creates a short task in the PVE task list on the driving node:

| Task type | When | Status |
|---|---|---|
| `cluster-update-start` | a cycle starts | OK |
| `cluster-update-reboot` | the driving node is about to reboot itself | OK |
| `cluster-update-result` | the cycle ends | OK, or failed with the reason |
| `cluster-update-blocked` | `start` refused because an earlier cycle needs attention | failed with the reason |

The task ID is the cycle ID. Opening a `result` task shows this cycle's log lines
(up to 500) and where to find the full log. The tasks last a second or two, so a
reboot can't interrupt them and they have no Stop button that could abort a cycle.

The helper uses Proxmox's internal Perl API (`PVE::RPCEnvironment::fork_worker`),
which comes with no compatibility promise. If an update ever breaks it, the log
shows `WARN: could not record a task` and everything else carries on. Delete the
helper to turn this off.

### Webhook

If `WEBHOOK_URL` is set, the script POSTs a plain JSON body for the same events:

```json
{
  "status": "success",
  "event": "result",
  "message": "Cluster update cycle complete. cycle=20260101-040000 quorum=OK rebooted=[pve2 pve3] critical:vm:104=running@pve1",
  "cycle_id": "20260101-040000",
  "node": "pve1",
  "time": "2026-01-01T04:17:42-07:00"
}
```

`status` is one of `info`, `success`, or `failure`, and `event` is one of `start`,
`reboot`, `result`, or `blocked`. This isn't shaped for any one notification
service. It's a generic JSON object, so it works with anything that can receive a
webhook and inspect fields: a Home Assistant `webhook` automation trigger, Node-RED,
n8n, a small receiving script, and so on. Services that expect a specific payload
shape (Slack's `{"text": ...}`, Discord's `{"content": ...}`) need a small transform
in between; point `WEBHOOK_URL` at that instead of the service directly.

## State and recovery

The script does the normal case on its own and calls for help when something is
unclear. It does not try to repair a half-finished cycle.

- **Cluster cycle record**: `/etc/pve/priv/cluster-update-cycle.lock/record`
  (owner node, cycle ID, `running` or `failed`, reason). It exists from the start of a
  cycle until the cycle succeeds. Every node can see it.
- **Local state**: `/var/lib/cluster-update-cycle/state` on the driving node. It
  survives the self-reboot so `resume` can pick back up.

How failures are handled:

- **Failure before anything changed** (quorum pre-flight, the package-removal check,
  a node that can't be reached): failure notification, record removed, and the next
  scheduled run tries again.
- **Failure after something changed** (upgrade, evacuation, reboot, rejoin, finish):
  the record is marked `failed` and left in place. Every node's `start` then refuses
  to run, and the driving node re-sends the failure notification on each scheduled
  run (any node does, if the driving node is offline). Fix what's wrong, then run
  `clear`. It lists nodes still in HA maintenance and parked guests that aren't
  running, but does not change them. Note 'clear' cannot fix your cluster for you.
- **Interrupted cycle** (crash, kill, power loss): the next `start` on the driving
  node marks it `failed`, as above. If the driving node is offline for more than 6
  hours while the record says `running`, the other nodes start sending notifications;
  use `clear --force` once you've checked.
- **`clear --force` from another node** checks the owner node over SSH first. If a
  `start` or `resume` is running there (it holds the local lock), `clear` refuses. If
  the owner can't be reached, `clear` warns and asks you to type the cycle ID. It
  refuses when not run on a terminal.
- **Record no longer ours**: the driving node checks before each node and before
  resuming. If someone cleared or replaced the record, the driving node stops without
  changing anything else.

No node ever takes over another node's cycle. A new cycle can start on any node once
the previous one succeeded or was cleared. It re-detects which nodes need a reboot,
and starts any parked guests again at its end.

## Safety notes

- A cycle refuses to reboot a node unless the cluster would stay quorate with that
  node removed, and all nodes are online, before every reboot — not just at the
  start.
- If evacuation, a critical-guest check, or HA settling fails partway through, the
  cycle halts without rebooting the affected node and leaves everything else as-is
  for manual review (see the failure notification / log for why).
- Parked guests (`PARK_SIDS`) are only restarted if the rest of the cycle succeeded;
  otherwise they're left stopped and the failure notification says so. Restarting is
  checked: a parked guest that doesn't reach `running` fails the cycle.
- Before upgrading anything, every node simulates the upgrade (`apt-get -s
  dist-upgrade`). If any node would remove a package (the classic case is broken
  repositories removing `proxmox-ve`), the cycle stops with nothing upgraded. The real
  upgrade also runs with `--no-remove`. `autoremove` is never run; clean up old
  kernels and packages yourself.
- Nodes are upgraded one at a time, with a health check after each one before the
  next starts. A bad `corosync`, `pve-cluster` or HA package therefore stops at the
  first node instead of reaching all of them. The check:
  - `corosync` and `pve-cluster` are active, plus `pve-ha-lrm` and `pve-ha-crm` when
    HA is in use;
  - the cluster is quorate with all nodes and votes present;
  - the node's HA agent (LRM) has reported since its upgrade;
  - HA has settled.

  A failure stops the cycle (sticky, like other failures after a change), and the
  notification lists which nodes were and weren't upgraded. The check adds roughly
  30–60 seconds per node.
- Reboot detection has three outcomes: needed, not needed, and couldn't tell (which
  stops the cycle). It uses `needrestart` when that gives a usable answer, and
  otherwise compares the running kernel with the newest one in `/boot`. If you pin
  an older kernel with `proxmox-boot-tool kernel pin` and don't have `needrestart`,
  that comparison reports a reboot every time.
- A reboot that is requested but never happens (the command fails, or the node never
  goes down) is reported as such, not as a timeout. If the node is clearly still up,
  its HA maintenance is turned off before the cycle fails.

## License

MIT; see [LICENSE](LICENSE). The task helper loads Proxmox VE's own Perl modules
(AGPL-3.0) at runtime; none of Proxmox's code is included in this repository.
