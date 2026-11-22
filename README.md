# NFS Server Setup and Management Toolkit

An automated, menu-driven Bash toolkit designed for setting up, managing, and auditing a Network File System (NFS) server on Ubuntu (22.04 LTS and 24.04 LTS) for isolated lab networks.

Developed as an **Operating Systems Course Project**, this toolkit emphasizes defensive systems programming, clear privilege boundaries, non-destructive workflows, and thorough validation.

---

## Table of Contents
1. [Purpose & Key Highlights](#purpose--key-highlights)
2. [Ubuntu Requirements & Prerequisites](#ubuntu-requirements--prerequisites)
3. [Architecture & Safety Design](#architecture--safety-design)
4. [Installation & Setup](#installation--setup)
5. [Complete Step-by-Step Procedure: Setup, Connect & Teardown](#complete-step-by-step-procedure-setup-connect--teardown)
6. [Usage & Menu Walkthrough](#usage--menu-walkthrough)
7. [CLI Flags & Dry-Run Mode](#cli-flags--dry-run-mode)
8. [NFS Export Options Explained](#nfs-export-options-explained)
9. [Client-Side Instructions](#client-side-instructions)
10. [Security Notes & Best Practices](#security-notes--best-practices)
11. [Troubleshooting](#troubleshooting)

---

## Purpose & Key Highlights

Network File System (NFS) provides remote distributed file access across UNIX-like machines. In an educational lab environment, misconfigured NFS exports can expose root filesystems, allow remote root privilege escalation, or inadvertently expose services to untrusted networks.

This toolkit addresses these operational challenges with:
- **Interactive Menu Interface**: Clean, guided workflow with confirmation gates before any system alteration.
- **Strict Environment Detection**: Audits Ubuntu distribution, kernel release, required tools (`exportfs`, `systemctl`, `ss`), active network interfaces, and sudo privileges.
- **Strict Environment & Network Detection**: Audits Ubuntu distribution, kernel release, required tools (`exportfs`, `systemctl`, `ss`), active network interfaces, sudo privileges, and **automatically calculates the local lab subnet from the device's active IP address** (e.g. `192.168.1.10/24` -> `192.168.1.0/24`).
- **Dynamic Subnet Recommendations**: Pre-populates the export authorization prompt with the auto-detected device subnet so administrators can accept it with a single press of Enter, while still supporting custom subnets or multi-interface servers.
- **Idempotent Managed Exports**: Configures exports inside an isolated delimiter block (`# >>> BEGIN NFS-TOOLKIT MANAGED EXPORT >>>`), preserving all unrelated manual exports in `/etc/exports`.
- **Pre-Flight Validation & Automatic Backups**: Backs up `/etc/exports` with microsecond timestamps and validates proposed syntax before applying changes to disk.
- **Dry-Run Simulation**: Enables full execution without touching system configuration or installing packages (`--dry-run` or menu toggle).
- **Safe Defaults**: Restricts access to explicit lab subnets (default: `192.168.1.0/24`), rejects wildcard (`*`) and global exposure (`0.0.0.0/0`), disallows exporting `/` or `/home`, and mandates `root_squash`.
- **Audit Logging**: Logs all actions and errors with timestamps to `nfs-toolkit.log` without recording passwords or secrets.

---

## Ubuntu Requirements & Prerequisites

### Target Platform
- **Operating System**: Ubuntu 22.04 LTS (Jammy Jellyfish) or Ubuntu 24.04 LTS (Noble Numbat). Also compatible with Debian 11/12 and Ubuntu 20.04 LTS.
- **Shell**: Bash 4.4+.
- **User Privileges**: Standard user with `sudo` permissions or `root`.

### System Dependencies
The toolkit detects these packages and utilities:
- `nfs-kernel-server` (Server package providing kernel threads and `exportfs`)
- `systemd` / `systemctl` (Service daemon management)
- `iproute2` (`ip` command) or `net-tools` (`ifconfig`)
- `ss` or `netstat` (Socket inspection on port 2049 / 111)
- Standard core utilities: `awk`, `sed`, `grep`, `cp`, `chmod`

---

## Architecture & Safety Design

```
+-------------------------------------------------------------------------+
|                         nfs-toolkit.sh (UI / CLI)                       |
+-------------------------------------------------------------------------+
       |                         |                          |
       v                         v                          v
 [Diagnostics]           [Config & Safety]          [State Management]
 - OS / Kernel check     - Path Safety Validator    - Timestamped Backups
 - Sudo Privilege check  - Subnet CIDR Validator    - Delimited Block parser
 - Port & Service audit  - ro/rw & Squash Checks    - Atomic exportfs test
       |                         |                          |
       +-------------------------+--------------------------+
                                 |
                                 v
               +-----------------------------------+
               | Live System: /etc/exports         |
               | (Only managed block is modified)  |
               +-----------------------------------+
```

### Safety Principles Enforced:
1. **Never Export Whole Filesystem**: Absolute paths like `/`, `/home`, `/root`, `/etc`, `/sys`, `/proc`, and `/boot` are rejected by path validation.
2. **Never Expose to Wildcards**: Wildcard patterns (`*` or `0.0.0.0/0`) are rejected. Clients must belong to an explicit IP or lab CIDR subnet (e.g. `192.168.1.0/24`).
3. **No Automatic Firewall Alterations**: The toolkit never modifies UFW or iptables rules behind the administrator's back. Clear copy-paste commands are printed instead.
4. **No Direct Remote Testing Claims**: The script never claims client access works until empirically verified from an authorized client.
5. **No `eval` Execution**: All command invocations and variables are strictly quoted and executed directly.

---

## Installation & Setup

1. Clone or download the repository to your Ubuntu server:
   ```bash
   cd ~/Documents/NFS-Server
   ```

2. Make the script executable:
   ```bash
   chmod +x nfs-toolkit.sh
   ```

3. (Optional) Run the non-interactive diagnostic check:
   ```bash
   ./nfs-toolkit.sh --check
   ```

---

## Complete Step-by-Step Procedure: Setup, Connect & Teardown

Follow this end-to-end procedure on an authorized Ubuntu server and client machine.

### Phase 1: Pre-Flight Check & Package Installation
1. **Launch the Toolkit**:
   ```bash
   ./nfs-toolkit.sh
   ```
2. **Install NFS Server Package**:
   - In the menu, select **`2`** (*Install NFS Kernel Server Package*).
   - Review the planned changes (`nfs-kernel-server`, `rpcbind`).
   - At the prompt: `Do you authorize updating apt caches and installing 'nfs-kernel-server'? [y/N]:` $\rightarrow$ Type **`y`** and press Enter.

### Phase 2: Configure & Publish the NFS Export
1. In the menu, select **`3`** (*Configure & Apply Managed Export Entry*).
2. **Step 1 - Directory to Share**:
   - Press **`Enter`** to accept the standard default `/srv/nfs/labshare`, **OR** type any custom directory path (e.g. `/home/munsi/Documents` or `~/my_share`).
   - If the directory does not exist, type **`y`** to let the toolkit create it.
   - If asked to configure permissions (`nobody:nogroup`, `chmod 775`), type **`y`**.
3. **Step 2 - Target Subnet**:
   - Press **`Enter`** to accept your auto-detected device subnet (e.g., `192.168.0.0/24` or `192.168.1.0/24`).
4. **Step 3 - Access Permissions**:
   - Press **`1`** for Read-Only (`ro`), or **`2`** for Read-Write (`rw`). If `2` is selected, acknowledge the security warning with **`y`**.
5. **Step 4 - Write Synchronization**:
   - Press **`1`** for Synchronous (`sync`, recommended for data integrity).
6. **Step 5 - Root Squash**:
   - Press **`1`** for `root_squash` (secure default: maps remote UID 0 to `nobody`).
7. **Step 6 - macOS & Windows Compatibility**:
   - Press **`y`** to enable `insecure` (allows client RPC connections from unprivileged high ports > 1024).
8. **Validation & Apply**:
   - Type **`y`** to validate and apply the export entry.
   - The toolkit validates syntax, applies the configuration, reloads active exports via `sudo exportfs -ra`, and immediately displays your **Quick Connect Links**.

### Phase 3: Connect from Client Devices

Copy and paste the appropriate link or command from the generated Quick Connect banner:

#### A. From macOS:
- **GUI (Finder)**:
  1. Click desktop $\rightarrow$ Press **`Cmd + K`** (*Connect to Server*).
  2. Paste URI: `nfs://<SERVER_IP>/<SHARE_PATH>` (e.g., `nfs://192.168.0.10/home/munsi/Documents`).
  3. Click **Connect**.
- **CLI (Terminal)**:
  ```bash
  sudo mkdir -p /Volumes/labshare
  sudo mount -t nfs -o resvport 192.168.0.10:/home/munsi/Documents /Volumes/labshare
  ```

#### B. From Windows (Pro, Enterprise, Education):
1. Enable NFS client in Administrator PowerShell (one-time):
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly, ClientForNFS-Infrastructure -NoRestart
   ```
2. Mount as a network drive in Command Prompt or PowerShell:
   ```cmd
   mount -o anon \\192.168.0.10\home\munsi\Documents Z:
   ```
3. Open File Explorer to access drive `Z:`.

#### C. From Another Linux Machine:
1. Install client package:
   ```bash
   sudo apt update && sudo apt install -y nfs-common
   ```
2. Mount the share:
   ```bash
   sudo mkdir -p /mnt/labshare
   sudo mount -t nfs -o sync,hard,intr 192.168.0.10:/home/munsi/Documents /mnt/labshare
   ```

### Phase 4: Verify Permissions & Root Squash
On your client machine:
1. **Read Verification**: List and view files inside the mounted directory.
2. **Write Verification (If `rw`)**:
   ```bash
   touch /mnt/labshare/test_file.txt
   echo "NFS Lab Verification" > /mnt/labshare/test_file.txt
   ```
3. **Root Squash Verification**:
   ```bash
   sudo touch /mnt/labshare/root_test.txt
   ls -la /mnt/labshare/root_test.txt
   ```
   *(Notice that the file is owned by `nobody:nogroup`, proving `root_squash` successfully blocked remote root privileges).*

### Phase 5: Unmount & Full Server Teardown
1. **Unmount on Client First**:
   - Linux: `sudo umount /mnt/labshare`
   - macOS: `sudo umount /Volumes/labshare` (or click Eject in Finder sidebar)
   - Windows: `umount Z:`
2. **Stop NFS Service Completely on Server**:
   - In `./nfs-toolkit.sh`, select **`8`** (*Remove Managed Export & Stop NFS Services Completely*).
   - Confirm with **`y`**.
   - The toolkit cleanly deletes the managed block from `/etc/exports`, flushes the kernel table (`exportfs -au`), stops and disables `nfs-kernel-server` systemd services, and verifies that ports 2049 and 111 are closed.

Launch the interactive interface:
```bash
./nfs-toolkit.sh
```

### Menu Options Overview:
```
========================================================================
         NFS SERVER SETUP AND MANAGEMENT TOOLKIT v1.2.0
         Operating Systems Course Project - Lab Administration
========================================================================
 [Dry-Run Mode: OFF] | Target Subnet: 192.168.1.0/24

  Setup & Diagnostics:
    1) Run System & Environment Diagnostics
    2) Install NFS Kernel Server Package (with safety checks)
    3) Configure & Apply Managed Export Entry

  Management & Operations:
    4) List Active NFS Exports (/etc/exports & /var/lib/nfs/etab)
    5) Inspect NFS Service & Network Ports (2049, 111)
    6) Reload Active Exports (exportfs -ra)
    7) Remove Toolkit-Managed Export Block (preserve unrelated)
    8) Remove Managed Export & Stop NFS Services Completely (Full Teardown)

  Reference, Security & Utilities:
    9) View Client-Side Mount & Unmount Instructions
   10) View Ownership, Permissions, UID/GID & Security Guidance
   11) Toggle Dry-Run Mode
   12) View Activity & Audit Log
    0) Exit
