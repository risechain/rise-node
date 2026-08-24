#!/usr/bin/env bash
# Install and run a RISE replica node as native systemd services (no docker).
#
#   sudo ./scripts/install.sh --network testnet [--data-dir /mnt/data] [--l1-rpc <url>] [--no-start]
#
# Supported: Ubuntu 20.04+, Amazon Linux 2023, CentOS Stream 9 / RHEL 9 family.
# rise-exec is dynamic: needs glibc >= 2.30 — CentOS 7 / CentOS-RHEL 8 are docker-compose only.
set -euo pipefail
# secrets (node.env carries the L1 key) must never be world-readable, even briefly
umask 077

NETWORK=""
DATA_DIR=""
PREFIX="/opt/rise-node"
START=true
L1_RPC_OVERRIDE=""
ORAS_VERSION="1.3.3"

usage() { grep '^#   ' "$0" | sed 's/^#   //'; exit "${1:-1}"; }
# value-taking flags must actually have their value (set -u would die cryptically)
need_arg() { [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --network)  need_arg "$@"; NETWORK="$2"; shift 2 ;;
    --data-dir) need_arg "$@"; DATA_DIR="$2"; DATA_DIR_FLAG="$2"; shift 2 ;;
    --l1-rpc)   need_arg "$@"; L1_RPC_OVERRIDE="$2"; shift 2 ;;
    --no-start) START=false; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root (sudo)" >&2; exit 1; }

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT

# Settings survive re-runs: CLI flag > .env > what the installed node already uses
INSTALLED_ENV="$PREFIX/etc/node.env"
# never fails, even before first install (pipefail-safe)
installed_get() { sed -n "s/^$1=//p" "$INSTALLED_ENV" 2>/dev/null | head -1 || true; }
# pipefail-safe .env lookup, tolerant of `export X=`, quoted values and CRLF
dotenv_get() { sed -n "s/^export //;s/^$1=//p" "$REPO_DIR/.env" 2>/dev/null | head -1 | sed "s/\r\$//;s/^[\"']//;s/[\"']\$//" || true; }
[ -z "$NETWORK" ] && NETWORK=$(dotenv_get NETWORK)
[ -z "$NETWORK" ] && NETWORK=$(installed_get NETWORK)
[ -n "$NETWORK" ] || { echo "ERROR: pass --network mainnet|testnet (first install)" >&2; exit 1; }
case "$NETWORK" in mainnet|testnet) ;; *) echo "ERROR: --network must be mainnet|testnet" >&2; exit 1 ;; esac
installed_net=$(installed_get NETWORK)
if [ -n "$installed_net" ] && [ "$installed_net" != "$NETWORK" ]; then
  echo "ERROR: this host is installed for '$installed_net' but network resolves to '$NETWORK'." >&2
  echo "       Switching networks needs a fresh data dir: wipe $PREFIX and pass --network + --data-dir explicitly." >&2
  exit 1
fi
[ -z "$DATA_DIR" ] && DATA_DIR=$(installed_get DATA_DIR)
[ -z "$DATA_DIR" ] && DATA_DIR="/mnt/data"

ENV_FILE="$REPO_DIR/env.$NETWORK"
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
# .env (the user's copy, shared with docker-compose) overrides the preset.
# Imported per-key, never shell-sourced: URLs with & or ; must stay literal.
if [ -f "$REPO_DIR/.env" ]; then
  echo "==> Applying overrides from .env"
  CHOSEN_NETWORK="$NETWORK"
  for v in NETWORK CHAIN_CONFIG_DIR L1_RPC_URL L1_RPC_KIND L1_TRUST_RPC PUBLIC_RPC \
           DA_SERVER P2P_STATIC RISE_EXEC_TAG RISE_NODE_TAG RISE_WITNESS_CONCURRENCY \
           RPC_GAS_CAP RPC_ETH_PROOF_WINDOW RPC_PROOF_PERMITS RPC_MAX_RESPONSE_SIZE \
           OP_NODE_P2P_GOSSIP_TIMESTAMP_THRESHOLD; do
    val=$(dotenv_get "$v")
    if [ -n "$val" ]; then eval "$v=\$val"; fi
  done
  if [ "$NETWORK" != "$CHOSEN_NETWORK" ] || [ "${CHAIN_CONFIG_DIR:-./chain/$CHOSEN_NETWORK}" != "./chain/$CHOSEN_NETWORK" ]; then
    echo "ERROR: .env repoints NETWORK/CHAIN_CONFIG_DIR away from '$CHOSEN_NETWORK' — fix .env or --network" >&2
    exit 1
  fi
  # old README said `cp env.mainnet .env`: frozen copies shadow preset updates forever
  for v in P2P_STATIC DA_SERVER PUBLIC_RPC CHAIN_CONFIG_DIR; do
    if [ -n "$(dotenv_get "$v")" ]; then
      echo "WARNING: $v in .env overrides the git-managed $NETWORK preset — remove it unless deliberate"
    fi
  done
