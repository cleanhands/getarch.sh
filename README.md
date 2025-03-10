# Arch Linux ISO Downloader and Writer

A Bash script to download the latest Arch Linux ISO, verify its integrity, and optionally write it to a USB flash drive. Designed for both macOS and Linux, with robust error handling and debug support.

## Features
- **Automatic Download**: Fetches the latest Arch Linux ISO via torrent using `aria2c`.
- **Integrity Verification**: Checks the ISO’s SHA256 checksum and GPG signature.
- **USB Writing**: Detects removable/external drives and writes the ISO with `dd`.
- **Cross-Platform**: Works on macOS and Linux with platform-specific drive detection.
- **Debug Mode**: Enable detailed logging with `DEBUG=true` or `DEBUG=1`.

## Requirements
- **Core Tools**:
  - `curl`: For downloading torrent and verification files.
  - `aria2c`: For torrent-based ISO download.
  - `sha256sum`: For checksum verification.
  - `gpg`: For signature verification.
  - `mktemp`: For temporary directory creation.
  - `dd`: For writing the ISO to a USB drive.
- **Optional**:
  - `tput`: For colored terminal output (falls back to plain text if unavailable).
- **Platform-Specific**:
  - macOS: `diskutil` (pre-installed).
  - Linux: `lsblk` (typically pre-installed).

Install missing tools with your package manager (e.g., `brew` on macOS, `pacman` on Arch Linux).

## Usage
1. **Clone the Repository**:
   ```bash
   git clone https://github.com/cleanhands/getarch.sh.git
   cd arch-iso-script
   ```
2. **Make Executable**:
   ```bash
   chmod +x getarch.sh
   ```
3. **Run the Script**:
   - Basic run:
     ```bash
     ./getarch.sh
     ```
   - With debug output:
     ```bash
     DEBUG=1 ./getarch.sh
     ```
4. **Follow Prompts**:
   - The script downloads and verifies the ISO.
   - If run interactively, it asks to write the ISO to a USB drive, listing detected devices.

## Output
- Downloads the ISO to `~/Downloads` (or `$XDG_DOWNLOAD_DIR` if set).
- Caches the ISO in `~/.cache/archlinux` (or `$XDG_CACHE_HOME/archlinux`).
- Optionally writes to a selected USB drive with progress feedback.

## Example
```bash
$ DEBUG=1 ./getarch.sh
Starting script...
Initializing...
[DEBUG] Starting main function
[DEBUG] Commands checked
[DEBUG] Creating temporary directory
[DEBUG] Changed to temp directory: /tmp/tmp.abc123
[DEBUG] Fetching version from https://archlinux.org/releng/releases/
[DEBUG] Determined version: 2025.03.01
...
Successfully downloaded and verified archlinux-2025.03.01-x86_64.iso

Would you like to write the ISO to a flash drive? (y/N): y
[DEBUG] Detected 1 USB drives

Available USB drives:
1) disk4

Select a drive (1-1, or 0 to skip): 1
...
Successfully wrote ISO to disk4
```

## Notes
- **macOS Detection**: Detects USB drives based on "Removable Media: Removable" or "Device Location: External" from `diskutil`.
- **Linux Detection**: Uses `lsblk` to find removable block devices.

## Contributing
Feel free to open issues or submit pull requests for improvements, especially for edge cases in drive detection or additional features.

## License
MIT License - feel free to use, modify, and distribute.
