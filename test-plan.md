# NFS Toolkit Comprehensive Lab Test Plan

This document details safe, step-by-step procedures to verify every aspect of the **NFS Server Setup and Management Toolkit** in an isolated Ubuntu lab network.

---

## Lab Environment Topology

```
+------------------------------------+           +------------------------------------+
|            NFS Server              |           |       Authorized Lab Client        |
|  OS: Ubuntu 22.04 / 24.04 LTS      |           |  OS: Ubuntu 22.04 / 24.04 LTS      |
|  IP: 192.168.1.10                  |           |  IP: 192.168.1.50                  |
|  Exports: /srv/nfs/labshare        |           |  Mount Point: /mnt/labshare        |
+------------------------------------+           +------------------------------------+
                   \                               /
                    \                             /
                     +---------------------------+
                     | Isolated Switch / Subnet  |
                     |     (192.168.1.0/24)      |
                     +---------------------------+
                                   |
                     +---------------------------+
                     |    Unauthorized Host      |
                     |    IP: 192.168.2.100      |
                     +---------------------------+
```

---

## Test Phase 1: Local Server Verification & Non-Destructive Dry-Run

### Test Case 1.1: Syntax & Code Integrity Check
- **Objective**: Ensure Bash script is syntactically sound, quotes are balanced, and strict mode compliance passes.
- **Commands**:
  ```bash
  bash -n nfs-toolkit.sh
  ```
- **Expected Result**: Clean execution with return code 0 and no output or syntax errors.

### Test Case 1.2: Diagnostic Mode Non-Interactive Check
- **Objective**: Verify non-destructive environment detection without modifying system files.
- **Commands**:
  ```bash
  ./nfs-toolkit.sh --check
  ```
- **Expected Result**: Reports distribution name, kernel release, available tools, current privileges, and network interfaces. Leaves `/etc/exports` untouched.

### Test Case 1.3: Dry-Run Export Configuration Simulation
- **Objective**: Test that dry-run mode previews changes without modifying `/etc/exports` or executing mutative commands.
- **Commands**:
  ```bash
  ./nfs-toolkit.sh --dry-run
  ```
  *In the menu, select `3) Configure & Apply Managed Export Entry`.*
  *Accept defaults (`/srv/nfs/labshare`, `192.168.1.0/24`, `ro`, `sync`, `root_squash`).*
- **Expected Result**: The toolkit outputs a preview of the candidate `/etc/exports` block labeled `[DRY-RUN]`. The live `/etc/exports` file on the filesystem remains unchanged.

### Test Case 1.4: Input Sanitization & Safety Boundary Enforcement
- **Objective**: Confirm that dangerous paths and open network patterns are rejected.
- **Inputs to Test**:
  1. Export path: `/` -> Must be rejected with warning.
  2. Export path: `/home` or `/root` -> Must be rejected with warning.
  3. Export path: `/etc` -> Must be rejected with warning.
  4. Client address: `*` -> Must be rejected with error.
  5. Client address: `0.0.0.0/0` -> Must be rejected with error.
  6. Client address: `203.0.113.1` (Public IP) -> Must trigger explicit security confirmation.
- **Expected Result**: The toolkit refuses invalid inputs and re-prompts the user until valid or safe inputs are provided.

---

## Test Phase 2: Live Server Configuration & Service Checks

*(Perform these tests on an authorized Ubuntu lab server)*

### Test Case 2.1: Controlled Package Installation
- **Procedure**:
  1. Launch `./nfs-toolkit.sh` and select `2) Install NFS Kernel Server Package`.
  2. Review the detailed explanation of dependencies (`nfs-kernel-server`, `rpcbind`).
  3. Confirm installation.
- **Verification**:
  ```bash
  dpkg -s nfs-kernel-server | grep Status
  ```
- **Expected Result**: Package installs cleanly, services register with systemd, and status reports `install ok installed`.

### Test Case 2.2: Live Export Creation & Idempotency
- **Procedure**:
  1. Launch `./nfs-toolkit.sh` and select `3) Configure & Apply Managed Export Entry`.
  2. Provide:
     - Path: `/srv/nfs/labshare`
     - Subnet: `192.168.1.0/24`
     - Permission: `ro` (Read-Only)
     - Sync: `sync`
     - Squash: `root_squash`
  3. Confirm creation and reload.
- **Verification**:
  ```bash
  # Check backup was created
  ls -la /etc/exports.bak.*
  # Check managed block exists
  grep -A 4 "BEGIN NFS-TOOLKIT MANAGED EXPORT" /etc/exports
  # Check kernel etab
  cat /var/lib/nfs/etab
  ```
- **Expected Result**: The managed block is cleanly inserted with comment delimiters. An automatic timestamped backup is generated.

