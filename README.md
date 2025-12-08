# Debian Package Builder Scripts

This repository provides automated scripts to build Debian packages for:

- [Zen Browser](https://zen-browser.app/) – privacy-focused web browser
- [Zed Editor](https://zed.dev/) – high-performance, multiplayer code editor
- [Neovim (git)](https://neovim.io/) – built from source using CMake and packaged as a .deb
- [Rofi (git)](https://github.com/davatorium/rofi) – built from source with Meson/Ninja and packaged as a .deb
- [Picom (git)](https://github.com/yshui/picom) – built from source with Meson/Ninja and packaged as a .deb
- [Alacritty (git)](https://github.com/alacritty/alacritty) – GPU-accelerated terminal emulator, built from source with Cargo and packaged as a .deb

Zed and Zen scripts fetch the latest upstream release from GitHub and build a .deb that integrates with desktop environments (icons, desktop entries, and executables on PATH). Neovim is built from the latest `neovim/neovim` repo source and then packaged.

## Requirements

Common (all scripts):

- `curl` for downloading
- `jq` for JSON parsing
- `tar` for extracting archives
- `dpkg-deb` for building the package

Additional for `neovim.sh` (build from source):

- `git`
- `cmake`
- `make`

Additional for `rofi.sh` and `picom.sh` (build from source):

- `git`
- `meson`
- `ninja`
- `pkg-config`
- `flex`
- `bison`
- `flex`
- `bison`

Additional for `alacritty.sh` (build from source):

- `cargo` (Rust package manager)
- `rustc` (Rust compiler)
- `cmake`
- `pkg-config`
- `gzip`
- `scdoc` (optional, for man pages)

## Usage

1. Clone this repository:

   ```bash
   git clone https://github.com/TheCrazyGM/create-deb-scripts.git && cd create-deb-scripts
   ```

2. Build Glide Browser .deb:

   ```bash
   bash glide_browser.sh
   ```

3. Build Zen Browser .deb:

   ```bash
   bash zen_browser.sh
   ```

4. Build Zed Editor .deb:

   ```bash
   bash zed_editor.sh
   ```

5. Build Neovim (git) .deb:

   ```bash
   bash neovim.sh
   ```

6. Build Rofi (git) .deb:

   ```bash
   bash rofi.sh
   ```

7. Build Picom (git) .deb:

   ```bash
   bash picom.sh
   ```

8. Build Alacritty (git) .deb:

   ```bash
   bash alacritty.sh
   ```

9. What the scripts do:
   - Check for required dependencies
   - Zed/Zen: Fetch the latest release from GitHub and download the official tarball
   - Neovim: Clone `neovim/neovim`, build with CMake/Make, and stage install
   - Rofi: Clone `davatorium/rofi`, build with Meson/Ninja, and stage install
   - Picom: Clone `yshui/picom`, build with Meson/Ninja, and stage install
   - Alacritty: Clone `alacritty/alacritty`, build with Cargo, and stage install (includes terminfo, desktop entry, man pages, shell completions)
   - Generate Debian control metadata and desktop integration (where applicable)
   - Build the Debian package (.deb)

10. Install the generated .deb files:

   ```bash
   sudo dpkg -i glide-browser_<version>.deb
   sudo dpkg -i zen-browser_<version>.deb
   sudo dpkg -i zed-editor_<version>.deb
   ```

## Output

- Glide: `glide-browser_<version>.deb`
- Zen: `zen-browser_<version>.deb`
- Zed: `zed-editor_<version>.deb`
- Neovim: `neovim-git_<version>_<arch>.deb`
- Rofi: `rofi-git_<version>_<arch>.deb`
- Picom: `picom-git_<version>_<arch>.deb`
- Alacritty: `alacritty-git_<version>_<arch>.deb`

The scripts print the absolute path to the generated `.deb` on success.

## Notes

- Architecture is auto-detected via `dpkg --print-architecture` and the correct upstream asset is selected (Zed/Zen). Neovim is compiled for the detected architecture.
- Upstream tags with a leading `v` (e.g., `v1.2.3`) are normalized for Debian versioning where applicable.
- Scripts handle cleanup automatically, removing temporary files on completion or failure.
- Desktop entries are installed to `usr/share/applications` and icons to `usr/share/icons/hicolor` (Zed/Zen).
- Post-install scripts refresh icon and desktop caches to ensure entries appear immediately.
