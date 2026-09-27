#!/bin/bash
# Install the privileged half of the WireGuard bar widget.
#
#   ./install.sh              install or update it
#   ./install.sh --check      report what is in place, change nothing
#   ./install.sh --uninstall  remove what this script installed, and nothing else
#
# Run it as your normal user from the plugin folder
# (~/.config/omarchy/plugins/blacksheep.wireguard); it calls sudo where it
# needs to. Re-run it after `omarchy plugin update`, because the root-owned
# copies do not update themselves.
#
# Everything it installs is under a name that belongs to this plugin:
#   /usr/local/libexec/blacksheep.wireguard/wg-toggle, wg-ssid-apply   0755
#   /etc/NetworkManager/dispatcher.d/90-blacksheep-wireguard           0755
#   /etc/sudoers.d/99-blacksheep-wireguard                             0440, checked by visudo
#   /etc/blacksheep.wireguard/trusted     0644, only if absent: the networks you enter
#   /var/lib/blacksheep.wireguard/        0755: the override, and the ownership record
#
# OWNERSHIP. The installer records a SHA-256 of every file it installs in
# /var/lib/blacksheep.wireguard/installed. It replaces a file only if the file
# is absent, is its own recorded copy unchanged, or is already byte-identical
# to what it would install; anything else stops the install before it changes
# a thing. --uninstall removes only files that still match their record, and
# leaves anything changed since in place. It never guesses from a file name.
#
# It never writes /etc/wireguard/wg0.conf: that holds your private key, and you
# install it yourself (system/examples/wg0.conf.example shows the shape).

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

MODE=install
case "${1:-}" in
"") ;;
--check) MODE=check ;;
--uninstall) MODE=uninstall ;;
*)
  echo "usage: install.sh [--check|--uninstall]" >&2
  exit 1
  ;;
esac

if ((EUID == 0)); then
  echo "Run this as your normal user, not root — it calls sudo where it needs to." >&2
  exit 1
fi
# The account name goes into a sudoers rule, so it must be a plain name.
[[ $USER =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "unexpected user name: $USER" >&2; exit 1; }

NS=blacksheep.wireguard
LIBEXEC=/usr/local/libexec/$NS
ETC=/etc/$NS
VAR=/var/lib/$NS
RUN=/run/$NS
RECORD=$VAR/installed
TRUSTED_FILE=$ETC/trusted
DISPATCH=/etc/NetworkManager/dispatcher.d/90-blacksheep-wireguard
SUDOERS=/etc/sudoers.d/99-blacksheep-wireguard
VERBS=("wg-toggle toggle" "wg-toggle on" "wg-toggle off" "wg-toggle auto"
  "wg-toggle trust" "wg-toggle untrust")

ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; }
trusted_count() { grep -cvE '^[[:space:]]*(#|$)' "$TRUSTED_FILE" 2>/dev/null || true; }

# `sudo -l` alone only answers "is this permitted", which a blanket wheel rule
# says yes to. The long listing prints the matched entry's tags, so
# !authenticate proves the grant is ours and the widget will not be stopped by
# a password prompt it has no terminal to show.
check_verbs() {
  local verb
  for verb in "${VERBS[@]}"; do
    # shellcheck disable=SC2086
    if sudo -n -l -l $LIBEXEC/$verb 2>/dev/null | grep -q '!authenticate'; then
      ok "sudo -n $verb"
    else
      bad "sudo -n $verb"
    fi
  done
}

# ---------------------------------------------------------- ownership record

# One "sha256  path" line per installed file. The record is root-owned and
# world-readable; only root can change it.
declare -A OWNED=()
load_record() {
  local sum path
  [[ -r $RECORD ]] || return 0
  while read -r sum path; do
    [[ -n $path ]] && OWNED[$path]=$sum
  done <"$RECORD"
}
# Most targets are world-readable; the sudoers drop-in is 0440, so it takes sudo.
sum_of() {
  { sha256sum "$1" 2>/dev/null || sudo sha256sum "$1" 2>/dev/null; } | cut -d' ' -f1
}
# `test -e` follows symlinks, so a dangling link would read as absent. Every
# check here asks about the path itself: a symlink is never ours, whatever it
# points at, and is never followed, replaced or removed.
is_link() { sudo test -L "$1"; }
present() { sudo test -e "$1" || sudo test -L "$1"; }

