#!/usr/bin/env bash
# ==============================================================================
# NFS Server Setup and Management Toolkit
# Operating Systems Course Project
#
# Target Platform: Ubuntu 22.04 LTS / 24.04 LTS (and compatible Debian-based OS)
# Default Lab Subnet: 192.168.1.0/24
# ==============================================================================

# Enable strict mode where appropriate, but avoid premature exit on user input checks
set -u

# Script Metadata
readonly TOOLKIT_VERSION="1.2.0"
readonly DEFAULT_LOG_FILE="$(pwd)/nfs-toolkit.log"
readonly MANAGED_BEGIN_MARKER="# >>> BEGIN NFS-TOOLKIT MANAGED EXPORT >>>"
readonly MANAGED_END_MARKER="# <<< END NFS-TOOLKIT MANAGED EXPORT <<<"
readonly DEFAULT_EXPORTS_FILE="/etc/exports"
readonly DEFAULT_SUBNET="192.168.1.0/24"
readonly DEFAULT_SHARE_DIR="/srv/nfs/labshare"

# Runtime State Variables
DRY_RUN=false
LOG_FILE="${DEFAULT_LOG_FILE}"
EXPORTS_FILE="${DEFAULT_EXPORTS_FILE}"

# Color codes for terminal UI (ANSI-C escape representation)
if [[ -t 1 ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_DIM=$'\033[2m'
    COLOR_RED=$'\033[1;31m'
    COLOR_GREEN=$'\033[1;32m'
    COLOR_YELLOW=$'\033[1;33m'
    COLOR_BLUE=$'\033[1;34m'
    COLOR_MAGENTA=$'\033[1;35m'
    COLOR_CYAN=$'\033[1;36m'
    COLOR_WHITE=$'\033[1;37m'
    COLOR_GRAY=$'\033[0;90m'
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_DIM=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
    COLOR_WHITE=""
    COLOR_GRAY=""
fi

# ------------------------------------------------------------------------------
# Logging & Console Output Helpers
# ------------------------------------------------------------------------------

log_msg() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    # Ensure log file exists or can be appended safely
    if [[ -w "$(dirname "${LOG_FILE}")" ]] || [[ -w "${LOG_FILE}" ]]; then
        printf "[%s] [%-7s] %s\n" "${timestamp}" "${level}" "${message}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

info() {
    printf "  ${COLOR_CYAN}ℹ [INFO]${COLOR_RESET} %s\n" "$1"
    log_msg "INFO" "$1"
}

success() {
    printf "  ${COLOR_GREEN}✔ [SUCCESS]${COLOR_RESET} %s\n" "$1"
    log_msg "SUCCESS" "$1"
}

warn() {
    printf "  ${COLOR_YELLOW}▲ [WARNING]${COLOR_RESET} %s\n" "$1"
    log_msg "WARNING" "$1"
}

error() {
    printf "  ${COLOR_RED}✖ [ERROR]${COLOR_RESET} %s\n" "$1" >&2
    log_msg "ERROR" "$1"
}

dry_run_notice() {
    if [[ "${DRY_RUN}" == true ]]; then
        printf "${COLOR_CYAN}[DRY-RUN]${COLOR_RESET} (Simulation mode active - no filesystem or system changes made)\n"
    fi
}

# ------------------------------------------------------------------------------
# Sudo & Privilege Management
# ------------------------------------------------------------------------------

# Execute command directly if root, or via sudo if non-root
run_elevated() {
    local desc="$1"
    shift
    if [[ "${DRY_RUN}" == true ]]; then
        printf "${COLOR_CYAN}[DRY-RUN EXEC]${COLOR_RESET} %s -> %s\n" "${desc}" "$*"
        log_msg "DRY_RUN" "Simulated command: $*"
        return 0
    fi

    log_msg "EXEC" "Executing: $*"
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        if command -v sudo >/dev/null 2>&1; then
            sudo "$@"
        else
            error "Root privileges or sudo are required to execute: ${desc}"
            return 1
        fi
    fi
}

# ------------------------------------------------------------------------------
# User Prompt Helpers
# ------------------------------------------------------------------------------

prompt_confirm() {
    local prompt_text="$1"
    local default_choice="${2:-N}"
    local response

    if [[ "${default_choice}" =~ ^[Yy]$ ]]; then
        printf "%s [Y/n]: " "${prompt_text}"
    else
        printf "%s [y/N]: " "${prompt_text}"
    fi

    read -r response
    response="${response:-${default_choice}}"
    case "${response}" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

press_enter_to_continue() {
    printf "\n${COLOR_DIM}Press Enter to return to menu...${COLOR_RESET}"
    read -r _
}

# ------------------------------------------------------------------------------
# Validation Helpers
# ------------------------------------------------------------------------------

# Validate IPv4 address or IPv4 CIDR subnet (e.g., 192.168.1.50 or 192.168.1.0/24)
validate_client_spec() {
    local input="$1"
    # Basic check against wildcards or public internet exposure
    if [[ "${input}" == "*" ]] || [[ "${input}" == "0.0.0.0/0" ]]; then
        return 2 # Forbidden wildcard
    fi

    # Regex for IPv4 single host or CIDR
    local ip_pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$'
    if [[ "${input}" =~ ${ip_pattern} ]]; then
        # Validate numeric byte ranges for IP
        local ip_part="${input%%/*}"
        local IFS='.'
        local -i o1=0 o2=0 o3=0 o4=0
        read -r o1 o2 o3 o4 <<< "${ip_part}"
        if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then
            return 1
        fi
        return 0
    fi

    # Check if valid hostname or domain
    local host_pattern='^([a-zA-Z0-9][-a-zA-Z0-9]*\.)*[a-zA-Z0-9][-a-zA-Z0-9]*$'
    if [[ "${input}" =~ ${host_pattern} ]]; then
        return 0 # Valid hostname
    fi

    return 1 # Invalid format
}

# Check if client spec is private lab network
is_private_subnet() {
    local input="$1"
    local ip_pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$'
    if [[ ! "${input}" =~ ${ip_pattern} ]]; then
        # Hostnames in lab environments are assumed internal
        return 0
    fi

    local ip_part="${input%%/*}"
    local IFS='.'
    local -i o1=0 o2=0 o3=0 o4=0
    read -r o1 o2 o3 o4 <<< "${ip_part}"

    # RFC 1918 Private Address ranges:
    # 10.0.0.0 - 10.255.255.255
    # 172.16.0.0 - 172.31.255.255
    # 192.168.0.0 - 192.168.255.255
    # Loopback: 127.0.0.0/8
    if (( o1 == 10 )); then
        return 0
    elif (( o1 == 172 && o2 >= 16 && o2 <= 31 )); then
        return 0
    elif (( o1 == 192 && o2 == 168 )); then
        return 0
    elif (( o1 == 127 )); then
        return 0
    fi
    return 1
}

# Validate export directory path safety
validate_export_path() {
    local target_dir="$1"

    # Reject empty or relative paths
    if [[ -z "${target_dir}" ]] || [[ "${target_dir}" != /* ]]; then
        error "Export path must be an absolute path starting with '/'."
        return 1
    fi

    # Disallow root filesystem export
    if [[ "${target_dir}" == "/" ]]; then
        error "Refusing to export the root directory ('/'). Exporting root exposes the entire OS filesystem!"
        return 1
    fi

    # Disallow critical system virtual directories
    case "${target_dir}" in
        /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/boot|/boot/*)
            error "Refusing to export critical system directory '${target_dir}'."
            return 1
            ;;
        /etc|/etc/*)
            error "Refusing to export configuration directory '${target_dir}'."
            return 1
            ;;
    esac

    # Disallow user home base directories directly
    if [[ "${target_dir}" == "/home" ]] || [[ "${target_dir}" == "/root" ]]; then
        error "Refusing to export base directory '${target_dir}' directly. Choose a specific subfolder."
        return 1
    fi

    # Warn if exporting a user's entire home directory (/home/username)
    if [[ "${target_dir}" =~ ^/home/[^/]+/?$ ]]; then
        warn "You specified an entire user home directory ('${target_dir}')."
        warn "This exposes personal dotfiles, .ssh keys, shell histories, and user configs."
        if ! prompt_confirm "Are you sure you want to export the entire home folder rather than a subfolder?" "N"; then
            return 1
        fi
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Automatic Subnet Calculation from Device IP
# ------------------------------------------------------------------------------

# Calculate network address from IP and CIDR prefix length (e.g. 192.168.1.10/24 -> 192.168.1.0/24)
calc_subnet_from_ip_cidr() {
    local ip_cidr="$1"
    local ip="${ip_cidr%%/*}"
    local prefix="${ip_cidr##*/}"

    if [[ -z "${prefix}" || "${prefix}" == "${ip}" ]]; then
        prefix="24"
    fi

    # Validate IP format
    local IFS='.'
    local o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "${ip}"
    if [[ -z "${o1:-}" || -z "${o2:-}" || -z "${o3:-}" || -z "${o4:-}" ]]; then
        echo ""
        return 1
    fi

    local -i ip_int=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
    local -i mask
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    local -i net_int=$(( ip_int & mask ))
    local n1=$(( (net_int >> 24) & 255 ))
    local n2=$(( (net_int >> 16) & 255 ))
    local n3=$(( (net_int >> 8) & 255 ))
    local n4=$(( net_int & 255 ))

    echo "${n1}.${n2}.${n3}.${n4}/${prefix}"
}

# Auto-detect all active IPv4 interfaces and their calculated subnets
# Outputs lines with: <interface> <ip_with_cidr> <calculated_subnet>
get_detected_interface_subnets() {
    if command -v ip >/dev/null 2>&1; then
        while read -r iface ip_cidr; do
            if [[ -n "${ip_cidr}" && "${iface}" != "lo" && "${ip_cidr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+ ]]; then
                local subnet
                subnet="$(calc_subnet_from_ip_cidr "${ip_cidr}")"
                if [[ -n "${subnet}" ]]; then
                    printf "%s %s %s\n" "${iface}" "${ip_cidr}" "${subnet}"
                fi
            fi
        done < <(ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {print $2, $4}')
    elif command -v ifconfig >/dev/null 2>&1; then
        while read -r ip_raw mask_raw; do
            if [[ -n "${ip_raw}" && "${ip_raw}" != "127.0.0.1" && "${ip_raw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                local prefix=24
                if [[ "${mask_raw}" =~ ^0x ]]; then
                    local hex_clean="${mask_raw#0x}"
                    local -i mask_int=0x${hex_clean}
                    local -i p=0
                    for ((i=31; i>=0; i--)); do
                        if (( (mask_int & (1 << i)) != 0 )); then
                            ((p++))
                        fi
                    done
                    prefix="${p}"
                fi
                local subnet
                subnet="$(calc_subnet_from_ip_cidr "${ip_raw}/${prefix}")"
                if [[ -n "${subnet}" ]]; then
                    printf "%s %s %s\n" "inet" "${ip_raw}/${prefix}" "${subnet}"
                fi
            fi
        done < <(ifconfig 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2, $4}')
    fi
}

# Return the primary detected subnet or fallback default
get_primary_device_subnet() {
    local first_subnet
    first_subnet="$(get_detected_interface_subnets | head -n 1 | awk '{print $3}')"
    if [[ -n "${first_subnet}" ]]; then
        echo "${first_subnet}"
    else
        echo "${DEFAULT_SUBNET}"
    fi
}

# Return the primary detected server IP address for client URI generation
get_server_ip() {
    local detected_ip=""
    if command -v ip >/dev/null 2>&1; then
        detected_ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4; exit}' | cut -d'/' -f1)"
        if [[ -z "${detected_ip}" ]]; then
            detected_ip="$(ip -o -4 addr show 2>/dev/null | awk '!/127.0.0.1/ {print $4; exit}' | cut -d'/' -f1)"
        fi
    elif command -v ifconfig >/dev/null 2>&1; then
        detected_ip="$(ifconfig 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2; exit}')"
    fi
    echo "${detected_ip:-192.168.1.10}"
}

# Display convenient copy-pasteable client connection links and commands for macOS, Windows, and Linux
print_client_quick_connect_links() {
    local s_ip="${1:-}"
    local share_path="${2:-}"

    if [[ -z "${s_ip}" ]]; then
        s_ip="$(get_server_ip)"
    fi
    if [[ -z "${share_path}" ]]; then
        share_path="${DEFAULT_SHARE_DIR}"
    fi

    local nfs_uri="nfs://${s_ip}${share_path}"
    local win_unc="\\\\${s_ip}${share_path//\//\\}"
    local linux_mount="sudo mount -t nfs -o sync,hard,intr ${s_ip}:${share_path} /mnt/labshare"
    local mac_mount="sudo mount -t nfs -o resvport ${s_ip}:${share_path} /Volumes/labshare"
    local win_mount="mount -o anon ${win_unc} Z:"

    printf "\n${COLOR_CYAN}${COLOR_BOLD}┌────────────────────────────────────────────────────────────────────────┐\n"
    printf "│               >>> CLIENT QUICK CONNECT & MOUNT LINKS <<<               │\n"
    printf "└────────────────────────────────────────────────────────────────────────┘${COLOR_RESET}\n"
    printf "Share is ready! Copy and paste the link or command for your client OS:\n\n"

    printf "  ${COLOR_BOLD}[1] Universal / macOS Finder URI (Cmd + K in Finder):${COLOR_RESET}\n"
    printf "      ${COLOR_CYAN}${COLOR_BOLD}%s${COLOR_RESET}\n\n" "${nfs_uri}"

    printf "  ${COLOR_BOLD}[2] Linux Client Mount Command (Terminal):${COLOR_RESET}\n"
    printf "      ${COLOR_GREEN}%s${COLOR_RESET}\n\n" "${linux_mount}"

    printf "  ${COLOR_BOLD}[3] macOS Terminal Mount Command:${COLOR_RESET}\n"
    printf "      ${COLOR_GREEN}%s${COLOR_RESET}\n\n" "${mac_mount}"

    printf "  ${COLOR_BOLD}[4] Windows Mount Command (Command Prompt / PowerShell):${COLOR_RESET}\n"
    printf "      ${COLOR_GREEN}%s${COLOR_RESET}\n" "${win_mount}"
    printf "      ${COLOR_DIM}Windows File Explorer Path:${COLOR_RESET} ${COLOR_CYAN}%s${COLOR_RESET}\n" "${win_unc}"

    printf "${COLOR_CYAN}──────────────────────────────────────────────────────────────────────────${COLOR_RESET}\n"
}

# ------------------------------------------------------------------------------
# Feature 1: System & Environment Detection
# ------------------------------------------------------------------------------

detect_environment() {
    local diagnostics_pause="${1:-true}"
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [1] System and Environment Diagnostics ───────────────────────────────${COLOR_RESET}\n\n"
    dry_run_notice

    # 1. Operating System Detection
    local os_name="Unknown"
    local os_version="Unknown"
    local is_ubuntu=false

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_name="${NAME:-Linux}"
        os_version="${VERSION:-Unknown}"
        if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" =~ ubuntu ]]; then
            is_ubuntu=true
        fi
    elif command -v lsb_release >/dev/null 2>&1; then
        os_name="$(lsb_release -s -i 2>/dev/null || echo "Unknown")"
        os_version="$(lsb_release -s -r 2>/dev/null || echo "Unknown")"
        if [[ "${os_name}" =~ [Uu]buntu ]]; then
            is_ubuntu=true
        fi
    fi

    if [[ "${is_ubuntu}" == true ]]; then
        printf "  OS Distribution : ${COLOR_GREEN}%s (%s)${COLOR_RESET}\n" "${os_name}" "${os_version}"
    else
        printf "  OS Distribution : ${COLOR_YELLOW}%s (%s) [Non-Ubuntu/Debian environment]${COLOR_RESET}\n" "${os_name}" "${os_version}"
    fi

    # 2. Kernel and Architecture
    printf "  Kernel Release  : %s (%s)\n" "$(uname -r)" "$(uname -m)"

    # 3. Privilege / Sudo Verification
    local current_uid
    current_uid="$(id -u)"
    if [[ "${current_uid}" -eq 0 ]]; then
        printf "  User Privileges : ${COLOR_GREEN}Root (UID 0)${COLOR_RESET}\n"
    elif sudo -n true 2>/dev/null; then
        printf "  User Privileges : ${COLOR_GREEN}Non-root ($USER, UID %s) with active sudo access${COLOR_RESET}\n" "${current_uid}"
    elif command -v sudo >/dev/null 2>&1; then
        printf "  User Privileges : ${COLOR_YELLOW}Non-root ($USER, UID %s) - sudo available (password may be requested)${COLOR_RESET}\n" "${current_uid}"
    else
        printf "  User Privileges : ${COLOR_RED}Non-root ($USER, UID %s) - NO sudo found! Administrative actions will fail.${COLOR_RESET}\n" "${current_uid}"
    fi

    # 4. Required Command Tools
    printf "\n  ${COLOR_BOLD}Required Command Inspection:${COLOR_RESET}\n"
    local tools=("exportfs" "systemctl" "ip" "awk" "grep" "sed" "ss")
    for tool in "${tools[@]}"; do
        if command -v "${tool}" >/dev/null 2>&1; then
            printf "    - %-12s : ${COLOR_GREEN}Found${COLOR_RESET} (%s)\n" "${tool}" "$(command -v "${tool}")"
        else
            printf "    - %-12s : ${COLOR_YELLOW}Not Installed / Not in PATH${COLOR_RESET}\n" "${tool}"
        fi
    done

    # 5. NFS Kernel Server Package Status
    printf "\n  ${COLOR_BOLD}NFS Package Inspection:${COLOR_RESET}\n"
    local nfs_installed=false
    if command -v dpkg-query >/dev/null 2>&1; then
        if dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -q "ok installed"; then
            nfs_installed=true
        fi
    elif command -v exportfs >/dev/null 2>&1; then
        nfs_installed=true
    fi

    if [[ "${nfs_installed}" == true ]]; then
        printf "    - nfs-kernel-server : ${COLOR_GREEN}Installed${COLOR_RESET}\n"
    else
        printf "    - nfs-kernel-server : ${COLOR_RED}Not installed${COLOR_RESET}\n"
    fi

    # 6. Network Interfaces and Detected IP Addresses & Calculated Subnets
    printf "\n  ${COLOR_BOLD}Detected Network Interfaces & Calculated Lab Subnets:${COLOR_RESET}\n"
    local found_subnets=false
    while read -r iface ip_cidr calc_sub; do
        if [[ -n "${calc_sub}" ]]; then
            printf "    - %-10s : IP: ${COLOR_CYAN}%-18s${COLOR_RESET} -> Auto-Calculated Subnet: ${COLOR_GREEN}%s${COLOR_RESET}\n" "${iface}" "${ip_cidr}" "${calc_sub}"
            found_subnets=true
        fi
    done < <(get_detected_interface_subnets)

    if [[ "${found_subnets}" != true ]]; then
        printf "    ${COLOR_YELLOW}(No active non-loopback IPv4 interfaces detected)${COLOR_RESET}\n"
    fi

    # 7. Exports File Status
    printf "\n  ${COLOR_BOLD}NFS Exports File (/etc/exports):${COLOR_RESET}\n"
    if [[ -f "${EXPORTS_FILE}" ]]; then
        printf "    - File Status       : ${COLOR_GREEN}Present${COLOR_RESET} (%s bytes)\n" "$(wc -c < "${EXPORTS_FILE}" 2>/dev/null || echo "0")"
        if grep -qF "${MANAGED_BEGIN_MARKER}" "${EXPORTS_FILE}" 2>/dev/null; then
            printf "    - Toolkit Managed   : ${COLOR_GREEN}Existing managed export block found${COLOR_RESET}\n"
        else
            printf "    - Toolkit Managed   : None currently configured\n"
        fi
    else
        printf "    - File Status       : ${COLOR_YELLOW}Not found at ${EXPORTS_FILE}${COLOR_RESET}\n"
    fi

    if [[ "${diagnostics_pause}" != "no_pause" ]]; then
        press_enter_to_continue
    fi
}
# ------------------------------------------------------------------------------

install_nfs_server() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [2] Install NFS Kernel Server Package ────────────────────────────────${COLOR_RESET}\n\n"
    dry_run_notice

    # Check if already installed
    if command -v exportfs >/dev/null 2>&1 && dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -q "ok installed"; then
        success "The 'nfs-kernel-server' package is already installed on this machine."
        press_enter_to_continue
        return 0
    fi

    printf "${COLOR_BOLD}Planned Package Changes:${COLOR_RESET}\n"
    printf "  Package to install : ${COLOR_CYAN}nfs-kernel-server${COLOR_RESET}\n"
    printf "  Dependencies       : ${COLOR_DIM}nfs-common, rpcbind, keyutils, libnfsidmap2${COLOR_RESET}\n"
    printf "  System Services    : ${COLOR_DIM}nfs-server.service, rpcbind.service${COLOR_RESET}\n"
    printf "  Configuration File : ${COLOR_DIM}/etc/exports, /etc/nfs.conf, /etc/default/nfs-kernel-server${COLOR_RESET}\n"
    printf "\n${COLOR_YELLOW}Explanation:${COLOR_RESET}\n"
    printf "  NFS (Network File System) requires in-kernel server support on Ubuntu.\n"
    printf "  Installing this package registers kernel RPC threads for file sharing,\n"
    printf "  creates required system users/groups, and installs management tools like 'exportfs'.\n\n"

    if ! prompt_confirm "Do you authorize updating apt caches and installing 'nfs-kernel-server'?" "N"; then
        info "Package installation aborted by user."
        press_enter_to_continue
        return 0
    fi

    info "Starting package installation..."
    if run_elevated "apt-get update" apt-get update -y && \
       run_elevated "apt-get install nfs-kernel-server" apt-get install -y nfs-kernel-server; then
        success "Successfully installed 'nfs-kernel-server'."
    else
        error "Package installation failed. Please check network connectivity and package manager locks."
    fi

    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 3: Configure and Apply Managed Export
# ------------------------------------------------------------------------------

backup_exports_file() {
    if [[ ! -f "${EXPORTS_FILE}" ]]; then
        info "Exports file '${EXPORTS_FILE}' does not yet exist; creating an empty file."
        if [[ "${DRY_RUN}" == true ]]; then
            printf "${COLOR_CYAN}[DRY-RUN]${COLOR_RESET} Would create empty file '%s'\n" "${EXPORTS_FILE}"
        else
            run_elevated "create empty exports file" touch "${EXPORTS_FILE}"
        fi
        return 0
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local backup_path="${EXPORTS_FILE}.bak.${timestamp}"

    info "Creating backup of '${EXPORTS_FILE}' at '${backup_path}'..."
    if run_elevated "backup exports file" cp -p "${EXPORTS_FILE}" "${backup_path}"; then
        success "Backup saved: ${backup_path}"
        log_msg "BACKUP" "Created backup ${backup_path}"
    else
        error "Failed to create backup of '${EXPORTS_FILE}'."
        return 1
    fi
}

configure_export() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [3] Configure & Apply Managed NFS Export ─────────────────────────────${COLOR_RESET}\n\n"
    dry_run_notice

    # 1. Directory to Export
    printf "${COLOR_BOLD}Step 1: Select Export Directory${COLOR_RESET}\n"
    printf "  Default path : ${COLOR_CYAN}%s${COLOR_RESET}\n" "${DEFAULT_SHARE_DIR}"
    printf "  Tip: Press ${COLOR_GREEN}[Enter]${COLOR_RESET} for default, or type any custom directory path\n"
    printf "  (e.g. ${COLOR_CYAN}/home/munsi/Documents${COLOR_RESET}, ${COLOR_CYAN}~/my_share${COLOR_RESET}, ${COLOR_CYAN}/data/lab${COLOR_RESET}):\n\n"

    local export_dir=""
    while true; do
        printf "Enter directory to export [%s]: " "${DEFAULT_SHARE_DIR}"
        read -r export_dir
        export_dir="${export_dir:-${DEFAULT_SHARE_DIR}}"

        # Handle numeric shortcuts 1 and 2 if typed
        if [[ "${export_dir}" == "1" ]]; then
            export_dir="${DEFAULT_SHARE_DIR}"
        elif [[ "${export_dir}" == "2" ]]; then
            printf "Enter custom directory path to export: "
            read -r export_dir
        fi

        # Expand tilde ~ to $HOME
        export_dir="${export_dir/#\~/$HOME}"

        if validate_export_path "${export_dir}"; then
            break
        fi
    done

    # Check if target directory exists on disk
    if [[ ! -d "${export_dir}" ]]; then
        warn "Directory '${export_dir}' does not currently exist."
        if prompt_confirm "Would you like this toolkit to create '${export_dir}'?" "Y"; then
            if run_elevated "mkdir -p ${export_dir}" mkdir -p "${export_dir}"; then
                success "Created directory '${export_dir}'."
            else
                error "Failed to create directory '${export_dir}'."
                press_enter_to_continue
                return 1
            fi
        else
            warn "Continuing with uncreated path. Note that export validation may fail if path does not exist."
        fi
    fi

    # Offer to configure permissions if directory exists
    if [[ -d "${export_dir}" ]]; then
        if prompt_confirm "Configure permissions (nobody:nogroup, chmod 775) on '${export_dir}' for client access?" "Y"; then
            run_elevated "chown nobody:nogroup on ${export_dir}" chown -R nobody:nogroup "${export_dir}" 2>/dev/null || true
            run_elevated "chmod 775 on ${export_dir}" chmod -R 775 "${export_dir}" 2>/dev/null || true
            success "Configured ownership and permissions on '${export_dir}'."
        fi
    fi

    # 2. Client Specification / Subnet (Auto-Detected from Device IP)
    printf "\n${COLOR_BOLD}Step 2: Authorized Client or Lab Subnet${COLOR_RESET}\n"
    local auto_subnet
    auto_subnet="$(get_primary_device_subnet)"

    printf "  Auto-detected local subnet from device IP : ${COLOR_GREEN}%s${COLOR_RESET}\n" "${auto_subnet}"

    # List any other active network interfaces if present
    local -a detected_list=()
    while read -r iface ip_cidr calc_sub; do
        if [[ -n "${calc_sub}" ]]; then
            detected_list+=("${iface}|${ip_cidr}|${calc_sub}")
        fi
    done < <(get_detected_interface_subnets)

    if [[ ${#detected_list[@]} -gt 1 ]]; then
        printf "  Detected interfaces on this server:\n"
        local idx=1
        for item in "${detected_list[@]}"; do
            local d_iface="${item%%|*}"
            local remainder="${item#*|}"
            local d_ip="${remainder%%|*}"
            local d_sub="${remainder#*|}"
            printf "    %d) Interface %-8s (IP: %-18s) -> Subnet: %s\n" "${idx}" "${d_iface}" "${d_ip}" "${d_sub}"
            ((idx++))
        done
        printf "  You can press Enter to accept the auto-detected default [%s] or specify another.\n" "${auto_subnet}"
    fi

    printf "${COLOR_YELLOW}Safety Rule: Exporting to wildcard '*' or '0.0.0.0/0' is rejected.${COLOR_RESET}\n\n"

    local client_spec=""
    while true; do
        printf "Enter client IP address or subnet CIDR [%s]: " "${auto_subnet}"
        read -r client_spec
        client_spec="${client_spec:-${auto_subnet}}"

        local val_status=0
        validate_client_spec "${client_spec}" || val_status=$?

        if [[ ${val_status} -eq 2 ]]; then
            error "Wildcard or unrestricted access ('*' or '0.0.0.0/0') is prohibited."
            continue
        elif [[ ${val_status} -eq 1 ]]; then
            error "Invalid IP/CIDR or hostname syntax. Example: 192.168.1.0/24 or 192.168.1.50"
            continue
        fi

        if ! is_private_subnet "${client_spec}"; then
            warn "The specified address '${client_spec}' is NOT in standard private RFC 1918 ranges!"
            warn "NFS should never be exposed to public networks without a secure VPN tunnel."
            if ! prompt_confirm "Are you ABSOLUTELY sure you want to target this non-private address?" "N"; then
                continue
            fi
        fi

        break
    done

    # 3. Access Permission (ro vs rw)
    printf "\n${COLOR_BOLD}Step 3: Access Permissions (Read-Only vs Read-Write)${COLOR_RESET}\n"
    printf "  1) Read-Only (ro)   [Recommended for distribution and safety]\n"
    printf "  2) Read-Write (rw)  [Allows remote clients to modify and delete files]\n"
    printf "Select permission [1]: "
    local perm_choice
    read -r perm_choice
    perm_choice="${perm_choice:-1}"

    local access_opt="ro"
    if [[ "${perm_choice}" == "2" || "${perm_choice}" =~ ^[rR][wW]$ ]]; then
        access_opt="rw"
        printf "\n${COLOR_YELLOW}============================= SECURITY WARNING =============================\n"
        printf "You selected READ-WRITE ('rw') permissions.\n"
        printf "Any client on '%s' with network connectivity will be able to write,\n" "${client_spec}"
        printf "overwrite, and delete files inside '%s'.\n" "${export_dir}"
        printf "============================================================================${COLOR_RESET}\n\n"
        if ! prompt_confirm "Acknowledge warning and continue with READ-WRITE access?" "N"; then
            info "Defaulting back to Read-Only ('ro') for safety."
            access_opt="ro"
        fi
    fi

    # 4. Write Synchronization (sync vs async)
    printf "\n${COLOR_BOLD}Step 4: Write Synchronization (Data Integrity)${COLOR_RESET}\n"
    printf "  1) Synchronous (sync)   [Recommended: Server replies only after data is committed to disk]\n"
    printf "  2) Asynchronous (async) [Risky: Higher throughput, but potential data corruption on crash]\n"
    printf "Select synchronization [1]: "
    local sync_choice
    read -r sync_choice
    sync_choice="${sync_choice:-1}"

    local sync_opt="sync"
    if [[ "${sync_choice}" == "2" || "${sync_choice}" =~ ^[aA][sS][yY][nN][cC]$ ]]; then
        sync_opt="async"
        warn "Asynchronous mode selected. If the server crashes or reboots unexpectedly, unwritten client data will be lost!"
    fi

    # 5. Root Squashing Options
    printf "\n${COLOR_BOLD}Step 5: Root Squash & UID Mapping${COLOR_RESET}\n"
    printf "  1) root_squash    [Default & Secure: Maps remote UID 0 (root) to nobody/nogroup]\n"
    printf "  2) no_root_squash [DANGEROUS: Remote root retains UID 0 root privilege on exported files]\n"
    printf "  3) all_squash     [Maps all connecting remote UIDs to anonymous user]\n"
    printf "Select root option [1]: "
    local squash_choice
    read -r squash_choice
    squash_choice="${squash_choice:-1}"

    local squash_opt="root_squash"
    if [[ "${squash_choice}" == "2" ]]; then
        printf "\n${COLOR_RED}!!!!!!!!!!!!!!!!!!!!!!!! CRITICAL PRIVILEGE WARNING !!!!!!!!!!!!!!!!!!!!!!!!\n"
        printf "'no_root_squash' is EXTREMELY dangerous. Any user with root access on the\n"
        printf "client machine will have complete root write privileges over files in the share.\n"
        printf "This can lead to root privilege escalation, SUID tampering, and file compromise.\n"
        printf "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${COLOR_RESET}\n\n"
        if prompt_confirm "Do you explicitly confirm that this is an isolated, trusted lab and require 'no_root_squash'?" "N"; then
            squash_opt="no_root_squash"
        else
            info "Preserving secure default: 'root_squash'."
        fi
    elif [[ "${squash_choice}" == "3" ]]; then
        squash_opt="all_squash"
    fi

    # 6. Non-Linux Client Support (macOS / Windows high unprivileged ports)
    printf "\n${COLOR_BOLD}Step 6: Client OS Compatibility (macOS / Windows)${COLOR_RESET}\n"
    printf "  Linux NFS servers require client connections from ports < 1024 ('secure') by default.\n"
    printf "  macOS (Finder / CLI) and Windows clients usually connect from high ports (> 1024).\n"
    printf "  Specifying '${COLOR_CYAN}insecure${COLOR_RESET}' allows non-Linux clients to mount without port rejection.\n\n"
    local port_opt=""
    if prompt_confirm "Enable 'insecure' port option for macOS and Windows client compatibility?" "Y"; then
        port_opt="insecure"
        info "Enabled 'insecure' port option for cross-platform compatibility."
    fi

    # 7. Subtree Checking Option
    # no_subtree_check is NFS standard best practice to prevent cache invalidation issues
    local subtree_opt="no_subtree_check"

    # Assemble complete export line
    local export_options="${access_opt},${sync_opt},${subtree_opt},${squash_opt}"
    if [[ -n "${port_opt}" ]]; then
        export_options="${export_options},${port_opt}"
    fi
    local proposed_line="${export_dir} ${client_spec}(${export_options})"

    printf "\n${COLOR_BOLD}Proposed NFS Export Definition:${COLOR_RESET}\n"
    printf "  Path        : ${COLOR_CYAN}%s${COLOR_RESET}\n" "${export_dir}"
    printf "  Target      : ${COLOR_CYAN}%s${COLOR_RESET}\n" "${client_spec}"
    printf "  Parameters  : ${COLOR_CYAN}%s${COLOR_RESET}\n" "${export_options}"
    printf "  Export Line : ${COLOR_GREEN}%s${COLOR_RESET}\n\n" "${proposed_line}"

    if ! prompt_confirm "Do you want to validate and apply this export entry?" "Y"; then
        info "Export configuration cancelled by user."
        press_enter_to_continue
        return 0
    fi

    # Backup /etc/exports before any modifications
    if ! backup_exports_file; then
        error "Aborting export modification due to backup failure."
        press_enter_to_continue
        return 1
    fi

    # Prepare temporary file for validation
    local tmp_dir
    tmp_dir="$(mktemp -d 2>/dev/null || echo "/tmp/nfs-toolkit.$$")"
    mkdir -p "${tmp_dir}"
    local temp_exports="${tmp_dir}/exports.candidate"

    # Read existing /etc/exports, stripping any existing managed block to prevent duplicates
    if [[ -f "${EXPORTS_FILE}" ]]; then
        awk -v bmark="${MANAGED_BEGIN_MARKER}" -v emark="${MANAGED_END_MARKER}" '
            $0 == bmark { in_block=1; next }
            $0 == emark { in_block=0; next }
            !in_block { print $0 }
        ' "${EXPORTS_FILE}" > "${temp_exports}"
    else
        touch "${temp_exports}"
    fi

    # Append new managed block
    {
        printf "\n%s\n" "${MANAGED_BEGIN_MARKER}"
        printf "# Managed by NFS Server Setup and Management Toolkit (OS Lab Project)\n"
        printf "# Created: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "%s\n" "${proposed_line}"
        printf "%s\n" "${MANAGED_END_MARKER}"
    } >> "${temp_exports}"

    # Validation Phase
    info "Validating proposed export syntax..."
    local validation_passed=true

    # 1. Structural syntax regex check
    if [[ ! "${proposed_line}" =~ ^/[^[:space:]]+[[:space:]]+[^[:space:]]+\([a-zA-Z0-9_,=]+\)$ ]]; then
        error "Export line does not match standard NFS exports syntax!"
        validation_passed=false
    fi

    # 2. Check that target directory exists on disk
    if [[ ! -d "${export_dir}" ]]; then
        warn "Target export directory '${export_dir}' does not exist on disk."
    fi

    if [[ "${validation_passed}" != true ]]; then
        error "Export validation failed! The configuration will NOT be applied to ${EXPORTS_FILE}."
        rm -rf "${tmp_dir}"
        press_enter_to_continue
        return 1
    fi
    success "Pre-flight structural validation passed."

    # Apply configuration to live /etc/exports
    if [[ "${DRY_RUN}" == true ]]; then
        printf "\n${COLOR_CYAN}[DRY-RUN] The following content would be written to %s:${COLOR_RESET}\n" "${EXPORTS_FILE}"
        cat "${temp_exports}"
        rm -rf "${tmp_dir}"
        success "Dry-run simulation completed. No live changes were written."
        print_client_quick_connect_links "$(get_server_ip)" "${export_dir}"
        press_enter_to_continue
        return 0
    fi

    info "Writing updated configuration to '${EXPORTS_FILE}'..."
    if ! run_elevated "write to ${EXPORTS_FILE}" cp "${temp_exports}" "${EXPORTS_FILE}"; then
        error "Failed to write candidate configuration to ${EXPORTS_FILE}."
        rm -rf "${tmp_dir}"
        press_enter_to_continue
        return 1
    fi
    run_elevated "set permissions on ${EXPORTS_FILE}" chmod 644 "${EXPORTS_FILE}"

    # Atomic live verification with exportfs -ra (with automatic rollback on failure)
    if command -v exportfs >/dev/null 2>&1; then
        info "Synchronizing and activating live export with 'exportfs -ra'..."
        local reload_log="${tmp_dir}/exportfs_reload.log"
        if ! run_elevated "exportfs reload and verify" exportfs -ra >"${reload_log}" 2>&1; then
            error "NFS kernel server rejected the new export configuration!"
            if [[ -s "${reload_log}" ]]; then
                cat "${reload_log}"
            fi
            warn "Rolling back ${EXPORTS_FILE} to safety backup..."
            run_elevated "rollback exports" cp "${backup_path}" "${EXPORTS_FILE}"
            run_elevated "restore exports" exportfs -ra 2>/dev/null || true
            error "Rollback complete. System returned to previous stable state."
            rm -rf "${tmp_dir}"
            press_enter_to_continue
            return 1
        fi
        success "Export successfully synchronized with Linux kernel."
    else
        success "Updated ${EXPORTS_FILE} with managed export entry."
    fi
    rm -rf "${tmp_dir}"

    # Automatically print copy-pasteable client quick connect links for macOS, Windows, and Linux
    print_client_quick_connect_links "$(get_server_ip)" "${export_dir}"

    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 4: List Active Exports & Status
# ------------------------------------------------------------------------------

list_active_exports() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [4] List Active NFS Exports ──────────────────────────────────────────${COLOR_RESET}\n\n"
    dry_run_notice

    # 1. Check in /etc/exports
    printf "${COLOR_BOLD}1. Managed Block in %s:${COLOR_RESET}\n" "${EXPORTS_FILE}"
    if [[ -f "${EXPORTS_FILE}" ]]; then
        if grep -qF "${MANAGED_BEGIN_MARKER}" "${EXPORTS_FILE}" 2>/dev/null; then
            awk -v bmark="${MANAGED_BEGIN_MARKER}" -v emark="${MANAGED_END_MARKER}" '
                $0 == bmark { in_block=1; next }
                $0 == emark { in_block=0; next }
                in_block { print "   " $0 }
            ' "${EXPORTS_FILE}"
        else
            printf "   ${COLOR_DIM}(No toolkit-managed block found in %s)${COLOR_RESET}\n" "${EXPORTS_FILE}"
        fi
    else
        printf "   ${COLOR_YELLOW}%s does not exist.${COLOR_RESET}\n" "${EXPORTS_FILE}"
    fi

    # 2. Check kernel active exports table (/var/lib/nfs/etab)
    printf "\n${COLOR_BOLD}2. Kernel Established Exports Table (/var/lib/nfs/etab):${COLOR_RESET}\n"
    if [[ -r /var/lib/nfs/etab ]]; then
        if [[ -s /var/lib/nfs/etab ]]; then
            sed 's/^/   /' /var/lib/nfs/etab
        else
            printf "   ${COLOR_DIM}(Kernel export table is empty - no exports currently active)${COLOR_RESET}\n"
        fi
    else
        printf "   ${COLOR_DIM}(/var/lib/nfs/etab not readable or not present)${COLOR_RESET}\n"
    fi

    # 3. exportfs -v output
    printf "\n${COLOR_BOLD}3. Verbose Export Status (exportfs -v):${COLOR_RESET}\n"
    if command -v exportfs >/dev/null 2>&1; then
        local active_output
        active_output="$(exportfs -v 2>&1 || true)"
        if [[ -n "${active_output}" ]]; then
            echo "${active_output}" | sed 's/^/   /'
        else
            printf "   ${COLOR_DIM}(No active exports reported by exportfs)${COLOR_RESET}\n"
        fi
    else
        printf "   ${COLOR_YELLOW}'exportfs' command not available.${COLOR_RESET}\n"
    fi

    # Display Quick Connect URI if a managed export exists
    if [[ -f "${EXPORTS_FILE}" ]] && grep -qF "${MANAGED_BEGIN_MARKER}" "${EXPORTS_FILE}" 2>/dev/null; then
        local active_dir
        active_dir="$(awk -v bmark="${MANAGED_BEGIN_MARKER}" -v emark="${MANAGED_END_MARKER}" '
            $0 == bmark { in_block=1; next }
            $0 == emark { in_block=0; next }
            in_block && /^ *\// { print $1; exit }
        ' "${EXPORTS_FILE}")"
        if [[ -n "${active_dir}" ]]; then
            print_client_quick_connect_links "$(get_server_ip)" "${active_dir}"
        fi
    fi

    press_enter_to_continue
}

# ------------------------------------------------------------------------------

check_service_status() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [5] NFS Service and Port Inspection ──────────────────────────────────${COLOR_RESET}\n\n"
    dry_run_notice

    # Systemd Service Inspection
    printf "${COLOR_BOLD}1. Systemd Service Unit Status:${COLOR_RESET}\n"
    local services=("nfs-server" "nfs-kernel-server" "rpcbind")
    for svc in "${services[@]}"; do
        if command -v systemctl >/dev/null 2>&1; then
            local active_state
            active_state="$(systemctl is-active "${svc}" 2>/dev/null || echo "inactive")"
            local enabled_state
            enabled_state="$(systemctl is-enabled "${svc}" 2>/dev/null || echo "unknown")"

            if [[ "${active_state}" == "active" ]]; then
                printf "  %-20s : Active (${COLOR_GREEN}%s${COLOR_RESET}), Enabled: %s\n" "${svc}" "${active_state}" "${enabled_state}"
            else
                printf "  %-20s : State (${COLOR_YELLOW}%s${COLOR_RESET}), Enabled: %s\n" "${svc}" "${active_state}" "${enabled_state}"
            fi
        else
            printf "  %-20s : ${COLOR_YELLOW}systemctl not available${COLOR_RESET}\n" "${svc}"
        fi
    done

    # Network Listening Ports
    printf "\n${COLOR_BOLD}2. Listening Ports (NFS Port 2049 & RPC Port 111):${COLOR_RESET}\n"
    if command -v ss >/dev/null 2>&1; then
        local ports_output
        ports_output="$(ss -tulpn 2>/dev/null | grep -E '(:2049|:111|nfs|rpcbind)' || true)"
        if [[ -n "${ports_output}" ]]; then
            echo "${ports_output}" | sed 's/^/  /'
        else
            printf "  ${COLOR_YELLOW}No listening sockets found on ports 2049 or 111.${COLOR_RESET}\n"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -E '(:2049|:111|nfs|rpcbind)' | sed 's/^/  /' || true
    else
        printf "  ${COLOR_YELLOW}Neither 'ss' nor 'netstat' is available to inspect open ports.${COLOR_RESET}\n"
    fi

    # Service control options
    printf "\n${COLOR_BOLD}Service Control Actions:${COLOR_RESET}\n"
    printf "  1) Restart nfs-kernel-server\n"
    printf "  2) Enable nfs-kernel-server at boot\n"
    printf "  3) Return to main menu\n"
    printf "Select action [3]: "
    local act_choice
    read -r act_choice

    case "${act_choice}" in
        1)
            if prompt_confirm "Are you sure you want to restart 'nfs-kernel-server'?" "Y"; then
                run_elevated "restart nfs-kernel-server" systemctl restart nfs-kernel-server
                success "Restart command executed."
            fi
            ;;
        2)
            if prompt_confirm "Enable nfs-kernel-server to start automatically on system boot?" "Y"; then
                run_elevated "enable nfs-kernel-server" systemctl enable nfs-kernel-server
                success "Service enabled at boot."
            fi
            ;;
        *)
            # Return
            ;;
    esac

    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 6: Reload Exports
# ------------------------------------------------------------------------------

reload_exports_action() {
    info "Re-synchronizing exports table with 'exportfs -ra'..."
    if command -v exportfs >/dev/null 2>&1; then
        if run_elevated "reload exports" exportfs -ra; then
            success "NFS exports successfully reloaded without service interruption."
        else
            error "Failed to reload exports. Please verify export syntax in ${EXPORTS_FILE}."
        fi
    else
        error "'exportfs' utility is not installed. Please install 'nfs-kernel-server'."
    fi
}

menu_reload_exports() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [6] Reload NFS Exports ───────────────────────────────────────────────${COLOR_RESET}\n\n"
    dry_run_notice
    printf "Running 'exportfs -ra' refreshes the kernel's export table (/var/lib/nfs/etab)\n"
    printf "with changes made to %s without restarting the server daemon.\n\n" "${EXPORTS_FILE}"

    if prompt_confirm "Execute export reload now?" "Y"; then
        reload_exports_action
    else
        info "Reload aborted."
    fi
    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 7: Remove Only Project-Managed Export Block
# ------------------------------------------------------------------------------

remove_managed_export() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [7] Remove Toolkit-Managed Export ────────────────────────────────────${COLOR_RESET}\n\n"
    dry_run_notice

    if [[ ! -f "${EXPORTS_FILE}" ]]; then
        warn "Exports file '${EXPORTS_FILE}' does not exist. Nothing to remove."
        press_enter_to_continue
        return 0
    fi

    if ! grep -qF "${MANAGED_BEGIN_MARKER}" "${EXPORTS_FILE}" 2>/dev/null; then
        warn "No project-managed export block found in '${EXPORTS_FILE}'."
        printf "Unrelated manual entries exist in %s and will NOT be touched.\n" "${EXPORTS_FILE}"
        press_enter_to_continue
        return 0
    fi

    printf "${COLOR_BOLD}The following managed export block will be removed:${COLOR_RESET}\n"
    awk -v bmark="${MANAGED_BEGIN_MARKER}" -v emark="${MANAGED_END_MARKER}" '
        $0 == bmark { in_block=1; print; next }
        $0 == emark { in_block=0; print; next }
        in_block { print }
    ' "${EXPORTS_FILE}" | sed 's/^/  /'
    printf "\n${COLOR_YELLOW}Safety Guarantee: All unrelated exports in %s will be preserved intact.${COLOR_RESET}\n\n" "${EXPORTS_FILE}"

    if ! prompt_confirm "Are you sure you want to remove the managed export block?" "N"; then
        info "Removal cancelled."
        press_enter_to_continue
        return 0
    fi

    # Create safety backup
    if ! backup_exports_file; then
        error "Removal halted because safety backup could not be created."
        press_enter_to_continue
        return 1
    fi

    # Filter out managed block
    local tmp_clean
    tmp_clean="$(mktemp 2>/dev/null || echo "/tmp/exports_clean.$$")"

    awk -v bmark="${MANAGED_BEGIN_MARKER}" -v emark="${MANAGED_END_MARKER}" '
        $0 == bmark { in_block=1; next }
        $0 == emark { in_block=0; next }
        !in_block { print $0 }
    ' "${EXPORTS_FILE}" > "${tmp_clean}"

    if [[ "${DRY_RUN}" == true ]]; then
        printf "\n${COLOR_CYAN}[DRY-RUN] The following content would remain in %s:${COLOR_RESET}\n" "${EXPORTS_FILE}"
        cat "${tmp_clean}"
        rm -f "${tmp_clean}"
        success "Dry-run simulation completed. No live changes written."
        press_enter_to_continue
        return 0
    fi

    if run_elevated "replace exports with clean file" cp "${tmp_clean}" "${EXPORTS_FILE}"; then
        run_elevated "set permissions on exports" chmod 644 "${EXPORTS_FILE}"
        rm -f "${tmp_clean}"
        success "Project-managed export block removed from ${EXPORTS_FILE}."
        if prompt_confirm "Reload active exports now to revoke the share from the kernel table?" "Y"; then
            reload_exports_action
        fi
    else
        error "Failed to write updated configuration to ${EXPORTS_FILE}."
        rm -f "${tmp_clean}"
    fi

    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 8: Remove Managed Export & Stop NFS Services Completely (Full Teardown)
# ------------------------------------------------------------------------------

remove_share_and_stop_services() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [8] Full Teardown: Remove Export & Stop Services ────────────────────${COLOR_RESET}\n\n"
    dry_run_notice

    printf "${COLOR_YELLOW}This operation will:${COLOR_RESET}\n"
    printf "  1. Create a timestamped backup of '%s'\n" "${EXPORTS_FILE}"
    printf "  2. Remove the toolkit-managed export block from '%s'\n" "${EXPORTS_FILE}"
    printf "  3. Unexport and revoke shared directories from the Linux kernel ('exportfs -au')\n"
    printf "  4. Stop the NFS server systemd services ('systemctl stop nfs-kernel-server')\n"
    printf "  5. Disable NFS services from auto-starting on system boot\n"
    printf "  6. Verify server listening ports (2049 / 111) are closed\n\n"
    printf "${COLOR_YELLOW}Safety Guarantee: Any unrelated manual entries in %s will remain intact.${COLOR_RESET}\n\n" "${EXPORTS_FILE}"

    if ! prompt_confirm "Are you sure you want to remove the share and STOP all NFS services?" "N"; then
        info "Teardown aborted by user."
        press_enter_to_continue
        return 0
    fi

    # Step A: Clean /etc/exports if managed block exists
    if [[ -f "${EXPORTS_FILE}" ]] && grep -qF "${MANAGED_BEGIN_MARKER}" "${EXPORTS_FILE}" 2>/dev/null; then
        info "Backing up and removing managed export from '${EXPORTS_FILE}'..."
        if ! backup_exports_file; then
            error "Safety backup failed. Halting teardown."
            press_enter_to_continue
            return 1
        fi

        local tmp_clean
        tmp_clean="$(mktemp 2>/dev/null || echo "/tmp/exports_clean.$$")"
        awk -v bmark="${MANAGED_BEGIN_MARKER}" -v emark="${MANAGED_END_MARKER}" '
            $0 == bmark { in_block=1; next }
            $0 == emark { in_block=0; next }
            !in_block { print $0 }
        ' "${EXPORTS_FILE}" > "${tmp_clean}"

        if [[ "${DRY_RUN}" == true ]]; then
            printf "${COLOR_CYAN}[DRY-RUN] Would remove managed block from %s${COLOR_RESET}\n" "${EXPORTS_FILE}"
            rm -f "${tmp_clean}"
        else
            if run_elevated "clean exports file" cp "${tmp_clean}" "${EXPORTS_FILE}"; then
                run_elevated "set permissions" chmod 644 "${EXPORTS_FILE}"
                rm -f "${tmp_clean}"
                success "Cleaned managed export from ${EXPORTS_FILE}."
            else
                error "Failed to update ${EXPORTS_FILE}."
                rm -f "${tmp_clean}"
            fi
        fi
    else
        info "No toolkit-managed export block found in '${EXPORTS_FILE}'."
    fi

    # Step B: Unexport shares from kernel table
    info "Revoking and unexporting shares from kernel table ('exportfs -au')..."
    if command -v exportfs >/dev/null 2>&1; then
        run_elevated "unexport all shares" exportfs -au 2>/dev/null || true
        run_elevated "reload exports" exportfs -ra 2>/dev/null || true
        success "Kernel export tables flushed."
    fi

    # Step C: Stop and Disable systemd services
    info "Stopping NFS server systemd services..."
    if command -v systemctl >/dev/null 2>&1; then
        run_elevated "stop nfs-kernel-server" systemctl stop nfs-kernel-server 2>/dev/null || true
        run_elevated "stop nfs-server" systemctl stop nfs-server 2>/dev/null || true
        run_elevated "disable nfs-kernel-server" systemctl disable nfs-kernel-server 2>/dev/null || true
        run_elevated "disable nfs-server" systemctl disable nfs-server 2>/dev/null || true
        success "NFS server services stopped and disabled."

        if prompt_confirm "Also stop rpcbind portmapper service (if not needed by other RPC tools)?" "N"; then
            run_elevated "stop rpcbind" systemctl stop rpcbind 2>/dev/null || true
            success "rpcbind service stopped."
        fi
    fi

    # Step D: Port Verification
    printf "\n${COLOR_BOLD}Verifying Ports Status (2049, 111):${COLOR_RESET}\n"
    if command -v ss >/dev/null 2>&1; then
        local remaining_ports
        remaining_ports="$(ss -tulpn 2>/dev/null | grep -E '(:2049|:111)' || true)"
        if [[ -z "${remaining_ports}" ]]; then
            success "All NFS server listening ports (2049 / 111) are verified closed. Services completely stopped."
        else
            warn "The following sockets are still active:"
            echo "${remaining_ports}" | sed 's/^/  /'
        fi
    else
        success "Teardown command sequence complete."
    fi

    log_msg "TEARDOWN" "Completed full removal of managed export and stopped NFS services"
    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 9: Client-Side Mount & Unmount Instructions
# ------------------------------------------------------------------------------

show_client_instructions() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [9] Client-Side Mount & Unmount Instructions ─────────────────────────${COLOR_RESET}\n\n"

    # Identify primary server IPv4 for illustration
    local server_ip="<SERVER_IP>"
    if command -v ip >/dev/null 2>&1; then
        local detected_ip
        detected_ip="$(ip -o -4 addr show 2>/dev/null | awk '!/127.0.0.1/ {print $4; exit}' | cut -d'/' -f1)"
        if [[ -n "${detected_ip}" ]]; then
            server_ip="${detected_ip}"
        fi
    fi

    local target_share="${DEFAULT_SHARE_DIR}"
    if [[ -f "${EXPORTS_FILE}" ]] && grep -qF "${MANAGED_BEGIN_MARKER}" "${EXPORTS_FILE}"; then
        local extracted_dir
        extracted_dir="$(awk -v bmark="${MANAGED_BEGIN_MARKER}" -v emark="${MANAGED_END_MARKER}" '
            $0 == bmark { in_block=1; next }
            $0 == emark { in_block=0; next }
            in_block && /^ *\// { print $1; exit }
        ' "${EXPORTS_FILE}")"
        if [[ -n "${extracted_dir}" ]]; then
            target_share="${extracted_dir}"
        fi
    fi

    cat <<EOF
${COLOR_BOLD}========================================================================${COLOR_RESET}
${COLOR_CYAN}${COLOR_BOLD}                     CLIENT-SIDE MOUNT INSTRUCTIONS${COLOR_RESET}
${COLOR_BOLD}========================================================================${COLOR_RESET}
Server Export Target: ${COLOR_GREEN}${server_ip}:${target_share}${COLOR_RESET}

${COLOR_BOLD}A. LINUX CLIENT (Ubuntu / Debian / RHEL):${COLOR_RESET}
   1. Install NFS Client Utilities:
      $ ${COLOR_GREEN}sudo apt update && sudo apt install -y nfs-common${COLOR_RESET}   # Ubuntu/Debian
      $ ${COLOR_GREEN}sudo dnf install -y nfs-utils${COLOR_RESET}                   # RHEL/Fedora/Rocky

   2. Query Available Exports:
      $ ${COLOR_GREEN}showmount -e ${server_ip}${COLOR_RESET}

   3. Mount Share:
      $ ${COLOR_GREEN}sudo mkdir -p /mnt/labshare${COLOR_RESET}
      $ ${COLOR_GREEN}sudo mount -t nfs -o rw,sync,hard,intr ${server_ip}:${target_share} /mnt/labshare${COLOR_RESET}

   4. Unmount:
      $ ${COLOR_GREEN}sudo umount /mnt/labshare${COLOR_RESET}  (or: sudo umount -l /mnt/labshare)

   5. Permanent Boot Mount (/etc/fstab):
      ${COLOR_CYAN}${server_ip}:${target_share}   /mnt/labshare   nfs   defaults,_netdev,auto,nofail   0   0${COLOR_RESET}

------------------------------------------------------------------------
${COLOR_BOLD}B. macOS CLIENT (macOS Monterey / Ventura / Sonoma / Sequoia):${COLOR_RESET}
   macOS has built-in NFS support. No package installation is needed.

   1. Mount via Terminal (CLI):
      $ ${COLOR_GREEN}sudo mkdir -p /Volumes/labshare${COLOR_RESET}
      $ ${COLOR_GREEN}sudo mount -t nfs -o resvport,rw ${server_ip}:${target_share} /Volumes/labshare${COLOR_RESET}
      * Important: If the server export includes 'insecure', the '-o resvport' flag is optional.
        If the server export does NOT have 'insecure', '-o resvport' is MANDATORY on macOS!

   2. Mount via GUI (Finder):
      - Open Finder -> Press ${COLOR_CYAN}Cmd + K${COLOR_RESET} (Connect to Server)
      - Server Address: ${COLOR_CYAN}nfs://${server_ip}${target_share}${COLOR_RESET}
      - Click "Connect". (Note: Requires 'insecure' on the Linux NFS server).

   3. Unmount on macOS:
      $ ${COLOR_GREEN}sudo umount /Volumes/labshare${COLOR_RESET}
      * Or eject the volume in Finder sidebar, or run:
      $ ${COLOR_GREEN}diskutil unmount /Volumes/labshare${COLOR_RESET}

------------------------------------------------------------------------
${COLOR_BOLD}C. WINDOWS CLIENT (Windows 10 / 11 Pro, Enterprise, Education):${COLOR_RESET}
   Windows has a native "Client for NFS" feature (available in Pro/Enterprise/Edu).
   * Note: Windows Home edition does NOT include native Client for NFS (use WSL2 instead).

   1. Enable "Client for NFS" in Windows:
      Run PowerShell as Administrator:
      PS> ${COLOR_GREEN}Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly, ClientForNFS-Infrastructure -NoRestart${COLOR_RESET}
      (Or via Control Panel -> "Turn Windows features on or off" -> Check "Services for NFS" -> "Client for NFS")

   2. Mount Share in Command Prompt or PowerShell:
      C:\> ${COLOR_GREEN}mount -o anon \\\\${server_ip}\\${target_share#/}\\* Z:${COLOR_RESET}
      * Note: Use backslashes for Windows path syntax, e.g.:
      C:\> ${COLOR_GREEN}mount -o anon \\\\${server_ip}${target_share//\//\\} Z:${COLOR_RESET}

   3. Check Mounted Drives in Windows:
      C:\> ${COLOR_GREEN}net use${COLOR_RESET}
      (Or view Drive 'Z:' in Windows File Explorer)

   4. Unmount in Windows:
      C:\> ${COLOR_GREEN}umount Z:${COLOR_RESET}

   5. Windows UID/GID Mapping (Registry):
      By default, Windows connects as Anonymous UID -2. To map Windows to UID 1000:
      Open regedit -> HKLM\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default
      Create DWORD values: AnonymousUid = 1000, AnonymousGid = 1000, then restart NFS service:
      C:\> ${COLOR_CYAN}nfsadmin client stop && nfsadmin client start${COLOR_RESET}

------------------------------------------------------------------------
${COLOR_BOLD}D. Server-Side Firewall Notice (UFW):${COLOR_RESET}
   ${COLOR_YELLOW}This toolkit does NOT alter your firewall rules automatically.${COLOR_RESET}
   If UFW is active on this server, permit NFS traffic from your lab subnet:
   $ ${COLOR_CYAN}sudo ufw status${COLOR_RESET}
   $ ${COLOR_CYAN}sudo ufw allow from ${DEFAULT_SUBNET} to any port nfs comment 'NFS Lab Access'${COLOR_RESET}
========================================================================
EOF

    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 10: Permissions, Ownership, UID/GID & Security Guidance
# ------------------------------------------------------------------------------

show_security_guidance() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [10] Ownership, Permissions, UID/GID & Security Guidance ─────────────${COLOR_RESET}\n\n"
    cat <<EOF
${COLOR_BOLD}1. The Fundamental Model of NFSv3/v4 Permissions:${COLOR_RESET}
   NFS traditionally relies on the client kernel to authenticate the user and passes
   the raw numeric User ID (UID) and Group ID (GID) over the network RPC calls.
   - The NFS server trusts the numeric UID supplied by the client.
   - If user 'alice' is UID 1001 on the client, and UID 1001 on the server is 'bob',
     any file written by 'alice' on the client will be owned by 'bob' on the server!
   - In production environments, identity synchronization (e.g., LDAP, FreeIPA, Active Directory)
     or NFSv4 domain mapping (via idmapd) is used to guarantee consistent UID/GID mapping.

${COLOR_BOLD}2. The Risk of 'no_root_squash' (Privilege Escalation Vector):${COLOR_RESET}
   - ${COLOR_GREEN}root_squash (Secure Default):${COLOR_RESET}
     When a root user (UID 0) on the client attempts to access or create files on the share,
     the server daemon intercepts the request and maps UID 0 to the unprivileged user
     'nobody' (UID 65534, nogroup). Root cannot read root-restricted server files or alter
     root-owned executables.
   - ${COLOR_RED}no_root_squash (High Vulnerability):${COLOR_RESET}
     When 'no_root_squash' is enabled, UID 0 on any authorized client acts as true UID 0 (root)
     on the server's filesystem. An attacker with root on a client can:
     a) Plant setuid-root binaries inside the share.
     b) Overwrite system-critical scripts or cron files if exported.
     c) Read arbitrary sensitive files within the share.
     ${COLOR_YELLOW}Rule: Never enable 'no_root_squash' outside an isolated educational sandbox!${COLOR_RESET}

${COLOR_BOLD}3. Synchronous vs Asynchronous Writes:${COLOR_RESET}
   - ${COLOR_GREEN}sync (Default & Recommended):${COLOR_RESET}
     The NFS server commits every write request to non-volatile storage (disk) before
     sending an RPC acknowledgement to the client. This guarantees POSIX data consistency.
   - ${COLOR_YELLOW}async:${COLOR_RESET}
     The server acknowledges requests as soon as they reach memory buffers.
     While write throughput increases, an unclean shutdown, power failure, or kernel panic
     will corrupt data and cause silent data loss.

${COLOR_BOLD}4. Setting Proper Directory Permissions on the Server:${COLOR_RESET}
   To allow client users (e.g. UID 1000) or 'nobody' to write into a shared lab folder:
   $ ${COLOR_GREEN}sudo chown -R nobody:nogroup /srv/nfs/labshare${COLOR_RESET}
   $ ${COLOR_GREEN}sudo chmod -R 775 /srv/nfs/labshare${COLOR_RESET}
   Or create a shared project group with a setgid bit to preserve group ownership:
   $ ${COLOR_GREEN}sudo chmod g+s /srv/nfs/labshare${COLOR_RESET}

${COLOR_BOLD}5. Verification Philosophy:${COLOR_RESET}
   ${COLOR_YELLOW}Important: Never assume NFS export works until successfully mounted and tested${COLOR_RESET}
   from a designated authorized lab client machine!
EOF

    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 11: Toggle Dry-Run Mode
# ------------------------------------------------------------------------------

toggle_dry_run() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [11] Toggle Dry-Run Mode ─────────────────────────────────────────────${COLOR_RESET}\n\n"
    if [[ "${DRY_RUN}" == true ]]; then
        DRY_RUN=false
        success "Dry-run mode is now DISABLED. Actions will affect the system."
        log_msg "CONFIG" "Dry-run mode disabled"
    else
        DRY_RUN=true
        success "Dry-run mode is now ENABLED. System files and packages will NOT be altered."
        log_msg "CONFIG" "Dry-run mode enabled"
    fi
    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Feature 12: View Activity & Audit Log
# ------------------------------------------------------------------------------

view_audit_log() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}─── [12] Activity and Audit Log ──────────────────────────────────────────${COLOR_RESET}\n\n"
    printf "Log File: %s\n\n" "${LOG_FILE}"

    if [[ -f "${LOG_FILE}" ]]; then
        printf "${COLOR_DIM}--- Last 25 entries ---${COLOR_RESET}\n"
        tail -n 25 "${LOG_FILE}"
        printf "${COLOR_DIM}-----------------------${COLOR_RESET}\n"
    else
        info "No log file found at '${LOG_FILE}' yet."
    fi

    press_enter_to_continue
}

# ------------------------------------------------------------------------------
# Main Interactive Menu Loop
# ------------------------------------------------------------------------------

display_menu() {
    local dry_badge="${COLOR_RED}DISABLED (Live Changes Active)${COLOR_RESET}"
    if [[ "${DRY_RUN}" == true ]]; then
        dry_badge="${COLOR_GREEN}ENABLED (Simulation Mode)${COLOR_RESET}"
    fi

    local s_ip
    s_ip="$(get_server_ip)"
    local s_sub
    s_sub="$(get_primary_device_subnet)"

    cat <<EOF

${COLOR_CYAN}${COLOR_BOLD}┌────────────────────────────────────────────────────────────────────────┐
│             NFS SERVER SETUP AND MANAGEMENT TOOLKIT v${TOOLKIT_VERSION}             │
│          Operating Systems Course Project - Lab Administration         │
└────────────────────────────────────────────────────────────────────────┘${COLOR_RESET}
 ${COLOR_BOLD}Mode:${COLOR_RESET} [Simulation: ${dry_badge}]
 ${COLOR_BOLD}Host:${COLOR_RESET} IP: ${COLOR_CYAN}${s_ip}${COLOR_RESET} │ Auto Subnet: ${COLOR_GREEN}${s_sub}${COLOR_RESET}

  ${COLOR_BOLD}─── Setup & Diagnostics ────────────────────────────────────────────────${COLOR_RESET}
   ${COLOR_CYAN}[ 1]${COLOR_RESET}  Run System & Environment Diagnostics
   ${COLOR_CYAN}[ 2]${COLOR_RESET}  Install NFS Kernel Server Package (with safety checks)
   ${COLOR_CYAN}[ 3]${COLOR_RESET}  Configure & Apply Managed Export Entry (Directory & Subnet)

  ${COLOR_BOLD}─── Management & Operations ────────────────────────────────────────────${COLOR_RESET}
   ${COLOR_CYAN}[ 4]${COLOR_RESET}  List Active NFS Exports (/etc/exports & /var/lib/nfs/etab)
   ${COLOR_CYAN}[ 5]${COLOR_RESET}  Inspect NFS Service & Network Ports (2049, 111)
   ${COLOR_CYAN}[ 6]${COLOR_RESET}  Reload Active Exports (exportfs -ra)
   ${COLOR_CYAN}[ 7]${COLOR_RESET}  Remove Toolkit-Managed Export Block (preserve unrelated)
   ${COLOR_CYAN}[ 8]${COLOR_RESET}  Remove Managed Export & Stop NFS Services Completely (Teardown)

  ${COLOR_BOLD}─── Reference, Security & Utilities ────────────────────────────────────${COLOR_RESET}
   ${COLOR_CYAN}[ 9]${COLOR_RESET}  View Client-Side Mount & Unmount Instructions (Mac/Win/Linux)
   ${COLOR_CYAN}[10]${COLOR_RESET}  View Ownership, Permissions, UID/GID & Security Guidance
   ${COLOR_CYAN}[11]${COLOR_RESET}  Toggle Dry-Run Simulation Mode
   ${COLOR_CYAN}[12]${COLOR_RESET}  View Activity & Audit Log
   ${COLOR_YELLOW}[ 0]${COLOR_RESET}  Exit Toolkit
${COLOR_CYAN}──────────────────────────────────────────────────────────────────────────${COLOR_RESET}
EOF
}

main_loop() {
    log_msg "SESSION" "Started NFS Toolkit session (Version ${TOOLKIT_VERSION})"
    while true; do
        display_menu
        printf "Select an option [0-12]: "
        local choice=""
        if ! read -r choice; then
            echo ""
            info "EOF encountered. Exiting session."
            break
        fi
        case "${choice}" in
            1) detect_environment ;;
            2) install_nfs_server ;;
            3) configure_export ;;
            4) list_active_exports ;;
            5) check_service_status ;;
            6) menu_reload_exports ;;
            7) remove_managed_export ;;
            8) remove_share_and_stop_services ;;
            9) show_client_instructions ;;
            10) show_security_guidance ;;
            11) toggle_dry_run ;;
            12) view_audit_log ;;
            0|q|Q|exit)
                info "Exiting NFS Toolkit. Goodbye!"
                log_msg "SESSION" "Closed NFS Toolkit session"
                break
                ;;
            *)
                error "Invalid selection '${choice}'. Please select a number between 0 and 12."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Command Line Argument Parsing