========================================================================
```

### Option Walkthrough:
- **1) System Diagnostics**: Detects Ubuntu version, checks for required tools, inspects network interfaces, tests sudo privileges, and checks current `/etc/exports` status.
- **2) Install NFS Server**: Explains package dependencies (`nfs-kernel-server`, `rpcbind`), kernel implications, and requests confirmation before running `apt-get install`.
- **3) Configure Managed Export**:
  - **Directory Selection**: Choose standard lab share (`/srv/nfs/labshare`) OR enter any custom user-input directory (e.g. `~/my_share`, `/data/lab`). Offers to configure permissions (`nobody:nogroup`, `775`) automatically.
  - **Client & Subnet Selection**: Automatically detects device IP and calculates subnet (e.g. `192.168.1.0/24`). Supports custom CIDR or single IP.
  - **Permissions & Sync**: Selects `ro` vs `rw` (warns on `rw`) and `sync` vs `async`.
  - **Root Squash**: Configures `root_squash` (default) vs `no_root_squash` (privilege escalation warning).
  - **OS Compatibility**: Toggles `insecure` to allow high unprivileged ports from macOS and Windows.
  - **Auto-Generated Connect Links**: Automatically outputs ready-to-copy mount URIs (`nfs://...`), Linux mount commands, and Windows drive mapping commands.
