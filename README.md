# WireGuard — an Omarchy bar widget

Tunnel state in the bar, and a panel with live throughput, handshake age, peer
endpoint, a connect/disconnect switch, and the list of trusted Wi-Fi networks
where the tunnel stays down. On every other Wi-Fi network the tunnel comes up
by itself.

Follows the Wi-Fi widget convention: always visible, monochrome, and the same
shield glyph struck through when the tunnel is not carrying traffic. Colour is
reserved for a genuine fault.

Installs as the bar widget `blacksheep.wireguard`.

## What you need

- A WireGuard server and a client config for this machine, `/etc/wireguard/wg0.conf`.
  Many home routers (UniFi, OPNsense, pfSense, Fritz!Box) export one.
  [`system/examples/wg0.conf.example`](system/examples/wg0.conf.example) shows
  the shape. Give each machine its own keypair.
- NetworkManager, which Omarchy uses already.

## Install

The widget is only the UI. Switching the tunnel and following your Wi-Fi need
root, so a small privileged half ships in `system/` and `install.sh` puts it in
place. Read it first: it is short, and every file it installs is listed at the
top.

```bash
# 1. The widget
omarchy plugin add https://github.com/jonspinks/omarchy-wireguard --enable

# 2. Its privileged half. Asks for your trusted Wi-Fi networks: at least the
#    one your VPN server is on.
~/.config/omarchy/plugins/blacksheep.wireguard/install.sh

# 3. Your tunnel config, if it isn't there yet
sudo install -o root -g root -m 0600 wg0.conf /etc/wireguard/wg0.conf

omarchy restart shell
```

`install.sh --check` reports what is in place and changes nothing.

## Update

```bash
omarchy plugin update blacksheep.wireguard
~/.config/omarchy/plugins/blacksheep.wireguard/install.sh   # refresh the root-owned copies
```

`install.sh --check` says when an installed script differs from the plugin's.

## Remove

```bash
~/.config/omarchy/plugins/blacksheep.wireguard/install.sh --uninstall
omarchy plugin remove blacksheep.wireguard
omarchy restart shell
```

`--uninstall` brings the tunnel down and removes every file `install.sh` put in
place. It leaves `/etc/wg-ssid/trusted`, `/etc/wireguard/wg0.conf` and the
`wireguard-tools` package, because those are yours; it prints how to remove them.

## How it works

`90-wireguard-ssid`, a NetworkManager dispatcher script, runs on every network
change. It decides up or down from the current SSID and hands off to
`wg-ssid-apply` through a transient `systemd-run` unit: the apply script waits
up to 10 s for a handshake, and a dispatcher that blocks that long stalls
NetworkManager's queue for everything else.

**Trusted networks run bare.** Usually that means the network your VPN server is
on: connecting from inside it asks the router to hairpin its own public address,
which most home routers cannot do, so the handshake never lands.

`wg-ssid-apply` refuses to strand the machine. A tunnel whose handshake never
arrives still owns its routes and blackholes traffic, so after 10 s with no
handshake it tears the tunnel back down, including one that was forced on.

`wg-toggle` is the manual override the panel calls (`toggle`, `on`, `off`,
`auto`), stored in `/var/lib/wg-ssid/override`. A manual choice outranks the
Wi-Fi policy in both directions; `auto` hands the decision back.

The panel's **Trusted networks** section lists the networks, removes one with
its ⊗ button, and **Trust <network>** (key `t`) adds the network you are on.
Changes apply at once in automatic mode; a forced on or off is left alone. The
list is `/etc/wg-ssid/trusted`, one SSID per line, and `sudoedit` works too.
**An empty list means no network is trusted**, so the tunnel comes up on every
Wi-Fi network: the safe default for a VPN.

## Privilege model

The bar runs as you. It reads state from world-readable files
(`/var/lib/wg-ssid/override`, `/run/wg-ssid/last-result`,
`/sys/class/net/wg0/statistics/`) through `scripts/wireguard-stats`, which runs
from the plugin folder as a fixed command.

Everything that needs root goes through one `sudoers` drop-in,
[`system/sudoers.d/99-wg-toggle`](system/sudoers.d/99-wg-toggle), which lists
every command with its exact arguments and has **no wildcards**:

- `wg-toggle toggle|on|off|auto` — switch the tunnel.
- `wg-toggle trust` — takes no name, so it can only add the network the machine
  is connected to. Nothing can quietly trust an arbitrary network.
- `wg-toggle untrust` — reads the one name from stdin, not argv, and deletes
  only an exact existing entry. The worst a misuse can do is make the tunnel
  come up *more* often.
- `wg show wg0 latest-handshakes|endpoints|transfer` — read-only status. It
  never prints the private key.

The scripts it grants are installed root-owned in `/usr/local/bin`, never run
from the plugin folder, so nothing you can write is ever run as root. They keep
their state and locks in root-owned directories, never in a shared temporary
one. `install.sh` fills in your account name, validates the drop-in with
`visudo -c` in a temporary location and only then moves it into place: a
sudoers file that does not parse locks sudo out entirely.

The drop-in is named `99-` because sudo applies the **last** matching rule, so a
blanket `%wheel ALL=(ALL:ALL) ALL` sorting after it would bring the password
prompt back.

## License

MIT — see [LICENSE](LICENSE).