### Test Case 2.3: Idempotency & Duplicate Prevention
- **Procedure**: Run Option 3 again with modified options (e.g., change permission from `ro` to `rw`).
- **Verification**:
  ```bash
  grep -c "BEGIN NFS-TOOLKIT MANAGED EXPORT" /etc/exports
  ```
- **Expected Result**: Count is exactly `1`. The old managed block is updated in-place without duplicate blocks or orphaned entries.

### Test Case 2.4: Port & Service Verification
- **Procedure**: Select `5) Inspect NFS Service & Network Ports (2049, 111)`.
- **Verification**:
  ```bash
  ss -tulpn | grep -E '(:2049|:111)'
  systemctl is-active nfs-server
  ```
- **Expected Result**: `nfs-server` is active. Ports 2049 (NFS) and 111 (rpcbind) are listening.

---

## Test Phase 3: Client Access & Permission Enforcement

### Test Case 3.1: Authorized Client Read-Only (`ro`) Test
- **Pre-condition**: Server share configured as `ro` for `192.168.1.0/24`.
- **Actions on Server (192.168.1.10)**:
  ```bash
  sudo touch /srv/nfs/labshare/testfile.txt
  echo "Lab test payload" | sudo tee /srv/nfs/labshare/testfile.txt
  ```
- **Actions on Authorized Client (192.168.1.50)**:
  ```bash
  sudo mkdir -p /mnt/labshare
  sudo mount -t nfs 192.168.1.10:/srv/nfs/labshare /mnt/labshare
  
  # Read test (should succeed)
  cat /mnt/labshare/testfile.txt
  
  # Write test (should FAIL with Read-only file system)
  touch /mnt/labshare/client_write.txt
  ```
- **Expected Result**:
  - `cat` displays: `Lab test payload`.
  - `touch` fails with: `touch: cannot touch '/mnt/labshare/client_write.txt': Read-only file system`.

### Test Case 3.2: Authorized Client Read-Write (`rw`) Test
- **Pre-condition**: Update server export to `rw` via Option 3 in `./nfs-toolkit.sh`. Reload exports (Option 6).
- **Actions on Server (192.168.1.10)**:
  ```bash
  sudo chmod 777 /srv/nfs/labshare
  ```
- **Actions on Authorized Client (192.168.1.50)**:
  ```bash
  # Attempt file creation as normal user
  touch /mnt/labshare/client_success.txt
  echo "Client write verification" > /mnt/labshare/client_success.txt
  ls -l /mnt/labshare/client_success.txt
  ```
- **Expected Result**: File is created and written successfully.

### Test Case 3.3: Root Squash Verification (`root_squash`)
- **Pre-condition**: Export has `root_squash` enabled (default).
- **Actions on Authorized Client (192.168.1.50)**:
  ```bash
  sudo touch /mnt/labshare/root_created_file.txt
  ls -l /mnt/labshare/root_created_file.txt
  ```
- **Expected Result**: On the server and client, ownership of `root_created_file.txt` is mapped to user `nobody` (UID 65534) and group `nogroup`. Client root does NOT become server root.

### Test Case 3.4: Unauthorized Client Access Rejection
- **Pre-condition**: Share is restricted to `192.168.1.0/24`.
- **Actions on Unauthorized Host (192.168.2.100)**:
  ```bash
  sudo mkdir -p /mnt/unauth
  sudo mount -t nfs 192.168.1.10:/srv/nfs/labshare /mnt/unauth
  ```
- **Expected Result**: Mount fails immediately with: `mount.nfs: access denied by server while mounting 192.168.1.10:/srv/nfs/labshare`.

---

## Test Phase 4: Clean Teardown & Preservation of Manual Exports

### Test Case 4.1: Manual Entry Preservation
- **Pre-condition**: Manually add a dummy third-party entry outside the managed block in `/etc/exports`:
  ```bash
  echo "/tmp/unrelated_share 192.168.1.20(ro,sync)" | sudo tee -a /etc/exports
  ```
- **Procedure**:
  1. Launch `./nfs-toolkit.sh` and select `7) Remove Project-Managed Export`.
  2. Confirm removal.
- **Verification**:
  ```bash
  # Verify managed block is gone
  grep "BEGIN NFS-TOOLKIT MANAGED EXPORT" /etc/exports || echo "Block removed"
  
  # Verify third-party entry is still present
  grep "/tmp/unrelated_share" /etc/exports
  ```
- **Expected Result**: The toolkit managed block is removed cleanly, while `/tmp/unrelated_share` remains completely intact and unaffected.

### Test Case 4.2: Client Cleanup
- **Actions on Authorized Client**:
  ```bash
  sudo umount /mnt/labshare
  df -h | grep /mnt/labshare || echo "Cleanly unmounted"
  ```
- **Expected Result**: Unmount completes without hang or error. Mount point is cleared.
