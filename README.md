# omarchy-wiz

Control a WiZ bulb from the Omarchy bar. Power, brightness, white temperature, color, and scenes, all over the bulb's local UDP API. No cloud, no account.

- Click: open the light panel
- Right-click: switch the bulb on or off
- Scroll: brightness

In the panel:

- **Saved:** `+` saves the current look (brightness plus white, color or scene). Click a row to apply it, hover it to remove it. The row matching the light is highlighted. Presets live in `~/.config/omarchy-wiz/presets.json`.
- **Brightness and White:** drag the slider, or click the number and type a value, then Enter.
- **Color:** click or drag on the pad. Left to right picks the hue, top to bottom fades to white. Click the hex code to type one (`#7a3cff`, `7a3cff` or `#a3f`).
- **Scenes:** the active scene is highlighted.

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

Add the plugin while you are on your home network. With the setting empty, the first lookup picks the one bulb that accepts local control and saves it, along with your router, in `~/.cache/omarchy-wiz/`. After that the widget only talks to that bulb and only searches for it behind that router. On any other network it shows "bulb not on this network" and sends nothing. If several bulbs accept local control, set your bulb's MAC in the widget settings. To pair a different bulb, or after replacing your router, delete `~/.cache/omarchy-wiz/` while at home.

To list the bulbs on your network:

```sh
python3 ~/.config/omarchy/plugins/mohak34.wiz/wiz.py discover
```

## Remove

```sh
omarchy plugin remove mohak34.wiz
```
