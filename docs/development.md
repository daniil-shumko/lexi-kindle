# Developing Lexi

## Layout

| Path | What |
|---|---|
| `lexi.koplugin/main.lua` | KOReader glue: buttons, menu, dialogs, background requests |
| `lexi.koplugin/lexi_prompt.lua` | lookup context and language handling *(pure Lua)* |
| `lexi.koplugin/lexi_presets.lua` | prompt presets: the built-in prompts, custom prompts and their placeholders *(pure)* |
| `lexi.koplugin/lexi_providers.lua` | Claude / OpenAI / backend requests and parsers, model list *(pure)* |
| `lexi.koplugin/lexi_config.lua` | settings: menu value, else `config.lua` *(pure)* |
| `lexi.koplugin/lexi_format.lua` | answer → HTML with bold labels *(pure)* |
| `lexi.koplugin/lexi_store.lua` | saved words and sync state *(pure)* |
| `lexi.koplugin/lexi_cache.lua` | earlier answers, so a word is only paid for once *(pure)* |
| `lexi.koplugin/lexi_setup.lua` | phone setup page and server *(pure except the socket part)* |
| `lexi.koplugin/lexi_native.lua` | Kindle-reader helpers: log/event/window-message parsing, lookup → query *(pure)* |
| `lexi.koplugin/lexi_http.lua`, `lexi_client.lua` | HTTPS via KOReader's LuaSocket/LuaSec |
| `lexi.koplugin/lexi_tls.lua` | certificate host-name checks, which LuaSec doesn't do *(pure)* |
| `lexi.koplugin/config.example.lua` | the optional `config.lua`, documented; `config.lua` itself is git-ignored |
| `lexi.koplugin/lexi_viewer.lua`, `lexi_setupview.lua` | KOReader widgets: answer popup, QR screen |
| `lexi.koplugin/native/lexid.lua` | Kindle-reader bridge daemon |
| `lexi.koplugin/native/lexi.sh` | every on-device action: start/stop/toggle the bridge, phone setup, status |
| `lexi.koplugin/native/cli.lua` | status and phone setup outside KOReader |
| `lexi.koplugin/native/ui.lua` | Lexi's window over the Kindle UI: GTK2 + WebKitGTK 1.0 through LuaJIT's FFI |
| `lexi.koplugin/native/bridge.js` | the pages' side of that window (pillow's `nativeBridge` API) |
| `lexi.koplugin/native/dialog.html`, `setup.html`, `notice.html` | the pages: Ask AI over the reader, the QR code, short notices |
| `scriptlets/` | library items, installed to `documents/` (see [scriptlets](https://kindlemodding.org/kindle-dev/scriptlets.html)) |
| `dev/lexi-dev-ssh.sh` | developer-only library item: starts KOReader's SSH server while KOReader is closed |
| `scripts/` | deploy, package, on-device checks |
| `tests/run.lua` | unit tests |

KOReader only puts a plugin's folder on `package.path` while `main.lua` loads, so `main.lua` requires every module at the top. The daemon and CLI set the path themselves.

## Tests

```bash
luajit tests/run.lua
```

The pure modules are tested directly. The KOReader-dependent files are compile-checked. CI runs the tests, checks shell syntax, compiles every Lua file and builds the release zip.

## Running on a Kindle

You need SSH to the Kindle: KOReader → Network → SSH server, port 2222, key-only with your key in `koreader/settings/SSH/authorized_keys`. It stops when KOReader exits. To work on the Kindle-reader side with KOReader closed, deploy with `WITH_DEV_SSH=1` and tap **Lexi dev: Wi-Fi SSH** in the library: it starts the same server (same port and keys) without KOReader, until the next restart.

```bash
KINDLE_HOST=192.168.1.50 scripts/deploy.sh                   # KOReader SSH (2222)
KINDLE_HOST=192.168.1.50 WITH_DEV_SSH=1 scripts/deploy.sh    # also the dev SSH library item
```

`deploy.sh` runs the tests, copies the plugin (with your `config.lua`, if any) and the library items, and restarts the Kindle-reader bridge if it was running. Restart KOReader to load plugin changes.

## Tools

- **`scripts/device-check.sh [word]`**: runs a real AI request on the Kindle with KOReader's LuaJIT and no UI, and prints the status, latency and answer.
- **`scripts/native-capture.sh start | stop <dir>`**: records LIPC events, D-Bus, the system log, written files and Vocabulary Builder counts while you use Amazon's reader. It redacts Amazon tokens.
- **Screenshots:** `eips_v2 screenshot /mnt/us/shot.png` on firmware 5.16+. Or read `/dev/fb0` (1272×1696, 8-bit gray on a Paperwhite 12th gen) and convert it on your computer.
- **Logs:**
  - the bridge: `/var/tmp/lexi.log`;
  - KOReader: `/mnt/us/koreader/crash.log`;
  - the actions (`native/lexi.sh`): `/var/log/messages` (`grep lexi`);
  - Lexi's window (`native/ui.lua`): its errors and page console messages go to `/var/tmp/lexi.log`.

## Releasing

1. Bump `version` in `lexi.koplugin/_meta.lua` and add a `CHANGELOG.md` entry.
2. Tag and push: `git tag v1.2.3 && git push --tags`. The *Release* workflow builds `dist/lexi-1.2.3.zip` and attaches it to a GitHub release.

`scripts/package.sh` builds the same zip locally. It never includes `config.lua`.
