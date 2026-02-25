# Linux & FreeBSD Performance Forensic Tools

<a id="overview"></a>
## Overview

A comprehensive Bash-based diagnostic tool for Linux and FreeBSD servers that automatically detects performance bottlenecks and can create AWS Support cases with detailed forensic data. Originally created for AWS DMS migrations - run this on your SOURCE DATABASE SERVER. Now useful for any Linux/FreeBSD performance troubleshooting scenario. Uses only open-source utilities and automatically installs missing dependencies when possible.

Key Features:

- Performance forensics: CPU, memory, disk, network, database (vmstat, iostat, sar, etc.)
- Storage profiling (disk labeling, partition schemes, boot configuration)
- AWS DMS source database diagnostics (binary logging, replication lag, connection analysis)
- Automated bottleneck detection
- Graceful degradation when tools unavailable
- Database forensics: DBA-level query analysis and DMS readiness checks
- Automatic AWS Support case creation with diagnostic data
- Works on-premises and in cloud environments
- Automatic, version-aware dependency installation (Debian/Ubuntu, RHEL/CentOS/Amazon Linux, SUSE, Arch, Alpine, FreeBSD)
- Enhanced profiling tools: htop, btop, glances (auto-installed)

TL;DR — Run it now
```bash
git clone https://github.com/arsanmiguel/linux-forensics.git && cd linux-forensics
chmod +x invoke-linux-forensics.sh
sudo ./invoke-linux-forensics.sh
```
Then read on for AWS Support or troubleshooting.

