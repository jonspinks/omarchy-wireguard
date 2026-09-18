# WireGuard — an Omarchy bar widget

Tunnel state in the bar, and a panel with live throughput, handshake age, peer
endpoint, a connect/disconnect switch, and the list of trusted Wi-Fi networks
where the tunnel stays down.

Follows the Wi-Fi widget convention: always visible, monochrome, and the same
shield glyph struck through when the tunnel is not carrying traffic. Colour is
reserved for a genuine fault — `class: "active"` paints the widget in
`bar.urgent`, which looks wrong for an ordinary "on" state.

## Requires a privileged half

This widget is only the UI. It reads
`~/.config/omarchy/bar/scripts/wireguard-stats` and calls
`/usr/local/bin/wg-toggle`, neither of which ships here. Install the `network/`
half of [`omarchy-setup`](https://github.com/jonspinks/omarchy-setup) **first**.
Without it the panel loads but shows nothing and the switch does nothing.

## Install

```bash
# 1. the privileged half
git clone https://github.com/jonspinks/omarchy-setup ~/Projects/omarchy-setup
~/Projects/omarchy-setup/network/install.sh   # asks for your trusted Wi-Fi networks

# 2. this widget
omarchy plugin add https://github.com/jonspinks/omarchy-wireguard --enable
```

Update later with `omarchy plugin update blacksheep.wireguard`.

## Design notes

- The bar runs unprivileged and `wg show` needs `CAP_NET_ADMIN`, so interface
  state and byte counters come from `/sys/class/net/wg0/`. `wg show` only
  enriches the panel when the scoped `sudoers` rule permits it; without it, peer
  and handshake age simply stay unknown.
- **Received** bytes are the honest signal that the peer is answering. A tunnel
  with a dead endpoint still comes up, claims its routes, and transmits forever.
- **Nothing about your networks is built in.** The trusted list lives in
  `/etc/wg-ssid/trusted`. The installer asks for it, and the panel edits it.
  With an empty list, the tunnel comes up on every Wi-Fi network.
- **Trusted networks** in the panel lists them. Remove one with its ⊗ button.
  When you're on an untrusted network, **Trust <network>** adds it (key: `t`).
  The panel can only add the network you're connected to: the privileged
  `wg-toggle trust` takes no name, so nothing can quietly trust an arbitrary
  network. Changes apply straight away in automatic mode. A forced on or off is
  left alone.
- The panel refuses to connect on a trusted network and says why. Trust
  typically means the VPN server is on that network, and tunnelling from there
  asks the router to hairpin its own public address, so the handshake never
  lands. To connect there anyway, remove it from the list.
- If a privileged action fails, the panel shows why under the list. The usual
  cause is an installed sudoers rule that predates the `trust`/`untrust` verbs;
  re-run `network/install.sh`.
