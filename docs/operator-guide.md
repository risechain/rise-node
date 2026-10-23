# Operator guide

How a RISE node is put together, how to look inside it, which knobs to turn when debugging,
and the failure modes that come up most. Install and first start are in the [README](../README.md);
this page assumes the node is already running.

Every section covers both deployment modes:

- **Docker**: `docker-compose.yml`, README section 3a.
- **systemd**: native binaries installed by `scripts/install.sh`, README section 3b.

Commands are run from the repo checkout. **For Docker, define this helper once per shell**:

```sh
NETWORK=$(sed -n 's/^NETWORK=//p' .env)
dc() {
  [ -f docker-compose.override.yml ] && set -- -f docker-compose.override.yml "$@"
  docker compose --env-file "env.$NETWORK" --env-file .env -p rise -f docker-compose.yml -f monitor.yml "$@"
}
```

It matches the README commands (`monitor.yml` included) and picks up `docker-compose.override.yml`
whenever it exists, so `dc up -d` on upgrade never silently drops your overrides.

## 1. How a node works

| Component | Role | systemd unit | Docker container |
|---|---|---|---|
| `rise-exec` | Execution client (reth-based): state, JSON-RPC/WS for users | `rise-exec.service` | `rise-exec` |
| `op-node` | Consensus client: derivation from L1 + P2P, drives `rise-exec` | `rise-node.service` | `rise-node` |
| Stack | Starts/stops both together | `rise-replica.target` | compose project `rise` |

The two talk over an authenticated IPC socket: `/run/rise/auth_reth.ipc` (systemd) or
the shared `l2_ipc` volume (Docker). **After restarting `rise-exec`, restart `op-node` too**
(`install.sh` does this for you when it restarts rise-exec).
Otherwise op-node can hold a stale connection.

Where each head comes from. This tells you where to look when one lags:

| Head | Source | Config |
|---|---|---|
| **Unsafe** (latest) | P2P gossip from the **static peers only** (no discovery) | `P2P_STATIC` in `env.<network>` |
| **Safe** | Derived from L1 batch data **and** the alt-DA server | `L1_RPC_URL` (`.env`), `DA_SERVER` (`env.<network>`) |
| **Finalized** | L1 finality of the safe head | `L1_RPC_URL` |

It is normal for safe to trail unsafe by a few minutes, and finalized to trail further behind.

## 2. Layout and config

**Config precedence:** `env.<network>` (git-managed preset: peers, DA, version pins, tuning)
is overridden by `.env` (yours: `L1_RPC_URL`, `NETWORK`, optional overrides, see `env.example`).
Change settings in `.env`, then re-apply (re-run the installer, or `dc up -d`).

| What | systemd | Docker |
|---|---|---|
| Binaries | `/opt/rise-node/bin/{rise-exec,op-node}` (symlinks) | images `public.ecr.aws/risechain/risechain-public/...` |
| Versions on disk | `/opt/rise-node/versions/<component>/<tag>/` | `docker images` |
| Generated config | `/opt/rise-node/etc/`: `node.env`, `rise-exec.env`, `op-node.env`, `jwt.txt`, `genesis.json`, `rollup.json` | `./jwt.txt`, `chain/<network>/` |
| Unit / service definition | `/etc/systemd/system/rise-{exec,node}.service` | `docker-compose.yml` |
| Chain data | `<data-dir>/l2_data` (`--data-dir` at install) | `/mnt/data/l2_data` (fixed in `docker-compose.yml`) |
| Status CLI | `/usr/local/bin/riseops` | — |

On systemd, everything under `/opt/rise-node/etc` and the unit files is **rewritten by
`install.sh`**. Don't edit them in place. Use `.env` or a systemd drop-in (section 5).

### Ports

| Port | Service | systemd bind | Docker bind | Expose publicly? |
|---|---|---|---|---|
| 8545 / 8546 | RPC HTTP / WS | `0.0.0.0` | `0.0.0.0` | only if you serve RPC |
| 30003/tcp | op-node P2P | `0.0.0.0` | `0.0.0.0` | not needed: the node dials the static peers, so only **outbound** to their 30003 must be allowed |
| 7545 | op-node RPC | `127.0.0.1` | `0.0.0.0` | **no** |
| 9001 / 7300 | metrics (rise-exec / op-node) | `127.0.0.1` | `0.0.0.0` | **no** |

Docker publishes every port on all interfaces, and its iptables rules **bypass host firewalls such as ufw**
([Docker docs](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw)).
Keep 7545, the metrics ports and Grafana / Prometheus (3000 / 9090) private by binding them to loopback in `docker-compose.override.yml`
(`!override` needs Docker Compose v2.24.4+), or block them in your cloud firewall:

```yaml
services:
  rise-exec:
    ports: !override
      - "8545:8545"
      - "8546:8546"
      - "127.0.0.1:9001:9001"
  rise-node:
    ports: !override
      - "127.0.0.1:7545:7545"
      - "30003:30003/tcp"
      - "127.0.0.1:7300:7300"
  prometheus:
    ports: !override
      - "127.0.0.1:9090:9090"
  grafana:
    ports: !override
      - "127.0.0.1:3000:3000"
```