- **4) List Active Exports**: Inspects both `/etc/exports` and `/var/lib/nfs/etab`, displaying active quick connect links.
- **5) Service Status**: Shows systemd unit state (`nfs-kernel-server`, `rpcbind`), checks listening ports (`2049` for NFS, `111` for rpcbind), and provides restart/enable actions.
- **6) Reload Active Exports**: Runs `exportfs -ra` to immediately apply configuration changes without dropping client sessions.
- **7) Remove Managed Export**: Safely strips the toolkit-managed block from `/etc/exports`, creating a backup first, while preserving all custom manual entries.
- **8) Full Teardown & Stop Services**: Completely revokes the export, unexports kernel tables (`exportfs -au`), stops and disables `nfs-kernel-server` systemd services, and verifies ports 2049/111 are closed.
- **9) Client Instructions**: Displays copy-pasteable client commands for Linux, macOS (Finder / Terminal), and Windows (CMD / PowerShell).
- **10) Security Guidance**: Details UID/GID mismatch risks, NFSv4 identity mapping, and root squash architecture.
- **11) Toggle Dry-Run**: Toggles simulation mode on and off at runtime.
- **12) Activity Log**: Displays recent entries from `nfs-toolkit.log`.

---

## CLI Flags & Dry-Run Mode

The toolkit supports non-interactive flags for scripted environments or testing:

