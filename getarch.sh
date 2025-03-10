#!/usr/bin/env bash
# Revision: 1
# Date: 2025-03-09
# Description: Initial version with trap fix for early exit issue

# Enable modern bash features
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
shopt -s inherit_errexit  # Inherit errexit in subshells (Bash 4.4+)

# Define constants
readonly download_page="https://archlinux.org/releng/releases/"
readonly home_dir="${HOME:-$(/usr/bin/env printf '~')}"
readonly downloads_dir="${XDG_DOWNLOAD_DIR:-${home_dir}/Downloads}"
readonly cache_dir="${XDG_CACHE_HOME:-${home_dir}/.cache}/archlinux"

# Colors for output (with cross-platform check)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    red=$(tput setaf 1)
    green=$(tput setaf 2)
    yellow=$(tput setaf 3)
    reset=$(tput sgr0)
else
    red='' green='' yellow='' reset=''
fi

# Debug logging function
log_debug() {
    [[ -n "${DEBUG:-}" ]] && printf "${yellow}[DEBUG] %s${reset}\n" "$@" >&2
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -t 0 ]]; then  # Only prompt if interactive terminal
        printf "\nPress Enter to continue..." >&2
        read -r
    fi
    [[ -d "${temp_dir:-}" ]] && rm -rf "$temp_dir"
    exit "$exit_code"
}

# Check for required commands
check_commands() {
    local cmd missing=()
    for cmd in curl aria2c sha256sum gpg mktemp dd; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf "${red}Error: Missing required commands: %s${reset}\n" "${missing[*]}" >&2
        exit 1
    fi
    log_debug "All required commands found"
}

# List USB drives (works on Arch and macOS)
list_usb_drives() {
    local drives=()
    if [[ "$(uname)" == "Darwin" ]]; then
        while IFS= read -r disk; do
            if diskutil info "$disk" | grep -q "Removable Media:.*Yes"; then
                drives+=("$disk")
            fi
        done < <(diskutil list | grep -oE 'disk[0-9]+' | sort -u)
    else
        while IFS= read -r line; do
            local dev_name=$(echo "$line" | awk '{print $1}')
            if [[ -e "/sys/block/$dev_name/removable" ]] && [[ "$(cat "/sys/block/$dev_name/removable")" == "1" ]]; then
                drives+=("/dev/$dev_name")
            fi
        done < <(lsblk -dno NAME | grep -v '^loop')
    fi
    printf '%s\n' "${drives[@]}"
}

# Get drive details
get_drive_info() {
    local drive=$1
    if [[ "$(uname)" == "Darwin" ]]; then
        diskutil info "$drive" | grep -E "Device Identifier|Device Node|Volume Name|Media Name|Total Size|Removable Media"
    else
        lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN "$drive" | tail -n +2
    fi
}

# Write ISO to drive
write_to_drive() {
    local iso_path=$1 drive=$2
    if [[ "$(uname)" == "Darwin" ]]; then
        diskutil unmountDisk "$drive" || {
            printf "${red}Error: Failed to unmount disk${reset}\n" >&2
            return 1
        }
        local raw_drive="/dev/r${drive}"
    else
        local raw_drive="$drive"
    fi
    
    printf "${yellow}Writing ISO to %s...${reset}\n" "$drive"
    sudo dd if="$iso_path" of="$raw_drive" bs=4M status=progress conv=fsync || {
        printf "${red}Error: Failed to write ISO${reset}\n" >&2
        return 1
    }
    sync
    printf "${green}Successfully wrote ISO to %s${reset}\n" "$drive"
}

