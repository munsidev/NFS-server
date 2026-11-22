# Course Report Outline: NFS Server Setup and Management Toolkit
**Course**: Operating Systems (CS / Distributed Systems Lab)  
**Project**: NFS Server Setup and Management Toolkit  
**Author**: Systems & OS Lab Student  
**Target Environment**: Ubuntu 22.04 LTS / 24.04 LTS (Kernel In-Tree NFS)

---

## 1. Abstract & Executive Summary
- Brief overview of distributed file systems in UNIX environments.
- Problem statement: Operational risks, privilege escalation, and misconfiguration vulnerabilities inherent in manual NFS management.
- Solution: Development of an automated, defensive, menu-driven Bash toolkit adhering to POSIX principles, idempotency, strict validation, and least privilege.
- Key outcomes: Safe lifecycle management of NFS exports, guaranteed preservation of unrelated system configurations, and automated pre-flight checks.

---

## 2. Theoretical Foundations: Remote File Systems & NFS Architecture
### 2.1 Remote Procedure Calls (RPC)
- Role of Sun RPC / Open Network Computing (ONC) RPC in distributed computing.
- Port mapper daemon (`rpcbind`) architecture: Port 111 dynamic resolution.
- Transport layer protocols: TCP vs UDP in modern NFS implementations (why NFSv4 mandates TCP).

### 2.2 NFS Protocol Evolution: NFSv3 vs NFSv4
- **NFSv3**: Stateless architecture, auxiliary daemons (`rpc.mountd`, `rpc.statd`, `rpc.lockd`), multiple listening ports, host-based trust.
- **NFSv4**: Stateful operations, single well-known port (2049), integrated locking and mounting, mandatory UTF-8 string encoding, compound RPC requests.
- Domain mapping and `nfsidmapd`: Overcoming raw UID/GID network transfers.

### 2.3 Kernel Space vs User Space Operations
- In-kernel file server threads (`nfsd` threads in Linux kernel).
- Virtual File System (VFS) integration: How `vfs_read`, `vfs_write`, and inode operations translate to RPC calls over the wire.
- Kernel export table (`/var/lib/nfs/etab`) vs configuration declaration (`/etc/exports`).
- Role of `exportfs` utility in translating user-space text rules into kernel data structures.

---

## 3. Security Architecture & Access Control
### 3.1 Network-Level Access Boundaries
- Granular CIDR subnet masking (`192.168.1.0/24`) vs host-specific authorization (`192.168.1.50`).
- Risks of wildcard configurations (`*`, `0.0.0.0/0`) and public exposure.
- Defense-in-depth: Why host-based access in `/etc/exports` must be paired with packet filtering (e.g. UFW / Netfilter).

### 3.2 UNIX Identity, UID/GID Matching & Authorization
- The decentralized identity dilemma: Trusting client-side user authentication.
- UID collision scenarios: How divergent `/etc/passwd` mappings cause unauthorized data leakage between users.
- NFS permissions resolution: Evaluating traditional UNIX file mode bits (`rwxrwxrwx`) on the server vs client kernel checks.

### 3.3 Root Squash & Privilege Escalation Mitigation
- Anatomy of `root_squash`: Kernel mapping of remote UID 0 to `nobody` (UID 65534).
- The vulnerability of `no_root_squash`:
  - Remote root creates SUID binaries (`chmod 4755`).
  - Tampering with system binaries or shared scripts.
  - Full compromise of the host filesystem.
- Role of `all_squash` and anonymous UID/GID (`anonuid`, `anongid`) in shared drops.

---

## 4. Write Semantics & Data Integrity
### 4.1 Synchronous (`sync`) vs Asynchronous (`async`) Writes
- POSIX write semantics: Cache buffer flushing vs RPC commit replies.
- Failure models: Power outages, server kernel panics, and uncommitted dirty buffer loss in `async` mode.
- Operational trade-offs: Throughput benchmarks vs crash resilience.

### 4.2 Subtree Checking (`subtree_check` vs `no_subtree_check`)
- Inode handle resolution when exporting subdirectories of a larger filesystem.
- Security boundary checks vs file handle cache invalidation during file renaming.
- Industry consensus on `no_subtree_check` for modern Linux deployments.

