# Marlin (auto) firmware builder

One small repo that holds **my** printer's Marlin configuration. This makes my life so much easy to build Marlin.
Marlin itself is downloaded from GitHub on demand and thrown away after each build, so
there are no giant firmware trees lying around.

```
marlin-builder/
├── build.sh              # the builder
├── printers/
│   ├── ender3/           # one folder per printer
│   │   ├── Configuration.h
│   │   ├── Configuration_adv.h
│   │   └── printer.conf  # board env + Marlin version + description
│   └── cr10/
│       └── ...
├── output/               # built firmware .hex files land here (git-ignored)
├── .cache/               # downloaded Marlin tarballs, reused (git-ignored)
└── .build/               # transient extracted source (git-ignored)
```

## Usage

```bash
./build.sh                 # interactive menu of printers (includes "all")
./build.sh ender3          # build a specific printer
./build.sh --all           # build every printer, with a pass/fail summary
./build.sh cr10 --version latest   # build against the latest Marlin release
./build.sh --list          # list available printers
./build.sh --help          # all options
```

### Options

| Argument | Description |
|----------|-------------|
| `PRINTER` | Name of a folder under `printers/` to build. Omit for an interactive menu. |
| `all` | Positional alias for `--all` (also selectable from the menu). |
| `-a`, `--all` | Build **every** printer under `printers/`. Continues past failures, prints a pass/fail summary, and exits non-zero if any build failed — safe for scripts/CI. |
| `-v`, `--version VER` | Marlin tag to build (e.g. `2.1.2.8`) or `latest`. Overrides `MARLIN_VERSION` from the printer's `printer.conf`. |
| `-l`, `--list` | List available printers and exit. |
| `-k`, `--keep` | Keep the temporary build tree (`.build/`) instead of deleting it. |
| `-h`, `--help` | Show help and exit. |

> `--all` and a single `PRINTER` name are mutually exclusive. In `--all` mode
> each printer still uses its own `printer.conf` (env + version); a single
> `--version` applies to all of them.

The finished firmware is copied to:

- `output/<printer>-<version>-<timestamp>.hex`  (kept, timestamped)
- `output/<printer>-latest.hex`                 (overwritten each build)

Flash that `.hex` to the board as usual (e.g. via PlatformIO upload, `avrdude`,
or your slicer/host's firmware-update tool).

## Which Marlin version gets built?

Resolved in this order (first one wins):

1. `--version` on the command line
2. `MARLIN_VERSION` in the printer's `printer.conf`
3. `latest` (newest stable GitHub release)

**By default every printer is set to `latest`**, so a newly released Marlin is
picked up automatically — you never have to edit a file when Marlin publishes a
release. `latest` resolves to GitHub's newest *stable* release (betas/pre-releases
are ignored).

> **If a future release breaks the build:** these configs were authored/validated
> against Marlin 2.1.2.8, so a release that bumps `CONFIGURATION_H_VERSION` may
> warn or fail to compile. When that happens, either update the configs for the
> new version, or temporarily pin a working tag — set `MARLIN_VERSION="2.1.2.8"`
> in that printer's `printer.conf`, or build with `--version 2.1.2.8`.

## Adding a new printer

1. Create a folder: `printers/<name>/`
2. Put its `Configuration.h` and `Configuration_adv.h` inside.
3. Add a `printer.conf`:

   ```sh
   DESCRIPTION="My Printer — notes"
   PIO_ENV="melzi_optiboot_optimized"   # PlatformIO env matching the board
   MARLIN_VERSION="2.1.2.8"             # or "latest"
   ```

4. `./build.sh <name>`

Tips for a new board:
- Find the right `PIO_ENV` from the comment next to your board in
  Marlin's `Marlin/src/pins/pins.h` (e.g. `env:melzi_optiboot`).
- On the tight 128 KB AVR boards (Melzi/CR-10/Ender-3), use the
  `*_optimized` env and expect to trim features to fit flash.

## Current printers

| Printer | Board | Notes |
|---------|-------|-------|
| `ender3`    | Creality 1.1.4 (Melzi / ATmega1284P), 235×235×250 | BLTouch + bilinear ABL, bed PID, babystepping |
| `cr10`      | Creality Melzi (ATmega1284P), 300×300×400 | BLTouch + bilinear ABL, bed PID, babystepping |
| `ender5`    | Creality 1.1.x Melzi (ATmega1284P), 220×220×300 | BLTouch + bilinear ABL, bed PID, babystepping |
| `ender5pro` | Creality v1.1.5 silent Melzi (TMC2208 standalone), 220×220×300 | BLTouch + bilinear ABL, bed PID, babystepping |

All use `PIO_ENV=melzi_optiboot_optimized` (Optiboot bootloader, USB @115200),
track the latest stable Marlin release, and share the same feature set (BLTouch, bilinear
auto bed leveling, Z safe homing, bed PID, LCD bed leveling, babystepping),
trimmed to fit the 128 KB flash.

## Automatic builds (GitHub Actions)

`.github/workflows/build.yml` builds every printer in CI. Once this repo is
pushed to GitHub (with Actions enabled) it will:

- **Daily** check for a new Marlin release; if there is one, build all printers
  against it and publish a GitHub Release tagged `marlin-<version>` with every
  `.hex` attached. (Nothing is published if that version was already built.)
- **On push** to `printers/**` or `build.sh`, build all printers to validate
  the change (no release).
- **Manually** via the *Actions → Build firmware → Run workflow* button, where
  you can pick a specific Marlin version.

> Because the configs are pinned/validated for a specific Marlin version, a
> future release that bumps `CONFIGURATION_H_VERSION` may fail the auto-build —
> which is a useful signal that the configs need updating for the new version.

## Requirements

- `bash`, `curl`, `tar`
- [PlatformIO](https://platformio.org/) CLI (`platformio` / `pio` on PATH, or at
  `~/.platformio/penv/bin/platformio`)
