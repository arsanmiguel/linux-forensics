#!/bin/bash

#############################################################################
# Linux Performance Forensic Tool
# 
# Comprehensive performance diagnostics with automatic bottleneck detection
# and AWS Support integration
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

set -euo pipefail

# Default values
MODE="standard"
CREATE_SUPPORT_CASE=false
SEVERITY="normal"
OUTPUT_DIR="$(pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/linux-forensics-${TIMESTAMP}.txt"
BOTTLENECKS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

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
    local cpu_cores=$(nproc)
    local load_per_core=$(echo "scale=2; $load_1min / $cpu_cores" | bc)
    
    echo "Load Average: ${load_avg}" | tee -a "$OUTPUT_FILE"
    echo "Load per Core: ${load_per_core}" | tee -a "$OUTPUT_FILE"
    
    if (( $(echo "$load_per_core > 1.0" | bc -l) )); then
        log_bottleneck "CPU" "High load average" "${load_per_core} per core" "1.0 per core" "High"
    fi
    
    # CPU usage
    log_info "Sampling CPU usage (10 seconds)..."
    local cpu_idle=$(mpstat 1 10 | tail -1 | awk '{print $NF}')
    local cpu_usage=$(echo "scale=2; 100 - $cpu_idle" | bc)
    
    echo "CPU Usage: ${cpu_usage}%" | tee -a "$OUTPUT_FILE"
    
    if (( $(echo "$cpu_usage > 80" | bc -l) )); then
        log_bottleneck "CPU" "High CPU utilization" "${cpu_usage}%" "80%" "High"
    fi
    
    # Context switches
    local ctx_switches=$(vmstat 1 5 | tail -1 | awk '{print $12}')
    echo "Context Switches: ${ctx_switches}/sec" | tee -a "$OUTPUT_FILE"
    
    if (( ctx_switches > 15000 )); then
        log_bottleneck "CPU" "Excessive context switches" "${ctx_switches}/sec" "15000/sec" "Medium"
    fi
    
    # CPU steal time (for VMs)
    local cpu_steal=$(mpstat 1 5 | tail -1 | awk '{print $(NF-1)}')
    echo "CPU Steal Time: ${cpu_steal}%" | tee -a "$OUTPUT_FILE"
    
    if (( $(echo "$cpu_steal > 10" | bc -l) )); then
        log_bottleneck "CPU" "High CPU steal time (hypervisor contention)" "${cpu_steal}%" "10%" "High"
    fi
    
    # Top CPU consumers
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Top 10 CPU-consuming processes:" | tee -a "$OUTPUT_FILE"
    ps aux --sort=-%cpu | head -11 | tail -10 | awk '{printf "  %-20s PID: %-8s CPU: %5s%% MEM: %5s%%\n", $11, $2, $3, $4}' | tee -a "$OUTPUT_FILE"
    
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
    local total_mem=$(free -m | grep Mem | awk '{print $2}')
    local used_mem=$(free -m | grep Mem | awk '{print $3}')
    local free_mem=$(free -m | grep Mem | awk '{print $4}')
    local available_mem=$(free -m | grep Mem | awk '{print $7}')
    local mem_usage_pct=$(echo "scale=2; ($used_mem / $total_mem) * 100" | bc)
    local mem_available_pct=$(echo "scale=2; ($available_mem / $total_mem) * 100" | bc)
    
    echo "Total Memory: ${total_mem} MB" | tee -a "$OUTPUT_FILE"
    echo "Used Memory: ${used_mem} MB (${mem_usage_pct}%)" | tee -a "$OUTPUT_FILE"
    echo "Available Memory: ${available_mem} MB (${mem_available_pct}%)" | tee -a "$OUTPUT_FILE"
    
    if (( $(echo "$mem_available_pct < 10" | bc -l) )); then
        log_bottleneck "Memory" "Low available memory" "${mem_available_pct}%" "10%" "Critical"
    fi
    
    # Swap usage
    local total_swap=$(free -m | grep Swap | awk '{print $2}')
    if (( total_swap > 0 )); then
        local used_swap=$(free -m | grep Swap | awk '{print $3}')
        local swap_usage_pct=$(echo "scale=2; ($used_swap / $total_swap) * 100" | bc)
        echo "Swap Usage: ${used_swap} MB / ${total_swap} MB (${swap_usage_pct}%)" | tee -a "$OUTPUT_FILE"
        
        if (( $(echo "$swap_usage_pct > 50" | bc -l) )); then
            log_bottleneck "Memory" "High swap usage" "${swap_usage_pct}%" "50%" "High"
        fi
    else
        echo "Swap: Not configured" | tee -a "$OUTPUT_FILE"
    fi
    
    # Page faults
    log_info "Sampling page faults (5 seconds)..."
    local page_faults=$(vmstat 1 5 | tail -1 | awk '{print $7}')
    echo "Page Faults: ${page_faults}/sec" | tee -a "$OUTPUT_FILE"
    
    if (( page_faults > 1000 )); then
        log_bottleneck "Memory" "High page fault rate" "${page_faults}/sec" "1000/sec" "Medium"
    fi
    
    # OOM killer check
    if dmesg | grep -i "out of memory" | tail -5 | grep -q .; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Recent OOM (Out of Memory) events detected:" | tee -a "$OUTPUT_FILE"
        dmesg | grep -i "out of memory" | tail -5 | tee -a "$OUTPUT_FILE"
        log_bottleneck "Memory" "OOM killer invoked recently" "Yes" "No" "Critical"
    fi
    
    # Top memory consumers
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Top 10 memory-consuming processes:" | tee -a "$OUTPUT_FILE"
    ps aux --sort=-%mem | head -11 | tail -10 | awk '{printf "  %-20s PID: %-8s MEM: %5s%% CPU: %5s%%\n", $11, $2, $4, $3}' | tee -a "$OUTPUT_FILE"
    
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
    df -h | grep -v tmpfs | grep -v devtmpfs | tee -a "$OUTPUT_FILE"
    
    # Check for full filesystems
    while IFS= read -r line; do
        local usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        local mount=$(echo "$line" | awk '{print $6}')
        if (( usage > 90 )); then
            log_bottleneck "Disk" "Filesystem nearly full: ${mount}" "${usage}%" "90%" "High"
        fi
    done < <(df -h | grep -v tmpfs | grep -v devtmpfs | tail -n +2)
    
    # I/O statistics
    if check_command iostat; then
        echo "" | tee -a "$OUTPUT_FILE"
        log_info "Sampling I/O statistics (10 seconds)..."
        iostat -x 1 10 | tail -n +4 > /tmp/iostat_output.txt
        
        echo "I/O Statistics:" | tee -a "$OUTPUT_FILE"
        cat /tmp/iostat_output.txt | tee -a "$OUTPUT_FILE"
        
        # Analyze I/O wait
        local avg_await=$(cat /tmp/iostat_output.txt | grep -v "^$" | grep -v "Device" | awk '{sum+=$10; count++} END {if(count>0) print sum/count; else print 0}')
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Average I/O Wait Time: ${avg_await} ms" | tee -a "$OUTPUT_FILE"
        
        if (( $(echo "$avg_await > 20" | bc -l) )); then
            log_bottleneck "Disk" "High I/O wait time" "${avg_await}ms" "20ms" "High"
        fi
        
        rm -f /tmp/iostat_output.txt
    fi
    
    # Disk I/O test (if in disk mode or deep mode)
    if [[ "$MODE" == "disk" ]] || [[ "$MODE" == "deep" ]]; then
        if check_command dd; then
            echo "" | tee -a "$OUTPUT_FILE"
            log_info "Running disk write performance test..."
            
            local test_file="/tmp/forensics_disk_test_$$"
            local write_speed=$(dd if=/dev/zero of="$test_file" bs=1M count=1024 oflag=direct 2>&1 | grep -oP '\d+\.?\d* MB/s' | head -1)
            
            echo "Disk Write Speed: ${write_speed}" | tee -a "$OUTPUT_FILE"
            
            log_info "Running disk read performance test..."
            sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
            local read_speed=$(dd if="$test_file" of=/dev/null bs=1M 2>&1 | grep -oP '\d+\.?\d* MB/s' | head -1)
            
            echo "Disk Read Speed: ${read_speed}" | tee -a "$OUTPUT_FILE"
            
            rm -f "$test_file"
        fi
    fi
    
    log_success "Disk forensics completed"
}