# This plugin's own directories must be real, root-owned directories, and the
# files it writes only when absent (or rewrites in place) must not be links.
DIRS=("$LIBEXEC" "$VAR" "$RUN" "$ETC")
NOLINK=("$RECORD" "$VAR/override" "$TRUSTED_FILE")

# The files this install would place: "source|target|mode". The sudoers source
# is generated for this account, so it is staged in a temporary file first.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
sed "s/@USER@/$USER/g" system/sudoers.d/99-blacksheep-wireguard >"$STAGE/sudoers"
PLAN=(
  "system/bin/wg-toggle|$LIBEXEC/wg-toggle|0755"
  "system/bin/wg-ssid-apply|$LIBEXEC/wg-ssid-apply|0755"
  "system/dispatcher.d/90-blacksheep-wireguard|$DISPATCH|0755"
  "$STAGE/sudoers|$SUDOERS|0440"
)

# Stop before changing anything if a target is somebody else's.
preflight() {
  local entry src target mode have d f conflicts=0
  for d in "${DIRS[@]}"; do
    if is_link "$d"; then
      echo "  STOP $d is a symbolic link"; conflicts=1
    elif sudo test -e "$d" && [[ $(sudo stat -c '%F %U' "$d") != "directory root" ]]; then
      echo "  STOP $d exists and is not a root-owned directory"; conflicts=1
    fi
  done
  for f in "${NOLINK[@]}"; do
    if is_link "$f"; then
      echo "  STOP $f is a symbolic link"; conflicts=1
    elif sudo test -d "$f"; then
      echo "  STOP $f is a directory"; conflicts=1
    fi
  done
  for entry in "${PLAN[@]}"; do
    IFS='|' read -r src target mode <<<"$entry"
    if is_link "$target"; then
      echo "  STOP $target is a symbolic link"; conflicts=1; continue
    fi
    present "$target" || continue
    if sudo test -d "$target"; then
      echo "  STOP $target is a directory"; conflicts=1; continue
    fi
    have=$(sum_of "$target")
    [[ $have == "$(sha256sum "$src" | cut -d' ' -f1)" ]] && continue
    [[ -n ${OWNED[$target]:-} && $have == "${OWNED[$target]}" ]] && continue
    echo "  STOP $target exists and was not installed by this plugin (or has changed since)"
    conflicts=1
  done
  if ((conflicts)); then
    echo
    echo "Nothing was changed. Move the files above aside yourself if they are safe" >&2
    echo "to replace, then run install.sh again." >&2
    exit 1
  fi
}

write_record() {
  local path
  for path in "${!OWNED[@]}"; do
    printf '%s  %s\n' "${OWNED[$path]}" "$path"
  done | sort -k2 >"$STAGE/record"
  sudo install -o root -g root -m 0644 "$STAGE/record" "$RECORD"
}

# ---------------------------------------------------------------- check mode