Quick links: [Install](#installation) · [Usage](#available-tool) · [Troubleshooting](#troubleshooting)

Contents
- [Overview](#overview)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Examples](#examples)
- [Use Cases](#use-cases)
- [What Bottlenecks Can Be Found](#what-bottlenecks-can-be-found)
- [Troubleshooting](#troubleshooting)
- [Configuration (AWS Support)](#configuration)
- [Support](#support)
- [Important Notes & Performance](#important-notes-and-performance)
- [Profiling Tools](#profiling-tools)
- [Version History](#version-history)

---

<a id="quick-start"></a>
## Quick Start

### Prerequisites
- Linux or FreeBSD server (see supported OS list below)
- Root or sudo privileges
- Bash shell (script will auto-detect and provide instructions if missing)
- AWS CLI (optional, for support case creation)

### Supported Operating Systems

Fully Supported (Automatic Package Installation with Version Detection):
- Ubuntu 18.04, 20.04, 22.04, 24.04+
- Debian 9, 10, 11, 12+
- RHEL 7, 8, 9+ (auto-detects dnf vs yum based on version)
- CentOS 7, 8 Stream
- Amazon Linux 2 (yum), Amazon Linux 2023 (dnf)
- Rocky Linux 8, 9+
- AlmaLinux 8, 9+
- Oracle Linux 7, 8, 9+
- Fedora 22+ (auto-detects dnf)
- SUSE Linux Enterprise Server 12, 15+
- openSUSE Leap, Tumbleweed
- Arch Linux, Manjaro (pacman)
- Alpine Linux (apk)
- FreeBSD 12, 13, 14+ (pkg)

Note: The script automatically detects your OS and version, then selects the correct package manager and package names. For example, RHEL 8+ uses `dnf` while RHEL 7 uses `yum`, and iSCSI tools are named differently across distros (`open-iscsi` vs `iscsi-initiator-utils`).

<a id="installation"></a>
### Installation

1. Clone the repository:
```bash
git clone https://github.com/arsanmiguel/linux-forensics.git
cd linux-forensics
```

2. Make executable:
```bash
chmod +x invoke-linux-forensics.sh
```

3. Run diagnostics:
```bash
sudo ./invoke-linux-forensics.sh
```

---

<a id="available-tool"></a>
The script runs system diagnostics and writes a report to a timestamped file; optional AWS Support case creation when issues are found. Usage: `sudo ./invoke-linux-forensics.sh [-m mode] [-s] [-v severity] [-o dir]`.

---

<a id="examples"></a>
## Examples

Run all script commands as root or with sudo.

<details>
<summary><strong>Example 1: Quick Health Check</strong></summary>

```bash
sudo ./invoke-linux-forensics.sh -m quick
```
Output: 3-minute assessment with automatic bottleneck detection

</details>

<details>
<summary><strong>Example 2: Production Issue with Auto-Ticket</strong></summary>

```bash
sudo ./invoke-linux-forensics.sh -m deep -s -v urgent
```
Output: Comprehensive diagnostics + AWS Support case with all data attached

</details>

<details>
<summary><strong>Example 3: Disk Performance Testing</strong></summary>

```bash
sudo ./invoke-linux-forensics.sh -m disk
```
Output: Detailed disk I/O testing and analysis

</details>

### Use Cases

<a id="use-cases"></a>
<details>
<summary><strong>Use Cases</strong> (DMS, DB perf, web server, EC2, incident response)</summary>

<details>
<summary><strong>AWS DMS Migrations</strong></summary>

This tool is designed to run on your SOURCE DATABASE SERVER, not on the DMS replication instance (which is AWS-managed).

What it checks for DMS by database type:

<details>
<summary><strong>MySQL/MariaDB</strong></summary>

- Binary logging enabled (log_bin=ON, required for CDC)
- Binlog format set to ROW (required for DMS)
- Binary log retention configured (expire_logs_days >= 1)
- Replication lag (if source is a replica)

</details>

<details>
<summary><strong>PostgreSQL</strong></summary>

- WAL level set to 'logical' (required for CDC)
- Replication slots configured (max_replication_slots >= 1)
- Replication lag (if standby server)

</details>

<details>
<summary><strong>Oracle</strong></summary>

- ARCHIVELOG mode enabled (required for CDC)
- Supplemental logging enabled (required for DMS)
- Data Guard apply lag (if standby)

</details>

<details>
<summary><strong>SQL Server</strong></summary>

- SQL Server Agent running (required for CDC)
- Database recovery model set to FULL (required for CDC)
- AlwaysOn replica lag (if applicable)

</details>

<details>
<summary><strong>All Databases</strong></summary>

- CloudWatch Logs Agent running
- Database connection health
- Network connectivity to database ports
- Connection churn that could impact DMS
- Source database performance issues
- Long-running queries/sessions
- High connection counts

</details>

Run this when:
- Planning a DMS migration (pre-migration assessment)
- DMS replication is slow or stalling
- Source database performance issues
- High replication lag
- Connection errors in DMS logs
- CDC not capturing changes

Usage:
```bash
sudo ./invoke-linux-forensics.sh -m deep -s -v high
```

</details>

<details>
<summary><strong>Database Server Performance Issues</strong></summary>

Diagnose MySQL, PostgreSQL, or other database performance problems:
```bash
sudo ./invoke-linux-forensics.sh -m deep -s
```

</details>

<details>
<summary><strong>Web Server Troubleshooting</strong></summary>

Identify bottlenecks affecting web application performance:
```bash
sudo ./invoke-linux-forensics.sh -m standard
```

</details>

<details>
<summary><strong>EC2 Instance Right-Sizing</strong></summary>

Gather baseline performance data for capacity planning:
```bash
sudo ./invoke-linux-forensics.sh -m quick
```

</details>

<details>
<summary><strong>Production Incident Response</strong></summary>

When things go wrong:
```bash
sudo ./invoke-linux-forensics.sh -m deep -s -v urgent
```

</details>

</details>

### What Bottlenecks Can Be Found

<a id="what-bottlenecks-can-be-found"></a>
<details>
<summary><strong>What Bottlenecks Can Be Found?</strong> (What the script can detect)</summary>

The tool automatically detects:

<details>
<summary><strong>CPU Issues</strong></summary>

- High load average (>1.0 per core)
- High CPU utilization (>80%)
- Excessive context switches (>15,000/sec)
- High CPU steal time (>10% - indicates hypervisor/VM contention)

</details>

<details>
<summary><strong>Memory Issues</strong></summary>

- Low available memory (<10%)
- High swap usage (>50%)
- High page fault rate (>1,000/sec)
- OOM (Out of Memory) killer invocations
- Memory leak candidates (high virtual, low resident memory)

</details>

<details>
<summary><strong>Disk Issues</strong></summary>

- Filesystem nearly full (>90%)
- High I/O wait time (>20ms average)
- Poor read/write performance

</details>

<details>
<summary><strong>Storage Issues</strong></summary>

- Misaligned partitions (4K alignment check - 30-50% perf loss on SSD/SAN/Cloud)
- MBR partition on >2TB disk (only 2TB usable - potential data loss)
- Degraded RAID arrays (mdadm software RAID)
- SMART drive failures or warnings (failing/about to fail)
- High SSD wear level (>80%)
- High disk temperature (>60°C)
- Inode exhaustion (>90% used)
- Failed multipath paths (SAN connectivity)
- AWS EBS gp2 volumes detected (recommend upgrade to gp3 for cost savings)
- AWS EBS io1 volumes detected (recommend upgrade to io2 for better durability)
- NFS mounts with suboptimal options (sync mode, missing noatime)

</details>

<details>
<summary><strong>Database Issues</strong></summary>

- High connection count (MySQL/PostgreSQL/Oracle/SQL Server: >500, MongoDB/Cassandra: >1000, Redis: >10,000)
- Slow queries detected (MySQL: >100 slow query log entries)
- High connection churn (>1,000 TIME_WAIT connections on database ports)
- Excessive resource usage by database processes
- Top 5 queries by CPU/time, long-running queries (>30s), blocking detection
- SQL Server/MySQL/PostgreSQL: DMV/performance schema queries, active sessions, wait states
- MongoDB: currentOp() and profiler analysis for slow operations
- Redis: SLOWLOG, ops/sec metrics, connection rejection tracking
- Oracle: v$session and v$sql analysis, blocking session detection
- Elasticsearch: Tasks API for long-running searches, thread pool monitoring

Supported Databases:
- MySQL / MariaDB
- PostgreSQL
- MongoDB
- Cassandra
- Redis
- Oracle Database
- Microsoft SQL Server (Linux)
- Elasticsearch

</details>

<details>
<summary><strong>Network Issues</strong></summary>

- Excessive TIME_WAIT connections (>5,000)
- Excessive CLOSE_WAIT connections (>1,000)
- High TCP retransmissions (>100)
- High RX/TX errors (>100)
- Network packet drops

</details>

</details>

---

<a id="troubleshooting"></a>
## Troubleshooting

<details>
<summary><strong>Missing Utilities</strong></summary>

The script automatically handles missing utilities on supported distributions.

If automatic installation fails, install manually:

RHEL / CentOS / Amazon Linux / Rocky / Alma:
```bash
sudo yum install -y sysstat net-tools bc
# or
sudo dnf install -y sysstat net-tools bc
```

Ubuntu / Debian:
```bash
sudo apt-get update
sudo apt-get install -y sysstat net-tools bc
```

SUSE:
```bash
sudo zypper install -y sysstat net-tools bc
```

Note: The script will continue with limited functionality if some tools are unavailable, using fallback methods where possible.

</details>

<details>
<summary><strong>Bash Not Available</strong></summary>

If you see "bash not found" error:

RHEL / CentOS:
```bash
yum install bash
```

Ubuntu / Debian:
```bash
apt-get install bash
```

SUSE / openSUSE:
```bash
zypper install bash
```

Arch Linux:
```bash
pacman -S bash
```

FreeBSD:
```bash
pkg install bash
```

</details>

<details>
<summary><strong>Permission Denied</strong></summary>

The script requires root privileges:
```bash
sudo ./invoke-linux-forensics.sh
```

Or run as root:
```bash
su -
./invoke-linux-forensics.sh
```

</details>

<details>
<summary><strong>AWS Support Case Creation Fails</strong></summary>

- Verify AWS CLI: `aws --version`
- Check credentials: `aws sts get-caller-identity`
- Ensure Support plan is active (Business or Enterprise)
- Verify IAM permissions for support:CreateCase

</details>

<details>
<summary><strong>Package Installation Fails</strong></summary>

The script provides detailed diagnostics when package installation fails, including:
- Repository configuration status
- Disk space availability
- Manual installation commands

Check the output for specific guidance based on your system.

</details>

<details>
<summary><strong>Storage Profiling Tools</strong></summary>

The script automatically installs storage-related tools when needed. Tools are only installed if the related subsystem is detected (e.g., LVM tools only if `/dev/mapper` exists).

| Tool | Purpose | Package (Debian/Ubuntu) | Package (RHEL/CentOS) | Package (FreeBSD) |
|------|---------|-------------------------|----------------------|-------------------|
| smartctl | SMART health monitoring | smartmontools | smartmontools | sysutils/smartmontools |
| nvme | NVMe device management | nvme-cli | nvme-cli | sysutils/nvme-cli |
| lsblk | Block device listing | util-linux | util-linux | N/A (use geom) |
| pvs/vgs/lvs | LVM information | lvm2 | lvm2 | N/A (use GEOM/ZFS) |
| mdadm | Software RAID management | mdadm | mdadm | N/A (use gmirror/graid) |
| iscsiadm | iSCSI initiator | open-iscsi | iscsi-initiator-utils | net/iscsi-initiator-utils |
| multipath | Multipath I/O | multipath-tools | device-mapper-multipath | sysutils/mpath-tools |
| fio | I/O benchmarking | fio | fio | benchmarks/fio |
| e4defrag | ext4 fragmentation | e2fsprogs | e2fsprogs | N/A |
| xfs_db | XFS analysis | xfsprogs | xfsprogs | N/A |
| blkid | Partition type detection | util-linux | util-linux | N/A (use gpart) |
| mokutil | Secure Boot status | mokutil | mokutil | N/A |

FreeBSD-Specific Tools (built-in or auto-installed):
| Tool | Purpose |
|------|---------|
| geom | GEOM disk subsystem management |
| gpart | Partition table manipulation |
| camcontrol | CAM (SCSI/SATA) device control |
| zpool/zfs | ZFS pool and filesystem management |
| gmirror | GEOM software mirroring |
| graid | GEOM software RAID |

Partition Scheme Detection:
- GPT (GUID Partition Table) - Modern, UEFI, supports >2TB
- MBR (msdos) - Legacy, BIOS, 2TB limit per partition
- BSD Disklabel (FreeBSD) - Traditional BSD partitioning
- Warns if MBR is used on disks >2TB

Partition Alignment Analysis:

*Linux:*
- Reads partition start sector from `/sys/block/*/start`
- Calculates offset in bytes using hardware sector size
- Detects storage type from `/sys/block/*/queue/rotational` and transport

*FreeBSD:*
- Reads partition layout from `gpart show`
- Detects storage type from `camcontrol identify`
- Checks ZFS ashift values for pool alignment

*Both:*
- Checks 4K (4096 byte) alignment - minimum for modern storage
- Checks 1MB (1048576 byte) alignment - optimal for SSD/SAN
- Severity based on storage type:
  - SSD/NVMe: High severity (30-50% performance loss)
  - SAN (iSCSI/FC/SAS): High severity (30-50% loss + I/O amplification)
  - Cloud (vd*/xvd*): High severity (typically SSD-backed)
  - HDD: Medium severity (10-20% loss from read-modify-write)
- Common cause: Partitions created on older systems

Partition Type Detection:
- EFI System Partition (ESP) - UEFI boot
- BIOS Boot Partition - GPT + Legacy BIOS
- LVM Physical Volumes
- MD RAID members
- Linux swap

Filesystem Detection:
- ext4, ext3, ext2 (Linux standard)
- XFS (RHEL/CentOS default)
- Btrfs (copy-on-write, snapshots)
- ZFS (advanced RAID + filesystem)
- bcachefs (next-gen CoW filesystem)
- FAT32/vfat (EFI partitions)

Manual installation if automatic install fails:

```bash
# Debian/Ubuntu
sudo apt-get install -y smartmontools nvme-cli lvm2 fio multipath-tools open-iscsi

# RHEL 8+/Rocky/Alma/Amazon Linux 2023
sudo dnf install -y smartmontools nvme-cli lvm2 fio device-mapper-multipath iscsi-initiator-utils

# RHEL 7/CentOS 7/Amazon Linux 2
sudo yum install -y smartmontools nvme-cli lvm2 fio device-mapper-multipath iscsi-initiator-utils

# SUSE/openSUSE
sudo zypper install -y smartmontools nvme-cli lvm2 fio multipath-tools open-iscsi

# Arch Linux
sudo pacman -S smartmontools nvme-cli lvm2 fio multipath-tools open-iscsi

# Alpine Linux
sudo apk add smartmontools nvme-cli lvm2 fio

# FreeBSD
sudo pkg install sysutils/smartmontools sysutils/nvme-cli benchmarks/fio
```

</details>

<details>
<summary><strong>SAR/Sysstat Historical Data Collection</strong></summary>

The script automatically detects and displays historical sar data if sysstat data collection is enabled. This provides valuable trending information to identify when performance issues started.

SAR Data Used:

| Command | Data | Purpose |
|---------|------|---------|
| `sar -u` | CPU utilization | CPU usage trends |
| `sar -q` | Run queue, load average | System load trends |
| `sar -P ALL` | Per-CPU statistics | CPU imbalance detection |
| `sar -r` | Memory utilization | Memory usage trends |
| `sar -S` | Swap statistics | Swap activity trends |
| `sar -B` | Paging statistics | Memory pressure trends |
| `sar -b` | I/O transfer rates | Overall I/O trends |
| `sar -d` | Block device I/O | Per-disk I/O trends |
| `sar -n DEV` | Network device stats | Network throughput trends |
| `sar -n EDEV` | Network errors | Network error trends |
| `sar -n TCP` | TCP statistics | Connection trends |
| `sar -n ETCP` | TCP errors | TCP error trends |
| `sar -n SOCK` | Socket statistics | Socket usage trends |

Enable Historical Data Collection:

```bash
# Debian/Ubuntu
sudo apt-get install sysstat
sudo systemctl enable --now sysstat

# RHEL/CentOS/Fedora
sudo dnf install sysstat   # or yum on older systems
sudo systemctl enable --now sysstat

# SUSE/openSUSE
sudo zypper install sysstat
sudo systemctl enable --now sysstat

# FreeBSD
sudo pkg install sysutils/sysstat
# Add to /etc/crontab: */10 * * * * root /usr/local/lib/sa/sa1 1 1
```

Data Locations:
- `/var/log/sa/saDD` (RHEL/CentOS/Fedora)
- `/var/log/sysstat/saDD` (Debian/Ubuntu)
- Where DD = day of month (01-31)

View Historical Data Manually:
```bash
# Today's CPU history
sar -u -f /var/log/sa/sa$(date +%d)

# Yesterday's memory history
sar -r -f /var/log/sa/sa$(date -d yesterday +%d)

# Specific time range
sar -u -s 09:00:00 -e 17:00:00 -f /var/log/sa/sa15
```

</details>

---

<a id="configuration"></a>
## Configuration

### AWS Support Integration

The tool can automatically create AWS Support cases when performance issues are detected.

<details>
<summary><strong>Setup Instructions</strong></summary>

Setup:
1. Install AWS CLI:
```bash
# Amazon Linux / RHEL / CentOS
sudo yum install -y aws-cli

# Ubuntu / Debian
sudo apt-get install -y awscli

# Or use pip
pip3 install awscli
```

2. Configure AWS credentials:
```bash
aws configure
```

3. Verify Support API access:
```bash
aws support describe-services
```

Required IAM Permissions:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "support:CreateCase",
        "support:AddAttachmentsToSet",
        "support:AddCommunicationToCase"
      ],
      "Resource": "*"
    }
  ]
}
```

Important: AWS Support API access requires a Business, Enterprise On-Ramp, or Enterprise Support plan. If you don't have one of these plans, the script will:
- Detect the API access error
- Skip support case creation
- Continue with diagnostic report generation
- Save all forensic data locally for manual review

</details>

---

<a id="profiling-tools"></a>
## Profiling Tools

<details>
<summary><strong>htop, btop, glances, iotop, sysstat, smartmontools</strong></summary>

The script automatically installs these enhanced profiling tools:

| Tool | Purpose | Linux Package | FreeBSD Package |
|------|---------|---------------|-----------------|
| htop | Interactive process viewer with CPU/memory bars | `htop` | `sysutils/htop` |
| btop | Modern resource monitor with graphs and history | `btop` | `sysutils/btop` |
| glances | Comprehensive system monitoring (CPU, mem, disk, network) | `glances` | `sysutils/py-glances` |
| iotop | I/O monitoring by process | `iotop` | `sysutils/py-iotop` |
| sysstat | SAR, mpstat, iostat for historical data | `sysstat` | `sysutils/sysstat` |
| smartmontools | Disk SMART health data | `smartmontools` | `sysutils/smartmontools` |

Manual Installation (if auto-install fails):
```bash
# Debian/Ubuntu
sudo apt-get install -y htop btop glances iotop sysstat smartmontools

# RHEL/CentOS/Fedora/Amazon Linux
sudo dnf install -y htop btop glances iotop sysstat smartmontools

# SUSE/openSUSE
sudo zypper install -y htop btop glances iotop sysstat smartmontools

# Arch Linux
sudo pacman -S htop btop glances iotop sysstat smartmontools

# FreeBSD
sudo pkg install sysutils/htop sysutils/btop sysutils/py-glances sysutils/py-iotop sysutils/sysstat sysutils/smartmontools
```

</details>

---

<a id="support"></a>
## Support

### Contact
- Report bugs and feature requests: [adrianr.sanmiguel@gmail.com](mailto:adrianr.sanmiguel@gmail.com)

### AWS Support
For AWS-specific issues, the tool can automatically create support cases with diagnostic data attached.

---

<a id="important-notes-and-performance"></a>
## Important Notes & Performance

<details>
<summary><strong>Important Notes & Expected Performance Impact</strong></summary>

- This tool requires root/sudo privileges
- Disk testing may impact system performance temporarily
- Automatic package installation works on Debian/Ubuntu, RHEL/CentOS/Amazon Linux, SUSE, Arch, Alpine, and FreeBSD
- Script uses graceful degradation - continues with available tools if some are missing
- Tested on Ubuntu 18.04+, RHEL 7+, Amazon Linux 2/2023, CentOS 7+, Debian 9+, Rocky Linux 8+, AlmaLinux 8+, FreeBSD 12+
- Works on AWS EC2, Azure VMs, GCP Compute, on-premises, and other cloud providers
- Uses only open-source utilities (no proprietary tools required)
- No warranty or official support provided - use at your own discretion

Expected Performance Impact

Quick Mode (3 minutes):
- CPU: <5% overhead - mostly reading /proc and system stats
- Memory: <50MB - lightweight data collection
- Disk I/O: Minimal - no performance testing, only stat collection
- Network: None - passive monitoring only
- Safe for production - read-only operations

Standard Mode (5-10 minutes):
- CPU: 5-10% overhead - includes sampling and process analysis
- Memory: <100MB - additional process tree analysis
- Disk I/O: Minimal - no write testing, only extended stat collection
- Network: None - passive monitoring only
- Safe for production - read-only operations

Deep Mode (15-20 minutes):
- CPU: 10-20% overhead - includes dd tests and extended sampling
- Memory: <150MB - comprehensive process and memory analysis
- Disk I/O: Moderate impact - performs dd read/write tests (1GB writes)
- Network: None - passive monitoring only
- Use caution in production - disk tests may cause temporary I/O spikes
- Recommendation: Run during maintenance windows or low-traffic periods

Database Query Analysis (all modes):
- CPU: <2% overhead per database - lightweight queries to system tables
- Memory: <20MB per database - result set caching
- Database Load: Minimal - uses performance schema/DMVs/system views
- Safe for production - read-only queries, no table locks

General Guidelines:
- The tool is read-only except for disk write tests in deep mode
- No application restarts or configuration changes
- Monitoring tools (mpstat, iostat, vmstat) run for 10-second intervals
- Database queries target system/performance tables only, not user data
- All operations are non-blocking and use minimal system resources

</details>

---

<a id="version-history"></a>
## Version History

- v1.3 (February 2026) – README overhaul
  - Structure and flow aligned with unix-forensics: table of contents (Contents) with anchors, TL;DR, Quick links
  - Replaced long “Available Tool” section with a short blurb; Use Cases and What Bottlenecks are subsections of Examples
  - Section order: Troubleshooting before Configuration; Profiling Tools and Important Notes & Performance are collapsible
  - Removed emojis; slimmed Key Features; consistent section headers and styling
- v1.2 (February 2026) – FreeBSD support
  - FreeBSD 12, 13, 14+ with pkg package manager
  - GEOM storage subsystem (gpart, geom, camcontrol)
  - ZFS pool alignment (ashift) analysis
  - BSD disklabel detection
  - FreeBSD-specific package mappings
- v1.1 (February 2026) – Storage profiling and distro expansion
  - Comprehensive storage profiling; improved OS version detection
  - Expanded distro support (Arch, Alpine, Oracle Linux); automatic storage tool installation
- v1.0 (January 2026) – Initial release
  - Comprehensive forensics and AWS Support integration

---

Note: This tool is provided as-is for diagnostic purposes. Always test in non-production environments first.