# Main function
main() {
    log_debug "Starting main function"
    printf "Initializing...\n"  # Visible even without DEBUG
    
    check_commands
    log_debug "Commands checked"

    log_debug "Creating temporary directory"
    temp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'archdl')
    cd "$temp_dir" || {
        printf "${red}Error: Cannot change to temp directory${reset}\n" >&2
        exit 1
    }
    log_debug "Changed to temp directory: $temp_dir"

    local version torrent_url iso_name iso_path cached_iso
    log_debug "Fetching version from $download_page"
    local version_output
    if ! version_output=$(curl -s "$download_page"); then
        printf "${red}Error: Failed to fetch download page${reset}\n" >&2
        exit 1
    fi
    version=$(echo "$version_output" | grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}' | head -n 1)
    if [[ -z "$version" ]]; then
        printf "${red}Error: Could not determine latest version${reset}\n" >&2
        exit 1
    fi
    log_debug "Determined version: $version"
    
    torrent_url="https://archlinux.org/releng/releases/${version}/torrent/"
    iso_name="archlinux-${version}-x86_64.iso"
    iso_path="${downloads_dir}/${iso_name}"
    cached_iso="${cache_dir}/${iso_name}"

    log_debug "Checking for cached ISO at $cached_iso"
    if [[ -f "$cached_iso" ]]; then
        printf "${yellow}Found cached ISO at %s${reset}\n" "$cached_iso"
        cp "$cached_iso" "$iso_name" || {
            printf "${red}Error: Failed to copy cached ISO${reset}\n" >&2
            exit 1
        }
        log_debug "Copied cached ISO to $temp_dir/$iso_name"
    else
        log_debug "No cached ISO found, proceeding with download"
        local curl_opts=(-sL)
        [[ -t 1 ]] && curl_opts+=(--progress-bar)
        
        curl "${curl_opts[@]}" "$torrent_url" -o archlinux-latest.torrent
        curl "${curl_opts[@]}" "https://archlinux.org/iso/$version/$iso_name.sig" -o "$iso_name.sig"
        curl "${curl_opts[@]}" "https://archlinux.org/iso/$version/sha256sums.txt" -o sha256sums.txt

        aria2c --seed-time=0 --max-upload-limit=1K --dir="$temp_dir" \
               --console-log-level=warn archlinux-latest.torrent
        log_debug "Download completed"
    fi

    printf "Verifying ISO checksum...\n"
    if ! sha256sum -c --status <(grep "$iso_name" sha256sums.txt); then
        printf "${red}Error: ISO checksum verification failed!${reset}\n" >&2
        exit 1
    fi
    log_debug "Checksum verified"

    printf "Fetching release key...\n"
    if [[ -n "${DEBUG:-}" ]]; then
        gpg --auto-key-locate clear,wkd -v --locate-external-key pierre@archlinux.org || {
            printf "${red}Error: Failed to fetch release key${reset}\n" >&2
            exit 1
        }
    else
        gpg --auto-key-locate clear,wkd -v --locate-external-key pierre@archlinux.org >/dev/null 2>&1 || {
            printf "${red}Error: Failed to fetch release key${reset}\n" >&2
            exit 1
        }
    fi
    
    printf "Verifying ISO signature...\n"
    if [[ -n "${DEBUG:-}" ]]; then
        gpg --keyserver-options auto-key-retrieve --verify "$iso_name.sig" "$iso_name" || {
            printf "${red}Error: ISO signature verification failed!${reset}\n" >&2
            exit 1
        }
    else
        gpg --keyserver-options auto-key-retrieve --verify "$iso_name.sig" "$iso_name" >/dev/null 2>&1 || {
            printf "${red}Error: ISO signature verification failed!${reset}\n" >&2
            exit 1
        }
    fi
    log_debug "Signature verified"

    mkdir -p "$downloads_dir"
    mv "$iso_name" "$iso_path" || {
        printf "${red}Error: Failed to move ISO to Downloads${reset}\n" >&2
        exit 1
    }
    log_debug "ISO moved to $iso_path"

    mkdir -p "$cache_dir"
    cp "$iso_path" "$cached_iso" || {
        printf "${red}Error: Failed to cache ISO${reset}\n" >&2
        exit 1
    }
    log_debug "ISO cached at $cached_iso"

    printf "${green}Successfully downloaded and verified %s${reset}\n" "$iso_name"

    if [[ -t 0 ]]; then
        printf "\nWould you like to write the ISO to a flash drive? (y/N): "
        read -r response
        if [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]; then
            local drives
            mapfile -t drives < <(list_usb_drives)
            if [[ ${#drives[@]} -eq 0 ]]; then
                printf "${red}No USB drives detected${reset}\n"
                return
            fi

            printf "\nAvailable USB drives:\n"
            for i in "${!drives[@]}"; do
                printf "%d) %s\n" "$((i+1))" "${drives[$i]}"
            done

            printf "\nSelect a drive (1-%d, or 0 to skip): " "${#drives[@]}"
            read -r choice
            if [[ "$choice" -eq 0 || -z "$choice" ]]; then
                printf "Skipping flash drive writing\n"
                return
            fi
            if [[ "$choice" -lt 1 || "$choice" -gt ${#drives[@]} ]]; then
                printf "${red}Invalid selection${reset}\n"
                return
            fi

            local selected_drive="${drives[$((choice-1))]}"
            printf "\nDrive details:\n"
            get_drive_info "$selected_drive"
            printf "\n${yellow}WARNING: This will erase all data on %s${reset}\n" "$selected_drive"
            printf "Type YES to confirm: "
            read -r confirm
            if [[ "$confirm" != "YES" ]]; then
                printf "Operation cancelled\n"
                return
            fi

            write_to_drive "$iso_path" "$selected_drive"
            log_debug "ISO written to $selected_drive"
        fi
    fi
}

# Setup trap with explicit success check
if ! trap cleanup EXIT INT TERM; then
    printf "${red}Error: Failed to set trap${reset}\n" >&2
    exit 1
fi
log_debug "Trap set successfully"

# Execute main with explicit tracing
log_debug "Before calling main"
printf "Starting script...\n"  # Visible even without DEBUG
main "$@"