---

## 5. Client Mount Semantics & Operational Resilience
### 5.1 Mount Options Analysis
- `hard` vs `soft` mounts: Preventing silent write failures and I/O corruption during network partitions.
- `intr` flag: Allowing process interrupts (`SIGINT`) when an NFS server fails to respond.
- `_netdev` & `nofail`: Preventing client boot hangs in systemd when network targets are unreachable.

### 5.2 Failure Modes & Recovery
- Stale file handles (`ESTALE`): Causes and remediation.
- Lazy unmount (`umount -l`) vs Force unmount (`umount -f`).
- Network partition behavior and reconnection timeouts.

---

## 6. Implementation & Engineering Design of the Toolkit
### 6.1 Design Philosophy & Defensive Shell Programming
- Elimination of dangerous shell anti-patterns: Strict avoidance of `eval`.
- Unbound variable protection (`set -u`) and comprehensive quote sanitization.
- Modular functional architecture: Clear separation of diagnostics, configuration, validation, and execution.

### 6.2 Idempotent Managed Blocks
- Use of distinctive delimiters:
  - `# >>> BEGIN NFS-TOOLKIT MANAGED EXPORT >>>`
  - `# <<< END NFS-TOOLKIT MANAGED EXPORT <<<`
- Guarantee of zero side effects on existing, third-party, or manual export declarations.
- Automatic deduplication on repeated configuration runs.

### 6.3 Pre-Flight Syntax Validation & Rollback Architecture
- Creation of candidate configuration files in isolated temporary directories.
- Automated validation via `exportfs -f` prior to touching live configuration.
- Timestamped backup creation (`/etc/exports.bak.<timestamp>`) before every write operation.

### 6.4 Non-Destructive Dry-Run Engine
- CLI (`--dry-run`) and runtime menu toggle support.
- Interception of all mutative system commands (`cp`, `mkdir`, `apt`, `systemctl`, `chmod`).
- Real-time simulation and diff visualization without altering host state.

### 6.5 Secure Logging Framework
- Audit trail writing to `nfs-toolkit.log`.
- Sanitization: Zero capture of credentials, tokens, or sensitive system details.

---

## 7. Experimental Methodology & Test Results
*(Refer to `test-plan.md` for specific execution procedures)*
- **Test Case 1**: Pre-flight system detection across Ubuntu environments.
- **Test Case 2**: Safe directory creation and path boundary enforcement.
- **Test Case 3**: Export validation against invalid syntax and wildcard IP patterns.
- **Test Case 4**: Authorized client mounting vs unauthorized subnet isolation.
- **Test Case 5**: Enforcing Read-Only (`ro`) immutability.
- **Test Case 6**: Root squash verification (remote root mapped to `nobody`).
- **Test Case 7**: Idempotent removal and preservation of unrelated `/etc/exports` entries.

---

## 8. Limitations & Future Extensions
- **Stateless vs Kerberos Authentication**: Current reliance on host-level CIDR filtering rather than cryptographically authenticated RPCSEC_GSS (Kerberos).
- **Multi-Export Management**: Extending the toolkit to manage multiple distinct share profiles concurrently.
- **Dynamic Firewall Orchestration**: Optional opt-in module for UFW/nftables rule management.
- **High Availability (HA)**: Clustered NFS architectures (DRBD, Pacemaker, Corosync).

---

## 9. Conclusion
- Summary of how the toolkit bridges theoretical distributed systems concepts with practical, robust system administration.
- Final thoughts on the necessity of defensive coding when authoring administrative infrastructure tools.

---

## 10. References & Bibliography
- Callon, R., RFC 1094: NFS: Network File System Protocol Specification.
- Pawlowski, B., et al., RFC 1813: NFS Version 3 Protocol Specification.
- Shepler, S., et al., RFC 3530: Network File System (NFS) version 4 Protocol.
- Linux Kernel Organization, Documentation for NFS server (`nfsd`) and `exports(5)` man pages.
- Ubuntu Server Guide: Network File System (NFS) Administration.
