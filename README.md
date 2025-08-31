# Zen Browser Debian Package Builder

This repository provides an automated script to build Debian packages for the [Zen Browser](https://zen-browser.app/), a privacy-focused web browser.

The main script, `get_zen_deb.sh`, combines GitHub release fetching and deb package creation into a single automated process.

## Features

- Fetches the latest Zen Browser release from GitHub
- Automatically determines the version number
- Downloads the official tarball
- Builds a Debian package (.deb) ready for installation

## Requirements

- `curl` for downloading
- `jq` for JSON parsing
- `tar` for extracting archives
- `dpkg-deb` for building the package

## Usage

1. Clone this repository:

   ```bash
   git clone https://github.com/sh4r10/zen-browser-debian.git && cd zen-browser-debian
   ```

2. Run the script:

   ```bash
   ./get_zen_deb.sh
   ```

3. The script will:
   - Check for required dependencies
   - Fetch the latest release from zen-browser/desktop
   - Download the tarball
   - Build the Debian package

4. Install the generated .deb file:

   ```bash
   dpkg -i zen-browser_VERSION.deb
   ```

## Output

The script produces a file named `zen-browser_VERSION.deb` in the current directory, where VERSION is the latest release tag.

## Notes

- The script handles cleanup automatically, removing temporary files on completion or failure.