| Flag | Long Option | Description |
|---|---|---|
| `-d` | `--dry-run` | Launch with dry-run mode enabled (no system modifications) |
| `-c` | `--check` | Execute system diagnostics non-interactively and exit |
| `-l <path>` | `--log <path>` | Direct log outputs to a custom file |
| `-e <path>` | `--exports <path>`| Use a custom export file path (useful for sandboxed test suites) |
| `-h` | `--help` | Display syntax and flag documentation |
| `-v` | `--version` | Display toolkit version |

### Example: Running Non-Destructive Dry Run
```bash
./nfs-toolkit.sh --dry-run
```

---

## NFS Export Options Explained

| Option | Category | Purpose | Recommendation |
|---|---|---|---|
| `ro` | Access | Read-Only. Remote clients cannot create, alter, or remove files. | **Recommended for distribution** |
| `rw` | Access | Read-Write. Remote clients can modify and delete files in the share. | Use with caution |
| `sync` | Integrity | Guarantees changes are committed to physical disk before replying to client. | **Default & strongly recommended** |
| `async` | Performance | Replies to client before writing to disk. Higher throughput, risk of corruption. | Avoid in production |
| `root_squash` | Security | Maps remote UID 0 (root) to `nobody:nogroup` (UID 65534). | **Mandatory default** |
| `no_root_squash` | Security | Allows remote root to retain root privileges on server share. | **High vulnerability (Lab only)** |
| `no_subtree_check` | Reliability | Disables subtree checking. Improves transfer reliability when subdirectories are renamed. | Standard best practice |
| `insecure` | Compatibility | Permits client RPC requests originating from unprivileged ports (>= 1024). | **Mandatory for macOS/Windows clients** |
| `all_squash` | Mapping | Maps all connecting remote users (regardless of UID) to anonymous user. | Useful for public repositories |

---

## Client-Side Instructions

> **Note**: Do not run client commands on the NFS server. Run these on an authorized client in the lab subnet (e.g., `192.168.1.50`).

### 1. Install Client Tools (Ubuntu / Debian)
```bash
sudo apt update && sudo apt install -y nfs-common
```

