#!/usr/bin/env bash
# Install and run a RISE replica node as native systemd services (no docker).
#
#   sudo ./scripts/install.sh --network testnet [--data-dir /mnt/data] [--l1-rpc <url>] [--no-start]
#
# Supported: Ubuntu 20.04+, Amazon Linux 2023, CentOS Stream 9 / RHEL 9 family.
# Requires glibc >= 2.30 (rise-exec is dynamic) — CentOS 7 (2.17) and
# CentOS/RHEL 8 (2.28) cannot run the binaries; use docker-compose there.
set -euo pipefail

NETWORK=""
DATA_DIR=""
PREFIX="/opt/rise-node"
START=true
L1_RPC_OVERRIDE=""
ORAS_VERSION="1.3.3"

usage() { grep '^#   ' "$0" | sed 's/^#   //'; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --network)  NETWORK="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; DATA_DIR_FLAG="$2"; shift 2 ;;
    --l1-rpc)   L1_RPC_OVERRIDE="$2"; shift 2 ;;
    --no-start) START=false; shift ;;
    -h|--help)  usage ;;
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
[ -z "$NETWORK" ] && NETWORK=$(sed -n 's/^NETWORK=//p' "$REPO_DIR/.env" 2>/dev/null | head -1)
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
set -a; . "$ENV_FILE"; set +a
# .env (the user's copy, shared with docker-compose) overrides the preset
if [ -f "$REPO_DIR/.env" ]; then
  dotenv_net=$(sed -n 's/^NETWORK=//p; s|^CHAIN_CONFIG_DIR=./chain/||p' "$REPO_DIR/.env" | head -1)
  if [ -n "$dotenv_net" ] && [ "$dotenv_net" != "$NETWORK" ]; then
    echo "ERROR: .env is configured for '$dotenv_net' but --network is '$NETWORK' — fix one of them" >&2
    exit 1
  fi
  echo "==> Applying overrides from .env"
  set -a; . "$REPO_DIR/.env"; set +a
fi
[ -n "${DATA_DIR_FLAG:-}" ] && DATA_DIR="$DATA_DIR_FLAG"
[ -n "$L1_RPC_OVERRIDE" ] && L1_RPC_URL="$L1_RPC_OVERRIDE"
[ -z "${L1_RPC_URL:-}" ] && L1_RPC_URL=$(installed_get L1_RPC_URL)
[ -n "${L1_RPC_URL:-}" ] || { echo "ERROR: L1_RPC_URL is empty — set it in .env or pass --l1-rpc" >&2; exit 1; }
# Version pins live in env.<network> (git) — pinning them in .env freezes upgrades
if grep -q '^RISE_EXEC_TAG=..*\|^RISE_NODE_TAG=..*' "$REPO_DIR/.env" 2>/dev/null; then
  echo "NOTE: RISE_EXEC_TAG/RISE_NODE_TAG pinned in .env override the git preset — upgrades won't apply until you remove them"
fi
for v in RISE_EXEC_TAG RISE_NODE_TAG DA_SERVER P2P_STATIC; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is empty — an empty value in .env overrides the $NETWORK preset" >&2; exit 1; }
done

EXEC_ARTIFACT="public.ecr.aws/risechain/risechain-public/rise-exec/replica-bin"
NODE_ARTIFACT="public.ecr.aws/risechain/risechain-public/rise-op-node-bin"

case "$(uname -m)" in
  x86_64)        ARCH=amd64; ARCH_MARKER="x86-64" ;;
  aarch64|arm64) ARCH=arm64; ARCH_MARKER="aarch64" ;;
  *) echo "ERROR: unsupported architecture $(uname -m) (amd64/arm64 only)" >&2; exit 1 ;;
esac

# --- OS detection -------------------------------------------------------------
. /etc/os-release
SYSTEMD_VERSION=$(systemctl --version | head -1 | awk '{print $2}' | grep -o '^[0-9]*')
echo "==> OS: $PRETTY_NAME · systemd $SYSTEMD_VERSION · arch $ARCH · network $NETWORK"

# rise-exec links against glibc — fail fast on distros that can't run it
GLIBC_MIN="2.30"
GLIBC_VER=$(ldd --version 2>/dev/null | head -1 | grep -o '[0-9][0-9]*\.[0-9][0-9]*$' || true)
if [ -n "$GLIBC_VER" ] && [ "$(printf '%s\n' "$GLIBC_MIN" "$GLIBC_VER" | sort -V | head -1)" != "$GLIBC_MIN" ]; then
  echo "ERROR: glibc $GLIBC_VER < $GLIBC_MIN — this OS cannot run the native binaries." >&2
  echo "       CentOS 7 / CentOS-RHEL 8 are docker-only: use docker-compose instead." >&2
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
pkg_install curl tar file openssl python3 zstd >/dev/null
# aria2 is optional (snapshot downloads) and missing from AL2023/RHEL9 base repos
pkg_install aria2 >/dev/null 2>&1 || true

# --- oras (anonymous OCI artifact pulls from public ECR) ------------------------
if ! command -v oras >/dev/null 2>&1 || ! oras version 2>/dev/null | grep -q "$ORAS_VERSION"; then
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
# Tracks whether anything a running service depends on changed (restart trigger)
CHANGED=0
copy_if_changed() {
  if ! cmp -s "$1" "$2" 2>/dev/null; then cp "$1" "$2"; CHANGED=1; fi
}

echo "==> Creating layout under $PREFIX"
mkdir -p "$PREFIX"/{bin,versions,etc} "$DATA_DIR"

copy_if_changed "$REPO_DIR/chain/$NETWORK/genesis.json" "$PREFIX/etc/genesis.json"
copy_if_changed "$REPO_DIR/chain/$NETWORK/rollup.json" "$PREFIX/etc/rollup.json"

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
PUBLIC_RPC=${PUBLIC_RPC:-}
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
for f in node.env rise-exec.env op-node.env; do
  copy_if_changed "$STAGE/$f" "$PREFIX/etc/$f"
done
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
        echo "Hint: glibc >= 2.30 required — on older distros use docker-compose instead." >&2
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
    CHANGED=1
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
for unit in rise-exec.service rise-node.service rise-replica.target; do
  copy_if_changed "$STAGE/$unit" "/etc/systemd/system/$unit"
done

install -m 0755 "$REPO_DIR/scripts/riseops" /usr/local/bin/riseops
systemctl daemon-reload

# Re-runs (version bump, config change) must actually reach the running node
if [ "$START" = true ] && [ "$CHANGED" = 1 ] && systemctl is-active --quiet rise-exec.service; then
  echo "==> Restarting services to apply changes"
  systemctl try-restart rise-exec.service rise-node.service
fi

if [ "$START" = true ]; then
  echo "==> Starting rise-replica.target"
  systemctl enable --now rise-replica.target

  echo "==> Health check (waiting for RPC on :8545)"
  for _ in $(seq 1 30); do
    b1=$(curl -sf -m 3 -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      http://127.0.0.1:8545 | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null) && break
    sleep 10
  done
  [ -n "${b1:-}" ] || { echo "ERROR: rise-exec RPC did not come up — journalctl -u rise-exec" >&2; exit 1; }
  echo "    head at block $b1 — run 'riseops' to watch sync progress"
else
  echo "==> Staged only (--no-start): systemctl enable --now rise-replica.target"
fi
echo "==> Done"
