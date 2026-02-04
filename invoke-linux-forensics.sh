#!/bin/bash

#############################################################################
# Linux Performance Forensic Tool
# 
# Comprehensive performance diagnostics with automatic bottleneck detection
# and AWS Support integration
#
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora/Amazon Linux, SLES/openSUSE, Arch, Alpine, FreeBSD
#
# Usage: sudo ./invoke-linux-forensics.sh [OPTIONS]
#
# Options:
#   -m, --mode MODE          Diagnostic mode: quick, standard, deep, disk, cpu, memory
#   -s, --support            Create AWS Support case if issues found
#   -v, --severity LEVEL     Support case severity: low, normal, high, urgent, critical
#   -o, --output PATH        Output directory (default: current directory)
#   -h, --help               Show this help message
#
# Requires: root/sudo privileges
# Optional: AWS CLI for support case creation
#############################################################################

# Check if bash is available, if not try to re-execute with bash
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "ERROR: This script requires bash, but it's not available."
        echo "Please install bash using your system's package manager:"
        echo "  - Debian/Ubuntu: apt-get install bash"
        echo "  - RHEL/CentOS/Fedora: yum install bash or dnf install bash"
        echo "  - SLES/openSUSE: zypper install bash"
        echo "  - Arch: pacman -S bash"
        echo "  - Alpine: apk add bash"
        echo "  - FreeBSD: pkg install bash"
        exit 1
    fi
fi

set -euo pipefail

# Default values
MODE="standard"
CREATE_SUPPORT_CASE=false
SEVERITY="normal"
OUTPUT_DIR="$(pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/linux-forensics-${TIMESTAMP}.txt"
BOTTLENECKS=()
DISTRO=""
PACKAGE_MANAGER=""
MISSING_PACKAGES=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

#############################################################################
# System Detection
#############################################################################

detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        DISTRO="macos"
        OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
        OS_VERSION_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
    elif [[ "$(uname -s)" == "FreeBSD" ]]; then
        DISTRO="freebsd"
        OS_VERSION=$(freebsd-version -u 2>/dev/null || uname -r)
        OS_VERSION_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
        OS_NAME="FreeBSD $OS_VERSION"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_VERSION_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
        OS_NAME="${PRETTY_NAME:-$ID}"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="rhel"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
        OS_VERSION_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
        OS_NAME=$(cat /etc/redhat-release)
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        OS_VERSION=$(cat /etc/debian_version)
        OS_VERSION_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
        OS_NAME="Debian $OS_VERSION"
    else
        DISTRO="unknown"
        OS_VERSION="unknown"
        OS_VERSION_MAJOR="0"
        OS_NAME="Unknown"
    fi
    
    # Determine package manager based on distro and version
    case "$DISTRO" in
        macos)
            PACKAGE_MANAGER="brew"
            ;;
        ubuntu|debian|linuxmint|pop)
            PACKAGE_MANAGER="apt-get"
            ;;
        rhel|centos|rocky|alma|ol)
            # RHEL 8+ and derivatives use dnf
            if [[ -n "$OS_VERSION_MAJOR" ]] && (( OS_VERSION_MAJOR >= 8 )); then
                PACKAGE_MANAGER="dnf"
            elif command -v dnf >/dev/null 2>&1; then
                PACKAGE_MANAGER="dnf"
            else
                PACKAGE_MANAGER="yum"
            fi
            ;;
        fedora)
            # Fedora has used dnf since version 22
            if [[ -n "$OS_VERSION_MAJOR" ]] && (( OS_VERSION_MAJOR >= 22 )); then
                PACKAGE_MANAGER="dnf"
            elif command -v dnf >/dev/null 2>&1; then
                PACKAGE_MANAGER="dnf"
            else
                PACKAGE_MANAGER="yum"
            fi
            ;;
        amzn)
            # Amazon Linux 2023+ uses dnf, Amazon Linux 2 uses yum
            if [[ -n "$OS_VERSION_MAJOR" ]] && (( OS_VERSION_MAJOR >= 2023 )); then
                PACKAGE_MANAGER="dnf"
            elif command -v dnf >/dev/null 2>&1; then
                PACKAGE_MANAGER="dnf"
            else
                PACKAGE_MANAGER="yum"
            fi
            ;;
        sles|opensuse*|opensuse-leap|opensuse-tumbleweed)
            PACKAGE_MANAGER="zypper"
            ;;
        arch|manjaro)
            PACKAGE_MANAGER="pacman"
            ;;
        alpine)
            PACKAGE_MANAGER="apk"
            ;;
        freebsd)
            PACKAGE_MANAGER="pkg"
            ;;
        *)
            # Try to detect package manager if distro unknown
            if command -v pkg >/dev/null 2>&1 && [[ "$(uname -s)" == "FreeBSD" ]]; then
                PACKAGE_MANAGER="pkg"
            elif command -v apt-get >/dev/null 2>&1; then
                PACKAGE_MANAGER="apt-get"
            elif command -v dnf >/dev/null 2>&1; then
                PACKAGE_MANAGER="dnf"
            elif command -v yum >/dev/null 2>&1; then
                PACKAGE_MANAGER="yum"
            elif command -v zypper >/dev/null 2>&1; then
                PACKAGE_MANAGER="zypper"
            elif command -v pacman >/dev/null 2>&1; then
                PACKAGE_MANAGER="pacman"
            elif command -v apk >/dev/null 2>&1; then
                PACKAGE_MANAGER="apk"
            else
                PACKAGE_MANAGER="unknown"
            fi
            ;;
    esac
}

diagnose_package_install_failure() {
    local package="$1"
    
    echo "" | tee -a "$OUTPUT_FILE"
    log_error "Failed to install required package: ${package}"
    echo "" | tee -a "$OUTPUT_FILE"
    echo "DIAGNOSTIC INFORMATION:" | tee -a "$OUTPUT_FILE"
    echo "======================" | tee -a "$OUTPUT_FILE"
    
    # Check repository configuration
    case "$PACKAGE_MANAGER" in
        apt-get)
            echo "Repository configuration:" | tee -a "$OUTPUT_FILE"
            if [[ -f /etc/apt/sources.list ]]; then
                echo "  - /etc/apt/sources.list exists" | tee -a "$OUTPUT_FILE"
                local repo_count=$(grep -v "^#" /etc/apt/sources.list | grep -c "^deb" || echo "0")
                echo "  - Active repositories: ${repo_count}" | tee -a "$OUTPUT_FILE"
            fi
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Try updating package cache:" | tee -a "$OUTPUT_FILE"
            echo "  sudo apt-get update" | tee -a "$OUTPUT_FILE"
            ;;
        yum|dnf)
            echo "Repository configuration:" | tee -a "$OUTPUT_FILE"
            local repo_count=$($PACKAGE_MANAGER repolist 2>/dev/null | grep -c "^[^!]" || echo "0")
            echo "  - Active repositories: ${repo_count}" | tee -a "$OUTPUT_FILE"
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Try:" | tee -a "$OUTPUT_FILE"
            echo "  sudo ${PACKAGE_MANAGER} clean all" | tee -a "$OUTPUT_FILE"
            echo "  sudo ${PACKAGE_MANAGER} makecache" | tee -a "$OUTPUT_FILE"
            ;;
        pkg)
            echo "Repository configuration:" | tee -a "$OUTPUT_FILE"
            echo "  Check /etc/pkg/FreeBSD.conf" | tee -a "$OUTPUT_FILE"
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Try:" | tee -a "$OUTPUT_FILE"
            echo "  sudo pkg update -f" | tee -a "$OUTPUT_FILE"
            ;;
    esac
    
    # Check disk space
    echo "" | tee -a "$OUTPUT_FILE"
    local root_usage=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    echo "Disk space on /: ${root_usage}% used" | tee -a "$OUTPUT_FILE"
    if (( root_usage > 90 )); then
        echo "  ⚠️  WARNING: Low disk space may prevent package installation" | tee -a "$OUTPUT_FILE"
    fi
    
    # Manual installation instructions
    echo "" | tee -a "$OUTPUT_FILE"
    echo "MANUAL INSTALLATION:" | tee -a "$OUTPUT_FILE"
    echo "===================" | tee -a "$OUTPUT_FILE"
    
    case "$DISTRO" in
        ubuntu|debian)
            echo "Try installing manually:" | tee -a "$OUTPUT_FILE"
            echo "  sudo apt-get update" | tee -a "$OUTPUT_FILE"
            echo "  sudo apt-get install -y ${package}" | tee -a "$OUTPUT_FILE"
            ;;
        rhel|centos|fedora|amzn|rocky|alma)
            echo "Try installing manually:" | tee -a "$OUTPUT_FILE"
            echo "  sudo ${PACKAGE_MANAGER} install -y ${package}" | tee -a "$OUTPUT_FILE"
            ;;
        freebsd)
            echo "Try installing manually:" | tee -a "$OUTPUT_FILE"
            echo "  sudo pkg install -y ${package}" | tee -a "$OUTPUT_FILE"
            ;;
    esac
    
    echo "" | tee -a "$OUTPUT_FILE"
    echo "The script will continue with limited functionality..." | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"
}

install_package() {
    local package="$1"
    
    log_info "Installing ${package}..."
    
    case "$PACKAGE_MANAGER" in
        apt-get)
            if apt-get update >/dev/null 2>&1 && apt-get install -y "$package" >/dev/null 2>&1; then
                log_success "${package} installed successfully"
                return 0
            fi
            ;;
        yum|dnf)
            if $PACKAGE_MANAGER install -y "$package" >/dev/null 2>&1; then
                log_success "${package} installed successfully"
                return 0
            fi
            ;;
        zypper)
            if zypper install -y "$package" >/dev/null 2>&1; then
                log_success "${package} installed successfully"
                return 0
            fi
            ;;
        pacman)
            if pacman -S --noconfirm "$package" >/dev/null 2>&1; then
                log_success "${package} installed successfully"
                return 0
            fi
            ;;
        apk)
            if apk add --no-cache "$package" >/dev/null 2>&1; then
                log_success "${package} installed successfully"
                return 0
            fi
            ;;
        pkg)
            if pkg install -y "$package" >/dev/null 2>&1; then
                log_success "${package} installed successfully"
                return 0
            fi
            ;;
        *)
            log_warning "Unknown package manager - cannot auto-install ${package}"
            MISSING_PACKAGES+=("$package")
            return 1
            ;;
    esac
    
    diagnose_package_install_failure "$package"
    MISSING_PACKAGES+=("$package")
    return 1
}

# Get the correct package name for a tool based on distro
get_package_name() {
    local tool="$1"
    local pkg=""
    
    case "$tool" in
        # Basic performance tools
        mpstat|iostat|sar)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="sysstat" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="sysstat" ;;
                sles|opensuse*) pkg="sysstat" ;;
                arch|manjaro) pkg="sysstat" ;;
                alpine) pkg="sysstat" ;;
                freebsd) pkg="sysutils/sysstat" ;;
                *) pkg="sysstat" ;;
            esac
            ;;
        vmstat)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="procps" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="procps-ng" ;;
                sles|opensuse*) pkg="procps" ;;
                arch|manjaro) pkg="procps-ng" ;;
                alpine) pkg="procps" ;;
                freebsd) pkg="base" ;;  # vmstat is part of FreeBSD base system
                *) pkg="procps" ;;
            esac
            ;;
        netstat)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="net-tools" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="net-tools" ;;
                sles|opensuse*) pkg="net-tools" ;;
                arch|manjaro) pkg="net-tools" ;;
                alpine) pkg="net-tools" ;;
                freebsd) pkg="base" ;;  # netstat is part of FreeBSD base system
                *) pkg="net-tools" ;;
            esac
            ;;
        bc)
            case "$DISTRO" in
                freebsd) pkg="math/bc" ;;
                *) pkg="bc" ;;
            esac
            ;;
        # Storage profiling tools
        smartctl)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="smartmontools" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="smartmontools" ;;
                sles|opensuse*) pkg="smartmontools" ;;
                arch|manjaro) pkg="smartmontools" ;;
                alpine) pkg="smartmontools" ;;
                freebsd) pkg="sysutils/smartmontools" ;;
                *) pkg="smartmontools" ;;
            esac
            ;;
        nvme)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="nvme-cli" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="nvme-cli" ;;
                sles|opensuse*) pkg="nvme-cli" ;;
                arch|manjaro) pkg="nvme-cli" ;;
                alpine) pkg="nvme-cli" ;;
                freebsd) pkg="sysutils/nvme-cli" ;;
                *) pkg="nvme-cli" ;;
            esac
            ;;
        lsblk|blkid)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="util-linux" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="util-linux" ;;
                sles|opensuse*) pkg="util-linux" ;;
                arch|manjaro) pkg="util-linux" ;;
                alpine) pkg="util-linux" ;;
                freebsd) pkg="none" ;;  # FreeBSD uses geom/gpart/camcontrol instead
                *) pkg="util-linux" ;;
            esac
            ;;
        pvs|vgs|lvs)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="lvm2" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="lvm2" ;;
                sles|opensuse*) pkg="lvm2" ;;
                arch|manjaro) pkg="lvm2" ;;
                alpine) pkg="lvm2" ;;
                freebsd) pkg="none" ;;  # FreeBSD uses GEOM/ZFS instead of LVM
                *) pkg="lvm2" ;;
            esac
            ;;
        mdadm)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="mdadm" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="mdadm" ;;
                sles|opensuse*) pkg="mdadm" ;;
                arch|manjaro) pkg="mdadm" ;;
                alpine) pkg="mdadm" ;;
                freebsd) pkg="none" ;;  # FreeBSD uses GEOM (gmirror/graid) instead of mdadm
                *) pkg="mdadm" ;;
            esac
            ;;
        iscsiadm)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="open-iscsi" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="iscsi-initiator-utils" ;;
                sles|opensuse*) pkg="open-iscsi" ;;
                arch|manjaro) pkg="open-iscsi" ;;
                alpine) pkg="open-iscsi" ;;
                freebsd) pkg="net/iscsi-initiator-utils" ;;
                *) pkg="open-iscsi" ;;
            esac
            ;;
        multipath)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="multipath-tools" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="device-mapper-multipath" ;;
                sles|opensuse*) pkg="multipath-tools" ;;
                arch|manjaro) pkg="multipath-tools" ;;
                freebsd) pkg="sysutils/mpath-tools" ;;
                *) pkg="multipath-tools" ;;
            esac
            ;;
        fio)
            case "$DISTRO" in
                freebsd) pkg="benchmarks/fio" ;;
                *) pkg="fio" ;;
            esac
            ;;
        iotop)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="iotop" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="iotop" ;;
                sles|opensuse*) pkg="iotop" ;;
                arch|manjaro) pkg="iotop" ;;
                alpine) pkg="iotop" ;;
                freebsd) pkg="sysutils/py-iotop" ;;
                *) pkg="iotop" ;;
            esac
            ;;
        e4defrag)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="e2fsprogs" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="e2fsprogs" ;;
                *) pkg="e2fsprogs" ;;
            esac
            ;;
        xfs_db)
            case "$DISTRO" in
                ubuntu|debian|linuxmint|pop) pkg="xfsprogs" ;;
                rhel|centos|fedora|amzn|rocky|alma|ol) pkg="xfsprogs" ;;
                *) pkg="xfsprogs" ;;
            esac
            ;;
        *)
            pkg="$tool"
            ;;
    esac
    
    echo "$pkg"
}

# Check if a tool exists, if not try to install it
ensure_tool() {
    local tool="$1"
    local optional="${2:-false}"
    
    if command -v "$tool" >/dev/null 2>&1; then
        return 0
    fi
    
    local pkg=$(get_package_name "$tool")
    
    if [[ "$optional" == "true" ]]; then
        log_info "Optional tool '$tool' not found, attempting to install ($pkg)..."
    else
        log_warning "Required tool '$tool' not found, attempting to install ($pkg)..."
    fi
    
    if install_package "$pkg"; then
        # Verify the tool is now available
        if command -v "$tool" >/dev/null 2>&1; then
            return 0
        else
            log_warning "Package installed but '$tool' still not available"
            return 1
        fi
    else
        return 1
    fi
}

