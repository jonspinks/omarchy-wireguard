#!/bin/bash
# Install the privileged half of the WireGuard bar widget.
#
#   ./install.sh              install or update it
#   ./install.sh --check      report what is in place, change nothing
#   ./install.sh --uninstall  remove everything this script installed
#
# Run it as your normal user from the plugin folder
# (~/.config/omarchy/plugins/blacksheep.wireguard); it calls sudo where it
# needs to. Re-run it after `omarchy plugin update`, because the root-owned
# copies in /usr/local/bin do not update themselves.
#
# What it installs, all root-owned:
#   /usr/local/bin/wg-toggle, wg-ssid-apply          0755
#   /etc/NetworkManager/dispatcher.d/90-wireguard-ssid 0755
#   /etc/sudoers.d/99-wg-toggle                      0440, checked by visudo
#   /etc/wg-ssid/trusted                             0644, the networks you enter
#   /var/lib/wg-ssid/override                        0644, auto|on|off
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

SCRIPTS=(wg-toggle wg-ssid-apply)
DISPATCH=90-wireguard-ssid
SUDOERS=99-wg-toggle
TRUSTED_FILE=/etc/wg-ssid/trusted
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
    if sudo -n -l -l /usr/local/bin/$verb 2>/dev/null | grep -q '!authenticate'; then
      ok "sudo -n $verb"
    else
      bad "sudo -n $verb"
    fi
  done
}

# ---------------------------------------------------------------- check mode

if [[ $MODE == check ]]; then
  echo "==> Scripts"
  for f in "${SCRIPTS[@]}"; do
    [[ -x /usr/local/bin/$f ]] && ok "/usr/local/bin/$f" || bad "/usr/local/bin/$f missing"
    [[ -x /usr/local/bin/$f ]] && ! cmp -s "system/bin/$f" "/usr/local/bin/$f" &&
      bad "/usr/local/bin/$f differs from this plugin's copy — re-run install.sh"
  done
  echo "==> Dispatcher"
  [[ -x /etc/NetworkManager/dispatcher.d/$DISPATCH ]] && ok "$DISPATCH" || bad "$DISPATCH missing"
  echo "==> Trusted Wi-Fi"
  if [[ -r $TRUSTED_FILE ]]; then
    n=$(trusted_count)
    ((n > 0)) && ok "$TRUSTED_FILE: $n network(s)" ||
      bad "$TRUSTED_FILE lists no networks: the tunnel comes up on every Wi-Fi network"
  else
    bad "$TRUSTED_FILE missing: the tunnel comes up on every Wi-Fi network"
  fi
  echo "==> Tunnel config"
  # /etc/wireguard is 0700 root, so an unprivileged test cannot tell "absent"
  # from "unreadable". Say so rather than report a key that is really there.
  if sudo -n test -f /etc/wireguard/wg0.conf 2>/dev/null; then
    ok "/etc/wireguard/wg0.conf"
  else
    echo "  ?    /etc/wireguard/wg0.conf — cannot tell without a password; check with:"
    echo "         sudo test -f /etc/wireguard/wg0.conf && echo present"
  fi
  echo "==> Passwordless verbs"
  check_verbs
  exit 0
fi

# ------------------------------------------------------------ uninstall mode

if [[ $MODE == uninstall ]]; then
  echo "==> Bringing the tunnel down"
  sudo wg-quick down wg0 2>/dev/null && ok "wg0 down" || ok "wg0 was not up"
  echo "==> Removing"
  sudo rm -f "/etc/sudoers.d/$SUDOERS" && ok "/etc/sudoers.d/$SUDOERS"
  sudo rm -f "/etc/NetworkManager/dispatcher.d/$DISPATCH" && ok "$DISPATCH"
  for f in "${SCRIPTS[@]}"; do
    sudo rm -f "/usr/local/bin/$f" && ok "/usr/local/bin/$f"
  done
  sudo rm -rf /var/lib/wg-ssid /run/wg-ssid && ok "state"
  cat <<'LEFT'

Left in place, because they are yours rather than this plugin's:
  /etc/wg-ssid/trusted        your trusted networks   (sudo rm -r /etc/wg-ssid)
  /etc/wireguard/wg0.conf     your tunnel and its key
  the wireguard-tools package

