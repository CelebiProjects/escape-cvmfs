# Yuki on CVMFS

This directory packages Yuki, Celebi, Erlang, and RabbitMQ as an immutable
Python 3.11 runtime for CVMFS. Storage, workflow state, SSH keys, RabbitMQ data,
logs, and PID files remain under the user's writable `~/.Yuki` directory.

## Build

The `Build Yuki Tarball` workflow builds inside an AlmaLinux 9 x86_64 container
and takes separate full, published commit SHAs
for `yuki_ref` and `celebi_ref`. Select compatible releases; their version
numbers do not need to be identical.

Build from local Yuki and Celebi source checkouts:

```bash
YUKI_SOURCE_DIR=/path/to/Yuki \
CELEBI_SOURCE_DIR=/path/to/Celebi \
./make_tarball.sh
```

The build requires Conda (or Mamba) and `conda-pack`. RabbitMQ defaults to
conda-forge version `4.2.5`. Use `RABBITMQ_VERSION` for a different version
that supports `deprecated_features.permit.transient_nonexcl_queues`.
`RABBITMQ_PACKAGES` records the resolved dependency versions.

The output is `yuki-<version>-<commit>.tar.gz` plus a SHA-256 checksum.
The version comes from Yuki's `pyproject.toml`. `SOURCE_COMMIT` records both
source revisions, and `PACKAGE_VERSIONS` lists the installed packages.
When Yuki requires its own Snakemake version, the build places it under
`lib/snakemake` and exposes it through `bin/snakemake`. REANA keeps its
own Snakemake dependencies in the service's Python package directory.
`NATIVE_PACKAGE_VERSIONS` records the separate CLI's dependencies.
For local release builds, use EL9 x86_64 and Python 3.11.
The packed RabbitMQ runtime embeds the destination path. To test outside
CVMFS, set `YUKI_CVMFS_PREFIX` during the build to the absolute directory
where the test tarball will be extracted.

The deployed layout is:

```text
/cvmfs/sw.escape.eu/yuki/<version>/
├── bin/
│   ├── yuki
│   ├── yuki-service
│   ├── rabbitmq-server
│   └── rabbitmqctl
├── lib/
│   ├── python3.11/site-packages/
│   ├── rabbitmq/                 # packed Erlang + RabbitMQ environment
│   └── erlang -> rabbitmq/lib/erlang
└── setup.sh
```

## Deploy

```bash
TOKEN="$GITHUB_TOKEN" ./utils/yuki-cvmfs-updater.sh --set-latest <ARTIFACT_ID>
```

The artifact must contain the tarball and its matching `.sha256` file.
This checksum verifies integrity within the artifact. Use `--force` to
replace an existing release label and `--set-latest` to move the default
symlink. Omit `--set-latest` when publishing a release without promoting it.

## Use

```bash
source /cvmfs/sw.escape.eu/yuki/latest/setup.sh
yuki-service start
```

The setup script checks that the selected interpreter is Python 3.11.
It defaults to the LCG 107 `x86_64-el9-gcc13-opt` interpreter, or to
`python3.11` on `PATH` if that CVMFS path is absent. Select another compatible
interpreter with `YUKI_PYTHONBIN`. Test imports and service startup on EL9
before promotion to check dependencies with compiled extensions.

Lifecycle commands are:

```bash
yuki-service status
yuki-service logs
yuki-service stop
yuki-service restart
```

`yuki-service start` starts the bundled RabbitMQ on `127.0.0.1:5672`,
then starts Yuki Flask and Celery. When port 5672 is occupied, the wrapper
only reuses RabbitMQ if the recorded PID, local UID and node identity match.
Stop brokers from older releases with their original wrapper before upgrading.

Use a dedicated host or an isolated runtime. Local users can reach RabbitMQ's
loopback listener and the packaged Yuki API on port 3315 has no authentication.
Restrict access to port 3315 to trusted clients.

Runtime state is created automatically:

```text
~/.Yuki/
├── RabbitMQ/{mnesia,log,rabbitmq.pid}
├── Storage/
├── Workflows/
├── logs/
└── run/
```

The default state directory is `~/.Yuki`. A dedicated service account can set
`HOME=/srv/yuki`; note that parts of Yuki still use `$HOME/.Yuki` directly, so
custom `YUKIDIR` values should match that location.