fi
[ -n "${DATA_DIR_FLAG:-}" ] && DATA_DIR="$DATA_DIR_FLAG"
# a changed datadir would restart the node on an empty DB — moving it is manual
installed_dd=$(installed_get DATA_DIR)
if [ -n "$installed_dd" ] && [ "$installed_dd" != "$DATA_DIR" ]; then
  echo "ERROR: this host already uses data dir '$installed_dd' (requested '$DATA_DIR')." >&2
  echo "       To move it: stop rise-replica.target, move the data, edit $INSTALLED_ENV, re-run." >&2
  exit 1
fi
[ -n "$L1_RPC_OVERRIDE" ] && L1_RPC_URL="$L1_RPC_OVERRIDE"
[ -z "${L1_RPC_URL:-}" ] && L1_RPC_URL=$(installed_get L1_RPC_URL)
[ -n "${L1_RPC_URL:-}" ] || { echo "ERROR: L1_RPC_URL is empty — set it in .env or pass --l1-rpc" >&2; exit 1; }
# Version pins live in env.<network> (git) — pinning them in .env freezes upgrades
if [ -n "$(dotenv_get RISE_EXEC_TAG)$(dotenv_get RISE_NODE_TAG)" ]; then
  echo "NOTE: RISE_EXEC_TAG/RISE_NODE_TAG pinned in .env override the git preset — upgrades won't apply until you remove them"
fi
for v in RISE_EXEC_TAG RISE_NODE_TAG DA_SERVER P2P_STATIC; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is empty — an empty value in .env overrides the $NETWORK preset" >&2; exit 1; }
done

EXEC_ARTIFACT="public.ecr.aws/risechain/risechain-public/rise-exec/replica-bin"
NODE_ARTIFACT="public.ecr.aws/risechain/risechain-public/rise-op-node-bin"

# tolerate arch-suffixed tags copied from the ECR gallery — fetch appends -$ARCH itself
RISE_EXEC_TAG=${RISE_EXEC_TAG%-amd64}; RISE_EXEC_TAG=${RISE_EXEC_TAG%-arm64}
RISE_NODE_TAG=${RISE_NODE_TAG%-amd64}; RISE_NODE_TAG=${RISE_NODE_TAG%-arm64}

case "$(uname -m)" in
  x86_64)        ARCH=amd64; ARCH_MARKER="x86-64" ;;
  aarch64|arm64) ARCH=arm64; ARCH_MARKER="aarch64" ;;
  *) echo "ERROR: unsupported architecture $(uname -m) (amd64/arm64 only)" >&2; exit 1 ;;
esac

# --- OS detection -------------------------------------------------------------
. /etc/os-release
command -v systemctl >/dev/null 2>&1 || { echo "ERROR: systemd is required for the native install — use docker-compose instead" >&2; exit 1; }
SYSTEMD_VERSION=$(systemctl --version | head -1 | awk '{print $2}' | grep -o '^[0-9]*' || true)
[ -n "$SYSTEMD_VERSION" ] || { echo "ERROR: cannot parse systemd version from 'systemctl --version'" >&2; exit 1; }
echo "==> OS: $PRETTY_NAME · systemd $SYSTEMD_VERSION · arch $ARCH · network $NETWORK"

