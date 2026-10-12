# omarchy-wiz

Control a WiZ bulb from the Omarchy bar. Power, brightness, white temperature, color, and scenes, all over the bulb's local UDP API. No cloud, no account.

- Click: open the light panel
- Right-click: switch the bulb on or off
- Scroll: brightness

## Requirements

- Omarchy 4 (Quattro shell)
- In the WiZ app: Settings > Current home > Security > Local communication > **All controls**. In "Only verified controls" mode the bulb rejects every command from outside the WiZ app.

## Install

From the Omarchy menu: Setup > Plugins > Add Plugin, paste `https://github.com/mohak34/omarchy-wiz.git`, then Enable Plugin. Or:

```sh
omarchy plugin add https://github.com/mohak34/omarchy-wiz.git --yes
omarchy plugin enable mohak34.wiz
```

Nothing to build. The widget runs `wiz.py`, a standard-library Python script that sends one command and exits, so nothing stays running between clicks. While the panel is closed it checks the bulb once a minute at its last known address and never scans the network.

## Configure

With the setting empty, the helper picks the one bulb on the network that accepts local control and caches its address in `~/.cache/omarchy-wiz/`. If several do, set the bulb's MAC in the widget settings. To list the bulbs on your network:

```sh
python3 ~/.config/omarchy/plugins/mohak34.wiz/wiz.py discover
```

## Remove

```sh
omarchy plugin remove mohak34.wiz
```
