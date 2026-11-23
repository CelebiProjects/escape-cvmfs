# Celebi on CVMFS

This directory builds and deploys a self-contained CelebiChrono Python 3.11
runtime under `/cvmfs/sw.escape.eu/celebi/<version>/`.

## Build

The normal build is performed by the `Build Celebi Tarball` GitHub Actions
workflow, which builds inside an AlmaLinux 9 x86_64 container. Supply a full,
published Celebi commit SHA as `celebi_ref`.
For a local source checkout:

```bash
CELEBI_SOURCE_DIR=/path/to/Celebi ./make_tarball.sh
```

The output is `celebi-<version>-<commit>.tar.gz` plus a SHA-256 checksum. The
version is read from the source checkout's `pyproject.toml`; the commit suffix
makes the CVMFS release label unambiguous while the project is in beta.
`SOURCE_COMMIT` records the source revision, and `PACKAGE_VERSIONS` lists the
installed packages. For local release builds, use EL9 x86_64 and Python 3.11.

## Deploy

On the CVMFS publisher, deploy the GitHub Actions artifact:

```bash
TOKEN="$GITHUB_TOKEN" ./utils/celebi-cvmfs-updater.sh --set-latest <ARTIFACT_ID>
```

The artifact must contain the tarball and its matching `.sha256` file.
This checksum verifies integrity within the artifact. Use `--force` to
replace an existing release label and `--set-latest` to move the default
symlink. Omit `--set-latest` when publishing a release without promoting it.

## Use

```bash
source /cvmfs/sw.escape.eu/celebi/latest/setup.sh
celebi-cli --help
```

The setup script checks that the selected interpreter is Python 3.11.
It defaults to the LCG 107 `x86_64-el9-gcc13-opt` interpreter, or to
`python3.11` on `PATH` if that CVMFS path is absent. Select another
compatible interpreter with `CELEBI_PYTHONBIN`. Test imports and the CLI
on EL9 before promotion to check dependencies with compiled extensions.
