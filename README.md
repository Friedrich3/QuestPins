# QuestPins

Questie-style quest markers for **World of Warcraft: Forever**. Only on the world map, nothing else.

- **Yellow `!`**: quests you can pick up now (blue `!` = repeatable, grey `!` = low level, off by default)
- **Yellow `?`**: where to turn in quests you have completed (off by default, `/qpins turnin`)
- **Objective icons**: where to kill (sword), loot (bag), use objects (gears) or explore (dot) for quests in your log. Finished objectives disappear. (Off by default, `/qpins objectives`.)

Quests you have already completed never get a marker.
- **Small tooltip** on hover: the NPC/object name and the quest name(s) with level, or the objective with its progress.

It does **not** add a quest tracker, change Blizzard's objective tracker, track or untrack quests, add minimap icons, change tooltips or automate anything. It only adds markers to the world map.

## Requirements

QuestPins reads its quest data from the **QuestieDB** addon, the database that Questie uses on Forever. It does not need Questie itself.

1. Install **QuestieDB** (it is included in the Questie download for Forever, or available on its own from <https://github.com/Questie/QuestieDB/releases>).
2. If Questie is installed, **disable Questie** and keep **QuestieDB** enabled. Otherwise you get two sets of markers and Questie's tracker.

## Install

Extract the zip so the folder is `World of Warcraft\_forever_\Interface\AddOns\QuestPins\`. The `QuestPins.toc` file must be directly inside that folder.

## Commands

`/qpins` shows the current settings. Each option toggles on/off:

| Command | What it toggles | Default |
| --- | --- | --- |
| `/qpins toggle` | all markers | on |
| `/qpins available` | quests you can pick up | on |
| `/qpins turnin` | turn-ins of completed quests | off |
| `/qpins incomplete` | turn-ins of quests still in progress (grey `?`) | off |
| `/qpins objectives` | objective areas | off |
| `/qpins trivial` | low-level (grey) quests | off |
| `/qpins repeatable` | repeatable quests | on |
| `/qpins continent` | quest givers and turn-ins on continent maps | on |
| `/qpins continentobjectives` | objectives on continent maps | off |
| `/qpins scale 1.2` | icon size (0.5 to 2) | 1.0 |
| `/qpins reset` | restore defaults | |

## How it decides what to show

- Quest-giver locations come from QuestieDB and are indexed once after login, in the background over a few frames.
- Availability follows the same rules as Questie for Classic content: race and class, level, prerequisites (single and group), exclusive quests, follow-ups, breadcrumbs, parent quests, profession skill, reputation and spells.
- Quests that Questie hides on Forever (removed, duplicate, event, AQ War Effort and invasion quests) are hidden too. The list is generated from Questie's blacklist; see `tools/generate_blacklist.lua`.
- Spawns inside dungeons are shown at the dungeon entrance. Nearby spawns of the same objective are merged into one marker.

## Known limitations

- Quest names come from the game client when it has them, so they follow your client language. NPC and object names come from QuestieDB, which has no Italian translations, so on an Italian client those are in English.
- Coverage of Forever-only content (for example the Skyborne starting zone) is only as complete as QuestieDB's data.
- Seasonal and holiday quests are not shown.

## Development

- `tools/generate_blacklist.lua <Questie checkout> <revision>` regenerates `Data/Blacklist.lua`.
- `tests/headless.lua` runs the addon outside the game against a QuestieDB checkout, using QuestieDB's own Forever emulator and mocked map/quest-log APIs:
  `cd QuestieDB && lua5.1 ../QuestPins/tests/headless.lua ../QuestPins orc` (or `human`).

## Credits and licenses

- QuestPins is licensed under the GNU GPL v3 or later (see `LICENSE`). The quest blacklist in `Data/Blacklist.lua` is derived from Questie (GPL-3.0); quest data is read at runtime from QuestieDB.
- Objective icons (`Icons/*.tga`) come from pfQuest by Shagu, used under the MIT license (`Icons/MIT.txt`), via Questie's redistribution of them.
- The `!` and `?` markers are Blizzard's own textures from the game client.
