# WireGuard — an Omarchy bar widget

Tunnel state in the bar, and a panel with live throughput, handshake age, peer
endpoint and a connect/disconnect switch.

Follows the Wi-Fi widget convention: always visible, monochrome, and the same
shield glyph struck through when the tunnel is not carrying traffic. Colour is
reserved for a genuine fault — `class: "active"` paints the widget in
`bar.urgent`, which looks wrong for an ordinary "on" state.

## Requires a privileged half

This widget is only the UI. It reads
`~/.config/omarchy/bar/scripts/wireguard-stats` and calls
`/usr/local/bin/wg-toggle`, neither of which ships here — install
[`omarchy-netconfig`](https://github.com/jonspinks/omarchy-netconfig) **first**.
Without it the panel loads but shows nothing and the switch does nothing.

## Install

```bash
# 1. the privileged half
git clone https://github.com/jonspinks/omarchy-netconfig ~/Projects/omarchy-netconfig
~/Projects/omarchy-netconfig/install.sh

# 2. this widget
omarchy plugin add https://github.com/jonspinks/omarchy-wireguard --enable
```

Update later with `omarchy plugin update jon.wireguard`.

## Design notes

- The bar runs unprivileged and `wg show` needs `CAP_NET_ADMIN`, so interface
  state and byte counters come from `/sys/class/net/wg0/`. `wg show` only
  enriches the panel when the scoped `sudoers` rule permits it; without it, peer
  and handshake age simply stay unknown.
- **Received** bytes are the honest signal that the peer is answering. A tunnel
  with a dead endpoint still comes up, claims its routes, and transmits forever.
- The panel refuses to connect on a trusted SSID and says why: the VPN endpoint
  lives on the home LAN, so tunnelling from there asks the router to hairpin its
  own WAN address and the handshake never lands.
