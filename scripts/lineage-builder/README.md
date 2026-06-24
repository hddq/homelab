# LineageOS Builder Trigger & Orchestration

This folder contains the scripts and local manifests to execute LineageOS builds for multiple target devices using the builder VM.

## File Structure

- [build.sh](file:///home/hddq/git/homelab/scripts/lineage-builder/build.sh): Main entry wrapper that delegates to either the local orchestrator or remote worker.
- **scripts/**: Modular bash and python scripts handling different stages of the build.
  - `orchestrator.sh`: Local logic for connecting to the VM and staging files.
  - `worker/`: Remote scripts executed inside the VM (`main.sh`, `sync.sh`, `build_rom.sh`, `release.sh`, `patch_updater.py`).
- **manifests/**: Local device manifests defining vendor trees, kernels, and device trees for target builds.
  - [marble.xml](file:///home/hddq/git/homelab/scripts/lineage-builder/manifests/marble.xml): Example Xiaomi Poco F5 local manifest.

## Usage

### 1. Define Device Manifests

Place your custom local manifest file for each target device under `manifests/<device_codename>.xml`. The script uses the filename to detect valid target options and copy the correct configuration to the VM during the build initiation phase.

### 2. Execute the Build Trigger

Run the script locally on your control machine. It will automatically read configurations (VM IP, builder username) from [lineage_vm.yaml](file:///home/hddq/git/homelab/ansible/vars/lineage_vm.yaml) and guide you through triggering the build.

```bash
# General usage info:
./scripts/lineage-builder/build.sh --help

# Interactively select a target and trigger dirty build:
./scripts/lineage-builder/build.sh

# Trigger sync and clean build for POCO F5 (marble) with cherrypicks:
./scripts/lineage-builder/build.sh --device marble --sync --clean --cherrypick "489879 489705 488403"
```

### 3. Build Process Flow

1. **Host (Control Machine)**:
   - Parses arguments and extracts VM metadata from [lineage_vm.yaml](file:///home/hddq/git/homelab/ansible/vars/lineage_vm.yaml).
   - Prompts for device selection if not specified.
   - Uploads the selected device manifest to the builder VM as `.repo/local_manifests/manifest.xml` (clearing other manifests to avoid repo synchronization conflicts).
   - Uploads the wrapper `build.sh` and the entire `scripts/` directory to the VM.
   - Triggers a background tmux session (`lineage-build`) running the script in `--worker` mode.
   - Prints instructions on how to manually connect to the tmux session on the VM to monitor the build. The script then exits, and the build continues executing in the background.

2. **VM (Build Worker)** (`scripts/worker/main.sh`):
   - Sets up build directory structure (`~/android/lineage`).
   - If `--sync` is requested, performs `repo sync` (using all available cores).
   - Initializes environment via `build/envsetup.sh` and runs `breakfast <device>`.
   - Cherrypicks Gerrit changes using `repopick` if specified.
   - Patches `lineage.updater.uri` in the device makefiles to point to your OTA repository.
   - Runs `mka clobber` if `--clean` is specified, then starts compilation via `mka bacon`.
   - Creates a GitHub Release for `hddq/lineage-ota` and uploads the output ZIP.
   - Generates/updates the OTA update metadata inside the `lineage-ota` repository at `test/<device_codename>.json` (using the new LineageOS API v2 format) and pushes it to the `main` branch.