# rise-exec links against glibc — fail fast on distros that can't run it
GLIBC_MIN="2.30"
GLIBC_VER=$(ldd --version 2>/dev/null | head -1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*$' || true)
if [ -n "$GLIBC_VER" ] && [ "$(printf '%s\n' "$GLIBC_MIN" "$GLIBC_VER" | sort -V | head -1)" != "$GLIBC_MIN" ]; then
  echo "ERROR: glibc $GLIBC_VER < $GLIBC_MIN — this OS cannot run the native binaries." >&2
  echo "       CentOS 7 / CentOS-RHEL 8 are docker-only: use docker-compose instead." >&2
  exit 1
fi

# a live docker stack keeps 8545/30003 busy and its RPC would fool the health check
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -Eqx 'rise-exec|rise-node'; then
  echo "ERROR: docker containers rise-exec/rise-node are running — stop them first:" >&2
  echo "       docker compose -p rise -f docker-compose.yml -f monitor.yml down" >&2
  exit 1
fi
# same trap for any other squatter on the RPC port (only our own service may hold it)
if ! systemctl is-active --quiet rise-exec.service 2>/dev/null \
  && ss -Hltn 'sport = :8545' 2>/dev/null | grep -q .; then
  echo "ERROR: something is already listening on :8545 — stop it before installing the native node" >&2
  exit 1
fi

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then yum install -y "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  else echo "ERROR: no dnf/yum/apt-get found" >&2; exit 1
  fi
}

echo "==> Installing dependencies"
# only install what's missing — on AL2023 `dnf install curl` conflicts with curl-minimal
missing=()
for c in curl tar gzip file openssl python3 zstd; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then pkg_install "${missing[@]}" >/dev/null; fi
# aria2 is optional (snapshot downloads) and missing from AL2023/RHEL9 base repos
command -v aria2c >/dev/null 2>&1 || pkg_install aria2 >/dev/null 2>&1 || true

# --- oras (anonymous OCI artifact pulls from public ECR) ------------------------
if ! command -v oras >/dev/null 2>&1 || ! oras version 2>/dev/null | grep -qF "$ORAS_VERSION"; then
  echo "==> Installing oras $ORAS_VERSION"
  tmp="$STAGE/oras"
  mkdir -p "$tmp"
  base="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}"
  tarball="oras_${ORAS_VERSION}_linux_${ARCH}.tar.gz"
  curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
  curl -fsSL -o "$tmp/checksums.txt" "$base/oras_${ORAS_VERSION}_checksums.txt"
  (cd "$tmp" && grep " ${tarball}\$" checksums.txt | sha256sum -c - >/dev/null)
  tar -xzf "$tmp/$tarball" -C /usr/local/bin oras
  chmod 0755 /usr/local/bin/oras
fi

# --- Layout & config -----------------------------------------------------------
# restart intent = on-disk markers: a run that fails midway must not lose it
mark_restart() {
  case "$1" in exec|both) touch "$PREFIX/etc/.restart-exec" ;; esac
  case "$1" in node|both) touch "$PREFIX/etc/.restart-node" ;; esac
}
# copy_if_changed <src> <dst> <exec|node|both|none>: cp on diff + mark restart scope
copy_if_changed() {
  if ! cmp -s "$1" "$2" 2>/dev/null; then
    cp "$1" "$2"
    mark_restart "$3"
  fi
}

echo "==> Creating layout under $PREFIX"
mkdir -p "$PREFIX"/{bin,versions,etc} "$DATA_DIR"

copy_if_changed "$REPO_DIR/chain/$NETWORK/genesis.json" "$PREFIX/etc/genesis.json" exec
copy_if_changed "$REPO_DIR/chain/$NETWORK/rollup.json" "$PREFIX/etc/rollup.json" node

if [ ! -f "$PREFIX/etc/jwt.txt" ]; then
  (umask 077 && openssl rand -hex 32 | tr -d '\n' > "$PREFIX/etc/jwt.txt")
fi
chmod 0600 "$PREFIX/etc/jwt.txt"

