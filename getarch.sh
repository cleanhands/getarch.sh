#!/usr/bin/env bash
# Revision: 22
# Date: 2025-03-11
# Description: Added disk size to Available USB drives menu

set -euo pipefail
shopt -s inherit_errexit

readonly download_page="https://archlinux.org/releng/releases/"
readonly home_dir="${HOME:-$(/usr/bin/env printf '~')}"
readonly downloads_dir="${XDG_DOWNLOAD_DIR:-${home_dir}/Downloads}"
readonly cache_dir="${XDG_CACHE_HOME:-${home_dir}/.cache}/archlinux"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    red=$(tput setaf 1)
    green=$(tput setaf 2)
    yellow=$(tput setaf 3)
    reset=$(tput sgr0)
else
    red=''
    green=''
    yellow=''
    reset=''
fi

log_debug() {
    { [[ "${DEBUG:-}" == "true" || "${DEBUG:-}" == "1" ]] && printf "${yellow}[DEBUG] %s${reset}\n" "$@" >&2; } || :
}

cleanup() {
    local exit_code=$?
    if [[ -t 0 && ("${DEBUG:-}" == "true" || "${DEBUG:-}" == "1") ]]; then
        printf "\nPress Enter to continue..." >&2
        read -r
    fi
    [[ -d "${temp_dir:-}" ]] && rm -rf "$temp_dir"
    exit "$exit_code"
}

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

