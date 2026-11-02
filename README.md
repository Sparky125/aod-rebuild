# Army of Darkness Defense: Fan Rebuild

Fan-made port of Army of Darkness Defense (2011), the mobile lane-defense
game, to Godot 4.7. The original stopped working on modern iOS and Android
devices. This rebuild makes it playable again on PC and in the browser.

Unofficial, non-commercial fan project made for preservation. Not affiliated
with the original game's developer/publisher or the film's rights holders.
All trademarks and original assets belong to their respective owners.

## Playing the game

The easiest way to play is on the itch.io page:
https://tucksed0.itch.io/aodrebuild

It runs in the browser (desktop and phones) and has downloadable Windows and
Linux builds.

## Running from source

1. Install [Godot 4.7](https://godotengine.org/download), the standard build
   (not .NET).
2. Import `rebuild/project.godot` from this repository and press F5.

Or from a terminal:

    godot --path rebuild

## Controls

| Input | Action |
|---|---|
| A / D or Arrow Keys | Move Ash |
| 1 - 5 | Summon Troops |
| 6 | Upgrade Smithy |
| Q / E | Cast Spells |
| M | Mute |
| Esc | Pause |

On touch screens, tap or hold the field to move Ash and tap the trays and
plates for everything else.

## Save data (web build)

Saves live in your browser's storage. Safari and other iOS browsers clear
website storage after 7 days of not playing; desktop browsers keep your
save indefinitely. On iPhone the game runs, but home-screen save states
have been finicky: a refresh can drop progress. The desktop and browser
builds are the more reliable options today, and a sideload guide can be
added on request.

## Project layout

- `rebuild/` is the Godot project. `scripts/` holds the gameplay code,
  `data/` the game tables ported from the original, `assets/` the art and
  audio, and `export/` the web shell used for the itch.io build.
- Exported builds and engine caches are not committed.

## Testing

A headless smoke test plays a wave with a bot and exits 0 when the wave is
cleared:

    godot --headless --path rebuild -- --smoke-test

If you change a specific wave, smoke test that wave too:

    godot --headless --path rebuild -- --smoke-test --wave=25

Please include a passing run with any pull request.

## Credits

Special thanks to the original team responsible for the game's development
(credits archived by Mobygames).

| Role | Name |
|---|---|
| Executive Producer | Julian Farrior |
| Technical Director | Dale Thoms |
| Lead Game Designer | Tom Blind |
| Art Director | Ryan Drag |
| Project Manager | Bryan Mashinter |
| Game Programming | Mike Lewandowski, Zack Smith |
| Engine Programming | Justin Larrabee, Kevin Depue |
| Additional Programming | Ambrose Krapacs |
| Game Design | Ben Scott Harper |
| Art | Adam Roark, Tommy Zhou |
| Additional Art | Annie Fodge, Thomas Olson |
| Sound / Music | Aubrey Hodges |
| Special Thanks | Jim Packer, Aaron Berndtson, Juli Logemann, Lucy Lathan, Linda Kim |

## License

The code, tooling, and scripts of this rebuild are released under the MIT
license (see LICENSE). The game's art, audio, and video belong to the
original rights holders and are included solely as part of this
non-commercial preservation project.