The bundled Prometheus scrapes over the compose network, so it keeps working.
Reach Grafana / Prometheus through an SSH tunnel, e.g. `ssh -L 3000:127.0.0.1:3000 <host>`.

## 3. Everyday commands

| Task | systemd | Docker |
|---|---|---|
| Status | `riseops` | `dc ps` + section 4 |
| Logs (follow) | `journalctl -u rise-exec -f` / `-u rise-node -f` | `docker logs -f rise-exec` / `rise-node` |
| Last errors | `journalctl -u rise-node -n 300 --no-pager` | `docker logs --tail 300 rise-node` |
| Start / stop stack | `systemctl start\|stop rise-replica.target` | `dc up -d` / `dc down` |
| Restart op-node only | `systemctl restart rise-node` | `docker restart rise-node` |
| Restart rise-exec | `systemctl restart rise-exec && systemctl restart rise-node` | `docker restart rise-exec && docker restart rise-node` |
| Upgrade | `git pull --ff-only && sudo ./scripts/install.sh` | `git pull --ff-only && dc up -d` |
| Run a specific version | `RISE_EXEC_TAG=` / `RISE_NODE_TAG=` in `.env`, re-run installer | same `.env` pins, `dc up -d` |

`riseops` judges the head by block age: under 30s means **in sync**, under 300s **lagging**,
anything older **STALLED**. `lagging`/`STALLED` is expected while the node catches up to the tip.

Remove a version pin from `.env` once you're done with it: a pin freezes the node on that version.
Rolling back does not downgrade the database. If a newer version migrated the datadir, restore a snapshot.

## 4. Inspecting a running node