list_usb_drives() {
    local drives=()
    if [[ "$(uname)" == "Darwin" ]]; then
        while IFS= read -r disk; do
            if [[ -n "$disk" ]]; then
                local disk_info size
                disk_info=$(diskutil info "$disk")
                if echo "$disk_info" | grep -q "Removable Media:.*Removable" || echo "$disk_info" | grep -q "Device Location:.*External"; then
                    size=$(echo "$disk_info" | grep -E "Disk Size:" | awk '{print $3 " " $4}' | sed 's/([^)]*)//')
                    drives+=("$disk ($size)")
                fi
            fi
        done < <(diskutil list | grep -oE 'disk[0-9]+' | sort -u)
    else
        while IFS= read -r line; do
            local dev_name size
            dev_name=$(echo "$line" | awk '{print $1}')
            if [[ -n "$dev_name" && -e "/sys/block/$dev_name/removable" ]] && [[ "$(cat "/sys/block/$dev_name/removable")" == "1" ]]; then
                size=$(lsblk -dno SIZE "/dev/$dev_name" | head -n 1)
                drives+=("/dev/$dev_name ($size)")
            fi
        done < <(lsblk -dno NAME | grep -v '^loop')
    fi
    if [[ ${#drives[@]} -gt 0 ]]; then
        printf '%s\n' "${drives[@]}"
    fi
}

get_drive_info() {
    local drive=$1
    if [[ "$(uname)" == "Darwin" ]]; then
        # Parse diskutil info into variables
        local info identifier node media_name volume_name disk_size removable location
        info=$(diskutil info "$drive")
        identifier=$(echo "$info" | grep -E "Device Identifier:" | sed 's/.*Device Identifier: *//')
        node=$(echo "$info" | grep -E "Device Node:" | sed 's/.*Device Node: *//')
        media_name=$(echo "$info" | grep -E "Device / Media Name:" | sed 's/.*Device \/ Media Name: *//')
        volume_name=$(echo "$info" | grep -E "Volume Name:" | sed 's/.*Volume Name: *//')
        disk_size=$(echo "$info" | grep -E "Disk Size:" | awk '{print $3 " " $4}' | sed 's/([^)]*)//')
        removable=$(echo "$info" | grep -E "Removable Media:" | sed 's/.*Removable Media: *//')
        location=$(echo "$info" | grep -E "Device Location:" | sed 's/.*Device Location: *//')

        # Output custom aligned table
        printf "   %-20s %s\n" "Device Identifier:" "$identifier"
        printf "   %-20s %s\n" "Device Node:" "$node"
        printf "   %-20s %s\n" "Media Name:" "$media_name"
        printf "   %-20s %s\n" "Volume Name:" "$volume_name"
        printf "   %-20s %s\n" "Disk Size:" "$disk_size"
        printf "   %-20s %s\n" "Removable Media:" "$removable"
        printf "   %-20s %s\n" "Device Location:" "$location"
    else
        lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN "$drive" | tail -n +2
    fi
}

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

main() {
    log_debug "Starting main function"
    printf "Initializing...\n"
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
    local temp_file="$temp_dir/page_content.txt"
    local versions_file="$temp_dir/versions.txt"
    local sorted_versions_file="$temp_dir/sorted_versions.txt"
    if ! curl -s "$download_page" > "$temp_file"; then
        printf "${red}Error: Failed to fetch download page${reset}\n" >&2
        exit 1
    fi
    log_debug "Page content saved to $temp_file"
    grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}' "$temp_file" > "$versions_file" || {
        printf "${red}Error: No versions found in page content${reset}\n" >&2
        exit 1
    }
    sort -rV "$versions_file" > "$sorted_versions_file"
    version=$(head -n 1 "$sorted_versions_file")
    if [[ -z "$version" ]]; then
        printf "${red}Error: Could not determine latest version${reset}\n" >&2
        exit 1
    fi
    log_debug "Determined version: $version"
    torrent_url="https://archlinux.org/releng/releases/${version}/torrent/"
    iso_name="archlinux-${version}-x86_64.iso"
    iso_path="${downloads_dir}/${iso_name}"
    cached_iso="${cache_dir}/${iso_name}"
    local curl_opts=(-sL)
    [[ -t 1 ]] && curl_opts+=(--progress-bar)
    log_debug "Fetching torrent file from $torrent_url"
    curl "${curl_opts[@]}" "$torrent_url" -o archlinux-latest.torrent
    log_debug "Fetching signature file"
    curl "${curl_opts[@]}" "https://archlinux.org/iso/$version/$iso_name.sig" -o "$iso_name.sig"
    log_debug "Fetching checksum file"
    curl "${curl_opts[@]}" "https://archlinux.org/iso/$version/sha256sums.txt" -o sha256sums.txt
    log_debug "Checking for cached ISO at $cached_iso"
    if [[ -f "$cached_iso" ]]; then
        printf "${yellow}Found cached ISO at %s${reset}\n" "$cached_iso"
        cp "$cached_iso" "$iso_name" || {
            printf "${red}Error: Failed to copy cached ISO${reset}\n" >&2
            exit 1
        }
        log_debug "Copied cached ISO to $temp_dir/$iso_name"
        log_debug "Verifying cached ISO with aria2c"
        aria2c --no-conf --check-integrity=true --seed-time=0 --dir="$temp_dir" \
            --console-log-level=warn archlinux-latest.torrent || {
            printf "${red}Error: Cached ISO verification failed${reset}\n" >&2
            exit 1
        }
        log_debug "Cached ISO verified"
    else
        log_debug "No cached ISO found, proceeding with download"
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
            printf "${red}Error: Failed to fetch release key${reset}\n" >&2
            exit 1
        }
    else
        gpg --keyserver-options auto-key-retrieve --verify "$iso_name.sig" "$iso_name" >/dev/null 2>&1 || {
            printf "${red}Error: Failed to fetch release key${reset}\n" >&2
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
    if [[ -f "$cached_iso" && "$(sha256sum "$cached_iso" | cut -d' ' -f1)" == "$(sha256sum "$iso_path" | cut -d' ' -f1)" ]]; then
        log_debug "Cached ISO at $cached_iso matches downloaded file, skipping copy"
    else
        cp "$iso_path" "$cached_iso" || {
            printf "${red}Error: Failed to cache ISO${reset}\n" >&2
            exit 1
        }
        log_debug "ISO cached at $cached_iso"
    fi
    printf "${green}Successfully downloaded and verified %s${reset}\n" "$iso_name"
    if [[ -t 0 ]]; then
        printf "\nWould you like to write the ISO to a flash drive? (y/N): "
        read -r response
        if [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]; then
            local drives
            mapfile -t drives < <(list_usb_drives)
            log_debug "Detected ${#drives[@]} USB drives"
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
            # Strip size from selected_drive for write_to_drive
            selected_drive="${selected_drive%% (*}"
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

if ! trap cleanup EXIT INT TERM; then
    printf "${red}Error: Failed to set trap${reset}\n" >&2
    exit 1
fi
log_debug "Trap set successfully"

log_debug "Before calling main"
printf "Starting script...\n"
main "$@"
