# Spell Folders for RuneScape: Dragonwilds

A UE4SS Lua mod for RuneScape: Dragonwilds that adds folders to the spell
radial. A folder takes one radial slot and holds up to 11 spells of its own,
so you can keep many more spells within reach.

- Pick a folder in the spell radial (**Q**) and the radial switches to the
  folder's spells straight away. Pick one and the game casts it. The bottom
  slot (7) of every folder is a **Back** button to your own spells.
- A folder is shown by the game's own radial, so it looks and handles exactly
  like a normal page: the same pointer, number keys, rune costs, cooldowns,
  aiming and placing.
- In the Spellbook (**P**) you arrange a folder's spells the same way as a
  normal page, by drag and drop.
- Works with the game's spells and with custom spells from the
  [Spell Framework](https://github.com/MichaelRyan2319/RSDragonwilds-SpellFramework)
  (which this mod does not need).
- Works in your own world (single player, or as the host).
- Your saves stay valid with or without the mod (see "Saves" below).
- Doesn't change any world settings, so achievements keep working.

Built for game build 26162923 (Unreal Engine 5.6) with UE4SS v3.0.1.

## Requirements

- [UE4SS for RuneScape: Dragonwilds](https://github.com/MichaelRyan2319/RSDragonwilds-UE4SS).
  Any other UE4SS v3 install works too.

## Install with Mod Loader

[Mod Loader](https://github.com/MichaelRyan2319/ModLoader) installs the mod and
keeps it up to date.

1. **Add game** and pick RuneScape: Dragonwilds. Mod Loader 1.0.1 or later sets
   the mods folder to the game's inner `RSDragonwilds` folder (the one with
   `Binaries` and `Content` in it). If you added the game with an older version,
   edit it and choose that folder.
2. **Add mod** `MichaelRyan2319/RSDragonwilds-SpellFolders`. The mod needs
   UE4SS, so Mod Loader 1.1.0 or later offers to add
   `MichaelRyan2319/RSDragonwilds-UE4SS` as well; click **Yes**. With an older
   Mod Loader, add `MichaelRyan2319/RSDragonwilds-UE4SS` yourself first.
3. Start the game, load your world, press P and scroll the spell list down to
   **Spell Folders**.

## Install by hand

1. Install UE4SS (see Requirements).
2. Download `SpellFolders.zip` from the [Releases](../../releases) page.
   In Steam, right-click RuneScape: Dragonwilds > Manage > Browse local files,
   then open the `RSDragonwilds` folder (the one with `Binaries` and `Content`
   in it) and extract the zip there. The mod ends up in
   `Binaries\Win64\ue4ss\Mods\SpellFolders`.
3. Start the game and load your world.

The mod folder contains `enabled.txt`, so UE4SS loads it without any change to
`mods.txt`. To install from this repo instead of a release, copy the
`SpellFolders` folder into `Win64\ue4ss\Mods\`.

## Using it

**Put a folder in the radial.** Press **P** to open the Spellbook and scroll the
spell list down to **Spell Folders**. Drag a folder into a slot of the radial,
like a spell. There are eight folders.

**Fill and arrange a folder.** In the Spellbook, point at the folder in the
radial and press **O**. The radial now shows the folder's spells, and its title
shows the folder's name. Arrange it like any page:

- drag spells in from the list;
- drag spells from one slot to another;
- remove a spell the way you remove one from a normal page.

Press **O** again to close the folder. It also closes when you change page or
leave the Spellbook. While a folder is open:

- **I** changes the folder's picture (twelve book pictures);
- **R** renames it. The Spellbook closes while you type and opens again after.

A quicker way to add one spell: drag it from the list onto a closed folder.

(Don't right-click a folder to open it: in the game, a right-click takes a
spell out of its slot.)

**Cast from a folder.** Press **Q**, pick the folder, and the radial switches to
the folder's spells. Pick a spell to cast it, or close the radial to cast
nothing. Your normal page is back the next time you open the radial.

The bottom slot of an open folder (slot 7, so the **7** key works too) is a
**Back** button: it takes you straight back to your own spells with the radial
still open. That slot is reserved in every folder, so a folder holds 11 spells.

Pressing **P** while a folder is open in the radial opens the Spellbook on that
folder, ready to arrange.

A folder can't hold another folder.

## Settings

Edit `Win64\ue4ss\Mods\SpellFolders\Scripts\config.lua` in Notepad, then restart
the game.

| Setting | Default | What it does |
| --- | --- | --- |
| `Folders` | `8` | How many folders the Spellbook offers (1 to 24) |
| `BackButton` | `true` | The bottom slot of an open folder is a Back button; `false` gives folders 12 spells and no button |
| `BackIcon` | an arrow | Texture for the Back button |
| `CategoryName` | `"SPELL FOLDERS"` | Name of the Spellbook category |
| `CategoryIcon` | `""` | Texture for that category; empty uses the Magic skill's icon |
| `DebugLogging` | `false` | More detail in the log |

An update replaces `config.lua`, so change it again after an update.

## Saves

The game refuses to load a character whose save contains a spell it doesn't
know, so a folder is never saved under an ID of its own. It borrows the save ID
of Siphon Runes, a spell everyone has. The mod keeps your folders (names,
pictures, spells) and the radial slots they are in in its own file,
`saved_<character>.txt`, in the mod folder.

While a folder is open, its spells sit in the radial page the folder is on, and
the page is put back when the folder closes. If the game stops while a folder
is open, the mod puts the page back the next time you load the character.

If you remove the mod, the slots that held folders show Siphon Runes, and your
character loads normally.

## Achievements

The game skips achievement unlocks only in Creative and Custom worlds. This mod
never touches the world's mode or settings. The game's mod check (`CheckForMods`)
only logs a warning and marks the world as modded for people joining; it doesn't
block achievements.

## Troubleshooting

The log is `Win64\ue4ss\UE4SS.log`. Lines from this mod start with
`[SpellFolders]`. Set `DebugLogging = true` in `config.lua` for more detail.

## Uninstall

Delete `Win64\ue4ss\Mods\SpellFolders`, or remove it in Mod Loader.

## Credits

UE4SS is made by the UE4SS team ([RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS),
MIT licence).
