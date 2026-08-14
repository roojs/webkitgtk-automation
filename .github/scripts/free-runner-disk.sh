#!/usr/bin/env bash
# Free disk/RAM on GitHub-hosted Ubuntu runners for WebKit package builds.
#
# Removes preinstalled SDKs and toolchains we do not use. Keeps compilers,
# build-essential, git, and swap (linker RAM). Safe to re-run.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> disk before cleanup"
df -h /

bytes_of() {
  local p="$1"
  if [[ -e "$p" ]]; then
    du -sb "$p" 2>/dev/null | awk '{print $1}'
  else
    echo 0
  fi
}

remove_path() {
  local p="$1"
  local label="${2:-$p}"
  local before after saved
  if [[ -z "$p" || "$p" == "/" ]]; then
    return 0
  fi
  before="$(bytes_of "$p")"
  if [[ "$before" -eq 0 ]]; then
    echo "    skip (missing): $label"
    return 0
  fi
  echo "    removing: $label"
  "${SUDO[@]}" rm -rf "$p" || true
  after="$(bytes_of "$p")"
  saved=$(( (before - after) / 1024 / 1024 ))
  echo "    freed ~${saved} MiB from $label"
}

echo "==> removing language/runtime SDKs and tool caches"

# Android SDK / NDK (~6–14 GiB)
remove_path /usr/local/lib/android "Android SDK"
remove_path "${ANDROID_HOME:-}" "ANDROID_HOME"
remove_path "${ANDROID_SDK_ROOT:-}" "ANDROID_SDK_ROOT"

# .NET (~2–3 GiB)
remove_path /usr/share/dotnet ".NET"
remove_path /usr/lib/dotnet ".NET lib"

# Haskell / GHCup
remove_path /usr/local/.ghcup "Haskell GHCup"
remove_path /opt/ghcup "Haskell GHCup (opt)"

# PowerShell
remove_path /usr/local/share/powershell "PowerShell"
remove_path /opt/microsoft/powershell "PowerShell (opt)"

# Swift
remove_path /usr/share/swift "Swift"

# Julia
remove_path /usr/local/julia "Julia"
shopt -s nullglob
for p in /usr/local/julia-*; do
  remove_path "$p" "Julia ($p)"
done
shopt -u nullglob

# Hosted toolcache (Node/Go/Python/Ruby/CodeQL/…)
remove_path /opt/hostedtoolcache "hostedtoolcache"
remove_path "${AGENT_TOOLSDIRECTORY:-}" "AGENT_TOOLSDIRECTORY"

# Cloud CLIs / SDKs we do not need for packaging
remove_path /opt/az "Azure CLI"
remove_path /usr/lib/google-cloud-sdk "Google Cloud SDK"
remove_path /usr/local/google-cloud-sdk "Google Cloud SDK (local)"
remove_path /usr/local/aws-cli "AWS CLI (local install)"
remove_path /usr/local/aws-sam-cli "AWS SAM"

# Java JDKs (WebKit build does not need them)
remove_path /usr/lib/jvm "Java JDKs"

# Miniconda / Homebrew
remove_path /usr/share/miniconda "Miniconda"
remove_path /opt/miniconda "Miniconda (opt)"
remove_path /home/linuxbrew "Homebrew"
remove_path /home/runner/.linuxbrew "Homebrew (runner)"

# Rust toolchains (large; not used)
remove_path /home/runner/.rustup "Rustup"
remove_path /home/runner/.cargo "Cargo"
remove_path /usr/share/rust "Rust share"

# Browsers / drivers (not used; WebKit is built from source)
remove_path /opt/google "Google Chrome/opt"
remove_path /opt/microsoft "Microsoft Edge/opt"
remove_path /usr/local/share/chromium "Chromium"
remove_path /usr/local/share/chrome "Chrome"
remove_path /usr/local/share/chromedriver-linux64 "ChromeDriver"
remove_path /usr/local/share/edge_driver "EdgeDriver"
remove_path /usr/local/share/gecko_driver "GeckoDriver"
remove_path /usr/share/java/selenium-server.jar "Selenium jar"

# Database data dirs (services usually inactive, data still large)
echo "==> stopping unused database/web services and removing data"
for svc in mysql postgresql apache2 nginx mono-xsp4; do
  "${SUDO[@]}" systemctl stop "$svc" 2>/dev/null || true
  "${SUDO[@]}" systemctl disable "$svc" 2>/dev/null || true
done
remove_path /var/lib/mysql "MySQL data"
remove_path /var/lib/postgresql "PostgreSQL data"

# Snap cache if present
remove_path /var/lib/snapd/snaps "snap packages"
remove_path /var/cache/snapd "snap cache"

echo "==> purging apt packages we do not need (best-effort)"
# Only purge packages that are typically present and unused for this build.
# Failures are ignored so the script stays portable across image revisions.
PURGE_PKGS=(
  dotnet-sdk-8.0
  dotnet-sdk-9.0
  dotnet-runtime-8.0
  aspnetcore-runtime-8.0
  powershell
  google-chrome-stable
  microsoft-edge-stable
  firefox
  firefox-esr
  chromium-browser
  apache2
  nginx
  mysql-server
  postgresql
  postgresql-16
  mono-complete
  mono-devel
  php8.3-cli
  php8.3-common
  HHVM
  temurin-8-jdk
  temurin-11-jdk
  temurin-17-jdk
  temurin-21-jdk
  temurin-25-jdk
  openjdk-8-jdk
  openjdk-11-jdk
  openjdk-17-jdk
  openjdk-21-jdk
)
EXISTING=()
for pkg in "${PURGE_PKGS[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    EXISTING+=("$pkg")
  fi
done
if [[ ${#EXISTING[@]} -gt 0 ]]; then
  "${SUDO[@]}" apt-get purge -y "${EXISTING[@]}" || true
  "${SUDO[@]}" apt-get autoremove -y --purge || true
  "${SUDO[@]}" apt-get clean || true
fi

# Drop apt lists/archives on the system cache (we use a workspace apt cache later)
"${SUDO[@]}" rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb || true

echo "==> disk after cleanup"
df -h /
echo "==> free-runner-disk done"
