# omarchy-wiz

Control a WiZ bulb from the Omarchy bar. Power, brightness, white temperature, color, and scenes, all over the bulb's local UDP API. No cloud, no account.

- Click: open the light panel
- Right-click: switch the bulb on or off
- Scroll: brightness

## Requirements

- Omarchy 4 (Quattro shell)
- Go, to build the helper
- In the WiZ app: Settings > Current home > Security > Local communication > **All controls**. In "Only verified controls" mode the bulb rejects every command from outside the WiZ app.

## Install

```sh
omarchy plugin add https://github.com/mohak34/omarchy-wiz.git --yes
make -C ~/.config/omarchy/plugins/mohak34.wiz
omarchy plugin enable mohak34.wiz
```

The widget runs `bin/wiz`, a small Go helper that sends one command and exits. Nothing stays running between clicks.

## Configure

With the setting empty, the helper picks the one bulb on the network that accepts local control and caches its address in `~/.cache/omarchy-wiz/`. If several do, set the bulb's MAC in the widget settings. To list the bulbs on your network:

```sh
~/.config/omarchy/plugins/mohak34.wiz/bin/wiz discover
```

## Remove

```sh
omarchy plugin remove mohak34.wiz
```
