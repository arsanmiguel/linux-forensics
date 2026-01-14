# Linux Performance Forensic Tools

## Overview

A comprehensive Bash-based diagnostic tool for Linux servers that automatically detects performance bottlenecks and can create AWS Support cases with detailed forensic data. Uses only open-source utilities available on standard Linux distributions.

**Key Features:**
- ✅ Comprehensive performance forensics (CPU, Memory, Disk, Network)
- ✅ Automated bottleneck detection
- ✅ Disk I/O performance testing (native tools only)
- ✅ CPU forensics (load average, context switches, steal time)
- ✅ Memory forensics (OOM detection, swap analysis, page faults)
- ✅ Network analysis (connection states, retransmissions, errors)
- ✅ **Automatic AWS Support case creation** with diagnostic data
- ✅ Works across all major distributions (Ubuntu, RHEL, Amazon Linux, CentOS, Debian)

---

## 🚀 **Quick Start**

### **Prerequisites**
- Linux server (any major distribution)
- Root or sudo privileges
- Standard utilities: `mpstat`, `iostat`, `vmstat`, `netstat` (usually pre-installed)
- AWS CLI (optional, for support case creation)

### **Installation**

1. **Clone the repository:**
```bash
git clone https://github.com/arsanmiguel/linux-performance-forensic-tools.git
cd linux-performance-forensic-tools
```

2. **Make executable:**
```bash
chmod +x invoke-linux-forensics.sh
```

3. **Run diagnostics:**
```bash
sudo ./invoke-linux-forensics.sh
```

---

## 📊 **Available Tool**

### **invoke-linux-forensics.sh**
**A complete Linux performance diagnostic tool** - comprehensive forensics with automatic issue detection.

<details>
<summary><strong>What it does</strong></summary>

- Collects system information (OS, kernel, hardware, EC2 metadata)
- Analyzes CPU performance (load average, usage, context switches, steal time)
- Performs memory forensics (usage, swap, page faults, OOM detection)
- Tests disk I/O performance (usage, wait times, read/write speeds)
- Analyzes network performance (connections, retransmissions, errors)
- **Automatically identifies bottlenecks**
- **Creates AWS Support case** with all diagnostic data

</details>

<details>
<summary><strong>Usage</strong></summary>

```bash
# Quick diagnostics (1-2 minutes)
sudo ./invoke-linux-forensics.sh -m quick

# Standard diagnostics (3-5 minutes) - recommended
sudo ./invoke-linux-forensics.sh -m standard

# Deep diagnostics with I/O testing (5-10 minutes)
sudo ./invoke-linux-forensics.sh -m deep

# Auto-create support case if issues found
sudo ./invoke-linux-forensics.sh -m standard -s -v high

# Disk-only diagnostics
sudo ./invoke-linux-forensics.sh -m disk

# CPU-only diagnostics
sudo ./invoke-linux-forensics.sh -m cpu

# Memory-only diagnostics
sudo ./invoke-linux-forensics.sh -m memory

# Custom output directory
sudo ./invoke-linux-forensics.sh -m standard -o /var/log
```

**Options:**
- `-m, --mode` - Diagnostic mode: quick, standard, deep, disk, cpu, memory
- `-s, --support` - Create AWS Support case if issues found
- `-v, --severity` - Support case severity: low, normal, high, urgent, critical
- `-o, --output` - Output directory (default: current directory)
- `-h, --help` - Show help message

</details>

<details>
<summary><strong>Output Example</strong></summary>

```
BOTTLENECKS DETECTED: 3 performance issue(s) found

  CRITICAL ISSUES (1):
    • Memory: Low available memory

  HIGH PRIORITY (2):
    • Disk: High I/O wait time
    • CPU: High load average

Detailed report saved to: linux-forensics-20260114-070000.txt
AWS Support case created: case-123456789
```

</details>

---

## 📖 **Examples**

<details>
<summary><strong>Example 1: Quick Health Check</strong></summary>

```bash
sudo ./invoke-linux-forensics.sh -m quick
```
Output: 1-2 minute assessment with automatic bottleneck detection

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

---

## 🎯 **Use Cases**

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

---

## **What Bottlenecks Can Be Found?**

The tool automatically detects:

<details>
<summary><strong>CPU Issues</strong></summary>

- High load average (>1.0 per core)
- High CPU utilization (>80%)
- Excessive context switches (>15,000/sec)
- High CPU steal time (>10% - hypervisor contention)

</details>

<details>
<summary><strong>Memory Issues</strong></summary>

- Low available memory (<10%)
- High swap usage (>50%)
- High page fault rate (>1,000/sec)
- OOM (Out of Memory) killer invocations

</details>

<details>
<summary><strong>Disk Issues</strong></summary>

- Filesystem nearly full (>90%)
- High I/O wait time (>20ms)
- Poor read/write performance

</details>

<details>
<summary><strong>Network Issues</strong></summary>

- Excessive TIME_WAIT connections (>5,000)
- High TCP retransmissions
- Network interface errors

</details>

---

## 🔧 **Configuration**

### **AWS Support Integration**

The tool can automatically create AWS Support cases when performance issues are detected.

<details>
<summary><strong>Setup Instructions</strong></summary>

**Setup:**
1. **Install AWS CLI:**
```bash
# Amazon Linux / RHEL / CentOS
sudo yum install -y aws-cli

# Ubuntu / Debian
sudo apt-get install -y awscli

# Or use pip
pip3 install awscli
```

2. **Configure AWS credentials:**
```bash
aws configure
```

3. **Verify Support API access:**
```bash
aws support describe-services
```

**Required IAM Permissions:**
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

</details>

---

## 🛠️ **Troubleshooting**

<details>
<summary><strong>Missing Utilities</strong></summary>

Install required utilities if missing:

**RHEL / CentOS / Amazon Linux:**
```bash
sudo yum install -y sysstat net-tools
```

**Ubuntu / Debian:**
```bash
sudo apt-get install -y sysstat net-tools
```

</details>

<details>
<summary><strong>Permission Denied</strong></summary>

The script requires root privileges:
```bash
sudo ./invoke-linux-forensics.sh
```

</details>

<details>
<summary><strong>AWS Support Case Creation Fails</strong></summary>

- Verify AWS CLI: `aws --version`
- Check credentials: `aws sts get-caller-identity`
- Ensure Support plan is active (Business or Enterprise)
- Verify IAM permissions for support:CreateCase

</details>

---

## 📦 **What's Included**

- `invoke-linux-forensics.sh` - Comprehensive forensics tool with bottleneck detection
- `README.md` - This documentation

---

## 🤝 **Support**

### **Contact**
- **Report bugs and feature requests:** [adrianrs@amazon.com](mailto:adrianrs@amazon.com)

### **AWS Support**
For AWS-specific issues, the tool can automatically create support cases with diagnostic data attached.

---

## ⚠️ **Important Notes**

- This tool requires root/sudo privileges
- Disk testing may impact system performance temporarily
- Tested on Ubuntu 18.04+, RHEL 7+, Amazon Linux 2/2023, CentOS 7+, Debian 9+
- Works on AWS EC2, Azure VMs, GCP Compute, and on-premises
- Uses only open-source utilities (no proprietary tools required)
- **No warranty or official support provided** - use at your own discretion

---

## 📝 **Version History**

- **v1.0** (January 2026) - Initial release with comprehensive forensics and AWS Support integration

---

**Note:** This tool is provided as-is for diagnostic purposes. Always test in non-production environments first.
