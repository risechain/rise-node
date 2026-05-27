# RISE Node

Blazingly fast Ethereum rollup that reaches 1 Gigagas/s for enormous blocks and is 6~18 times faster than OP.

## Hardware Requirements
Below are suggested minimum hardware requirements for full node.
- Disk: At least 1TB (NVMe recommended)
- Memory: 16GB+
- CPU: High clock speeds.

If you're using AWS, we recommend at least `c6id.4xlarge` instance with a 6000 IOPS disk enabled.

## How to run RISE full node.

This guide will help you set up a full node on our Mainnet.

### Generate the jwt token

```sh
$ ./generate-jwt.sh
```

### Prepare your config

```sh

$ cp env.example .env

# To run RISE Mainnet node
$ cp env.mainnet .env
```

Config your Ethereum L1 RPC

### Run the full node from snapshot

We take a snapshot of the full node once every day. You can use these snapshots to speed up your node synchronization.

The archive includes the databases for both the execution and consensus layers, specifically `l2_data` and `safedb_data`.

Snapshots are hosted on Cloudflare R2 and are available over HTTPS. Make sure to download and extract the archive into your node’s data directory (default is `./data`).

### Latest snapshot

You can download the latest snapshot using the following URL:

- Mainnet: https://snapshot.mainnet.risechain.com/rise-mainnet.snapshot_{date}.tar.zst
- Testnet: currently unavailable

Snapshot filename format: `rise-mainnet.snapshot_{date}.tar.zst`
- `{date}` is "YYYYMMDD"

Example snapshot url:
`https://snapshot.mainnet.risechain.com/rise-mainnet.snapshot_20260518.tar.zst`

You can alway find a snapshot of yesterday.

### Download and decompress
```sh
mkdir -p /mnt/data

cd /mnt/data

wget --continue --tries=0 -O rise-mainnet.tar.zst https://snapshot.mainnet.risechain.com/rise-mainnet.snapshot_20260518.tar.zst
```
Or using `aria2c`:
```sh
aria2c -o rise-mainnet.tar.zst -s14 -x14 -k100M https://snapshot.mainnet.risechain.com/rise-mainnet.snapshot_{date}.tar.zst
```

Decompress:
```sh
tar -I zstd -xvf rise-mainnet.tar.zst
```

### Start the node

```sh
cd rise-node/
docker compose -p rise -f docker-compose.yml -f monitor.yml up -d
```

After starting the node, you can monitor your chain via the Grafana dashboard. The default login credentials are:
- username: admin
- password: admin

![dashboard](./assets/dashboard.png)