check_and_install_dependencies() {
    log_info "Checking required utilities for ${OS_NAME:-$DISTRO}..."
    
    # Core performance monitoring tools
    local core_tools=("mpstat" "iostat" "vmstat" "netstat" "bc")
    
    # Check and install core tools
    local missing=false
    for tool in "${core_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_warning "${tool} not found"
            
            local pkg=$(get_package_name "$tool")
            if [[ "$pkg" != "base" ]] && [[ -n "$pkg" ]]; then
                if install_package "$pkg"; then
                    # Verify installation
                    if ! command -v "$tool" >/dev/null 2>&1; then
                        log_warning "${tool} still not available after installing $pkg"
                        missing=true
                    else
                        log_success "${tool} is now available"
                    fi
                else
                    missing=true
                fi
            else
                log_warning "${tool} should be part of base system but is missing"
                missing=true
            fi
        fi
    done
    
    # Check for modern alternatives (ss instead of netstat, ip instead of ifconfig)
    if ! command -v netstat >/dev/null 2>&1; then
        if command -v ss >/dev/null 2>&1; then
            log_info "Using 'ss' as alternative to netstat"
        fi
    fi
    
    if [[ "$missing" == true ]]; then
        log_warning "Some utilities are missing - diagnostics will be limited"
        if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Missing packages: ${MISSING_PACKAGES[*]}" | tee -a "$OUTPUT_FILE"
            echo "The script will continue with available tools..." | tee -a "$OUTPUT_FILE"
        fi
    else
        log_success "All required utilities are available"
    fi
    
    # Show OS-specific notes
    echo "" | tee -a "$OUTPUT_FILE"
    case "$DISTRO" in
        ubuntu|debian|linuxmint|pop)
            if [[ -n "$OS_VERSION_MAJOR" ]] && (( OS_VERSION_MAJOR >= 22 )); then
                log_info "Note: Ubuntu 22.04+ uses systemd-resolved for DNS"
            fi
            ;;
        rhel|centos|rocky|alma|ol)
            if [[ -n "$OS_VERSION_MAJOR" ]] && (( OS_VERSION_MAJOR >= 8 )); then
                log_info "Note: RHEL 8+ uses nftables instead of iptables by default"
            fi
            ;;
        fedora)
            if [[ -n "$OS_VERSION_MAJOR" ]] && (( OS_VERSION_MAJOR >= 33 )); then
                log_info "Note: Fedora 33+ uses btrfs as default filesystem"
            fi
            ;;
        amzn)
            if [[ "$OS_VERSION" == "2" ]]; then
                log_info "Note: Amazon Linux 2 (based on RHEL 7)"
            elif [[ -n "$OS_VERSION_MAJOR" ]] && (( OS_VERSION_MAJOR >= 2023 )); then
                log_info "Note: Amazon Linux 2023 (based on Fedora)"
            fi
            ;;
    esac
}

#############################################################################
# Helper Functions
#############################################################################

log_info() {
    local msg="$1"
    echo -e "${CYAN}[$(date +%H:%M:%S)] ${msg}${NC}" | tee -a "$OUTPUT_FILE"
}

log_success() {
    local msg="$1"
    echo -e "${GREEN}[$(date +%H:%M:%S)] ${msg}${NC}" | tee -a "$OUTPUT_FILE"
}

log_warning() {
    local msg="$1"
    echo -e "${YELLOW}[$(date +%H:%M:%S)] ${msg}${NC}" | tee -a "$OUTPUT_FILE"
}

log_error() {
    local msg="$1"
    echo -e "${RED}[$(date +%H:%M:%S)] ${msg}${NC}" | tee -a "$OUTPUT_FILE"
}

log_bottleneck() {
    local category="$1"
    local issue="$2"
    local current="$3"
    local threshold="$4"
    local impact="$5"
    
    BOTTLENECKS+=("${impact}|${category}|${issue}|${current}|${threshold}")
    echo -e "${MAGENTA}[$(date +%H:%M:%S)] BOTTLENECK FOUND: ${category} - ${issue} (Current: ${current}, Threshold: ${threshold})${NC}" | tee -a "$OUTPUT_FILE"
}

print_header() {
    local title="$1"
    echo "" | tee -a "$OUTPUT_FILE"
    echo "================================================================================" | tee -a "$OUTPUT_FILE"
    echo "  ${title}" | tee -a "$OUTPUT_FILE"
    echo "================================================================================" | tee -a "$OUTPUT_FILE"
    echo "" | tee -a "$OUTPUT_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_warning "Command '$1' not found. Some diagnostics may be limited."
        return 1
    fi
    return 0
}

#############################################################################
# System Information
#############################################################################

collect_system_info() {
    print_header "SYSTEM INFORMATION"
    
    log_info "Gathering system information..."
    
    # Basic system info
    echo "Hostname: $(hostname)" | tee -a "$OUTPUT_FILE"
    echo "Kernel: $(uname -r)" | tee -a "$OUTPUT_FILE"
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)" | tee -a "$OUTPUT_FILE"
    echo "Architecture: $(uname -m)" | tee -a "$OUTPUT_FILE"
    echo "Uptime: $(uptime -p)" | tee -a "$OUTPUT_FILE"
    
    # CPU info
    local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    local cpu_cores=$(nproc)
    echo "CPU: ${cpu_model}" | tee -a "$OUTPUT_FILE"
    echo "CPU Cores: ${cpu_cores}" | tee -a "$OUTPUT_FILE"
    
    # Memory info
    local total_mem=$(free -h | grep Mem | awk '{print $2}')
    echo "Total Memory: ${total_mem}" | tee -a "$OUTPUT_FILE"
    
    # Check if running on EC2
    if curl -s -m 2 http://169.254.169.254/latest/meta-data/instance-id &>/dev/null; then
        local instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
        local instance_type=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
        local az=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
        echo "Instance ID: ${instance_id}" | tee -a "$OUTPUT_FILE"
        echo "Instance Type: ${instance_type}" | tee -a "$OUTPUT_FILE"
        echo "Availability Zone: ${az}" | tee -a "$OUTPUT_FILE"
    else
        echo "Instance ID: Not EC2" | tee -a "$OUTPUT_FILE"
    fi
    
    log_success "System information collected"
}

#############################################################################
# CPU Forensics
#############################################################################

