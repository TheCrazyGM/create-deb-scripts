# Debian Package Builder Scripts

This repository provides automated scripts to build Debian packages for:

- [Zen Browser](https://zen-browser.app/) – privacy-focused web browser
- [Zed Editor](https://zed.dev/) – high-performance, multiplayer code editor

Each script fetches the latest release from GitHub and builds a .deb that integrates with desktop environments (icons, desktop entries, and executables on PATH).

## Requirements

- `curl` for downloading
- `jq` for JSON parsing
- `tar` for extracting archives
- `dpkg-deb` for building the package

## Usage

1. Clone this repository:

   ```bash
   git clone https://github.com/TheCrazyGM/create-deb-scripts.git && cd create-deb-scripts
   ```

2. Build Zen Browser .deb:

   ```bash
   bash zen_browser.sh
   ```

3. Build Zed Editor .deb:

   ```bash
   bash zed_editor.sh
   ```

4. What the scripts do:
   - Check for required dependencies
   - Fetch the latest release from GitHub
   - Download the official tarball
   - Build the Debian package (.deb)

5. Install the generated .deb files:

   ```bash
   sudo dpkg -i zen-browser_<version>.deb
   sudo dpkg -i zed-editor_<version>.deb
   ```

## Output

- Zen: `zen-browser_<version>.deb`
- Zed: `zed-editor_<version>.deb`

## Notes

- Scripts handle cleanup automatically, removing temporary files on completion or failure.
- Desktop entries are installed to `usr/share/applications` and icons to `usr/share/icons/hicolor`.