On systemd, `riseops` shows the head, its age, unsafe / safe / finalized and the gap to the network in one view.
The commands below work in both modes (Docker publishes the same ports on the host) and are for Docker or for digging deeper.
`cast` comes with [Foundry](https://getfoundry.sh). Plain `curl` works too.

```sh
# rise-exec: head number and age
cast bn -r http://127.0.0.1:8545
cast block latest -f timestamp -r http://127.0.0.1:8545     # compare with: date +%s
curl -s -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545

# compare with the network (PUBLIC_RPC from env.<network>)
cast bn -r "$(sed -n 's/^PUBLIC_RPC=//p' "env.$NETWORK")"

# rise-exec internals: canonical / safe / finalized heads and engine API calls
curl -s 127.0.0.1:9001/metrics | grep -E '^reth_chain_(head_|engine_[a-z_]*(fails|messages) )'

# op-node: unsafe / safe / finalized heads and peer count
curl -s 127.0.0.1:7300/metrics | grep -E 'op_node_default_refs_number|peer_count'
```

## 5. Debug knobs

### Log level

| Component | Variable | systemd default | Docker default |
|---|---|---|---|
| rise-exec | `RUST_LOG` | `info` | `info` |
| op-node | `OP_NODE_LOG_LEVEL` | `INFO` | `DEBUG` |

Prefer narrow filters over global debug, e.g. `RUST_LOG=info,rise=debug` (all RISE components).
Global `debug`/`trace` is very noisy.

Set them in `.env`, like any other override, then re-apply:

```sh
# .env
RUST_LOG=info,rise=debug
OP_NODE_LOG_LEVEL=DEBUG
```

```sh
sudo ./scripts/install.sh            # systemd: rewrites the env files, restarts what changed
dc up -d                             # Docker: recreates the containers whose env changed

# systemd: check what the running process got
sudo cat /proc/$(systemctl show -p MainPID --value rise-exec)/environ | tr '\0' '\n' | grep RUST_LOG
```

To go back, delete the lines from `.env` and re-apply.

### Extra flags

- **systemd:** in the drop-in, clear and redefine the whole command. Copy the current one from `systemctl cat rise-exec`:
  ```ini
  [Service]
  ExecStart=
  ExecStart=/opt/rise-node/bin/rise-exec node ... --your-flag
  ```
  This freezes the flag list: unit updates shipped with later releases won't apply until you `systemctl revert` it. Use it for debugging only.
- **Docker:** set `command:` for the service in `docker-compose.override.yml`. It replaces the whole list, so copy it from `docker-compose.yml` first.

### Resource limits

- **Docker:** `deploy.resources` in `docker-compose.yml`. The defaults (rise-exec 10 CPU / 100g, op-node 2.5 CPU / 12g) assume a 128GB host. Adjust them to yours through the override file. A container that hits its memory limit is OOM-killed and restarted.
- **systemd:** no limits by default. To cap memory, add `MemoryMax=` in a drop-in. Avoid `MemoryHigh=`: it throttles forever instead of killing.

### RPC namespaces

Default: `eth,web3` on both HTTP (8545) and WS (8546), set by the rise-exec flags `--http.api` and `--ws.api`.
To change them, edit those two flags the same way as [extra flags](#extra-flags):

- **systemd:** drop-in that redefines `ExecStart=` (`systemctl edit rise-exec`), then restart rise-exec and op-node.
- **Docker:** override `command:` for `rise-exec` in `docker-compose.override.yml`, then `dc up -d`.

## 6. Common issues

Start every investigation with the status (`riseops` or section 4) and the last ~300 log lines of both components.

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Unsafe head lags, `peer_count` is 0 or low | The host can't reach the static peers. They are the only source of new blocks | [peer check](#peer-reachability-check) below | Allow **outbound** TCP to the static peers' 30003 (host firewall, cloud security group, provider network), then restart op-node. Check `P2P_STATIC` isn't overridden by a stale `.env` |
| Safe/finalized head lags or stalls, unsafe fine | L1 RPC throttled/failing, or the DA server unreachable | op-node logs: `grep -iE 'l1\|altda\|da-server\|429\|rate'` | Use an L1 RPC without rate limits (ideally your own). With a paid provider set `L1_RPC_KIND` (+ `L1_TRUST_RPC=true`) in `.env`. A throttled L1 keeps the node behind forever |
| Head far behind and advancing slowly, never catching up | Same as above. On mainnet, also a missing snapshot (syncing from genesis) | Compare `cast bn` with `PUBLIC_RPC` over a few minutes | Fix L1 first. Mainnet: start from a snapshot (README section 2) |
| op-node logs engine/IPC errors after a rise-exec restart | Stale IPC connection | op-node logs | Restart op-node |
| op-node exits at startup: `flag provided but not defined` | Binary and unit/compose flags from different releases, usually an old `RISE_NODE_TAG` pin in `.env` | `grep TAG .env` | Remove the pin, `git pull`, re-apply |
| Service keeps restarting (`activating (auto-restart)` / container `Restarting`) | Crash loop. systemd units retry forever and never park in `failed` | `systemctl show rise-exec -p NRestarts` / `docker inspect -f '{{.RestartCount}}' rise-exec` | Read the **first** error after a restart, not the last line |
| Restarts with no error in the app log | OOM kill | `journalctl -k \| grep -i oom` / `docker inspect -f '{{.State.OOMKilled}}' rise-exec` | Give the host more RAM or raise the memory limit |
| Stopping rise-exec takes minutes | The database flushes on shutdown. Both modes wait up to 300s, then SIGKILL | `journalctl -u rise-exec \| grep -E 'timed out\|status=9/KILL'` | Wait. Never `kill -9` / `docker kill`. If it was killed and the next start shows `MDBX` errors, restore from snapshot |
| `install.sh` refuses: docker containers running / something on :8545 | The Docker stack or another process holds the ports | `docker ps`, `ss -ltnp 'sport = :8545'` | Stop it first (`dc down`), then re-run the installer |
| `install.sh`: `RPC not up after 10m` | Large datadir still initializing | `journalctl -u rise-exec -f` | Usually not fatal: wait and watch `riseops` |
| Head is current but block hashes differ from the network | Node forked off the canonical chain | See [fork check](#fork-check) below | Stop, delete `l2_data`, restore a snapshot, start |

### Peer reachability check

```sh
NETWORK=$(sed -n 's/^NETWORK=//p' .env)
sed -n 's/^P2P_STATIC=//p' "env.$NETWORK" | tr ',' '\n' | awk -F/ '{print $3, $5}' \
  | while read -r ip port; do nc -zvw3 "$ip" "$port"; done
# Every peer should report "succeeded" / "Connected". A timeout means the path to that peer is blocked.
```

### Fork check

```sh
N=$(cast bn -r http://127.0.0.1:8545)
cast block "$N" -f hash -r http://127.0.0.1:8545
cast block "$N" -f hash -r "$(sed -n 's/^PUBLIC_RPC=//p' "env.$NETWORK")"
# Different hashes at the same height mean the node is on a fork.
```

## 7. Rules of operation

- **Upgrade only through git:** `git pull --ff-only`, then re-run the installer or `dc up -d`. Don't hand-edit generated files or `docker-compose.yml`. Use `.env`, drop-ins and override files.
- **Stop cleanly** and give rise-exec its time to shut down. A killed database may need a snapshot restore.
- **Keep `.env` minimal:** only your own values. Copying preset values or tag pins into `.env` stops future peer, DA and version updates from applying.
- **Keep 7545 and the metrics ports off the public internet.** systemd binds them to loopback by default; Docker publishes them on all interfaces past ufw, so rebind them to loopback ([ports](#ports)) or block them in your cloud firewall.
- **Running several nodes behind a load balancer?** Upgrade one at a time, and wait until it is in sync (`riseops`, or head age under 30s on Docker, see section 4) before moving to the next. Never take down the last healthy one.
- **Don't run Docker and systemd on the same host at once:** they compete for the same ports.