analyze_cpu() {
    print_header "CPU FORENSICS"
    
    if [[ "$MODE" == "disk" ]] || [[ "$MODE" == "memory" ]]; then
        log_info "Skipping CPU forensics in ${MODE} mode"
        return
    fi
    
    log_info "Analyzing CPU performance..."
    
    # Load average
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local load_1min=$(echo "$load_avg" | cut -d',' -f1 | xargs)
    local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
    
    if command -v bc >/dev/null 2>&1; then
        local load_per_core=$(echo "scale=2; $load_1min / $cpu_cores" | bc)
    else
        local load_per_core=$(awk "BEGIN {printf \"%.2f\", $load_1min / $cpu_cores}")
    fi
    
    echo "Load Average: ${load_avg}" | tee -a "$OUTPUT_FILE"
    echo "Load per Core: ${load_per_core}" | tee -a "$OUTPUT_FILE"
    
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "$load_per_core > 1.0" | bc -l) )); then
            log_bottleneck "CPU" "High load average" "${load_per_core} per core" "1.0 per core" "High"
        fi
    else
        if (( $(awk "BEGIN {print ($load_per_core > 1.0)}") )); then
            log_bottleneck "CPU" "High load average" "${load_per_core} per core" "1.0 per core" "High"
        fi
    fi
    
    # CPU usage - try mpstat first, fallback to top
    if command -v mpstat >/dev/null 2>&1; then
        log_info "Sampling CPU usage with mpstat (10 seconds)..."
        local cpu_idle=$(mpstat 1 10 2>/dev/null | tail -1 | awk '{print $NF}')
        if command -v bc >/dev/null 2>&1; then
            local cpu_usage=$(echo "scale=2; 100 - $cpu_idle" | bc)
        else
            local cpu_usage=$(awk "BEGIN {printf \"%.2f\", 100 - $cpu_idle}")
        fi
    else
        log_warning "mpstat not available, using top for CPU sampling..."
        local cpu_idle=$(top -bn2 -d1 | grep "Cpu(s)" | tail -1 | awk '{print $8}' | sed 's/%id,//')
        if command -v bc >/dev/null 2>&1; then
            local cpu_usage=$(echo "scale=2; 100 - $cpu_idle" | bc)
        else
            local cpu_usage=$(awk "BEGIN {printf \"%.2f\", 100 - $cpu_idle}")
        fi
    fi
    
    echo "CPU Usage: ${cpu_usage}%" | tee -a "$OUTPUT_FILE"
    
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "$cpu_usage > 80" | bc -l) )); then
            log_bottleneck "CPU" "High CPU utilization" "${cpu_usage}%" "80%" "High"
        fi
    else
        if (( $(awk "BEGIN {print ($cpu_usage > 80)}") )); then
            log_bottleneck "CPU" "High CPU utilization" "${cpu_usage}%" "80%" "High"
        fi
    fi
    
    # Context switches - try vmstat
    if command -v vmstat >/dev/null 2>&1; then
        local ctx_switches=$(vmstat 1 5 2>/dev/null | tail -1 | awk '{print $12}')
        echo "Context Switches: ${ctx_switches}/sec" | tee -a "$OUTPUT_FILE"
        
        if (( ctx_switches > 15000 )); then
            log_bottleneck "CPU" "Excessive context switches" "${ctx_switches}/sec" "15000/sec" "Medium"
        fi
    else
        log_warning "vmstat not available - skipping context switch analysis"
    fi
    
    # CPU steal time (for VMs) - only if mpstat available
    if command -v mpstat >/dev/null 2>&1; then
        local cpu_steal=$(mpstat 1 5 2>/dev/null | tail -1 | awk '{print $(NF-1)}')
        echo "CPU Steal Time: ${cpu_steal}%" | tee -a "$OUTPUT_FILE"
        
        if command -v bc >/dev/null 2>&1; then
            if (( $(echo "$cpu_steal > 10" | bc -l) )); then
                log_bottleneck "CPU" "High CPU steal time (hypervisor contention)" "${cpu_steal}%" "10%" "High"
            fi
        else
            if (( $(awk "BEGIN {print ($cpu_steal > 10)}") )); then
                log_bottleneck "CPU" "High CPU steal time (hypervisor contention)" "${cpu_steal}%" "10%" "High"
            fi
        fi
    fi
    
    # Top CPU consumers
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Top 10 CPU-consuming processes:" | tee -a "$OUTPUT_FILE"
    ps aux --sort=-%cpu 2>/dev/null | head -11 | tail -10 | awk '{printf "  %-20s PID: %-8s CPU: %5s%% MEM: %5s%%\n", $11, $2, $3, $4}' | tee -a "$OUTPUT_FILE" || \
    ps -eo comm,pid,pcpu,pmem --sort=-pcpu 2>/dev/null | head -11 | tail -10 | tee -a "$OUTPUT_FILE" || \
    log_warning "Unable to list top CPU consumers"
    
    # ==========================================================================
    # SAR CPU ANALYSIS (Real-time and Historical)
    # ==========================================================================
    if command -v sar >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "--- SAR CPU ANALYSIS ---" | tee -a "$OUTPUT_FILE"
        
        # Real-time CPU sampling with sar
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Real-time CPU Sampling (sar -u, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -u 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -u failed"
        
        # Load average history with sar
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Run Queue and Load Average (sar -q, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -q 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -q failed"
        
        # Per-CPU breakdown
        if [[ "$MODE" == "deep" ]]; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Per-CPU Breakdown (sar -P ALL, 3 samples):" | tee -a "$OUTPUT_FILE"
            sar -P ALL 1 3 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -P ALL failed"
        fi
        
        # Check for historical sar data
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Historical SAR Data (today):" | tee -a "$OUTPUT_FILE"
        
        # Try different sar data locations
        local sar_data_found=false
        for sar_dir in /var/log/sa /var/log/sysstat /var/log/sysstat/sa; do
            if [[ -d "$sar_dir" ]]; then
                local today=$(date +%d)
                local sar_file="${sar_dir}/sa${today}"
                
                if [[ -f "$sar_file" ]]; then
                    echo "  Found sar data: $sar_file" | tee -a "$OUTPUT_FILE"
                    sar_data_found=true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  CPU History (today):" | tee -a "$OUTPUT_FILE"
                    sar -u -f "$sar_file" 2>/dev/null | tail -20 | tee -a "$OUTPUT_FILE" || true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  Load Average History (today):" | tee -a "$OUTPUT_FILE"
                    sar -q -f "$sar_file" 2>/dev/null | tail -20 | tee -a "$OUTPUT_FILE" || true
                    
                    break
                fi
            fi
        done
        
        if [[ "$sar_data_found" == "false" ]]; then
            echo "  No historical sar data found." | tee -a "$OUTPUT_FILE"
            echo "  To enable: systemctl enable --now sysstat (or enable sysstat cron)" | tee -a "$OUTPUT_FILE"
        fi
    else
        echo "" | tee -a "$OUTPUT_FILE"
        echo "sar not available - install sysstat for detailed CPU history" | tee -a "$OUTPUT_FILE"
    fi
    
    log_success "CPU forensics completed"
}

#############################################################################
# Memory Forensics
#############################################################################

analyze_memory() {
    print_header "MEMORY FORENSICS"
    
    if [[ "$MODE" == "disk" ]] || [[ "$MODE" == "cpu" ]]; then
        log_info "Skipping memory forensics in ${MODE} mode"
        return
    fi
    
    log_info "Analyzing memory usage..."
    
    # Memory statistics
    local total_mem=$(free -m 2>/dev/null | grep Mem | awk '{print $2}')
    local used_mem=$(free -m 2>/dev/null | grep Mem | awk '{print $3}')
    local free_mem=$(free -m 2>/dev/null | grep Mem | awk '{print $4}')
    local available_mem=$(free -m 2>/dev/null | grep Mem | awk '{print $7}')
    
    if [[ -z "$total_mem" ]]; then
        log_warning "Unable to get memory statistics"
        return
    fi
    
    if command -v bc >/dev/null 2>&1; then
        local mem_usage_pct=$(echo "scale=2; ($used_mem / $total_mem) * 100" | bc)
        local mem_available_pct=$(echo "scale=2; ($available_mem / $total_mem) * 100" | bc)
    else
        local mem_usage_pct=$(awk "BEGIN {printf \"%.2f\", ($used_mem / $total_mem) * 100}")
        local mem_available_pct=$(awk "BEGIN {printf \"%.2f\", ($available_mem / $total_mem) * 100}")
    fi
    
    echo "Total Memory: ${total_mem} MB" | tee -a "$OUTPUT_FILE"
    echo "Used Memory: ${used_mem} MB (${mem_usage_pct}%)" | tee -a "$OUTPUT_FILE"
    echo "Available Memory: ${available_mem} MB (${mem_available_pct}%)" | tee -a "$OUTPUT_FILE"
    
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "$mem_available_pct < 10" | bc -l) )); then
            log_bottleneck "Memory" "Low available memory" "${mem_available_pct}%" "10%" "Critical"
        fi
    else
        if (( $(awk "BEGIN {print ($mem_available_pct < 10)}") )); then
            log_bottleneck "Memory" "Low available memory" "${mem_available_pct}%" "10%" "Critical"
        fi
    fi
    
    # Swap usage
    local total_swap=$(free -m 2>/dev/null | grep Swap | awk '{print $2}')
    if [[ -n "$total_swap" ]] && (( total_swap > 0 )); then
        local used_swap=$(free -m 2>/dev/null | grep Swap | awk '{print $3}')
        if command -v bc >/dev/null 2>&1; then
            local swap_usage_pct=$(echo "scale=2; ($used_swap / $total_swap) * 100" | bc)
        else
            local swap_usage_pct=$(awk "BEGIN {printf \"%.2f\", ($used_swap / $total_swap) * 100}")
        fi
        echo "Swap Usage: ${used_swap} MB / ${total_swap} MB (${swap_usage_pct}%)" | tee -a "$OUTPUT_FILE"
        
        if command -v bc >/dev/null 2>&1; then
            if (( $(echo "$swap_usage_pct > 50" | bc -l) )); then
                log_bottleneck "Memory" "High swap usage" "${swap_usage_pct}%" "50%" "High"
            fi
        else
            if (( $(awk "BEGIN {print ($swap_usage_pct > 50)}") )); then
                log_bottleneck "Memory" "High swap usage" "${swap_usage_pct}%" "50%" "High"
            fi
        fi
    else
        echo "Swap: Not configured" | tee -a "$OUTPUT_FILE"
    fi
    
    # Page faults
    if command -v vmstat >/dev/null 2>&1; then
        log_info "Sampling page faults (5 seconds)..."
        local page_faults=$(vmstat 1 5 2>/dev/null | tail -1 | awk '{print $7}')
        if [[ -n "$page_faults" ]]; then
            echo "Page Faults: ${page_faults}/sec" | tee -a "$OUTPUT_FILE"
            
            if (( page_faults > 1000 )); then
                log_bottleneck "Memory" "High page fault rate" "${page_faults}/sec" "1000/sec" "Medium"
            fi
        fi
    fi
    
    # Memory pressure indicators
    if [[ -f /proc/pressure/memory ]]; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Memory Pressure (PSI):" | tee -a "$OUTPUT_FILE"
        cat /proc/pressure/memory | tee -a "$OUTPUT_FILE"
    fi
    
    # Slab memory usage
    if [[ -f /proc/meminfo ]]; then
        local slab_mem=$(grep "^Slab:" /proc/meminfo | awk '{print $2}')
        local slab_reclaimable=$(grep "^SReclaimable:" /proc/meminfo | awk '{print $2}')
        local slab_unreclaimable=$(grep "^SUnreclaim:" /proc/meminfo | awk '{print $2}')
        
        if [[ -n "$slab_mem" ]]; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Slab Memory: $((slab_mem / 1024)) MB" | tee -a "$OUTPUT_FILE"
            echo "  Reclaimable: $((slab_reclaimable / 1024)) MB" | tee -a "$OUTPUT_FILE"
            echo "  Unreclaimable: $((slab_unreclaimable / 1024)) MB" | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    # OOM killer check
    if command -v dmesg >/dev/null 2>&1; then
        if dmesg 2>/dev/null | grep -i "out of memory" | tail -5 | grep -q .; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Recent OOM (Out of Memory) events detected:" | tee -a "$OUTPUT_FILE"
            dmesg 2>/dev/null | grep -i "out of memory" | tail -5 | tee -a "$OUTPUT_FILE"
            log_bottleneck "Memory" "OOM killer invoked recently" "Yes" "No" "Critical"
        fi
    fi
    
    # Check for memory leaks - processes with high VSZ but low RSS
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Potential memory leak candidates (high virtual, low resident):" | tee -a "$OUTPUT_FILE"
    ps aux 2>/dev/null | awk '$5 > 2097152 && $6 < ($5 * 0.3) {printf "  %-20s PID: %-8s VSZ: %8d KB RSS: %8d KB\n", $11, $2, $5, $6}' | head -5 | tee -a "$OUTPUT_FILE" || \
    echo "  No significant candidates found" | tee -a "$OUTPUT_FILE"
    
    # Top memory consumers
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Top 10 memory-consuming processes:" | tee -a "$OUTPUT_FILE"
    ps aux --sort=-%mem 2>/dev/null | head -11 | tail -10 | awk '{printf "  %-20s PID: %-8s MEM: %5s%% CPU: %5s%%\n", $11, $2, $4, $3}' | tee -a "$OUTPUT_FILE" || \
    ps -eo comm,pid,pmem,pcpu --sort=-pmem 2>/dev/null | head -11 | tail -10 | tee -a "$OUTPUT_FILE" || \
    log_warning "Unable to list top memory consumers"
    
    # Huge pages status
    if [[ -f /proc/meminfo ]]; then
        local hugepages_total=$(grep "^HugePages_Total:" /proc/meminfo | awk '{print $2}')
        local hugepages_free=$(grep "^HugePages_Free:" /proc/meminfo | awk '{print $2}')
        if [[ -n "$hugepages_total" ]] && (( hugepages_total > 0 )); then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Huge Pages: ${hugepages_free} free / ${hugepages_total} total" | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    # ==========================================================================
    # SAR MEMORY ANALYSIS (Real-time and Historical)
    # ==========================================================================
    if command -v sar >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "--- SAR MEMORY ANALYSIS ---" | tee -a "$OUTPUT_FILE"
        
        # Real-time memory sampling with sar
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Real-time Memory Sampling (sar -r, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -r 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -r failed"
        
        # Swap usage with sar
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Swap Activity (sar -S, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -S 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -S failed"
        
        # Page statistics
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Paging Statistics (sar -B, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -B 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -B failed"
        
        # Check for historical sar data
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Historical Memory Data (today):" | tee -a "$OUTPUT_FILE"
        
        local sar_data_found=false
        for sar_dir in /var/log/sa /var/log/sysstat /var/log/sysstat/sa; do
            if [[ -d "$sar_dir" ]]; then
                local today=$(date +%d)
                local sar_file="${sar_dir}/sa${today}"
                
                if [[ -f "$sar_file" ]]; then
                    sar_data_found=true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  Memory History (today):" | tee -a "$OUTPUT_FILE"
                    sar -r -f "$sar_file" 2>/dev/null | tail -20 | tee -a "$OUTPUT_FILE" || true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  Swap History (today):" | tee -a "$OUTPUT_FILE"
                    sar -S -f "$sar_file" 2>/dev/null | tail -20 | tee -a "$OUTPUT_FILE" || true
                    
                    break
                fi
            fi
        done
        
        if [[ "$sar_data_found" == "false" ]]; then
            echo "  No historical sar data found." | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    log_success "Memory forensics completed"
}

#############################################################################
# Disk I/O Forensics
#############################################################################

analyze_disk() {
    print_header "DISK I/O FORENSICS"
    
    if [[ "$MODE" == "cpu" ]] || [[ "$MODE" == "memory" ]]; then
        log_info "Skipping disk forensics in ${MODE} mode"
        return
    fi
    
    log_info "Analyzing disk I/O performance..."
    
    # Disk usage
    echo "Disk Usage:" | tee -a "$OUTPUT_FILE"
    df -h 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | tee -a "$OUTPUT_FILE" || \
    df -k 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | tee -a "$OUTPUT_FILE" || \
    log_warning "Unable to get disk usage information"
    
    # Check for full filesystems
    while IFS= read -r line; do
        local usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        local mount=$(echo "$line" | awk '{print $6}')
        if [[ -n "$usage" ]] && (( usage > 90 )); then
            log_bottleneck "Disk" "Filesystem nearly full: ${mount}" "${usage}%" "90%" "High"
        fi
    done < <(df -h 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | tail -n +2 || df -k 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | tail -n +2)
    
    # I/O statistics - try iostat
    if command -v iostat >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        log_info "Sampling I/O statistics (10 seconds)..."
        iostat -x 1 10 2>/dev/null | tail -n +4 > /tmp/iostat_output.txt 2>/dev/null || true
        
        if [[ -s /tmp/iostat_output.txt ]]; then
            echo "I/O Statistics:" | tee -a "$OUTPUT_FILE"
            cat /tmp/iostat_output.txt | tee -a "$OUTPUT_FILE"
            
            # Analyze I/O wait
            local avg_await=$(cat /tmp/iostat_output.txt | grep -v "^$" | grep -v "Device" | awk '{sum+=$10; count++} END {if(count>0) print sum/count; else print 0}')
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Average I/O Wait Time: ${avg_await} ms" | tee -a "$OUTPUT_FILE"
            
            if command -v bc >/dev/null 2>&1; then
                if (( $(echo "$avg_await > 20" | bc -l) )); then
                    log_bottleneck "Disk" "High I/O wait time" "${avg_await}ms" "20ms" "High"
                fi
            else
                if (( $(awk "BEGIN {print ($avg_await > 20)}") )); then
                    log_bottleneck "Disk" "High I/O wait time" "${avg_await}ms" "20ms" "High"
                fi
            fi
            
            rm -f /tmp/iostat_output.txt
        else
            log_warning "iostat produced no output"
        fi
    else
        log_warning "iostat not available - skipping detailed I/O statistics"
    fi
    
    # Check for processes in uninterruptible sleep (I/O wait)
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Processes in I/O Wait (D state):" | tee -a "$OUTPUT_FILE"
    local io_wait_procs=$(ps aux | awk '$8 ~ /D/' | wc -l)
    if (( io_wait_procs > 0 )); then
        ps aux | awk 'NR==1 || $8 ~ /D/' | head -20 | tee -a "$OUTPUT_FILE"
        if (( io_wait_procs > 5 )); then
            log_bottleneck "Disk" "High I/O wait - processes stuck in uninterruptible sleep" "${io_wait_procs}" "5" "High"
        fi
    else
        echo "  No processes in I/O wait" | tee -a "$OUTPUT_FILE"
    fi
    
    # Top I/O consumers using iotop if available
    if command -v iotop >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Top I/O Consumers (iotop):" | tee -a "$OUTPUT_FILE"
        timeout 5 iotop -b -n 2 -o 2>/dev/null | tail -20 | tee -a "$OUTPUT_FILE" || echo "  Unable to run iotop" | tee -a "$OUTPUT_FILE"
    else
        echo "" | tee -a "$OUTPUT_FILE"
        echo "iotop not available - install with package manager for per-process I/O analysis" | tee -a "$OUTPUT_FILE"
    fi
    
    # Disk I/O test (if in disk mode or deep mode)
    if [[ "$MODE" == "disk" ]] || [[ "$MODE" == "deep" ]]; then
        if command -v dd >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            log_info "Running disk write performance test..."
            
            local test_file="/tmp/forensics_disk_test_$$"
            local write_result=$(dd if=/dev/zero of="$test_file" bs=1M count=1024 oflag=direct 2>&1 || echo "failed")
            
            if [[ "$write_result" != "failed" ]]; then
                local write_speed=$(echo "$write_result" | grep -oP '\d+\.?\d* MB/s' | head -1 || echo "N/A")
                echo "Disk Write Speed: ${write_speed}" | tee -a "$OUTPUT_FILE"
                
                log_info "Running disk read performance test..."
                sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
                local read_result=$(dd if="$test_file" of=/dev/null bs=1M 2>&1 || echo "failed")
                
                if [[ "$read_result" != "failed" ]]; then
                    local read_speed=$(echo "$read_result" | grep -oP '\d+\.?\d* MB/s' | head -1 || echo "N/A")
                    echo "Disk Read Speed: ${read_speed}" | tee -a "$OUTPUT_FILE"
                fi
            else
                log_warning "Disk performance test failed"
            fi
            
            rm -f "$test_file"
        else
            log_warning "dd command not available - skipping disk performance test"
        fi
    fi
    
    # ==========================================================================
    # SAR DISK I/O ANALYSIS (Real-time and Historical)
    # ==========================================================================
    if command -v sar >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "--- SAR DISK I/O ANALYSIS ---" | tee -a "$OUTPUT_FILE"
        
        # Real-time disk I/O with sar
        echo "" | tee -a "$OUTPUT_FILE"
        echo "I/O Transfer Rates (sar -b, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -b 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -b failed"
        
        # Per-device I/O statistics
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Per-Device I/O Statistics (sar -d, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -d 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -d failed"
        
        # Detailed disk activity in deep mode
        if [[ "$MODE" == "deep" ]]; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Extended Disk Statistics (sar -dp, 5 samples):" | tee -a "$OUTPUT_FILE"
            sar -dp 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -dp failed"
        fi
        
        # Check for historical sar data
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Historical Disk I/O Data (today):" | tee -a "$OUTPUT_FILE"
        
        local sar_data_found=false
        for sar_dir in /var/log/sa /var/log/sysstat /var/log/sysstat/sa; do
            if [[ -d "$sar_dir" ]]; then
                local today=$(date +%d)
                local sar_file="${sar_dir}/sa${today}"
                
                if [[ -f "$sar_file" ]]; then
                    sar_data_found=true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  I/O Transfer History (today):" | tee -a "$OUTPUT_FILE"
                    sar -b -f "$sar_file" 2>/dev/null | tail -20 | tee -a "$OUTPUT_FILE" || true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  Per-Device History (today):" | tee -a "$OUTPUT_FILE"
                    sar -d -f "$sar_file" 2>/dev/null | tail -30 | tee -a "$OUTPUT_FILE" || true
                    
                    break
                fi
            fi
        done
        
        if [[ "$sar_data_found" == "false" ]]; then
            echo "  No historical sar data found." | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    log_success "Disk forensics completed"
}

#############################################################################
# Storage Profiling
#############################################################################

analyze_storage_profile() {
    print_header "STORAGE PROFILING"
    
    log_info "Performing comprehensive storage analysis..."
    log_info "OS: ${OS_NAME:-$DISTRO} (Version: ${OS_VERSION:-unknown})"
    
    # ==========================================================================
    # ENSURE STORAGE TOOLS ARE AVAILABLE
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- CHECKING STORAGE TOOLS ---" | tee -a "$OUTPUT_FILE"
    
    # Core tools (try to install if missing)
    ensure_tool "lsblk" "false" || true
    ensure_tool "smartctl" "true" || true
    ensure_tool "nvme" "true" || true
    
    # LVM tools (only if LVM appears to be in use)
    if [[ -d /dev/mapper ]] || [[ -e /etc/lvm/lvm.conf ]]; then
        ensure_tool "pvs" "true" || true
    fi
    
    # RAID tools (only if RAID appears to be in use)
    if [[ -f /proc/mdstat ]] && grep -q "^md" /proc/mdstat 2>/dev/null; then
        ensure_tool "mdadm" "true" || true
    fi
    
    # iSCSI tools (only if iSCSI appears configured)
    if [[ -d /etc/iscsi ]] || [[ -f /etc/iscsi/initiatorname.iscsi ]]; then
        ensure_tool "iscsiadm" "true" || true
    fi
    
    # Multipath tools (only if multipath appears configured)
    if [[ -f /etc/multipath.conf ]] || [[ -d /etc/multipath ]]; then
        ensure_tool "multipath" "true" || true
    fi
    
    # Performance testing tools (optional)
    if [[ "$MODE" == "deep" ]] || [[ "$MODE" == "disk" ]]; then
        ensure_tool "fio" "true" || true
    fi
    
    # ==========================================================================
    # STORAGE TOPOLOGY
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- STORAGE TOPOLOGY ---" | tee -a "$OUTPUT_FILE"
    
    # FreeBSD-specific storage topology
    if [[ "$DISTRO" == "freebsd" ]]; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "GEOM Disk Configuration:" | tee -a "$OUTPUT_FILE"
        
        # Use geom disk list for disk info
        if command -v geom >/dev/null 2>&1; then
            geom disk list 2>/dev/null | grep -E "^Geom name:|Mediasize:|Sectorsize:|Mode:|descr:" | tee -a "$OUTPUT_FILE"
        fi
        
        # Use camcontrol for SCSI/SATA devices
        if command -v camcontrol >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "CAM Device List:" | tee -a "$OUTPUT_FILE"
            camcontrol devlist 2>/dev/null | tee -a "$OUTPUT_FILE"
        fi
        
        # Show gpart info for partition layout
        if command -v gpart >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Partition Layout (gpart):" | tee -a "$OUTPUT_FILE"
            for disk in $(geom disk list 2>/dev/null | grep "^Geom name:" | awk '{print $3}'); do
                echo "" | tee -a "$OUTPUT_FILE"
                echo "  === $disk ===" | tee -a "$OUTPUT_FILE"
                gpart show "$disk" 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "    No partition table" | tee -a "$OUTPUT_FILE"
            done
        fi
    else
        # Linux: Block device listing with detailed info
        if command -v lsblk >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Block Devices:" | tee -a "$OUTPUT_FILE"
            lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,ROTA,DISC-GRAN 2>/dev/null | tee -a "$OUTPUT_FILE" || \
            lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    # ==========================================================================
    # PARTITION SCHEME ANALYSIS (GPT vs MBR vs Unknown)
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- PARTITION SCHEME ANALYSIS ---" | tee -a "$OUTPUT_FILE"
    
    local gpt_count=0
    local mbr_count=0
    local unknown_count=0
    local bsdlabel_count=0
    
    # FreeBSD-specific partition scheme detection
    if [[ "$DISTRO" == "freebsd" ]]; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Checking partition schemes via gpart..." | tee -a "$OUTPUT_FILE"
        
        for disk in $(geom disk list 2>/dev/null | grep "^Geom name:" | awk '{print $3}'); do
            local disk_dev="/dev/$disk"
            
            # Get disk size
            local size_bytes=$(geom disk list "$disk" 2>/dev/null | grep "Mediasize:" | awk '{print $2}')
            local size_gb=$((size_bytes / 1024 / 1024 / 1024))
            
            # Get partition scheme from gpart
            local scheme=$(gpart show "$disk" 2>/dev/null | head -1 | awk '{print $4}')
            
            local scheme_name=""
            case "$scheme" in
                GPT)
                    scheme_name="GPT"
                    ((gpt_count++))
                    ;;
                MBR)
                    scheme_name="MBR"
                    ((mbr_count++))
                    # Warn if MBR on >2TB disk
                    if (( size_gb > 2000 )); then
                        log_bottleneck "Storage" "MBR partition on >2TB disk $disk_dev (data loss risk)" "MBR on ${size_gb}GB" "GPT" "High"
                    fi
                    ;;
                BSD)
                    scheme_name="BSD disklabel"
                    ((bsdlabel_count++))
                    ;;
                *)
                    if [[ -n "$scheme" ]]; then
                        scheme_name="$scheme"
                    else
                        scheme_name="Unknown/Unpartitioned"
                        ((unknown_count++))
                    fi
                    ;;
            esac
            
            echo "  $disk_dev: ${size_gb}GB - $scheme_name" | tee -a "$OUTPUT_FILE"
        done
        
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Partition Scheme Summary:" | tee -a "$OUTPUT_FILE"
        echo "  GPT Disks: $gpt_count (modern, UEFI compatible, >2TB support)" | tee -a "$OUTPUT_FILE"
        echo "  MBR Disks: $mbr_count (legacy, BIOS, 2TB max per partition)" | tee -a "$OUTPUT_FILE"
        if (( bsdlabel_count > 0 )); then
            echo "  BSD Disklabel: $bsdlabel_count (traditional BSD partitioning)" | tee -a "$OUTPUT_FILE"
        fi
        if (( unknown_count > 0 )); then
            echo "  Unknown/Raw: $unknown_count (unpartitioned or unrecognized)" | tee -a "$OUTPUT_FILE"
        fi
    else
        # Linux partition scheme detection
        for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/xvd*; do
        [[ -d "$disk" ]] || continue
        local disk_name=$(basename "$disk")
        local disk_dev="/dev/$disk_name"
        
        [[ -b "$disk_dev" ]] || continue
        
        # Get partition table type
        local pttype=""
        if command -v blkid >/dev/null 2>&1; then
            pttype=$(blkid -o value -s PTTYPE "$disk_dev" 2>/dev/null)
        fi
        
        # Fallback to fdisk if blkid doesn't work
        if [[ -z "$pttype" ]] && command -v fdisk >/dev/null 2>&1; then
            if fdisk -l "$disk_dev" 2>/dev/null | grep -q "GPT"; then
                pttype="gpt"
            elif fdisk -l "$disk_dev" 2>/dev/null | grep -q "DOS"; then
                pttype="dos"
            fi
        fi
        
        # Get disk size
        local size_bytes=$(cat "$disk/size" 2>/dev/null)
        local size_gb=$((size_bytes * 512 / 1024 / 1024 / 1024))
        
        # Determine partition scheme
        local scheme_name=""
        case "$pttype" in
            gpt)
                scheme_name="GPT"
                ((gpt_count++))
                ;;
            dos|msdos)
                scheme_name="MBR (msdos)"
                ((mbr_count++))
                
                # Warn if MBR on >2TB disk
                if (( size_gb > 2000 )); then
                    log_bottleneck "Storage" "MBR partition on >2TB disk $disk_dev (data loss risk)" "MBR on ${size_gb}GB" "GPT" "High"
                fi
                ;;
            *)
                scheme_name="Unknown/Unpartitioned"
                ((unknown_count++))
                ;;
        esac
        
        echo "  $disk_dev: ${size_gb}GB - $scheme_name" | tee -a "$OUTPUT_FILE"
    done
    
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Partition Scheme Summary:" | tee -a "$OUTPUT_FILE"
    echo "  GPT Disks: $gpt_count (modern, UEFI compatible, >2TB support)" | tee -a "$OUTPUT_FILE"
    echo "  MBR Disks: $mbr_count (legacy, BIOS, 2TB max per partition)" | tee -a "$OUTPUT_FILE"
    if (( unknown_count > 0 )); then
        echo "  Unknown/Raw: $unknown_count (unpartitioned or unrecognized)" | tee -a "$OUTPUT_FILE"
    fi
    fi  # End of Linux-specific partition scheme detection
    
    # ==========================================================================
    # PARTITION ALIGNMENT ANALYSIS
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- PARTITION ALIGNMENT ANALYSIS ---" | tee -a "$OUTPUT_FILE"
    echo "Checking for 4K alignment (critical for SSD/SAN performance)..." | tee -a "$OUTPUT_FILE"
    
    local aligned_count=0
    local misaligned_count=0
    
    # FreeBSD-specific partition alignment check
    if [[ "$DISTRO" == "freebsd" ]]; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "FreeBSD Partition Alignment:" | tee -a "$OUTPUT_FILE"
        
        for disk in $(geom disk list 2>/dev/null | grep "^Geom name:" | awk '{print $3}'); do
            # Get sector size
            local sector_size=$(geom disk list "$disk" 2>/dev/null | grep "Sectorsize:" | awk '{print $2}')
            [[ -z "$sector_size" ]] && sector_size=512
            
            # Determine storage type
            local storage_type="HDD"
            local rotation=$(camcontrol identify "$disk" 2>/dev/null | grep -i "rotation" | grep -i "non")
            if [[ -n "$rotation" ]]; then
                storage_type="SSD"
            fi
            if [[ "$disk" == nvd* ]] || [[ "$disk" == nvme* ]]; then
                storage_type="NVMe"
            fi
            
            # Get partition info from gpart
            local gpart_output=$(gpart show -p "$disk" 2>/dev/null)
            if [[ -n "$gpart_output" ]]; then
                echo "" | tee -a "$OUTPUT_FILE"
                echo "  $disk [$storage_type] - Sector Size: ${sector_size} bytes:" | tee -a "$OUTPUT_FILE"
                
                # Parse gpart output for partition start offsets
                echo "$gpart_output" | while read -r start size index type rest; do
                    [[ "$start" =~ ^[0-9]+$ ]] || continue
                    [[ "$type" == "-" ]] && continue  # Skip free space
                    
                    local offset_bytes=$((start * sector_size))
                    local offset_kb=$((offset_bytes / 1024))
                    
                    # Check 4K alignment
                    local aligned_4k="NO"
                    local aligned_1mb="NO"
                    if (( offset_bytes % 4096 == 0 )); then
                        aligned_4k="YES"
                    fi
                    if (( offset_bytes % 1048576 == 0 )); then
                        aligned_1mb="YES"
                    fi
                    
                    if [[ "$aligned_4k" == "YES" ]]; then
                        ((aligned_count++)) 2>/dev/null || aligned_count=$((aligned_count + 1))
                        local align_status="ALIGNED"
                        if [[ "$aligned_1mb" == "YES" ]]; then
                            align_status="ALIGNED (1MB - optimal)"
                        fi
                        echo "    $index ($type): $align_status - Offset: ${offset_kb}KB ($start sectors)" | tee -a "$OUTPUT_FILE"
                    else
                        ((misaligned_count++)) 2>/dev/null || misaligned_count=$((misaligned_count + 1))
                        echo "    $index ($type): MISALIGNED - Offset: ${offset_kb}KB ($start sectors)" | tee -a "$OUTPUT_FILE"
                        
                        local severity="Medium"
                        if [[ "$storage_type" == "SSD" ]] || [[ "$storage_type" == "NVMe" ]]; then
                            severity="High"
                        fi
                        log_bottleneck "Storage" "Misaligned partition ${disk}${index}" "Offset ${offset_kb}KB" "4K aligned" "$severity"
                    fi
                done
            fi
        done
        
        # Check ZFS alignment (ashift)
        if command -v zpool >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "ZFS Pool Alignment (ashift):" | tee -a "$OUTPUT_FILE"
            
            for pool in $(zpool list -H -o name 2>/dev/null); do
                local ashift=$(zpool get -H -o value ashift "$pool" 2>/dev/null)
                [[ -z "$ashift" ]] && continue
                
                local sector_size=$((1 << ashift))
                
                local alignment_status=""
                if (( ashift >= 12 )); then
                    alignment_status="OPTIMAL (ashift=$ashift = ${sector_size}-byte sectors)"
                    ((aligned_count++)) 2>/dev/null || aligned_count=$((aligned_count + 1))
                elif (( ashift == 9 )); then
                    alignment_status="LEGACY (ashift=$ashift = 512-byte sectors)"
                else
                    alignment_status="ashift=$ashift (${sector_size}-byte sectors)"
                fi
                
                echo "  Pool $pool: $alignment_status" | tee -a "$OUTPUT_FILE"
            done
        fi
    else
        # Linux: Iterate through all block devices and their partitions
        for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/xvd* /sys/block/dm-*; do
        [[ -d "$disk" ]] || continue
        local disk_name=$(basename "$disk")
        local disk_dev="/dev/$disk_name"
        
        # Skip if not a block device
        [[ -b "$disk_dev" ]] || continue
        
        # Determine storage type for severity assessment
        local storage_type="HDD"
        local rotational=$(cat "$disk/queue/rotational" 2>/dev/null)
        if [[ "$rotational" == "0" ]]; then
            storage_type="SSD"
        fi
        
        # Check for SAN/iSCSI
        local transport=""
        if [[ -L "$disk/device" ]]; then
            transport=$(readlink -f "$disk/device" 2>/dev/null)
            if [[ "$transport" == *"iscsi"* ]] || [[ "$transport" == *"fc_host"* ]] || [[ "$transport" == *"sas"* ]]; then
                storage_type="SAN"
            fi
        fi
        
        # NVMe detection
        if [[ "$disk_name" == nvme* ]]; then
            storage_type="NVMe"
        fi
        
        # Cloud storage detection (virtio, xen)
        if [[ "$disk_name" == vd* ]] || [[ "$disk_name" == xvd* ]]; then
            storage_type="Cloud"
        fi
        
        # Get partitions for this disk
        for part in "$disk"/"$disk_name"[0-9]* "$disk"/"$disk_name"p[0-9]*; do
            [[ -d "$part" ]] || continue
            local part_name=$(basename "$part")
            local part_dev="/dev/$part_name"
            
            [[ -b "$part_dev" ]] || continue
            
            # Get partition start sector
            local start_sector=$(cat "$part/start" 2>/dev/null)
            [[ -z "$start_sector" ]] && continue
            
            # Calculate offset in bytes (assuming 512-byte sectors)
            local sector_size=$(cat "$disk/queue/hw_sector_size" 2>/dev/null || echo "512")
            local offset_bytes=$((start_sector * sector_size))
            local offset_kb=$((offset_bytes / 1024))
            
            # Check 4K alignment (offset must be divisible by 4096)
            local aligned_4k="NO"
            if (( offset_bytes % 4096 == 0 )); then
                aligned_4k="YES"
            fi
            
            # Check 1MB alignment (optimal for SSD/SAN)
            local aligned_1mb="NO"
            if (( offset_bytes % 1048576 == 0 )); then
                aligned_1mb="YES"
            fi
            
            # Get mount point if any
            local mount_point=$(lsblk -no MOUNTPOINT "$part_dev" 2>/dev/null | head -1)
            [[ -z "$mount_point" ]] && mount_point="not mounted"
            
            if [[ "$aligned_4k" == "YES" ]]; then
                ((aligned_count++))
                local align_status="ALIGNED"
                if [[ "$aligned_1mb" == "YES" ]]; then
                    align_status="ALIGNED (1MB boundary - optimal)"
                fi
                echo "  $part_dev: $align_status - Offset: ${offset_kb}KB ($start_sector sectors) [$storage_type] - $mount_point" | tee -a "$OUTPUT_FILE"
            else
                ((misaligned_count++))
                echo "  $part_dev: MISALIGNED - Offset: ${offset_kb}KB ($start_sector sectors) [$storage_type] - $mount_point" | tee -a "$OUTPUT_FILE"
                
                # Determine severity based on storage type
                local severity="Medium"
                local perf_impact="10-20% performance loss"
                if [[ "$storage_type" == "SSD" ]] || [[ "$storage_type" == "NVMe" ]]; then
                    severity="High"
                    perf_impact="30-50% performance loss"
                elif [[ "$storage_type" == "SAN" ]]; then
                    severity="High"
                    perf_impact="30-50% performance loss + backend I/O amplification"
                elif [[ "$storage_type" == "Cloud" ]]; then
                    severity="High"
                    perf_impact="30-50% performance loss (cloud storage typically SSD-backed)"
                fi
                
                log_bottleneck "Storage" "Misaligned partition $part_dev ($mount_point)" "Offset ${offset_kb}KB" "4K aligned" "$severity"
            fi
        done
    done
    
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Partition Alignment Summary:" | tee -a "$OUTPUT_FILE"
    echo "  Aligned partitions: $aligned_count" | tee -a "$OUTPUT_FILE"
    if (( misaligned_count > 0 )); then
        echo "  Misaligned partitions: $misaligned_count (PERFORMANCE IMPACT)" | tee -a "$OUTPUT_FILE"
        echo "" | tee -a "$OUTPUT_FILE"
        echo "  Misalignment Impact:" | tee -a "$OUTPUT_FILE"
        echo "    - SSD/NVMe: 30-50% performance degradation" | tee -a "$OUTPUT_FILE"
        echo "    - SAN (iSCSI/FC): 30-50% degradation + increased backend I/O" | tee -a "$OUTPUT_FILE"
        echo "    - Cloud (EBS/Azure): 30-50% degradation (SSD-backed)" | tee -a "$OUTPUT_FILE"
        echo "    - HDD: 10-20% degradation (extra read-modify-write cycles)" | tee -a "$OUTPUT_FILE"
        echo "" | tee -a "$OUTPUT_FILE"
        echo "  Remediation:" | tee -a "$OUTPUT_FILE"
        echo "    - Backup data and recreate partition with proper alignment" | tee -a "$OUTPUT_FILE"
        echo "    - Use 'parted' with 'align optimal' or specify 1MiB start" | tee -a "$OUTPUT_FILE"
        echo "    - fdisk: ensure partition starts at sector 2048 (1MB offset)" | tee -a "$OUTPUT_FILE"
        echo "    - Common cause: partitions created on older systems (pre-2010)" | tee -a "$OUTPUT_FILE"
    else
        echo "  All partitions are properly aligned" | tee -a "$OUTPUT_FILE"
    fi
    fi  # End of Linux-specific alignment check
    
    # ==========================================================================
    # BOOT MODE (UEFI vs BIOS)
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Boot Configuration:" | tee -a "$OUTPUT_FILE"
    
    # FreeBSD boot mode detection
    if [[ "$DISTRO" == "freebsd" ]]; then
        # Check for EFI
        if kenv -q smbios.bios.vendor 2>/dev/null | grep -qi "efi"; then
            echo "  Firmware: UEFI" | tee -a "$OUTPUT_FILE"
        elif [[ -d /boot/efi ]] || mount | grep -q "efisys"; then
            echo "  Firmware: UEFI" | tee -a "$OUTPUT_FILE"
        else
            echo "  Firmware: BIOS (Legacy)" | tee -a "$OUTPUT_FILE"
        fi
        
        # Boot device
        local boot_disk=$(sysctl -n kern.geom.confxml 2>/dev/null | grep -o 'bootcode="[^"]*"' | head -1)
        if [[ -n "$boot_disk" ]]; then
            echo "  Boot disk info available via kern.geom.confxml" | tee -a "$OUTPUT_FILE"
        fi
    elif [[ -d /sys/firmware/efi ]]; then
        echo "  Firmware: UEFI" | tee -a "$OUTPUT_FILE"
        
        # Check Secure Boot status
        if [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]] 2>/dev/null; then
            local secureboot=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}')
            if [[ "$secureboot" == "1" ]]; then
                echo "  Secure Boot: Enabled" | tee -a "$OUTPUT_FILE"
            else
                echo "  Secure Boot: Disabled" | tee -a "$OUTPUT_FILE"
            fi
        elif command -v mokutil >/dev/null 2>&1; then
            local sb_state=$(mokutil --sb-state 2>/dev/null)
            echo "  Secure Boot: $sb_state" | tee -a "$OUTPUT_FILE"
        fi
    else
        echo "  Firmware: Legacy BIOS" | tee -a "$OUTPUT_FILE"
    fi
    
    # ==========================================================================
    # PARTITION TYPES
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Partition Types:" | tee -a "$OUTPUT_FILE"
    
    if command -v lsblk >/dev/null 2>&1; then
        # Get partition types using lsblk
        lsblk -o NAME,PARTTYPE,PARTLABEL,FSTYPE,SIZE,MOUNTPOINT 2>/dev/null | head -30 | tee -a "$OUTPUT_FILE"
    fi
    
    # Identify special partition types
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Special Partitions Detected:" | tee -a "$OUTPUT_FILE"
    
    # EFI System Partition
    local efi_part=$(lsblk -o NAME,PARTTYPE 2>/dev/null | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print $1}')
    if [[ -n "$efi_part" ]]; then
        echo "  EFI System Partition (ESP): /dev/$efi_part" | tee -a "$OUTPUT_FILE"
    elif [[ -d /boot/efi ]]; then
        local efi_mount=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null)
        [[ -n "$efi_mount" ]] && echo "  EFI System Partition: $efi_mount (mounted at /boot/efi)" | tee -a "$OUTPUT_FILE"
    fi
    
    # BIOS Boot Partition (for GPT + BIOS)
    local bios_boot=$(lsblk -o NAME,PARTTYPE 2>/dev/null | grep -i "21686148-6449-6e6f-744e-656564454649" | awk '{print $1}')
    [[ -n "$bios_boot" ]] && echo "  BIOS Boot Partition: /dev/$bios_boot" | tee -a "$OUTPUT_FILE"
    
    # Linux swap
    local swap_parts=$(lsblk -o NAME,FSTYPE 2>/dev/null | grep -E "swap" | awk '{print $1}')
    [[ -n "$swap_parts" ]] && echo "  Swap Partition(s): $swap_parts" | tee -a "$OUTPUT_FILE"
    
    # LVM Physical Volumes
    local lvm_parts=$(lsblk -o NAME,FSTYPE 2>/dev/null | grep -E "LVM2_member" | awk '{print $1}')
    [[ -n "$lvm_parts" ]] && echo "  LVM Physical Volume(s): $lvm_parts" | tee -a "$OUTPUT_FILE"
    
    # RAID members
    local raid_parts=$(lsblk -o NAME,FSTYPE 2>/dev/null | grep -E "linux_raid" | awk '{print $1}')
    [[ -n "$raid_parts" ]] && echo "  RAID Member(s): $raid_parts" | tee -a "$OUTPUT_FILE"
    
    # ==========================================================================
    # FILESYSTEM TYPES
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Filesystem Types in Use:" | tee -a "$OUTPUT_FILE"
    
    # Count filesystem types
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o FSTYPE -n 2>/dev/null | grep -v "^$" | sort | uniq -c | while read count fstype; do
            case "$fstype" in
                ext4)
                    echo "  ext4: $count volume(s) - Linux standard, journaling" | tee -a "$OUTPUT_FILE"
                    ;;
                xfs)
                    echo "  XFS: $count volume(s) - High-performance, scalable (RHEL default)" | tee -a "$OUTPUT_FILE"
                    ;;
                btrfs)
                    echo "  Btrfs: $count volume(s) - Copy-on-write, snapshots, checksums" | tee -a "$OUTPUT_FILE"
                    ;;
                ext3)
                    echo "  ext3: $count volume(s) - Legacy journaling filesystem" | tee -a "$OUTPUT_FILE"
                    ;;
                ext2)
                    echo "  ext2: $count volume(s) - Legacy (no journal) - often used for /boot" | tee -a "$OUTPUT_FILE"
                    ;;
                vfat|fat32)
                    echo "  FAT32/vfat: $count volume(s) - EFI System Partition or removable media" | tee -a "$OUTPUT_FILE"
                    ;;
                ntfs)
                    echo "  NTFS: $count volume(s) - Windows filesystem" | tee -a "$OUTPUT_FILE"
                    ;;
                swap)
                    echo "  swap: $count volume(s) - Linux swap space" | tee -a "$OUTPUT_FILE"
                    ;;
                zfs_member)
                    echo "  ZFS: $count volume(s) - Advanced filesystem with built-in RAID" | tee -a "$OUTPUT_FILE"
                    ;;
                LVM2_member)
                    echo "  LVM: $count physical volume(s)" | tee -a "$OUTPUT_FILE"
                    ;;
                linux_raid_member)
                    echo "  MD RAID: $count member(s)" | tee -a "$OUTPUT_FILE"
                    ;;
                *)
                    [[ -n "$fstype" ]] && echo "  $fstype: $count volume(s)" | tee -a "$OUTPUT_FILE"
                    ;;
            esac
        done
    fi
    
    # Check for newer filesystems
    if mount | grep -q "bcachefs"; then
        echo "  bcachefs: Detected - Next-gen copy-on-write filesystem" | tee -a "$OUTPUT_FILE"
    fi
    
    # LVM Detection and Analysis
    echo "" | tee -a "$OUTPUT_FILE"
    echo "LVM Configuration:" | tee -a "$OUTPUT_FILE"
    if command -v pvs >/dev/null 2>&1; then
        local pv_count=$(pvs --noheadings 2>/dev/null | wc -l)
        if (( pv_count > 0 )); then
            echo "  Physical Volumes:" | tee -a "$OUTPUT_FILE"
            pvs 2>/dev/null | tee -a "$OUTPUT_FILE"
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Volume Groups:" | tee -a "$OUTPUT_FILE"
            vgs 2>/dev/null | tee -a "$OUTPUT_FILE"
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Logical Volumes:" | tee -a "$OUTPUT_FILE"
            lvs 2>/dev/null | tee -a "$OUTPUT_FILE"
        else
            echo "  No LVM configuration detected" | tee -a "$OUTPUT_FILE"
        fi
    else
        echo "  LVM tools not installed" | tee -a "$OUTPUT_FILE"
    fi
    
    # RAID Detection (mdadm)
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Software RAID (mdadm):" | tee -a "$OUTPUT_FILE"
    if [[ -f /proc/mdstat ]]; then
        cat /proc/mdstat | tee -a "$OUTPUT_FILE"
        
        # Check for degraded arrays
        if grep -q "degraded" /proc/mdstat 2>/dev/null || grep -q "_" /proc/mdstat 2>/dev/null; then
            log_bottleneck "Storage" "Degraded RAID array detected" "Degraded" "Healthy" "Critical"
        fi
    else
        echo "  No software RAID detected" | tee -a "$OUTPUT_FILE"
    fi
    
    # Hardware RAID detection
    if command -v megacli >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Hardware RAID (MegaRAID):" | tee -a "$OUTPUT_FILE"
        megacli -LDInfo -Lall -aALL 2>/dev/null | tee -a "$OUTPUT_FILE"
    fi
    
    if command -v ssacli >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Hardware RAID (HP Smart Array):" | tee -a "$OUTPUT_FILE"
        ssacli ctrl all show config 2>/dev/null | tee -a "$OUTPUT_FILE"
    fi
    
    # ==========================================================================
    # STORAGE TIERING (SSD vs HDD vs NVMe)
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- STORAGE TIERING ---" | tee -a "$OUTPUT_FILE"
    
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Drive Types:" | tee -a "$OUTPUT_FILE"
    
    local ssd_count=0
    local hdd_count=0
    local nvme_count=0
    
    for disk in /sys/block/*/; do
        local disk_name=$(basename "$disk")
        [[ "$disk_name" == loop* ]] && continue
        [[ "$disk_name" == ram* ]] && continue
        [[ "$disk_name" == dm-* ]] && continue
        
        local rotational_file="${disk}queue/rotational"
        local model_file="${disk}device/model"
        local size_file="${disk}size"
        
        if [[ -f "$rotational_file" ]]; then
            local is_rotational=$(cat "$rotational_file")
            local model="Unknown"
            local size_sectors=0
            local size_gb=0
            
            [[ -f "$model_file" ]] && model=$(cat "$model_file" | xargs)
            [[ -f "$size_file" ]] && size_sectors=$(cat "$size_file") && size_gb=$((size_sectors * 512 / 1024 / 1024 / 1024))
            
            if [[ "$disk_name" == nvme* ]]; then
                echo "  $disk_name: NVMe SSD - ${size_gb}GB - $model" | tee -a "$OUTPUT_FILE"
                ((nvme_count++))
            elif [[ "$is_rotational" == "0" ]]; then
                echo "  $disk_name: SSD - ${size_gb}GB - $model" | tee -a "$OUTPUT_FILE"
                ((ssd_count++))
            else
                echo "  $disk_name: HDD (Rotational) - ${size_gb}GB - $model" | tee -a "$OUTPUT_FILE"
                ((hdd_count++))
            fi
        fi
    done
    
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Storage Tier Summary: NVMe=$nvme_count, SSD=$ssd_count, HDD=$hdd_count" | tee -a "$OUTPUT_FILE"
    
    # NVMe specific info
    if command -v nvme >/dev/null 2>&1 && (( nvme_count > 0 )); then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "NVMe Device Details:" | tee -a "$OUTPUT_FILE"
        nvme list 2>/dev/null | tee -a "$OUTPUT_FILE"
    fi
    
    # ==========================================================================
    # AWS EBS / CLOUD STORAGE DETECTION
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- CLOUD STORAGE DETECTION ---" | tee -a "$OUTPUT_FILE"
    
    # Check if running on EC2
    if curl -s -m 2 http://169.254.169.254/latest/meta-data/instance-id &>/dev/null; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "AWS EC2 Instance Detected - Analyzing EBS Volumes:" | tee -a "$OUTPUT_FILE"
        
        # Get instance ID
        local instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
        local region=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || \
                       curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//')
        
        echo "  Instance ID: $instance_id" | tee -a "$OUTPUT_FILE"
        echo "  Region: $region" | tee -a "$OUTPUT_FILE"
        
        # Try to get EBS volume info via AWS CLI
        if command -v aws >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  EBS Volumes (via AWS CLI):" | tee -a "$OUTPUT_FILE"
            
            local volumes=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$instance_id" \
                --query 'Volumes[*].{ID:VolumeId,Type:VolumeType,Size:Size,IOPS:Iops,Throughput:Throughput,State:State,Device:Attachments[0].Device}' \
                --output table --region "$region" 2>/dev/null)
            
            if [[ -n "$volumes" ]]; then
                echo "$volumes" | tee -a "$OUTPUT_FILE"
                
                # Check for optimization opportunities
                echo "" | tee -a "$OUTPUT_FILE"
                echo "  EBS Optimization Analysis:" | tee -a "$OUTPUT_FILE"
                
                # Check for gp2 volumes (could upgrade to gp3)
                local gp2_count=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$instance_id" \
                    --query 'length(Volumes[?VolumeType==`gp2`])' --output text --region "$region" 2>/dev/null)
                
                if [[ "$gp2_count" -gt 0 ]]; then
                    echo "    - Found $gp2_count gp2 volume(s) - consider upgrading to gp3 for cost savings" | tee -a "$OUTPUT_FILE"
                    log_bottleneck "Storage" "gp2 volumes detected - gp3 recommended" "$gp2_count gp2 volumes" "gp3" "Low"
                fi
                
                # Check for io1 volumes (could upgrade to io2)
                local io1_count=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$instance_id" \
                    --query 'length(Volumes[?VolumeType==`io1`])' --output text --region "$region" 2>/dev/null)
                
                if [[ "$io1_count" -gt 0 ]]; then
                    echo "    - Found $io1_count io1 volume(s) - consider upgrading to io2 for better durability" | tee -a "$OUTPUT_FILE"
                fi
                
                # Check EBS-optimized instance
                local ebs_optimized=$(curl -s http://169.254.169.254/latest/meta-data/ebs-optimized 2>/dev/null || echo "unknown")
                echo "    - EBS Optimized: $ebs_optimized" | tee -a "$OUTPUT_FILE"
                
            else
                echo "  Unable to query EBS volumes (check IAM permissions)" | tee -a "$OUTPUT_FILE"
            fi
        else
            echo "  AWS CLI not available for detailed EBS analysis" | tee -a "$OUTPUT_FILE"
        fi
        
        # NVMe EBS mapping (for Nitro instances)
        if [[ -d /dev/disk/by-id ]]; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  NVMe to EBS Mapping:" | tee -a "$OUTPUT_FILE"
            ls -la /dev/disk/by-id/ 2>/dev/null | grep -E "nvme-Amazon" | tee -a "$OUTPUT_FILE" || echo "    No NVMe EBS mappings found" | tee -a "$OUTPUT_FILE"
        fi
        
        # Instance store detection
        local instance_store=$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/ 2>/dev/null | grep ephemeral)
        if [[ -n "$instance_store" ]]; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Instance Store (Ephemeral) Volumes:" | tee -a "$OUTPUT_FILE"
            echo "$instance_store" | tee -a "$OUTPUT_FILE"
            echo "    WARNING: Instance store data is lost on stop/terminate" | tee -a "$OUTPUT_FILE"
        fi
        
    else
        echo "  Not running on AWS EC2" | tee -a "$OUTPUT_FILE"
        
        # Check for Azure
        if curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" &>/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Azure VM Detected:" | tee -a "$OUTPUT_FILE"
            curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance/compute/storageProfile?api-version=2021-02-01" 2>/dev/null | tee -a "$OUTPUT_FILE"
        fi
        
        # Check for GCP
        if curl -s -H "Metadata-Flavor: Google" "http://169.254.169.254/computeMetadata/v1/instance/disks/?recursive=true" &>/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "GCP VM Detected:" | tee -a "$OUTPUT_FILE"
            curl -s -H "Metadata-Flavor: Google" "http://169.254.169.254/computeMetadata/v1/instance/disks/?recursive=true" 2>/dev/null | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    # ==========================================================================
    # SMART HEALTH STATUS
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- SMART HEALTH STATUS ---" | tee -a "$OUTPUT_FILE"
    
    if command -v smartctl >/dev/null 2>&1; then
        for disk in /dev/sd? /dev/nvme?n1; do
            [[ -b "$disk" ]] || continue
            
            echo "" | tee -a "$OUTPUT_FILE"
            echo "SMART Status for $disk:" | tee -a "$OUTPUT_FILE"
            
            local smart_health=$(smartctl -H "$disk" 2>/dev/null)
            echo "$smart_health" | grep -E "SMART overall-health|SMART Health Status" | tee -a "$OUTPUT_FILE"
            
            # Check for failing drive
            if echo "$smart_health" | grep -qi "FAILED\|FAILING"; then
                log_bottleneck "Storage" "SMART failure detected on $disk" "FAILING" "PASSED" "Critical"
            fi
            
            # Key SMART attributes
            smartctl -A "$disk" 2>/dev/null | grep -E "Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error|Wear_Leveling|Percentage_Used" | tee -a "$OUTPUT_FILE"
        done
    else
        echo "  smartctl not installed - install smartmontools for SMART analysis" | tee -a "$OUTPUT_FILE"
        echo "  Install with: apt-get install smartmontools OR yum install smartmontools" | tee -a "$OUTPUT_FILE"
    fi
    
    # ==========================================================================
    # CAPACITY PROFILING / SPACE UTILIZATION
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- CAPACITY PROFILING ---" | tee -a "$OUTPUT_FILE"
    
    # Filesystem usage with inode info
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Filesystem Capacity:" | tee -a "$OUTPUT_FILE"
    df -hT 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | tee -a "$OUTPUT_FILE"
    
    # Inode usage (can cause issues even with free space)
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Inode Usage:" | tee -a "$OUTPUT_FILE"
    df -i 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | tee -a "$OUTPUT_FILE"
    
    # Check for inode exhaustion
    while IFS= read -r line; do
        local inode_usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        local mount=$(echo "$line" | awk '{print $6}')
        if [[ -n "$inode_usage" ]] && [[ "$inode_usage" =~ ^[0-9]+$ ]] && (( inode_usage > 90 )); then
            log_bottleneck "Storage" "Inode exhaustion on $mount" "${inode_usage}%" "90%" "High"
        fi
    done < <(df -i 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | tail -n +2)
    
    # Top space consumers
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Top 10 Directories by Size (/):" | tee -a "$OUTPUT_FILE"
    du -hx --max-depth=1 / 2>/dev/null | sort -rh | head -11 | tee -a "$OUTPUT_FILE"
    
    # Large files detection
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Large Files (>1GB):" | tee -a "$OUTPUT_FILE"
    find / -xdev -type f -size +1G -exec ls -lh {} \; 2>/dev/null | sort -k5 -rh | head -10 | tee -a "$OUTPUT_FILE" || echo "  Unable to scan for large files" | tee -a "$OUTPUT_FILE"
    
    # Old/stale files in /tmp
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Old files in /tmp (>7 days):" | tee -a "$OUTPUT_FILE"
    local old_tmp_size=$(find /tmp -type f -mtime +7 -exec du -ch {} + 2>/dev/null | tail -1 | awk '{print $1}')
    echo "  Total size of old /tmp files: ${old_tmp_size:-0}" | tee -a "$OUTPUT_FILE"
    
    # Log file sizes
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Log Directory Sizes:" | tee -a "$OUTPUT_FILE"
    du -sh /var/log 2>/dev/null | tee -a "$OUTPUT_FILE"
    du -sh /var/log/* 2>/dev/null | sort -rh | head -5 | tee -a "$OUTPUT_FILE"
    
    # ==========================================================================
    # FILESYSTEM FRAGMENTATION
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- FILESYSTEM FRAGMENTATION ---" | tee -a "$OUTPUT_FILE"
    
    # ext4 fragmentation
    if command -v e4defrag >/dev/null 2>&1; then
        for mount in $(df -t ext4 --output=target 2>/dev/null | tail -n +2); do
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Fragmentation on $mount (ext4):" | tee -a "$OUTPUT_FILE"
            e4defrag -c "$mount" 2>/dev/null | grep -E "Total|Fragmented|Score" | tee -a "$OUTPUT_FILE"
        done
    fi
    
    # XFS fragmentation
    if command -v xfs_db >/dev/null 2>&1; then
        for mount in $(df -t xfs --output=source 2>/dev/null | tail -n +2); do
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Fragmentation on $mount (XFS):" | tee -a "$OUTPUT_FILE"
            xfs_db -c frag -r "$mount" 2>/dev/null | tee -a "$OUTPUT_FILE"
        done
    fi
    
    # ==========================================================================
    # SAN/NAS/iSCSI DETECTION
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- SAN/NAS/iSCSI DETECTION ---" | tee -a "$OUTPUT_FILE"
    
    # iSCSI sessions
    if command -v iscsiadm >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "iSCSI Sessions:" | tee -a "$OUTPUT_FILE"
        iscsiadm -m session 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  No active iSCSI sessions" | tee -a "$OUTPUT_FILE"
    fi
    
    # Multipath devices (common with SAN)
    if command -v multipath >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Multipath Devices:" | tee -a "$OUTPUT_FILE"
        multipath -ll 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  No multipath devices configured" | tee -a "$OUTPUT_FILE"
    fi
    
    # NFS mounts
    echo "" | tee -a "$OUTPUT_FILE"
    echo "NFS Mounts:" | tee -a "$OUTPUT_FILE"
    mount | grep -E "type nfs|type nfs4" | tee -a "$OUTPUT_FILE" || echo "  No NFS mounts detected" | tee -a "$OUTPUT_FILE"
    
    # Check NFS mount options for performance issues
    if mount | grep -qE "type nfs|type nfs4"; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "NFS Mount Analysis:" | tee -a "$OUTPUT_FILE"
        mount | grep -E "type nfs|type nfs4" | while read -r line; do
            if echo "$line" | grep -q "sync"; then
                echo "  WARNING: Synchronous NFS mount detected (performance impact): $line" | tee -a "$OUTPUT_FILE"
            fi
            if ! echo "$line" | grep -q "noatime"; then
                echo "  TIP: Consider adding 'noatime' option for better performance" | tee -a "$OUTPUT_FILE"
            fi
        done
    fi
    
    # CIFS/SMB mounts
    echo "" | tee -a "$OUTPUT_FILE"
    echo "CIFS/SMB Mounts:" | tee -a "$OUTPUT_FILE"
    mount | grep "type cifs" | tee -a "$OUTPUT_FILE" || echo "  No CIFS/SMB mounts detected" | tee -a "$OUTPUT_FILE"
    
    # Fibre Channel detection
    if [[ -d /sys/class/fc_host ]]; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Fibre Channel HBAs:" | tee -a "$OUTPUT_FILE"
        for fc in /sys/class/fc_host/host*; do
            [[ -d "$fc" ]] || continue
            local fc_name=$(basename "$fc")
            local port_state=$(cat "$fc/port_state" 2>/dev/null || echo "unknown")
            local port_name=$(cat "$fc/port_name" 2>/dev/null || echo "unknown")
            local speed=$(cat "$fc/speed" 2>/dev/null || echo "unknown")
            echo "  $fc_name: State=$port_state, WWN=$port_name, Speed=$speed" | tee -a "$OUTPUT_FILE"
        done
    fi
    
    # ==========================================================================
    # STORAGE PERFORMANCE BASELINE
    # ==========================================================================
    echo "" | tee -a "$OUTPUT_FILE"
    echo "--- STORAGE PERFORMANCE BASELINE ---" | tee -a "$OUTPUT_FILE"
    
    if [[ "$MODE" == "deep" ]] || [[ "$MODE" == "disk" ]]; then
        log_info "Running storage performance baseline tests..."
        
        local test_dir="/tmp/storage_baseline_$$"
        mkdir -p "$test_dir"
        
        # Sequential write test (1GB)
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Sequential Write Test (1GB):" | tee -a "$OUTPUT_FILE"
        local write_result=$(dd if=/dev/zero of="$test_dir/test_file" bs=1M count=1024 oflag=direct 2>&1)
        local write_speed=$(echo "$write_result" | grep -oP '[\d.]+ [MGK]B/s' | tail -1)
        echo "  Write Speed: ${write_speed:-N/A}" | tee -a "$OUTPUT_FILE"
        
        # Sequential read test
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Sequential Read Test (1GB):" | tee -a "$OUTPUT_FILE"
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        local read_result=$(dd if="$test_dir/test_file" of=/dev/null bs=1M 2>&1)
        local read_speed=$(echo "$read_result" | grep -oP '[\d.]+ [MGK]B/s' | tail -1)
        echo "  Read Speed: ${read_speed:-N/A}" | tee -a "$OUTPUT_FILE"
        
        # Random I/O test with fio if available
        if command -v fio >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "Random I/O Test (fio):" | tee -a "$OUTPUT_FILE"
            
            # 4K random read IOPS
            local fio_result=$(fio --name=randread --ioengine=libaio --iodepth=32 --rw=randread --bs=4k \
                --direct=1 --size=256M --runtime=10 --filename="$test_dir/fio_test" --output-format=json 2>/dev/null)
            
            if [[ -n "$fio_result" ]]; then
                local read_iops=$(echo "$fio_result" | grep -oP '"iops"\s*:\s*[\d.]+' | head -1 | grep -oP '[\d.]+')
                local read_lat=$(echo "$fio_result" | grep -oP '"lat_ns".*?"mean"\s*:\s*[\d.]+' | head -1 | grep -oP '[\d.]+$')
                read_lat=$(echo "scale=2; ${read_lat:-0} / 1000000" | bc 2>/dev/null || echo "N/A")
                echo "  4K Random Read: ${read_iops:-N/A} IOPS, ${read_lat}ms latency" | tee -a "$OUTPUT_FILE"
            fi
            
            # 4K random write IOPS
            fio_result=$(fio --name=randwrite --ioengine=libaio --iodepth=32 --rw=randwrite --bs=4k \
                --direct=1 --size=256M --runtime=10 --filename="$test_dir/fio_test" --output-format=json 2>/dev/null)
            
            if [[ -n "$fio_result" ]]; then
                local write_iops=$(echo "$fio_result" | grep -oP '"iops"\s*:\s*[\d.]+' | head -1 | grep -oP '[\d.]+')
                local write_lat=$(echo "$fio_result" | grep -oP '"lat_ns".*?"mean"\s*:\s*[\d.]+' | head -1 | grep -oP '[\d.]+$')
                write_lat=$(echo "scale=2; ${write_lat:-0} / 1000000" | bc 2>/dev/null || echo "N/A")
                echo "  4K Random Write: ${write_iops:-N/A} IOPS, ${write_lat}ms latency" | tee -a "$OUTPUT_FILE"
            fi
        else
            echo "  fio not installed - install for detailed I/O benchmarking" | tee -a "$OUTPUT_FILE"
        fi
        
        # Cleanup
        rm -rf "$test_dir"
    else
        echo "  Run with -m deep or -m disk for performance baseline tests" | tee -a "$OUTPUT_FILE"
    fi
    
    log_success "Storage profiling completed"
}

#############################################################################
# Database Forensics
#############################################################################

analyze_databases() {
    print_header "DATABASE FORENSICS"
    
    log_info "Scanning for database processes and connections..."
    
    local databases_found=false
    
    # Check for CloudWatch Logs Agent (common in DMS migrations)
    if pgrep -f "amazon-cloudwatch-agent" >/dev/null 2>&1 || pgrep -f "awslogs" >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== CloudWatch Logs Agent Detected ===" | tee -a "$OUTPUT_FILE"
        ps aux | grep -E "[a]mazon-cloudwatch-agent|[a]wslogs" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        echo "  Status: Running" | tee -a "$OUTPUT_FILE"
    else
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== CloudWatch Logs Agent ===" | tee -a "$OUTPUT_FILE"
        echo "  Status: Not detected" | tee -a "$OUTPUT_FILE"
        echo "  Note: CloudWatch Logs Agent recommended for DMS migrations" | tee -a "$OUTPUT_FILE"
    fi
    
    # MySQL/MariaDB Detection
    if pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== MySQL/MariaDB Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep -E "[m]ysqld|[m]ariadbd" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count
        local mysql_conns=$(netstat -ant 2>/dev/null | grep :3306 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${mysql_conns}" | tee -a "$OUTPUT_FILE"
        
        if (( mysql_conns > 500 )); then
            log_bottleneck "Database" "High MySQL connection count" "${mysql_conns}" "500" "Medium"
        fi
        
        # MySQL Query Analysis
        if command -v mysql >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  MySQL Query Analysis:" | tee -a "$OUTPUT_FILE"
            
            mysql -u root -e "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, LEFT(INFO, 100) AS QUERY FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep' AND TIME > 30 ORDER BY TIME DESC LIMIT 5;" 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  Unable to query MySQL (requires authentication)" | tee -a "$OUTPUT_FILE"
            
            mysql -u root -e "SELECT DIGEST_TEXT AS query, COUNT_STAR AS exec_count, ROUND(AVG_TIMER_WAIT/1000000000, 2) AS avg_time_ms, ROUND(SUM_TIMER_WAIT/1000000000, 2) AS total_time_ms, ROUND(SUM_ROWS_EXAMINED/COUNT_STAR, 0) AS avg_rows_examined FROM performance_schema.events_statements_summary_by_digest ORDER BY SUM_TIMER_WAIT DESC LIMIT 5;" 2>/dev/null | tee -a "$OUTPUT_FILE"
            
            # Check for long-running queries
            local long_running=$(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep' AND TIME > 30;" 2>/dev/null)
            if [[ -n "$long_running" ]] && (( long_running > 0 )); then
                log_bottleneck "Database" "Long-running MySQL queries detected (>30s)" "Yes" "30s" "High"
            fi
            
            # DMS-specific checks for MySQL
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  DMS Migration Readiness:" | tee -a "$OUTPUT_FILE"
            
            # Check binary logging (required for CDC)
            local binlog_status=$(mysql -u root -N -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | awk '{print $2}')
            echo "    Binary Logging: ${binlog_status:-Unknown}" | tee -a "$OUTPUT_FILE"
            if [[ "$binlog_status" != "ON" ]]; then
                log_bottleneck "DMS" "MySQL binary logging disabled - required for CDC" "OFF" "ON" "High"
            fi
            
            # Check binlog format (ROW required for DMS)
            local binlog_format=$(mysql -u root -N -e "SHOW VARIABLES LIKE 'binlog_format';" 2>/dev/null | awk '{print $2}')
            echo "    Binary Log Format: ${binlog_format:-Unknown}" | tee -a "$OUTPUT_FILE"
            if [[ "$binlog_format" != "ROW" ]]; then
                log_bottleneck "DMS" "MySQL binlog format not ROW - required for DMS CDC" "${binlog_format}" "ROW" "High"
            fi
            
            # Check binlog retention
            local binlog_retention=$(mysql -u root -N -e "SHOW VARIABLES LIKE 'expire_logs_days';" 2>/dev/null | awk '{print $2}')
            echo "    Binary Log Retention: ${binlog_retention:-0} days" | tee -a "$OUTPUT_FILE"
            if [[ -n "$binlog_retention" ]] && (( $(echo "$binlog_retention < 1" | bc -l 2>/dev/null || echo 1) )); then
                log_bottleneck "DMS" "MySQL binlog retention too low for DMS" "${binlog_retention}d" ">=1d" "Medium"
            fi
            
            # Check for replication lag (if slave)
            local slave_status=$(mysql -u root -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Seconds_Behind_Master" | awk '{print $2}')
            if [[ -n "$slave_status" ]] && [[ "$slave_status" != "NULL" ]]; then
                echo "    Replication Lag: ${slave_status} seconds" | tee -a "$OUTPUT_FILE"
                if (( slave_status > 300 )); then
                    log_bottleneck "Database" "High MySQL replication lag" "${slave_status}s" "300s" "High"
                fi
            fi
        fi
    fi
    
    # PostgreSQL Detection
    if pgrep -x postgres >/dev/null 2>&1 || pgrep -x postmaster >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== PostgreSQL Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep -E "[p]ostgres|[p]ostmaster" | head -1 | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count
        local pg_conns=$(netstat -ant 2>/dev/null | grep :5432 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${pg_conns}" | tee -a "$OUTPUT_FILE"
        
        if (( pg_conns > 500 )); then
            log_bottleneck "Database" "High PostgreSQL connection count" "${pg_conns}" "500" "Medium"
        fi
        
        # PostgreSQL Query Analysis
        if command -v psql >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  PostgreSQL Query Analysis:" | tee -a "$OUTPUT_FILE"
            
            psql -U postgres -c "SELECT pid, usename, application_name, state, EXTRACT(EPOCH FROM (now() - query_start)) AS duration_seconds, LEFT(query, 100) AS query FROM pg_stat_activity WHERE state != 'idle' AND query NOT LIKE '%pg_stat_activity%' ORDER BY duration_seconds DESC LIMIT 5;" 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  Unable to query PostgreSQL (requires authentication)" | tee -a "$OUTPUT_FILE"
            
            psql -U postgres -c "SELECT query, calls, ROUND(total_exec_time::numeric, 2) AS total_time_ms, ROUND(mean_exec_time::numeric, 2) AS avg_time_ms, ROUND((100 * total_exec_time / SUM(total_exec_time) OVER ())::numeric, 2) AS pct_total FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;" 2>/dev/null | tee -a "$OUTPUT_FILE"
            
            # Check for long-running queries
            local long_running=$(psql -U postgres -t -c "SELECT COUNT(*) FROM pg_stat_activity WHERE state != 'idle' AND EXTRACT(EPOCH FROM (now() - query_start)) > 30;" 2>/dev/null | tr -d ' ')
            if [[ -n "$long_running" ]] && (( long_running > 0 )); then
                log_bottleneck "Database" "Long-running PostgreSQL queries detected (>30s)" "Yes" "30s" "High"
            fi
            
            # DMS-specific checks for PostgreSQL
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  DMS Migration Readiness:" | tee -a "$OUTPUT_FILE"
            
            # Check WAL level (logical required for DMS)
            local wal_level=$(psql -U postgres -t -c "SHOW wal_level;" 2>/dev/null | tr -d ' ')
            echo "    WAL Level: ${wal_level:-Unknown}" | tee -a "$OUTPUT_FILE"
            if [[ "$wal_level" != "logical" ]]; then
                log_bottleneck "DMS" "PostgreSQL wal_level not 'logical' - required for DMS CDC" "${wal_level}" "logical" "High"
            fi
            
            # Check replication slots
            local repl_slots=$(psql -U postgres -t -c "SELECT COUNT(*) FROM pg_replication_slots;" 2>/dev/null | tr -d ' ')
            echo "    Replication Slots: ${repl_slots:-0}" | tee -a "$OUTPUT_FILE"
            
            # Check for replication lag (if standby)
            local is_standby=$(psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d ' ')
            if [[ "$is_standby" == "t" ]]; then
                local lag=$(psql -U postgres -t -c "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()));" 2>/dev/null | tr -d ' ')
                echo "    Replication Lag: ${lag:-Unknown} seconds" | tee -a "$OUTPUT_FILE"
                if [[ -n "$lag" ]] && (( $(echo "$lag > 300" | bc -l 2>/dev/null || echo 0) )); then
                    log_bottleneck "Database" "High PostgreSQL replication lag" "${lag}s" "300s" "High"
                fi
            fi
            
            # Check max_replication_slots
            local max_slots=$(psql -U postgres -t -c "SHOW max_replication_slots;" 2>/dev/null | tr -d ' ')
            echo "    Max Replication Slots: ${max_slots:-Unknown}" | tee -a "$OUTPUT_FILE"
            if [[ -n "$max_slots" ]] && (( max_slots < 1 )); then
                log_bottleneck "DMS" "PostgreSQL max_replication_slots is 0 - DMS requires at least 1" "${max_slots}" ">=1" "High"
            fi
        fi
    fi
    
    # MongoDB Detection
    if pgrep -x mongod >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== MongoDB Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep "[m]ongod" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count
        local mongo_conns=$(netstat -ant 2>/dev/null | grep :27017 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${mongo_conns}" | tee -a "$OUTPUT_FILE"
        
        if (( mongo_conns > 1000 )); then
            log_bottleneck "Database" "High MongoDB connection count" "${mongo_conns}" "1000" "Medium"
        fi
        
        # MongoDB Query Analysis
        if command -v mongo >/dev/null 2>&1 || command -v mongosh >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  MongoDB Query Analysis:" | tee -a "$OUTPUT_FILE"
            
            local mongo_cmd="mongo"
            command -v mongosh >/dev/null 2>&1 && mongo_cmd="mongosh"
            
            $mongo_cmd --quiet --eval "db.currentOp({\$or: [{op: {\$in: ['query', 'command']}}, {secs_running: {\$gte: 30}}]}).inprog.forEach(function(op) { print('OpID: ' + op.opid + ' | Duration: ' + op.secs_running + 's | NS: ' + op.ns + ' | Query: ' + JSON.stringify(op.command).substring(0,100)); }); print('---TOP 5 SLOWEST OPERATIONS---'); db.system.profile.find().sort({millis: -1}).limit(5).forEach(function(op) { print('Duration: ' + op.millis + 'ms | Op: ' + op.op + ' | NS: ' + op.ns + ' | Query: ' + JSON.stringify(op.command).substring(0,100)); });" 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  Unable to query MongoDB (requires authentication or profiling enabled)" | tee -a "$OUTPUT_FILE"
            
            # Check for long-running operations
            local long_running=$($mongo_cmd --quiet --eval "db.currentOp({secs_running: {\$gte: 30}}).inprog.length" 2>/dev/null)
            if [[ -n "$long_running" ]] && (( long_running > 0 )); then
                log_bottleneck "Database" "Long-running MongoDB operations detected (>30s)" "Yes" "30s" "High"
            fi
        fi
    fi
    
    # Cassandra Detection
    if pgrep -f "org.apache.cassandra" >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== Cassandra Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep "[o]rg.apache.cassandra" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count (native transport port)
        local cass_conns=$(netstat -ant 2>/dev/null | grep :9042 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${cass_conns}" | tee -a "$OUTPUT_FILE"
        
        if (( cass_conns > 1000 )); then
            log_bottleneck "Database" "High Cassandra connection count" "${cass_conns}" "1000" "Medium"
        fi
        
        # Check data directory size
        if [[ -d /var/lib/cassandra ]]; then
            local cass_size=$(du -sh /var/lib/cassandra 2>/dev/null | awk '{print $1}')
            echo "  Data Directory Size: ${cass_size}" | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    # Redis Detection
    if pgrep -x redis-server >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== Redis Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep "[r]edis-server" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count
        local redis_conns=$(netstat -ant 2>/dev/null | grep :6379 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${redis_conns}" | tee -a "$OUTPUT_FILE"
        
        if (( redis_conns > 10000 )); then
            log_bottleneck "Database" "High Redis connection count" "${redis_conns}" "10000" "Medium"
        fi
        
        # Redis Performance Analysis
        if command -v redis-cli >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Redis Performance Metrics:" | tee -a "$OUTPUT_FILE"
            
            local redis_stats=$(redis-cli INFO stats 2>/dev/null)
            local total_commands=$(echo "$redis_stats" | grep "total_commands_processed:" | cut -d: -f2 | tr -d '\r')
            local ops_per_sec=$(echo "$redis_stats" | grep "instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r')
            local rejected_conns=$(echo "$redis_stats" | grep "rejected_connections:" | cut -d: -f2 | tr -d '\r')
            
            echo "  Total Commands: ${total_commands} | Ops/sec: ${ops_per_sec} | Rejected Connections: ${rejected_conns}" | tee -a "$OUTPUT_FILE"
            
            echo "  Top 5 Slow Commands:" | tee -a "$OUTPUT_FILE"
            redis-cli SLOWLOG GET 5 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  Unable to query Redis slowlog" | tee -a "$OUTPUT_FILE"
            
            if [[ -n "$rejected_conns" ]] && (( rejected_conns > 0 )); then
                log_bottleneck "Database" "Redis connection rejections detected" "${rejected_conns}" "0" "High"
            fi
        fi
    fi
    
    # Oracle Detection
    if pgrep -x oracle >/dev/null 2>&1 || pgrep -f "ora_pmon" >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== Oracle Database Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep "[o]ra_pmon" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count (default listener port)
        local oracle_conns=$(netstat -ant 2>/dev/null | grep :1521 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${oracle_conns}" | tee -a "$OUTPUT_FILE"
        
        if (( oracle_conns > 500 )); then
            log_bottleneck "Database" "High Oracle connection count" "${oracle_conns}" "500" "Medium"
        fi
        
        # Oracle Query Analysis
        if command -v sqlplus >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Oracle Query Analysis:" | tee -a "$OUTPUT_FILE"
            
            # Active sessions query
            echo "SELECT sid, serial#, username, status, ROUND(last_call_et/60, 2) AS duration_min, sql_id, blocking_session, event FROM v\$session WHERE status = 'ACTIVE' AND username IS NOT NULL ORDER BY last_call_et DESC FETCH FIRST 5 ROWS ONLY;" | sqlplus -S / as sysdba 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  Unable to query Oracle (requires sqlplus and authentication)" | tee -a "$OUTPUT_FILE"
            
            # Top queries by elapsed time
            echo "SELECT sql_id, executions, ROUND(elapsed_time/1000000, 2) AS total_time_sec, ROUND(cpu_time/1000000, 2) AS cpu_time_sec, ROUND(buffer_gets/NULLIF(executions,0), 0) AS avg_buffer_gets FROM v\$sql ORDER BY elapsed_time DESC FETCH FIRST 5 ROWS ONLY;" | sqlplus -S / as sysdba 2>/dev/null | tee -a "$OUTPUT_FILE"
            
            # Check for long-running sessions
            local long_running=$(echo "SELECT COUNT(*) FROM v\$session WHERE status = 'ACTIVE' AND username IS NOT NULL AND last_call_et > 1800;" | sqlplus -S / as sysdba 2>/dev/null | grep -o '[0-9]*' | head -1)
            if [[ -n "$long_running" ]] && (( long_running > 0 )); then
                log_bottleneck "Database" "Long-running Oracle sessions detected (>30min)" "Yes" "30min" "High"
            fi
            
            # DMS-specific checks for Oracle
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  DMS Migration Readiness:" | tee -a "$OUTPUT_FILE"
            
            # Check archive log mode (required for CDC)
            local log_mode=$(echo "SELECT log_mode FROM v\$database;" | sqlplus -S / as sysdba 2>/dev/null | grep -E "ARCHIVELOG|NOARCHIVELOG" | tr -d ' ')
            echo "    Archive Log Mode: ${log_mode:-Unknown}" | tee -a "$OUTPUT_FILE"
            if [[ "$log_mode" != "ARCHIVELOG" ]]; then
                log_bottleneck "DMS" "Oracle not in ARCHIVELOG mode - required for DMS CDC" "${log_mode}" "ARCHIVELOG" "High"
            fi
            
            # Check supplemental logging
            local supp_log=$(echo "SELECT supplemental_log_data_min FROM v\$database;" | sqlplus -S / as sysdba 2>/dev/null | grep -E "YES|NO" | tr -d ' ')
            echo "    Supplemental Logging: ${supp_log:-Unknown}" | tee -a "$OUTPUT_FILE"
            if [[ "$supp_log" != "YES" ]]; then
                log_bottleneck "DMS" "Oracle supplemental logging not enabled - required for DMS CDC" "${supp_log}" "YES" "High"
            fi
            
            # Check for standby lag (if Data Guard)
            local standby_lag=$(echo "SELECT MAX(ROUND((SYSDATE - applied_time) * 24 * 60)) FROM v\$archived_log WHERE applied = 'YES';" | sqlplus -S / as sysdba 2>/dev/null | grep -o '[0-9]*' | head -1)
            if [[ -n "$standby_lag" ]] && (( standby_lag > 0 )); then
                echo "    Standby Apply Lag: ${standby_lag} minutes" | tee -a "$OUTPUT_FILE"
                if (( standby_lag > 30 )); then
                    log_bottleneck "Database" "High Oracle standby apply lag" "${standby_lag}min" "30min" "Medium"
                fi
            fi
        fi
    fi
    
    # Microsoft SQL Server Detection (Linux)
    if pgrep -x sqlservr >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== SQL Server Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep "[s]qlservr" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count
        local mssql_conns=$(netstat -ant 2>/dev/null | grep :1433 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${mssql_conns}" | tee -a "$OUTPUT_FILE"
        
        if (( mssql_conns > 500 )); then
            log_bottleneck "Database" "High SQL Server connection count" "${mssql_conns}" "500" "Medium"
        fi
        
        # SQL Server Query Analysis
        if command -v sqlcmd >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  SQL Server Query Analysis:" | tee -a "$OUTPUT_FILE"
            
            sqlcmd -S localhost -E -Q "SELECT TOP 5 qs.execution_count AS [Executions], qs.total_worker_time / 1000 AS [Total CPU (ms)], qs.total_worker_time / qs.execution_count / 1000 AS [Avg CPU (ms)], qs.total_elapsed_time / 1000 AS [Total Duration (ms)], SUBSTRING(qt.text, (qs.statement_start_offset/2)+1, ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text) ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1) AS [Query Text] FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt ORDER BY qs.total_worker_time DESC;" -h -1 -W 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  Unable to query SQL Server DMVs (requires authentication)" | tee -a "$OUTPUT_FILE"
            
            sqlcmd -S localhost -E -Q "SELECT r.session_id, r.status, r.command, r.cpu_time, r.total_elapsed_time, r.wait_type, r.wait_time, r.blocking_session_id, SUBSTRING(qt.text, (r.statement_start_offset/2)+1, ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text) ELSE r.statement_end_offset END - r.statement_start_offset)/2) + 1) AS [Current Query] FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) qt WHERE r.session_id > 50 ORDER BY r.total_elapsed_time DESC;" -h -1 -W 2>/dev/null | tee -a "$OUTPUT_FILE"
            
            # Check for long-running queries
            local long_running=$(sqlcmd -S localhost -E -Q "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE total_elapsed_time > 30000;" -h -1 -W 2>/dev/null | tail -1 | tr -d ' ')
            if [[ -n "$long_running" ]] && (( long_running > 0 )); then
                log_bottleneck "Database" "Long-running SQL queries detected (>30s)" "Yes" "30s" "High"
            fi
            
            # DMS-specific checks for SQL Server
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  DMS Migration Readiness:" | tee -a "$OUTPUT_FILE"
            
            # Check if SQL Server Agent is running (required for CDC)
            local agent_status=$(sqlcmd -S localhost -E -Q "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE '%Agent%' AND status_desc = 'Running') THEN 'Running' ELSE 'Stopped' END AS AgentStatus;" -h -1 -W 2>/dev/null | tail -1 | tr -d ' ')
            echo "    SQL Server Agent: ${agent_status:-Unknown}" | tee -a "$OUTPUT_FILE"
            if [[ "$agent_status" != "Running" ]]; then
                log_bottleneck "DMS" "SQL Server Agent not running - required for DMS CDC" "${agent_status}" "Running" "High"
            fi
            
            # Check if database is in FULL recovery model (required for CDC)
            local recovery_model=$(sqlcmd -S localhost -E -Q "SELECT name, recovery_model_desc FROM sys.databases WHERE name NOT IN ('master','model','msdb','tempdb');" -h -1 -W 2>/dev/null | grep -v "^$" | head -5 | tee -a "$OUTPUT_FILE")
            if echo "$recovery_model" | grep -q "SIMPLE"; then
                log_bottleneck "DMS" "SQL Server database(s) in SIMPLE recovery - DMS CDC requires FULL" "SIMPLE" "FULL" "High"
            fi
            
            # Check for AlwaysOn lag (if replica)
            local replica_lag=$(sqlcmd -S localhost -E -Q "SELECT ar.replica_server_name, drs.synchronization_state_desc, drs.log_send_queue_size, drs.redo_queue_size FROM sys.dm_hadr_database_replica_states drs INNER JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id WHERE drs.is_local = 1;" -h -1 -W 2>/dev/null | grep -v "^$" | head -5)
            if [[ -n "$replica_lag" ]]; then
                echo "    AlwaysOn Replica Status:" | tee -a "$OUTPUT_FILE"
                echo "$replica_lag" | tee -a "$OUTPUT_FILE"
            fi
        fi
    fi
    
    # Elasticsearch Detection
    if pgrep -f "org.elasticsearch" >/dev/null 2>&1; then
        databases_found=true
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== Elasticsearch Detected ===" | tee -a "$OUTPUT_FILE"
        
        # Process info
        ps aux | grep "[o]rg.elasticsearch" | awk '{printf "  Process: PID %s, CPU: %s%%, MEM: %s%%\n", $2, $3, $4}' | tee -a "$OUTPUT_FILE"
        
        # Connection count
        local es_conns=$(netstat -ant 2>/dev/null | grep :9200 | grep ESTABLISHED | wc -l || echo "0")
        echo "  Active Connections: ${es_conns}" | tee -a "$OUTPUT_FILE"
        
        # Elasticsearch Query Analysis
        if command -v curl >/dev/null 2>&1; then
            echo "" | tee -a "$OUTPUT_FILE"
            echo "  Elasticsearch Performance Analysis:" | tee -a "$OUTPUT_FILE"
            
            # Get current tasks
            local es_tasks=$(curl -s "http://localhost:9200/_tasks?detailed=true&actions=*search*" 2>/dev/null)
            if [[ -n "$es_tasks" ]]; then
                echo "  Active Search Tasks:" | tee -a "$OUTPUT_FILE"
                echo "$es_tasks" | grep -o '"running_time_in_nanos":[0-9]*' | head -5 | tee -a "$OUTPUT_FILE"
                
                # Check for long-running queries
                local long_running=$(echo "$es_tasks" | grep -o '"running_time_in_nanos":[0-9]*' | awk -F: '{if ($2 > 30000000000) print $2}' | wc -l)
                if (( long_running > 0 )); then
                    log_bottleneck "Database" "Long-running Elasticsearch queries detected (>30s)" "Yes" "30s" "High"
                fi
            fi
            
            # Get thread pool stats
            echo "  Thread Pool Status:" | tee -a "$OUTPUT_FILE"
            curl -s "http://localhost:9200/_cat/thread_pool?v&h=node_name,name,active,queue,rejected" 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "  Unable to query Elasticsearch API (requires HTTP access to localhost:9200)" | tee -a "$OUTPUT_FILE"
            
            # Check for rejections
            local rejections=$(curl -s "http://localhost:9200/_cat/thread_pool?h=rejected" 2>/dev/null | awk '{sum+=$1} END {print sum}')
            if [[ -n "$rejections" ]] && (( rejections > 0 )); then
                log_bottleneck "Database" "Elasticsearch thread pool rejections detected" "${rejections}" "0" "High"
            fi
        fi
    fi
    
    # General database connection analysis
    if [[ "$databases_found" == true ]]; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "=== Database Connection Summary ===" | tee -a "$OUTPUT_FILE"
        
        # Check for connection pool exhaustion indicators
        local total_db_conns=$(netstat -ant 2>/dev/null | grep -E ":3306|:5432|:27017|:9042|:6379|:1521|:1433|:9200" | grep ESTABLISHED | wc -l || echo "0")
        echo "Total Database Connections: ${total_db_conns}" | tee -a "$OUTPUT_FILE"
        
        # Check for TIME_WAIT on database ports (connection churn)
        local db_time_wait=$(netstat -ant 2>/dev/null | grep -E ":3306|:5432|:27017|:9042|:6379|:1521|:1433|:9200" | grep TIME_WAIT | wc -l || echo "0")
        if (( db_time_wait > 1000 )); then
            echo "  ⚠️  High TIME_WAIT on database ports: ${db_time_wait}" | tee -a "$OUTPUT_FILE"
            log_bottleneck "Database" "High connection churn (TIME_WAIT)" "${db_time_wait}" "1000" "Medium"
        fi
        
        log_success "Database forensics completed"
    else
        log_info "No common database processes detected"
    fi
}

#############################################################################
# Network Forensics
#############################################################################

analyze_network() {
    print_header "NETWORK FORENSICS"
    
    log_info "Analyzing network performance..."
    
    # Network interfaces and status
    echo "Network Interfaces:" | tee -a "$OUTPUT_FILE"
    if command -v ip >/dev/null 2>&1; then
        ip -br addr 2>/dev/null | tee -a "$OUTPUT_FILE"
    else
        ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | tee -a "$OUTPUT_FILE" || \
        log_warning "Unable to list network interfaces"
    fi
    
    # Network statistics and connection states
    if command -v netstat >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "TCP Connection States:" | tee -a "$OUTPUT_FILE"
        netstat -ant 2>/dev/null | awk '{print $6}' | sort | uniq -c | sort -rn | tee -a "$OUTPUT_FILE"
        
        # Check for excessive connections
        local established=$(netstat -ant 2>/dev/null | grep -c ESTABLISHED || echo "0")
        local time_wait=$(netstat -ant 2>/dev/null | grep -c TIME_WAIT || echo "0")
        local close_wait=$(netstat -ant 2>/dev/null | grep -c CLOSE_WAIT || echo "0")
        
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Established Connections: ${established}" | tee -a "$OUTPUT_FILE"
        echo "TIME_WAIT Connections: ${time_wait}" | tee -a "$OUTPUT_FILE"
        echo "CLOSE_WAIT Connections: ${close_wait}" | tee -a "$OUTPUT_FILE"
        
        if (( time_wait > 5000 )); then
            log_bottleneck "Network" "Excessive TIME_WAIT connections" "${time_wait}" "5000" "Medium"
        fi
        
        if (( close_wait > 1000 )); then
            log_bottleneck "Network" "Excessive CLOSE_WAIT connections" "${close_wait}" "1000" "Medium"
        fi
        
        # Listening ports
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Top 10 listening ports:" | tee -a "$OUTPUT_FILE"
        netstat -tuln 2>/dev/null | grep LISTEN | awk '{print $4}' | sed 's/.*://' | sort -n | uniq -c | sort -rn | head -10 | tee -a "$OUTPUT_FILE"
    elif command -v ss >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "TCP Connection States:" | tee -a "$OUTPUT_FILE"
        ss -ant 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | tee -a "$OUTPUT_FILE"
        
        local established=$(ss -ant 2>/dev/null | grep -c ESTAB || echo "0")
        local time_wait=$(ss -ant 2>/dev/null | grep -c TIME-WAIT || echo "0")
        
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Established Connections: ${established}" | tee -a "$OUTPUT_FILE"
        echo "TIME_WAIT Connections: ${time_wait}" | tee -a "$OUTPUT_FILE"
        
        if (( time_wait > 5000 )); then
            log_bottleneck "Network" "Excessive TIME_WAIT connections" "${time_wait}" "5000" "Medium"
        fi
    else
        log_warning "netstat and ss not available - skipping connection state analysis"
    fi
    
    # TCP retransmissions and errors
    if command -v ss >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "TCP Retransmission Analysis:" | tee -a "$OUTPUT_FILE"
        local retrans_info=$(ss -ti 2>/dev/null | grep -oP 'retrans:\d+/\d+' | head -20)
        if [[ -n "$retrans_info" ]]; then
            echo "$retrans_info" | tee -a "$OUTPUT_FILE"
            local total_retrans=$(echo "$retrans_info" | cut -d: -f2 | cut -d/ -f1 | awk '{sum+=$1} END {print sum}')
            if [[ -n "$total_retrans" ]] && (( total_retrans > 100 )); then
                log_bottleneck "Network" "High TCP retransmissions detected" "${total_retrans}" "100" "Medium"
            fi
        else
            echo "  No significant retransmissions detected" | tee -a "$OUTPUT_FILE"
        fi
    fi
    
    # Network interface statistics and errors
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Network Interface Statistics:" | tee -a "$OUTPUT_FILE"
    if command -v ip >/dev/null 2>&1; then
        ip -s link 2>/dev/null | grep -E "^\d+:|RX:|TX:|errors" | tee -a "$OUTPUT_FILE"
        
        # Check for errors
        local rx_errors=$(ip -s link 2>/dev/null | grep "RX:" -A 1 | grep errors | awk '{sum+=$2} END {print sum}')
        local tx_errors=$(ip -s link 2>/dev/null | grep "TX:" -A 1 | grep errors | awk '{sum+=$2} END {print sum}')
        
        if [[ -n "$rx_errors" ]] && (( rx_errors > 100 )); then
            log_bottleneck "Network" "High RX errors detected" "${rx_errors}" "100" "Medium"
        fi
        
        if [[ -n "$tx_errors" ]] && (( tx_errors > 100 )); then
            log_bottleneck "Network" "High TX errors detected" "${tx_errors}" "100" "Medium"
        fi
    else
        netstat -i 2>/dev/null | tee -a "$OUTPUT_FILE" || \
        ifconfig 2>/dev/null | grep -E "RX|TX" | tee -a "$OUTPUT_FILE" || \
        log_warning "Unable to get network interface statistics"
    fi
    
    # ==========================================================================
    # SAR NETWORK ANALYSIS (Real-time and Historical)
    # ==========================================================================
    if command -v sar >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "--- SAR NETWORK ANALYSIS ---" | tee -a "$OUTPUT_FILE"
        
        # Network device throughput
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Network Device Throughput (sar -n DEV, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -n DEV 1 5 2>/dev/null | grep -v "^$" | tail -25 | tee -a "$OUTPUT_FILE" || \
        log_warning "sar -n DEV failed"
        
        # Network errors
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Network Errors (sar -n EDEV, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -n EDEV 1 5 2>/dev/null | grep -v "^$" | tail -25 | tee -a "$OUTPUT_FILE" || \
        log_warning "sar -n EDEV failed"
        
        # TCP statistics
        echo "" | tee -a "$OUTPUT_FILE"
        echo "TCP Statistics (sar -n TCP, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -n TCP 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -n TCP failed"
        
        # TCP errors
        echo "" | tee -a "$OUTPUT_FILE"
        echo "TCP Errors (sar -n ETCP, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -n ETCP 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -n ETCP failed"
        
        # Socket statistics
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Socket Statistics (sar -n SOCK, 5 samples):" | tee -a "$OUTPUT_FILE"
        sar -n SOCK 1 5 2>/dev/null | tee -a "$OUTPUT_FILE" || log_warning "sar -n SOCK failed"
        
        # Check for historical sar data
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Historical Network Data (today):" | tee -a "$OUTPUT_FILE"
        
        local sar_data_found=false
        for sar_dir in /var/log/sa /var/log/sysstat /var/log/sysstat/sa; do
            if [[ -d "$sar_dir" ]]; then
                local today=$(date +%d)
                local sar_file="${sar_dir}/sa${today}"
                
                if [[ -f "$sar_file" ]]; then
                    sar_data_found=true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  Network Throughput History (today):" | tee -a "$OUTPUT_FILE"
                    sar -n DEV -f "$sar_file" 2>/dev/null | tail -30 | tee -a "$OUTPUT_FILE" || true
                    
                    echo "" | tee -a "$OUTPUT_FILE"
                    echo "  TCP Statistics History (today):" | tee -a "$OUTPUT_FILE"
                    sar -n TCP -f "$sar_file" 2>/dev/null | tail -20 | tee -a "$OUTPUT_FILE" || true
                    
                    break
                fi
            fi
        done
        
        if [[ "$sar_data_found" == "false" ]]; then
            echo "  No historical sar data found." | tee -a "$OUTPUT_FILE"
        fi
    else
        echo "" | tee -a "$OUTPUT_FILE"
        echo "sar not available - install sysstat for detailed network history" | tee -a "$OUTPUT_FILE"
    fi
    
    # Socket statistics
    if command -v ss >/dev/null 2>&1; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Socket Memory Usage:" | tee -a "$OUTPUT_FILE"
        ss -m 2>/dev/null | grep -A 1 "skmem:" | head -20 | tee -a "$OUTPUT_FILE"
    fi
    
    # Check for dropped packets
    if [[ -f /proc/net/dev ]]; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Dropped Packets by Interface:" | tee -a "$OUTPUT_FILE"
        awk 'NR>2 {print $1, "RX dropped:", $5, "TX dropped:", $13}' /proc/net/dev | column -t | tee -a "$OUTPUT_FILE"
    fi
    
    # Network buffer/queue statistics
    if [[ -f /proc/sys/net/core/netdev_max_backlog ]]; then
        local max_backlog=$(cat /proc/sys/net/core/netdev_max_backlog)
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Network Queue Settings:" | tee -a "$OUTPUT_FILE"
        echo "  Max backlog: ${max_backlog}" | tee -a "$OUTPUT_FILE"
    fi
    
    # Database connectivity checks (useful for DMS migrations)
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Database Port Connectivity:" | tee -a "$OUTPUT_FILE"
    
    # Check for active database connections
    local mysql_conns=$(netstat -ant 2>/dev/null | grep ":3306" | grep ESTABLISHED | wc -l || echo "0")
    local pg_conns=$(netstat -ant 2>/dev/null | grep ":5432" | grep ESTABLISHED | wc -l || echo "0")
    local oracle_conns=$(netstat -ant 2>/dev/null | grep ":1521" | grep ESTABLISHED | wc -l || echo "0")
    local mssql_conns=$(netstat -ant 2>/dev/null | grep ":1433" | grep ESTABLISHED | wc -l || echo "0")
    local mongo_conns=$(netstat -ant 2>/dev/null | grep ":27017" | grep ESTABLISHED | wc -l || echo "0")
    
    echo "  MySQL (3306): ${mysql_conns} connections" | tee -a "$OUTPUT_FILE"
    echo "  PostgreSQL (5432): ${pg_conns} connections" | tee -a "$OUTPUT_FILE"
    echo "  Oracle (1521): ${oracle_conns} connections" | tee -a "$OUTPUT_FILE"
    echo "  SQL Server (1433): ${mssql_conns} connections" | tee -a "$OUTPUT_FILE"
    echo "  MongoDB (27017): ${mongo_conns} connections" | tee -a "$OUTPUT_FILE"
    
    # Check for connection churn (high TIME_WAIT on database ports)
    local db_time_wait=$(netstat -ant 2>/dev/null | grep -E ":3306|:5432|:1521|:1433|:27017" | grep TIME_WAIT | wc -l || echo "0")
    echo "  Database TIME_WAIT: ${db_time_wait}" | tee -a "$OUTPUT_FILE"
    
    if (( db_time_wait > 1000 )); then
        log_bottleneck "Network" "High connection churn on database ports (DMS impact)" "${db_time_wait}" "1000" "Medium"
    fi
    
    log_success "Network forensics completed"
}

#############################################################################
# AWS Support Integration
#############################################################################

create_support_case() {
    print_header "AWS SUPPORT CASE CREATION"
    
    if [[ ${#BOTTLENECKS[@]} -eq 0 ]]; then
        log_info "No bottlenecks detected - skipping support case creation"
        return
    fi
    
    # Check AWS CLI
    if ! check_command aws; then
        log_error "AWS CLI not found. Install from: https://aws.amazon.com/cli/"
        return
    fi
    
    log_info "Creating AWS Support case with severity: ${SEVERITY}"
    
    # Build bottleneck summary
    local bottleneck_summary=""
    for bottleneck in "${BOTTLENECKS[@]}"; do
        IFS='|' read -r impact category issue current threshold <<< "$bottleneck"
        bottleneck_summary+="[${impact}] ${category}: ${issue} (Current: ${current}, Threshold: ${threshold})\n"
    done
    
    # Get system info
    local hostname=$(hostname)
    local os_info=$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
    local kernel=$(uname -r)
    local instance_id=$(curl -s -m 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
    
    # Use instance ID for AWS, hostname for non-AWS
    local system_identifier
    if [[ -n "$instance_id" ]]; then
        system_identifier="$instance_id"
    else
        system_identifier="$hostname"
    fi
    
    # Build case description
    local case_description="AUTOMATED LINUX FORENSICS REPORT

EXECUTIVE SUMMARY:
Comprehensive diagnostics detected ${#BOTTLENECKS[@]} performance issue(s) requiring attention.

BOTTLENECKS DETECTED:
${bottleneck_summary}

SYSTEM INFORMATION:
- Hostname: ${hostname}
- OS: ${os_info}
- Kernel: ${kernel}
- Instance ID: ${instance_id:-Not EC2}
- Diagnostic Mode: ${MODE}
- Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

Detailed forensics data is attached in the diagnostic report file.

Generated by: invoke-linux-forensics.sh v1.0"
    
    local case_subject="Linux Performance Issues Detected - ${system_identifier}"
    
    # Create case JSON
    local case_json=$(cat <<EOF
{
  "subject": "${case_subject}",
  "serviceCode": "amazon-ec2-linux",
  "severityCode": "${SEVERITY}",
  "categoryCode": "performance",
  "communicationBody": "${case_description}",
  "language": "en",
  "issueType": "technical"
}
EOF
)
    
    # Create the case
    local case_result=$(aws support create-case --cli-input-json "$case_json" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        local case_id=$(echo "$case_result" | grep -oP '"caseId":\s*"\K[^"]+')
        log_success "Support case created successfully!"
        log_success "Case ID: ${case_id}"
        
        # Attach diagnostic file
        log_info "Attaching diagnostic report..."
        
        local attachment_content=$(base64 -w 0 "$OUTPUT_FILE")
        local attachment_json=$(cat <<EOF
{
  "attachments": [
    {
      "fileName": "$(basename "$OUTPUT_FILE")",
      "data": "${attachment_content}"
    }
  ]
}
EOF
)
        
        local attachment_result=$(aws support add-attachments-to-set --cli-input-json "$attachment_json" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            local attachment_set_id=$(echo "$attachment_result" | grep -oP '"attachmentSetId":\s*"\K[^"]+')
            
            aws support add-communication-to-case \
                --case-id "$case_id" \
                --communication-body "Complete forensics diagnostic report attached." \
                --attachment-set-id "$attachment_set_id" &>/dev/null
            
            log_success "Diagnostic report attached successfully"
        fi
        
        echo "" | tee -a "$OUTPUT_FILE"
        log_info "View your case: https://console.aws.amazon.com/support/home#/case/?displayId=${case_id}"
        
    else
        log_error "Failed to create support case: ${case_result}"
        log_info "Ensure you have:"
        log_info "  1. AWS CLI configured (aws configure)"
        log_info "  2. Active AWS Support plan (Business or Enterprise)"
        log_info "  3. IAM permissions for support:CreateCase"
    fi
}

#############################################################################
# Main Execution
#############################################################################

show_banner() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                               ║"
    echo "║                LINUX PERFORMANCE FORENSICS TOOL v1.0                          ║"
    echo "║                                                                               ║"
    echo "║                    Comprehensive System Diagnostics                           ║"
    echo "║                    with AWS Support Integration                               ║"
    echo "║                                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
}

show_help() {
    cat << EOF
Linux Performance Forensic Tool

Usage: sudo $0 [OPTIONS]

Options:
  -m, --mode MODE          Diagnostic mode: quick, standard, deep, disk, cpu, memory
                          (default: standard)
  -s, --support            Create AWS Support case if issues found
  -v, --severity LEVEL     Support case severity: low, normal, high, urgent, critical
                          (default: normal)
  -o, --output PATH        Output directory (default: current directory)
  -h, --help               Show this help message

Modes:
  quick      - Fast assessment (CPU, memory, disk usage only)
  standard   - Comprehensive diagnostics (recommended)
  deep       - Extended diagnostics with I/O testing
  disk       - Disk-only diagnostics
  cpu        - CPU-only diagnostics
  memory     - Memory-only diagnostics

Examples:
  sudo $0 -m quick
  sudo $0 -m deep -s -v high
  sudo $0 -m standard -o /var/log

Requires: root/sudo privileges
Optional: AWS CLI for support case creation
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)
                MODE="$2"
                shift 2
                ;;
            -s|--support)
                CREATE_SUPPORT_CASE=true
                shift
                ;;
            -v|--severity)
                SEVERITY="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                OUTPUT_FILE="${OUTPUT_DIR}/linux-forensics-${TIMESTAMP}.txt"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    
    check_root
    
    # Detect OS and package manager
    detect_os
    
    show_banner
    
    log_info "Detected OS: ${OS_NAME:-$DISTRO}"
    log_info "OS Version: ${OS_VERSION:-unknown}"
    log_info "Package Manager: ${PACKAGE_MANAGER}"
    log_info "Starting forensics analysis in ${MODE} mode..."
    log_info "Output file: ${OUTPUT_FILE}"
    echo ""
    
    # Check and install dependencies
    check_and_install_dependencies
    echo ""
    
    local start_time=$(date +%s)
    
    # Execute diagnostics based on mode
    collect_system_info
    
    case "$MODE" in
        quick)
            analyze_cpu
            analyze_memory
            ;;
        standard)
            analyze_cpu
            analyze_memory
            analyze_disk
            analyze_storage_profile
            analyze_databases
            analyze_network
            ;;
        deep)
            analyze_cpu
            analyze_memory
            analyze_disk
            analyze_storage_profile
            analyze_databases
            analyze_network
            ;;
        disk)
            analyze_disk
            analyze_storage_profile
            ;;
        cpu)
            analyze_cpu
            ;;
        memory)
            analyze_memory
            ;;
        *)
            log_error "Invalid mode: ${MODE}"
            show_help
            exit 1
            ;;
    esac
    
    # Summary
    print_header "FORENSICS SUMMARY"
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_success "Analysis completed in ${duration} seconds"
    
    if [[ ${#BOTTLENECKS[@]} -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}NO BOTTLENECKS FOUND! System performance looks healthy.${NC}"
    else
        echo ""
        echo -e "${MAGENTA}BOTTLENECKS DETECTED: ${#BOTTLENECKS[@]} performance issue(s) found${NC}"
        echo ""
        
        # Group by impact
        local critical=()
        local high=()
        local medium=()
        local low=()
        
        for bottleneck in "${BOTTLENECKS[@]}"; do
            IFS='|' read -r impact category issue current threshold <<< "$bottleneck"
            case "$impact" in
                Critical) critical+=("${category}: ${issue}") ;;
                High) high+=("${category}: ${issue}") ;;
                Medium) medium+=("${category}: ${issue}") ;;
                Low) low+=("${category}: ${issue}") ;;
            esac
        done
        
        if [[ ${#critical[@]} -gt 0 ]]; then
            echo -e "${RED}  CRITICAL ISSUES (${#critical[@]}):${NC}"
            for issue in "${critical[@]}"; do
                echo "    • ${issue}"
            done
        fi
        
        if [[ ${#high[@]} -gt 0 ]]; then
            echo -e "${YELLOW}  HIGH PRIORITY (${#high[@]}):${NC}"
            for issue in "${high[@]}"; do
                echo "    • ${issue}"
            done
        fi
        
        if [[ ${#medium[@]} -gt 0 ]]; then
            echo -e "${YELLOW}  MEDIUM PRIORITY (${#medium[@]}):${NC}"
            for issue in "${medium[@]}"; do
                echo "    • ${issue}"
            done
        fi
        
        if [[ ${#low[@]} -gt 0 ]]; then
            echo "  LOW PRIORITY (${#low[@]}):"
            for issue in "${low[@]}"; do
                echo "    • ${issue}"
            done
        fi
    fi
    
    echo ""
    log_info "Detailed report saved to: ${OUTPUT_FILE}"
    
    # Create AWS Support case if requested
    if [[ "$CREATE_SUPPORT_CASE" == true ]] && [[ ${#BOTTLENECKS[@]} -gt 0 ]]; then
        echo ""
        create_support_case
    elif [[ ${#BOTTLENECKS[@]} -gt 0 ]] && [[ "$CREATE_SUPPORT_CASE" == false ]]; then
        echo ""
        log_info "Tip: Run with --support to automatically open an AWS Support case"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "                         Forensics Analysis Complete                            "
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
}

# Run main function
main "$@"