Then remove the widget itself:
  omarchy plugin remove blacksheep.wireguard
LEFT
  exit 0
fi

# ------------------------------------------------------------------ packages

echo "==> Packages"
omarchy pkg add wireguard-tools 2>/dev/null ||
  sudo pacman -S --needed --noconfirm wireguard-tools
ok "wireguard-tools"

# ----------------------------------------------------------- trusted Wi-Fi

# Written before the dispatcher is installed, so the policy never runs against a
# missing list. Nothing is built in: with no trusted networks the tunnel comes up
# on every Wi-Fi network, which is the safe default for a VPN.
echo "==> Trusted Wi-Fi networks (the tunnel stays down on these)"
if [[ -f $TRUSTED_FILE ]]; then
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
  tmp=$(mktemp)
  { cat system/examples/wg-ssid-trusted; printf '%s\n' "${names[@]}"; } >"$tmp"
  sudo install -D -o root -g root -m 0644 "$tmp" "$TRUSTED_FILE"
  rm -f "$tmp"
  if ((${#names[@]})); then
    ok "$TRUSTED_FILE: ${#names[@]} network(s)"
  else
    echo "  WARN no trusted networks: the tunnel will come up on every Wi-Fi network."
    echo "       Trust one later from the panel, or: sudoedit $TRUSTED_FILE"
  fi
fi

# ------------------------------------------------------------------- scripts

echo "==> Scripts"
for f in "${SCRIPTS[@]}"; do
  sudo install -o root -g root -m 0755 "system/bin/$f" "/usr/local/bin/$f"
  ok "/usr/local/bin/$f"
done
sudo install -o root -g root -m 0755 "system/dispatcher.d/$DISPATCH" \
  "/etc/NetworkManager/dispatcher.d/$DISPATCH"
ok "/etc/NetworkManager/dispatcher.d/$DISPATCH"

# ------------------------------------------------------------------- sudoers

# Never install a sudoers file that does not parse: a broken drop-in locks sudo
# out entirely, and there is no second chance on a machine with no root shell.
echo "==> Sudoers rule for '$USER'"
tmp=$(mktemp)
sed "s/@USER@/$USER/g" "system/sudoers.d/$SUDOERS" >"$tmp"
sudo install -o root -g root -m 0440 "$tmp" "/etc/sudoers.d/.$SUDOERS.new"
rm -f "$tmp"
if sudo visudo -c -f "/etc/sudoers.d/.$SUDOERS.new" >/dev/null; then
  sudo mv "/etc/sudoers.d/.$SUDOERS.new" "/etc/sudoers.d/$SUDOERS"
  ok "/etc/sudoers.d/$SUDOERS"
else
  sudo rm -f "/etc/sudoers.d/.$SUDOERS.new"
  echo "sudoers rule failed validation; nothing installed" >&2
  exit 1
fi

# --------------------------------------------------------------------- state

echo "==> State"
# World-readable: the bar runs unprivileged and reads it to draw the widget.
sudo install -d -o root -g root -m 0755 /var/lib/wg-ssid
[[ -f /var/lib/wg-ssid/override ]] ||
  echo auto | sudo tee /var/lib/wg-ssid/override >/dev/null
sudo chmod 0644 /var/lib/wg-ssid/override
ok "/var/lib/wg-ssid/override: $(cat /var/lib/wg-ssid/override)"

# ------------------------------------------------------------------ the key

echo "==> Tunnel config"
if sudo test -f /etc/wireguard/wg0.conf; then
  ok "/etc/wireguard/wg0.conf present"
else
  echo "  /etc/wireguard/wg0.conf is missing — it holds your tunnel's private key."
  echo "  Write it from system/examples/wg0.conf.example, then:"
  echo "    sudo install -o root -g root -m 0600 wg0.conf /etc/wireguard/wg0.conf"
fi

# ------------------------------------------------------------------ checking

echo
echo "==> Checking"
check_verbs
echo
echo "  wireguard-stats: $(scripts/wireguard-stats)"
cat <<'NEXT'

If any verb above says FAIL, look at what else is in /etc/sudoers.d: sudo
applies the LAST matching rule, so a file that sorts after 99-wg-toggle and
grants the same commands with a password wins over this one.

If the widget is not on the bar yet:
  omarchy plugin enable blacksheep.wireguard
NEXT