# Endpoints and tuning consumed by the systemd units via EnvironmentFile
cat > "$STAGE/node.env" <<EOF
# Generated by install.sh ($NETWORK) — re-run install.sh to change.
NETWORK=$NETWORK
DATA_DIR=$DATA_DIR
L1_RPC_URL=$L1_RPC_URL
OP_NODE_L1_ETH_RPC=$L1_RPC_URL
DA_SERVER=$DA_SERVER
P2P_STATIC=$P2P_STATIC
RPC_GAS_CAP=${RPC_GAS_CAP:-64000000}
RPC_ETH_PROOF_WINDOW=${RPC_ETH_PROOF_WINDOW:-216000}
RPC_PROOF_PERMITS=${RPC_PROOF_PERMITS:-3}
RPC_MAX_RESPONSE_SIZE=${RPC_MAX_RESPONSE_SIZE:-500}
EOF

{
  echo "RUST_LOG=info"
  [ -n "${RISE_WITNESS_CONCURRENCY:-}" ] && echo "RISE_WITNESS_CONCURRENCY=$RISE_WITNESS_CONCURRENCY"
  true
} > "$STAGE/rise-exec.env"

cat > "$STAGE/op-node.env" <<EOF
OP_NODE_L1_EPOCH_POLL_INTERVAL=12s
OP_NODE_L1_HTTP_POLL_INTERVAL=6s
OP_NODE_L1_RPC_MAX_BATCH_SIZE=30
OP_NODE_L1_MAX_CONCURRENCY=30
OP_NODE_VERIFIER_L1_CONFS=12
OP_NODE_ALTDA_MAX_CONCURRENT_DA_REQUESTS=5
OP_NODE_P2P_GOSSIP_TIMESTAMP_THRESHOLD=${OP_NODE_P2P_GOSSIP_TIMESTAMP_THRESHOLD:-45m0s}
OP_NODE_LOG_LEVEL=INFO
EOF
{
  [ -n "${L1_RPC_KIND:-}" ] && echo "OP_NODE_L1_RPC_KIND=$L1_RPC_KIND"
  [ -n "${L1_TRUST_RPC:-}" ] && echo "OP_NODE_L1_TRUST_RPC=$L1_TRUST_RPC"
  true
} >> "$STAGE/op-node.env"
# riseops-only metadata: changing it must not restart either service
printf 'PUBLIC_RPC=%s\n' "${PUBLIC_RPC:-}" > "$STAGE/riseops.env"
# a node.env from old installs may be 0644 — tighten before cp rewrites in place
[ -f "$PREFIX/etc/node.env" ] && chmod 0600 "$PREFIX/etc/node.env"
copy_if_changed "$STAGE/node.env" "$PREFIX/etc/node.env" both
copy_if_changed "$STAGE/rise-exec.env" "$PREFIX/etc/rise-exec.env" exec
copy_if_changed "$STAGE/op-node.env" "$PREFIX/etc/op-node.env" node
copy_if_changed "$STAGE/riseops.env" "$PREFIX/etc/riseops.env" none
chmod 0600 "$PREFIX/etc/node.env"

# --- Fetch binaries (versioned store + atomic symlink switch) -------------------
# Pull the OCI artifact, verify sha256 + arch + linked libs, then activate.
fetch_component() {
  local comp="$1" artifact="$2" tag="$3" ver_dir work tarball
  ver_dir="$PREFIX/versions/$comp/$tag"
  if [ ! -x "$ver_dir/$comp" ]; then
    echo "==> Fetching $comp $tag ($ARCH)"
    mkdir -p "$ver_dir"
    work="$ver_dir/.fetch.tmp"
    rm -rf "$work"; mkdir -p "$work"
    tarball="${comp}_linux-${ARCH}.tar.gz"
    if ! (
      set -e
      oras pull --output "$work" "$artifact:$tag-$ARCH"
      cd "$work"
      sha256sum --check "${tarball}.sha256"
      tar -xzf "$tarball" "$comp"
      file -b "$comp" | grep -q "$ARCH_MARKER"
      ldd_out=$(ldd "$comp" 2>&1 || true)
      case "$ldd_out" in *"not found"*)
        echo "ERROR: $comp cannot run on this OS (libc too old?):" >&2
        echo "$ldd_out" | grep "not found" >&2
        echo "Hint: glibc >= $GLIBC_MIN required — on older distros use docker-compose instead." >&2
        exit 1 ;;
      esac
      chmod 0755 "$comp"
      mv -f "$comp" "$ver_dir/$comp"
    ); then
      rm -rf "$ver_dir"
      echo "ERROR: fetch of $comp $tag failed — partial files removed, re-run to retry" >&2
      exit 1
    fi
    rm -rf "$work"
  fi
  if [ "$(readlink "$PREFIX/bin/$comp" 2>/dev/null || true)" != "$ver_dir/$comp" ]; then
    ln -sfn "$ver_dir/$comp" "$PREFIX/bin/$comp"
    case "$comp" in rise-exec) mark_restart exec ;; op-node) mark_restart node ;; esac
  fi
  echo "    $comp -> $tag"
}

