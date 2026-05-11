# usbguard plugin for noctalia-shell

Watch USBGuard's IPC stream live and allow/block/reject USB devices from the bar.

## What it does

- Runs `usbguard watch` in the background and parses `PresenceChanged` /
  `PolicyChanged` events into a live device list.
- Bar widget shows a USB icon that turns red when there are blocked devices
  awaiting a decision, with an optional `<blocked>/<total>` badge.
- Click the bar widget to open a panel listing every device known to the
  daemon, with per-row **Allow / Block / Reject** buttons. A "Make decisions
  permanent" toggle controls whether `-p` is passed (writes to `rules.conf`).
- Optional notification (via `pluginApi.notify`, falling back to
  `notify-send`) when a device is inserted in `block` state.

## Requirements

- `usbguard` daemon running (`systemctl enable --now usbguard.service`).
- Your user has IPC access. Confirm:

  ```sh
  usbguard list-devices    # should print without sudo
  ```

  If not:

  ```sh
  sudo usbguard add-user "$USER" \
      --devices=listen,modify \
      --policy=list,modify \
      --exceptions=listen
  sudo systemctl restart usbguard
  ```

- noctalia-shell **3.6.0 or newer** (plugin API).

## Install

```sh
mkdir -p ~/.config/noctalia/plugins
cp -r usbguard ~/.config/noctalia/plugins/
```

Then either restart noctalia or, if you've enabled debug mode
(`NOCTALIA_DEBUG=1` or 8 clicks on the logo in Settings → About), hot reload
picks it up.

## Add to your bar

In noctalia's Settings → Bar, add a widget with id `usbguard` to whichever
section you like (typically `right`, near Tray). Equivalent JSON edit to
`~/.config/noctalia/settings.json`:

```jsonc
{
  "bar": {
    "widgets": {
      "right": [
        // ... your existing widgets ...
        { "id": "usbguard" }
      ]
    }
  }
}
```

## Plugin settings

Settings → Plugins → USBGuard:

| Setting | Default | Notes |
|---|---|---|
| Notify on block | on | Uses noctalia notifications, or `notify-send`. |
| Default permanent | off | If on, the panel's permanent toggle starts checked. |
| Show count badge | on | `<blocked>/<total>` when any are blocked, else `<total>`. |
| Hide when empty | off | Hide the bar widget entirely when no devices are tracked. |
| usbguard command | `usbguard` | Override if you need a wrapper like `pkexec usbguard`. |

## Files

```
usbguard/
├── manifest.json
├── Main.qml         # spawns `usbguard watch`, owns the device ListModel
├── BarWidget.qml    # icon + badge in the bar
├── Panel.qml        # device list with per-row allow/block/reject
├── Settings.qml     # settings UI
└── README.md
```

## Troubleshooting

- **Panel says "watch offline"**: the `usbguard watch` process exited and the
  2s restart timer is pending, or the daemon isn't running. Check
  `systemctl status usbguard`.
- **Empty list but devices are plugged in**: confirm `usbguard list-devices`
  works as your user. The plugin uses the same binary.
- **Allow/Block does nothing**: check the noctalia journal (`journalctl
  --user -u noctalia-shell` or stderr of `qs -c noctalia-shell`) — the action
  Process logs stderr from `usbguard`.
- **`PolicyChanged` events double up after an insert**: this is a known
  usbguard quirk (issue #401); the plugin upserts by `id=` so it's harmless.
```