if [[ $MODE == check ]]; then
  load_record
  echo "==> Installed files"
  if ((${#OWNED[@]} == 0)); then
    bad "no ownership record at $RECORD — not installed (or check needs a password)"
  fi
  for entry in "${PLAN[@]}"; do
    IFS='|' read -r src target mode <<<"$entry"
    # /etc/sudoers.d can't be read without a password; the verbs below prove
    # the rule is in place instead.
    if [[ $target == "$SUDOERS" ]]; then
      echo "  --   $target (checked through the passwordless verbs below)"
    elif [[ -L $target ]]; then
      bad "$target is a symbolic link, not this plugin's file"
    elif [[ ! -e $target ]]; then
      bad "$target missing"
    elif [[ $(sum_of "$target") != "$(sha256sum "$src" | cut -d' ' -f1)" ]]; then
      bad "$target differs from this plugin's copy — re-run install.sh"
    else
      ok "$target"
    fi
  done
  echo "==> Trusted Wi-Fi"
  if [[ -r $TRUSTED_FILE ]]; then
    n=$(trusted_count)
    ((n > 0)) && ok "$TRUSTED_FILE: $n network(s)" ||
      bad "$TRUSTED_FILE lists no networks: the tunnel comes up on every Wi-Fi network"
  else
    bad "$TRUSTED_FILE missing: the tunnel comes up on every Wi-Fi network"
  fi
  echo "==> Tunnel"
  # /etc/wireguard is 0700 root, so an unprivileged test cannot tell "absent"
  # from "unreadable". Say so rather than report a key that is really there.
  if sudo -n test -f /etc/wireguard/wg0.conf 2>/dev/null; then
    ok "/etc/wireguard/wg0.conf"
  else
    echo "  ?    /etc/wireguard/wg0.conf — cannot tell without a password; check with:"
    echo "         sudo test -f /etc/wireguard/wg0.conf && echo present"
  fi
  if systemctl is-enabled --quiet wg-quick@wg0.service 2>/dev/null; then
    bad "wg-quick@wg0.service is enabled: it and this widget would both manage wg0"
  fi
  echo "==> Passwordless verbs"
  check_verbs
  exit 0
fi

# ------------------------------------------------------------ uninstall mode

if [[ $MODE == uninstall ]]; then
  load_record
  if ((${#OWNED[@]} == 0)); then
    echo "No ownership record at $RECORD, so there is nothing this script knows it"
    echo "installed. Nothing was removed."
    exit 0
  fi
  echo "==> The tunnel"
  # Only a wg0 this widget raised: wg-ssid-apply records its interface index,
  # and a tunnel started any other way has a different one.
  if ! ip link show wg0 &>/dev/null; then
    ok "wg0 is not up"
  elif [[ -r $RUN/raised && $(cat /sys/class/net/wg0/ifindex 2>/dev/null) == "$(cat "$RUN/raised")" ]]; then
    sudo wg-quick down wg0 2>/dev/null && ok "wg0 down"
  else
    echo "  KEEP wg0 is up but was not started by this widget; left up"
  fi
  echo "==> Removing what this plugin installed"
  # The sudoers rule goes first, so the grant never outlives the scripts it names.
  for path in "$SUDOERS" $(printf '%s\n' "${!OWNED[@]}" | grep -vxF "$SUDOERS" | sort); do
    [[ -n ${OWNED[$path]:-} ]] || continue
    if is_link "$path"; then
      echo "  KEEP $path is a symbolic link, not what this plugin installed; left in place"
    elif ! present "$path"; then
      ok "$path (already gone)"
    elif [[ $(sum_of "$path") == "${OWNED[$path]}" ]]; then
      sudo rm -f "$path" && ok "removed $path"
    else
      echo "  KEEP $path has changed since install; left in place"
    fi
  done
  sudo rmdir "$LIBEXEC" 2>/dev/null || true
  # State: only the files this plugin writes, inside its own directories.
  sudo rm -f "$VAR/override" "$RECORD" "$RUN/last-result" "$RUN/apply.lock" "$RUN/raised" "$ETC/.lock"
  sudo rmdir "$VAR" "$RUN" 2>/dev/null || true
  cat <<LEFT

Left in place, because they are yours rather than this plugin's:
  $TRUSTED_FILE     your trusted networks   (sudo rm -r $ETC)
  /etc/wireguard/wg0.conf     your tunnel and its key
  the wireguard-tools package

Then remove the widget itself:
  omarchy plugin remove blacksheep.wireguard
LEFT
  exit 0
fi

# -------------------------------------------------------------- install mode

load_record
echo "==> Checking for files this plugin doesn't own"
preflight
ok "no conflicts"

if systemctl is-enabled --quiet wg-quick@wg0.service 2>/dev/null; then
  echo "  WARN wg-quick@wg0.service is enabled. It and this widget would both manage"
  echo "       wg0; disable it (sudo systemctl disable wg-quick@wg0) if this widget"
  echo "       should decide when the tunnel is up."
fi

echo "==> Packages"
omarchy pkg add wireguard-tools 2>/dev/null ||
  sudo pacman -S --needed --noconfirm wireguard-tools
ok "wireguard-tools"

# Written before the dispatcher is installed, so the policy never runs against a
# missing list. Nothing is built in: with no trusted networks the tunnel comes up
# on every Wi-Fi network, which is the safe default for a VPN. It is your data,
# so it is written only if absent and never removed.
echo "==> Trusted Wi-Fi networks (the tunnel stays down on these)"
if sudo test -f "$TRUSTED_FILE"; then
  ok "$TRUSTED_FILE already present: $(trusted_count) network(s)"
  echo "       manage them from the panel, or: sudoedit $TRUSTED_FILE"
else
  echo "  List the Wi-Fi networks where the tunnel should NOT come up -- at least"
  echo "  the one your VPN server is on. Every other network raises the tunnel."
  current=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -1)
  [[ -n $current ]] && echo "  You are connected to: $current"
  names=()
  while read -rp "  Trusted SSID (blank when done): " name && [[ -n $name ]]; do
    names+=("$name")
  done
  { cat system/examples/trusted; printf '%s\n' "${names[@]}"; } >"$STAGE/trusted"
  sudo install -D -o root -g root -m 0644 "$STAGE/trusted" "$TRUSTED_FILE"
  if ((${#names[@]})); then
    ok "$TRUSTED_FILE: ${#names[@]} network(s)"
  else
    echo "  WARN no trusted networks: the tunnel will come up on every Wi-Fi network."
    echo "       Trust one later from the panel, or: sudoedit $TRUSTED_FILE"
  fi
fi

# Never install a sudoers file that does not parse: a broken drop-in locks sudo
# out entirely, and there is no second chance on a machine with no root shell.
# `visudo -c -f` checks the staged copy before anything is placed.
echo "==> Checking the sudoers rule for '$USER'"
sudo visudo -c -f "$STAGE/sudoers" >/dev/null || { echo "sudoers rule failed validation; nothing installed" >&2; exit 1; }
ok "parses"

echo "==> Installing"
sudo install -d -o root -g root -m 0755 "$LIBEXEC" "$VAR"
for entry in "${PLAN[@]}"; do
  IFS='|' read -r src target mode <<<"$entry"
  # Into place through a dot-named temporary in the same directory: sudo skips
  # dot files in sudoers.d, and the rename is atomic for every other reader.
  tmp=$(sudo mktemp -p "$(dirname "$target")" ".$(basename "$target").XXXXXX")
  sudo install -o root -g root -m "$mode" "$src" "$tmp"
  if [[ $target == "$SUDOERS" ]] && ! sudo visudo -c -f "$tmp" >/dev/null; then
    sudo rm -f "$tmp"
    echo "sudoers rule failed validation in place; not installed" >&2
    exit 1
  fi
  sudo mv -f -T "$tmp" "$target"
  OWNED[$target]=$(sha256sum "$src" | cut -d' ' -f1)
  write_record
  ok "$target"
done

echo "==> State"
# World-readable: the bar runs unprivileged and reads it to draw the widget.
sudo test -f "$VAR/override" || echo auto | sudo tee "$VAR/override" >/dev/null
sudo chmod 0644 "$VAR/override"
ok "$VAR/override: $(cat "$VAR/override")"

echo "==> Tunnel config"
if sudo test -f /etc/wireguard/wg0.conf; then
  ok "/etc/wireguard/wg0.conf present"
else
  echo "  /etc/wireguard/wg0.conf is missing — it holds your tunnel's private key."
  echo "  Write it from system/examples/wg0.conf.example, then:"
  echo "    sudo install -o root -g root -m 0600 wg0.conf /etc/wireguard/wg0.conf"
fi

echo
echo "==> Checking"
check_verbs
echo
echo "  wireguard-stats: $(scripts/wireguard-stats)"
cat <<'NEXT'

If any verb above says FAIL, look at what else is in /etc/sudoers.d: sudo
applies the LAST matching rule, so a file that sorts after
99-blacksheep-wireguard and grants the same commands with a password wins.

If the widget is not on the bar yet:
  omarchy plugin enable blacksheep.wireguard
NEXT