#############################################################################
# Network Forensics
#############################################################################

analyze_network() {
    print_header "NETWORK FORENSICS"
    
    log_info "Analyzing network performance..."
    
    # Network interfaces
    echo "Network Interfaces:" | tee -a "$OUTPUT_FILE"
    ip -br addr | tee -a "$OUTPUT_FILE"
    
    # Network statistics
    if check_command netstat; then
        echo "" | tee -a "$OUTPUT_FILE"
        echo "TCP Connection States:" | tee -a "$OUTPUT_FILE"
        netstat -ant | awk '{print $6}' | sort | uniq -c | sort -rn | tee -a "$OUTPUT_FILE"
        
        # Check for excessive connections
        local established=$(netstat -ant | grep ESTABLISHED | wc -l)
        local time_wait=$(netstat -ant | grep TIME_WAIT | wc -l)
        
        echo "" | tee -a "$OUTPUT_FILE"
        echo "Established Connections: ${established}" | tee -a "$OUTPUT_FILE"
        echo "TIME_WAIT Connections: ${time_wait}" | tee -a "$OUTPUT_FILE"
        
        if (( time_wait > 5000 )); then
            log_bottleneck "Network" "Excessive TIME_WAIT connections" "${time_wait}" "5000" "Medium"
        fi
    fi
    
    # TCP retransmissions
    if check_command ss; then
        local retrans=$(ss -ti | grep -oP 'retrans:\d+/\d+' | cut -d: -f2 | cut -d/ -f1 | awk '{sum+=$1} END {print sum}')
        if [[ -n "$retrans" ]] && (( retrans > 100 )); then
            log_bottleneck "Network" "High TCP retransmissions detected" "${retrans}" "100" "Medium"
        fi
    fi
    
    # Network errors
    echo "" | tee -a "$OUTPUT_FILE"
    echo "Network Interface Errors:" | tee -a "$OUTPUT_FILE"
    ip -s link | grep -E "^\d+:|RX:|TX:" | tee -a "$OUTPUT_FILE"
    
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
    local instance_id=$(curl -s -m 2 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "Not EC2")
    
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
- Instance ID: ${instance_id}
- Diagnostic Mode: ${MODE}
- Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

Detailed forensics data is attached in the diagnostic report file.

Generated by: invoke-linux-forensics.sh v1.0"
    
    local case_subject="Linux Performance Issues Detected - ${hostname}"
    
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
    
    show_banner
    
    log_info "Starting forensics analysis in ${MODE} mode..."
    log_info "Output file: ${OUTPUT_FILE}"
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
            analyze_network
            ;;
        deep)
            analyze_cpu
            analyze_memory
            analyze_disk
            analyze_network
            ;;
        disk)
            analyze_disk
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
