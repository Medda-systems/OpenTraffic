#!/bin/sh
# Installs the latest OpenTraffic:
#   curl -fsSL https://github.com/Medda-systems/OpenTraffic-releases/releases/latest/download/install.sh | sh
#
# Downloads the newest release, checks its SHA-256 checksum and code signature, quits a running
# OpenTraffic, puts the app in /Applications (or ~/Applications when that isn't writable), links the
# `opentraffic` command into your PATH, and opens the app. After that, OpenTraffic updates itself.
#
# OPENTRAFFIC_INSTALL_DIR  install somewhere else
# OPENTRAFFIC_NO_OPEN=1    don't open the app afterwards
# OPENTRAFFIC_NO_CLI=1     don't link the opentraffic command
set -eu

RELEASES="https://github.com/Medda-systems/OpenTraffic-releases/releases"

say() { printf '%s\n' "$*"; }
fail() { printf 'opentraffic install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "OpenTraffic is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "${major}" -ge 14 ] || fail "OpenTraffic needs macOS 14 or later."

work="$(mktemp -d)"
mounted=""
cleanup() {
  status=$?
  [ -n "${mounted}" ] && hdiutil detach "${mounted}" -quiet 2>/dev/null || true
  rm -rf "${work}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The newest version, from the update feed every installed copy also reads.
version="$(curl -fsSL "${RELEASES}/latest/download/appcast.xml" \
  | sed -n 's:.*<sparkle\:shortVersionString>\([^<]*\)</sparkle\:shortVersionString>.*:\1:p' | head -n 1)"
[ -n "${version}" ] || fail "couldn't find the latest version."
dmg="OpenTraffic-${version}.dmg"

say "Downloading OpenTraffic ${version}…"
curl -fsSL -o "${work}/${dmg}" "${RELEASES}/download/v${version}/${dmg}"
curl -fsSL -o "${work}/${dmg}.sha256" "${RELEASES}/download/v${version}/${dmg}.sha256"
(cd "${work}" && shasum -a 256 -c "${dmg}.sha256" >/dev/null) || fail "the download doesn't match its checksum."

mounted="${work}/volume"
mkdir "${mounted}"
hdiutil attach -readonly -nobrowse -mountpoint "${mounted}" "${work}/${dmg}" -quiet || fail "couldn't open the disk image."
codesign --verify --deep --strict "${mounted}/OpenTraffic.app" 2>/dev/null || fail "the app's signature is invalid."

if [ -n "${OPENTRAFFIC_INSTALL_DIR:-}" ]; then
  destination="${OPENTRAFFIC_INSTALL_DIR}"
elif [ -w /Applications ]; then
  destination="/Applications"
else
  destination="${HOME}/Applications"
fi
mkdir -p "${destination}"
app="${destination}/OpenTraffic.app"

# Quit a running copy gracefully, so it stops its shares and cleans up first.
if pgrep -f "${app}/Contents/MacOS/OpenTraffic" >/dev/null 2>&1; then
  say "Quitting OpenTraffic…"
  osascript -e 'tell application id "se.medda.opentraffic" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -f "${app}/Contents/MacOS/OpenTraffic" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "${i}" -le 20 ] || fail "OpenTraffic is still running. Quit it (close any open sheets first) and run this again."
    sleep 1
  done
fi

rm -rf "${app}"
ditto "${mounted}/OpenTraffic.app" "${app}"
say "Installed OpenTraffic ${version} in ${destination}."

# The opentraffic command: a link to the script in the app, so it follows updates. Like the app does
# at launch, an earlier link of OpenTraffic's is updated, and an `opentraffic` that isn't OpenTraffic's
# is left alone.
link_command() {
  target="${app}/Contents/Resources/opentraffic"
  [ -x "${target}" ] || return 0
  directories="/opt/homebrew/bin /usr/local/bin ${HOME}/.local/bin"
  link=""
  for dir in ${directories}; do
    case "$(readlink "${dir}/opentraffic" 2>/dev/null)" in
      *.app/Contents/Resources/opentraffic) link="${dir}/opentraffic"; break ;;
    esac
  done
  if [ -z "${link}" ]; then
    mkdir -p "${HOME}/.local/bin" 2>/dev/null || true
    for dir in ${directories}; do
      [ -d "${dir}" ] && [ -w "${dir}" ] || continue
      if [ -e "${dir}/opentraffic" ] || [ -L "${dir}/opentraffic" ]; then
        say "Left ${dir}/opentraffic alone: it isn't OpenTraffic's."
        continue
      fi
      link="${dir}/opentraffic"
      break
    done
  fi
  [ -n "${link}" ] || { say "Couldn't link the opentraffic command; turn it on in OpenTraffic → Settings → General."; return 0; }
  ln -sfn "${target}" "${link}" || return 0
  dir="$(dirname "${link}")"
  case ":${PATH}:" in
    *":${dir}:"*) say "Linked the opentraffic command. Run \`opentraffic setup\` once, then \`opentraffic help\`." ;;
    *) say "Linked the opentraffic command at ${link}. Add ${dir} to your PATH to use it." ;;
  esac
}
[ "${OPENTRAFFIC_NO_CLI:-}" = "1" ] || link_command

if [ "${OPENTRAFFIC_NO_OPEN:-}" != "1" ]; then
  open "${app}"
  say "OpenTraffic is in the menu bar. It updates itself from now on."
fi