# ------------------------------------------------------------------------------

show_help() {
    cat <<EOF
NFS Server Setup and Management Toolkit v${TOOLKIT_VERSION}
Usage: $(basename "$0") [OPTIONS]

Options:
  -d, --dry-run          Run in simulation mode (no system modifications)
  -c, --check            Run non-interactive system & environment diagnostics and exit
  -l, --log <file>       Specify custom log file path (default: ./nfs-toolkit.log)
  -e, --exports <file>   Specify custom exports file path (default: /etc/exports)
  -h, --help             Display this help message and exit
  -v, --version          Display version information

Examples:
  ./$(basename "$0") --dry-run
  ./$(basename "$0") --check
EOF
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -c|--check)
            detect_environment "no_pause"
            exit 0
            ;;
        -l|--log)
            if [[ -n "${2:-}" ]]; then
                LOG_FILE="$2"
                shift 2
            else
                error "--log requires a file path argument."
                exit 1
            fi
            ;;
        -e|--exports)
            if [[ -n "${2:-}" ]]; then
                EXPORTS_FILE="$2"
                shift 2
            else
                error "--exports requires a file path argument."
                exit 1
            fi
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "NFS Toolkit Version ${TOOLKIT_VERSION}"
            exit 0
            ;;
        *)
            error "Unknown parameter: $1"
            show_help
            exit 1
            ;;
    esac
done

# Entry point
chmod +x "$0" 2>/dev/null || true
main_loop