### 2. Check Available Exports from Server
```bash
showmount -e 192.168.1.10
```
*(Replace `192.168.1.10` with your server's actual IP address)*

### 3. Create Local Mount Point and Mount
```bash
sudo mkdir -p /mnt/labshare
sudo mount -t nfs -o rw,sync,hard,intr 192.168.1.10:/srv/nfs/labshare /mnt/labshare
```

### 4. Verify Mount Status
```bash
df -hT /mnt/labshare
mount | grep nfs
```

### 5. Safe Client Unmount
```bash
sudo umount /mnt/labshare
```
If the server is unreachable or hanging:
```bash
sudo umount -l /mnt/labshare    # Lazy unmount
```

### 6. Permanent Client Mount (`/etc/fstab`)
Add to `/etc/fstab` on the Linux client:
```text
192.168.1.10:/srv/nfs/labshare  /mnt/labshare  nfs  defaults,_netdev,auto,nofail  0  0
```

---

### macOS Client Instructions

macOS includes native NFS client support.

1. **Terminal Command (CLI)**:
   ```bash
   sudo mkdir -p /Volumes/labshare
   sudo mount -t nfs -o resvport,rw 192.168.1.10:/srv/nfs/labshare /Volumes/labshare
   ```
   > **Note on `resvport`**: macOS connects from an unprivileged port (> 1024) by default. The `-o resvport` flag forces macOS to use a reserved privileged port (< 1024). If your Linux server export includes `insecure`, `-o resvport` is optional.

2. **Finder GUI**:
   - In Finder, press **`Cmd + K`** (Connect to Server).
   - Enter: `nfs://192.168.1.10/srv/nfs/labshare`
   - Click **Connect** (Requires the server export to have `insecure` enabled).

3. **Unmount on macOS**:
   ```bash
   sudo umount /Volumes/labshare
   # Or using diskutil:
   diskutil unmount /Volumes/labshare
   ```

---

### Windows Client Instructions

Windows 10 and 11 (Pro, Enterprise, and Education editions) include a native **Client for NFS**.

1. **Enable "Client for NFS" Feature**:
   Open PowerShell as Administrator:
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly, ClientForNFS-Infrastructure -NoRestart
   ```
   *(Or navigate to: Control Panel -> Programs and Features -> Turn Windows features on or off -> check Services for NFS -> Client for NFS)*.

2. **Mount Share (Command Prompt or PowerShell)**:
   ```cmd
   mount -o anon \\192.168.1.10\srv\nfs\labshare Z:
   ```
   The share will appear as drive `Z:` in File Explorer.

3. **Unmount on Windows**:
   ```cmd
   umount Z:
   ```

4. **Windows UID/GID Matching**:
   By default, Windows connects as Anonymous UID `-2`. To map your Windows user to UID `1000`:
   - Open Registry Editor (`regedit`).
   - Navigate to `HKLM\SOFTWARE\Microsoft\ClientForNFS\CurrentVersion\Default`.
   - Create two `DWORD (32-bit)` values:
     - `AnonymousUid` = `1000` (Decimal)
     - `AnonymousGid` = `1000` (Decimal)
   - Restart the Windows NFS Client service:
     ```cmd
     nfsadmin client stop
     nfsadmin client start
     ```
   *(Windows Home Edition note: Windows Home lacks the native NFS client feature; use WSL2 with Ubuntu inside Windows instead).*

---

## Security Notes & Best Practices

1. **UID/GID Trust Boundary**:
   NFSv3 assumes the client's reported UID/GID is authentic. If user `student` is UID 1001 on the client, the server writes files with UID 1001. Ensure UID/GID consistency across systems or utilize NFSv4 `idmapd`.

2. **The Danger of `no_root_squash`**:
   If an export specifies `no_root_squash`, an attacker with root on any client machine in the subnet can create a setuid root binary (e.g., `chmod u+s shell`), which can then be executed on the server or other clients to obtain root privileges.

3. **Firewall Lockdown (UFW)**:
   Do not open port 2049 globally. Restrict it to the lab subnet:
   ```bash
   sudo ufw allow from 192.168.1.0/24 to any port nfs comment 'NFS Lab Share'
   ```

4. **Directory Ownership**:
   Ensure the exported directory has permissions compatible with `nobody:nogroup`:
   ```bash
   sudo chown -R nobody:nogroup /srv/nfs/labshare
   sudo chmod -R 775 /srv/nfs/labshare
   ```

---

## Troubleshooting

- **`RPC: Program not registered`**:
  NFS service is not running or RPC daemon failed to bind.
  ```bash
  sudo systemctl restart rpcbind
  sudo systemctl restart nfs-kernel-server
  ```
- **`mount.nfs: access denied by server while mounting`**:
  1. The client's IP is not within the authorized CIDR subnet configured in `/etc/exports`.
  2. The export table has not been reloaded. Run `./nfs-toolkit.sh` and select Option 6 (`exportfs -ra`).
  3. Server firewall is dropping the connection. Check `sudo ufw status`.
- **`Stale file handle`**:
  The exported directory was recreated or unmounted on the server while the client held an open mount. Unmount lazily on the client (`sudo umount -l /mnt/labshare`) and remount.