fetch_component rise-exec "$EXEC_ARTIFACT" "$RISE_EXEC_TAG"
fetch_component op-node   "$NODE_ARTIFACT" "$RISE_NODE_TAG"

# --- systemd units (with shims for pre-240 systemd) -----------------------------
echo "==> Installing systemd units"
for unit in rise-exec.service rise-node.service rise-replica.target; do
  cp "$REPO_DIR/systemd/$unit" "$STAGE/$unit"
done
if [ "$SYSTEMD_VERSION" -lt 240 ]; then
  sed -i 's/^Type=exec/Type=simple/; /^LogRateLimitBurst=/d' "$STAGE"/rise-{exec,node}.service
fi
if [ "$SYSTEMD_VERSION" -lt 235 ]; then
  sed -i '/^RuntimeDirectoryPreserve=/d' "$STAGE/rise-exec.service"
fi
if [ "$SYSTEMD_VERSION" -lt 230 ]; then
  sed -i '/^StartLimitIntervalSec=/d' "$STAGE"/rise-{exec,node}.service "$STAGE/rise-replica.target"
  sed -i '/^\[Service\]/a StartLimitInterval=0' "$STAGE"/rise-{exec,node}.service
fi
copy_if_changed "$STAGE/rise-exec.service" "/etc/systemd/system/rise-exec.service" exec
copy_if_changed "$STAGE/rise-node.service" "/etc/systemd/system/rise-node.service" node
copy_if_changed "$STAGE/rise-replica.target" "/etc/systemd/system/rise-replica.target" none

install -m 0755 "$REPO_DIR/scripts/riseops" /usr/local/bin/riseops
systemctl daemon-reload

# Re-runs must reach running services; try-restart is a no-op for inactive units
if [ "$START" = true ]; then
  if [ -f "$PREFIX/etc/.restart-exec" ]; then
    echo "==> Restarting rise-exec to apply changes"
    systemctl try-restart rise-exec.service
    rm -f "$PREFIX/etc/.restart-exec"
  fi
  if [ -f "$PREFIX/etc/.restart-node" ]; then
    echo "==> Restarting rise-node to apply changes"
    systemctl try-restart rise-node.service
    rm -f "$PREFIX/etc/.restart-node"
  fi
fi

if [ "$START" = true ]; then
  echo "==> Starting rise-replica.target"
  systemctl enable --now rise-replica.target

  echo "==> Health check (waiting for RPC on :8545)"
  for _ in $(seq 1 60); do
    b1=$(curl -sf -m 3 -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      http://127.0.0.1:8545 | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null) && break
    sleep 10
  done
  [ -n "${b1:-}" ] || { echo "ERROR: RPC not up after 10m — big datadirs can init longer; check journalctl -u rise-exec / riseops before assuming failure" >&2; exit 1; }
  echo "    head at block $b1 — run 'riseops' to watch sync progress"
else
  echo "==> Staged only (--no-start): systemctl enable --now rise-replica.target"
  if systemctl is-active --quiet rise-exec.service 2>/dev/null || systemctl is-active --quiet rise-node.service 2>/dev/null; then
    echo "WARNING: services are running — staged binaries/config are already live on disk and any restart (including crash-respawn) picks them up"
  fi
fi
echo "==> Done"
