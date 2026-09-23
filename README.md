# Defensive Siege Weapon Targeting Fix

Defensive Siege Weapon Targeting Fix is a script-only Total War: ROME II mod
that works around an engine-side live-unit targeting failure affecting
wall-mounted defensive artillery. It grew from a focused investigation of
Bastion Scorpion, Ballista and Onager behavior.

The release does not change combat balance. It intercepts a player-issued live
unit attack that Rome II refuses to complete and substitutes a native
`attack_location` order at a predicted point along the target's course.

## The failure being worked around

The original symptom was common to Bastion Scorpion, Ballista and Onager:

1. The weapon acquired or faced the general target direction.
2. Its loading/ready animation completed.
3. It stopped without releasing the shot and retained full ammunition.
4. First-person manual fire worked.
5. Alt-click ground fire also worked.

Those observations distinguish the failure from a projectile that immediately
collides with the battlement. The non-first-person engine, animation, muzzle and
projectile path can all release a shot when given a location.

Several narrower data changes were tested and rejected:

- changing low to high projectile trajectory;
- routing Bastion Scorpion and Ballista through their field missile weapons;
- replacing the Bastion Ballista engine with its complete field engine;
- changing the executable's accurate spatial-query option;
- issuing `unit_controller:attack_unit(target, true, true)` from Lua.

The last test is especially important: the native scripted live-unit order was
accepted by the API but still did not fire. In contrast,
`unit_controller:attack_location(position)` fired all in-range defensive
weapons. The defect therefore sits in the live-unit target validation or fire
authorization path shared by mountable defensive artillery.

## Architecture

The mod contains two packed files:

```text
lua_scripts/all_scripted.lua
ian_bastion_test11/battle.lua
```

The internal `ian_bastion_test11` key/path is an opaque legacy bridge ID from
the validated Test 18 build. A live release test showed that replacing it with
the much longer public mod name allowed registration but prevented battle-script
handoff. It is retained for engine compatibility; all Lua variables, functions,
callbacks, logs and public filenames use the generic `mfd_`/`MFD_` namespace.

### 1. Campaign loader bridge

ROME II loads `lua_scripts/all_scripted.lua` in campaign, but that ordinary Lua
state does not directly expose `empire_battle`. The appended loader fragment
waits for `events.UICreated`, obtains `game_interface`, and calls
`add_custom_battlefield()` with:

- a radius large enough to cover the campaign map;
- no loading-screen override;
- no physical battlefield override;
- only `ian_bastion_test11/battle.lua` as the battle script.

This preserves the settlement, armies and generated battle while allowing the
battle-control interfaces to initialize. It also explains why the current
release works in campaign battles but not in main-menu Custom Battle/Skirmish
or Historical Battle modes.

### 2. Mapping a UI card to a mount object

ROME II does not send its ordinary unit-selection callback when a player
selects mountable defensive artillery. The script therefore listens to
`events.ComponentLClickUp`.

When the player opens the Mountable Artillery filter (`cf_buildings`), the
script waits 150 ms for the card panel to redraw, gathers visible components
whose `CallbackId` is `UnitCard`, and sorts them by screen row and X position.
This produces a one-based card ordinal.

At command time, the script independently enumerates every local-alliance
mount through:

```lua
units:mountable_artillery_item(mount_index)
```

The flattened enumeration order matched the visible card order during live
testing. A positional calculation based on card width is retained as a fallback
when a newly drawn card ID is not yet in the map.

The clicked ordinal is combined with `mount:is_idle() == false` immediately
after the player's command. This guards against redirecting an old remembered
mount when an ordinary unit or another emplacement actually produced the
command. If that combined check fails, no substitute order is submitted.

### 3. Converting the rejected command

The raw battle command handler watches only events named `Attack Unit`. It
reads `event:get_unit()` as the desired target and resolves one source
emplacement from the card map.

For a valid source, it creates a fresh controller from the owning army, adds
only that mount, and calls:

```lua
controller:attack_location(target:position())
```

The controller is released after 500 ms. This delay is required: releasing too
early risks losing the submitted order, while failing to release makes the
weapon unselectable for the rest of the battle.

Each successful initial order stores an assignment keyed by mount ordinal, so
different weapons can follow different enemy units.

### 4. Predictive tracking

Every four seconds the tracker samples the current X/Z position of each valid
assigned target. It keeps two different pieces of state:

- `sample_x`/`sample_z`: the immediately preceding sample, used to estimate
  velocity;
- `last_order_x`/`last_order_z`: the target position that triggered the last
  submitted order, used to throttle controller creation.

A new order is issued only after the target has moved at least 15 metres from
the position associated with the preceding order. When that threshold is met,
the projected point is:

```text
movement  = current - previous_sample
projected = current + movement * prediction_intervals
```

`prediction_intervals` is `1.0`, so the default horizon is one four-second
sample. Horizontal lead is capped at 30 metres. The target's current Y
coordinate is copied into the new battle vector.

This is deliberately empirical. The relevant vanilla bastion projectiles use
`muzzle_velocity = -1`, meaning Rome II calculates launch velocity internally;
the database does not expose a reliable per-shot flight time. Full reload time
is also unsuitable as a lead horizon because a weapon may already be loaded
when an update arrives.

More aggressive tracking was tested at two seconds and one metre. It produced
73 successful controller updates but repeatedly disrupted selection, aiming
and reload progress. The four-second/15-metre values are retained because they
were the first settings that kept all three tested weapon families firing and
selectable.

## Investigation report

For the underlying evidence, failed experiments, vanilla data relationships,
and possible directions for further development, see the INVESTIGATION_REPORT.md.

## Vanilla asset and database coverage

The script contains no type-name whitelist. It operates on every local object
returned by `mountable_artillery_item()`. Vanilla
`mountable_artillery_units_tables` contains 54 actual culture-specific records
across four weapon families:

- Bastion Ballista;
- Bastion Onager;
- Bastion Scorpion;
- Bastion Polybolos.

The Polybolos chain, for example, is:

```text
Rom_Polybolos_Bastion / CiG_Rom_Polybolos_Bastion /
Gre_Polybolos_Bastion / Car_Polybolos_Bastion
    -> battlefield_engines: polybolos_bastion
    -> missile_weapons: rome_polybolos_bastion
    -> projectiles: arrow_polybolos_bastion
```

That projectile has low trajectory, zero minimum range, 320 effective range,
engine-calculated muzzle velocity and a five-second base reload. The mod does
not replace or edit any part of this chain.

The tested Bastion projectile records were:

| Family | Projectile | Effective range | Minimum range | Base reload |
|---|---|---:|---:|---:|
| Scorpion | `bolt_bastion` | 400 | 0 | 10 s |
| Ballista | `stone_ballista_bastion` | 460 | 50 | 23 s |
| Onager | `rock_bastion` | 400 | 40 | 20 s |
| Polybolos | `arrow_polybolos_bastion` | 320 | 0 | 5 s |

These values are documented for context and remain vanilla in the pack.

## Status

The release behavior has been exercised in a campaign settlement battle with
Bastion Ballista, Onager and Scorpion. All three accepted independent targets,
fired, received repeated projected aim updates, released script-controller
ownership and remained available for later orders.

The final public pack (SHA-256 `d0effa2b02fb5b5d7cdff957e7947a5a5a452c03e18301102975f3ffcdd82ec9`)
was also tested directly. Its release log records three successful battle-script
initializations, 8 player orders, 142 predictive tracking orders, 150 matching
controller releases and no errors. Ballista, Onager and Scorpion all appear in
those issued orders.

The successful Test 18 log contained:

- 33 submitted one-mount location orders;
- 33 matching controller releases;
- no Lua or battle-API errors;
- 11 Ballista, 8 Onager and 10 Scorpion predictive updates;
- mean applied leads of 5.26 m, 5.63 m and 6.08 m respectively;
- no use of the 30 m lead cap.

Polybolos is structurally covered by the same generic path but has not yet been
observed in a live campaign test.

## Installation

1. Copy `manual_fire_defensive_siege_weapons.pack` into the ROME II `data`
   directory.
2. Enable **Manual Fire Defensive Siege Weapons** in the ROME II Mod Manager.
3. Disable experimental or older versions of this mod.
4. Fully restart ROME II after enabling, disabling or replacing the pack.

The workaround is loaded when a campaign battle starts. It can be added to an
existing campaign; it does not require a new campaign.

## Player use

1. Enter a player-controlled settlement battle from an active campaign.
2. Open the **Mountable Artillery** unit-card filter.
3. Click the card for the desired emplacement.
4. Right-click an enemy unit within its valid firing sector.
5. Repeat for other emplacements if separate targets are desired.

The initial order uses the target's current position because no movement sample
exists yet. Later updates lead a moving target. Selecting an ordinary unit or a
different card filter clears the remembered mount to protect normal commands.

## Limitations

- This is manual target assignment. It does not repair autonomous fire-at-will
  acquisition.
- Only the local player's alliance is enumerated. AI defensive artillery is not
  redirected.
- Main-menu Custom Battle/Skirmish and Historical Battles do not pass through
  the campaign bridge and are not supported.
- Multiplayer and co-op campaign behavior has not been tested.
- The player must select the emplacement through the Mountable Artillery card
  filter for reliable source identification.
- Prediction assumes constant direction and speed across the latest sample.
  Sharp turns, stops and routing can invalidate it until the next update.
- The first shot is not predicted.
- An emplacement must still obey its vanilla range, minimum range, firing arc,
  elevation and physical obstruction rules.

## Compatibility

The mod is script-only and includes no DB tables, models, maps or projectiles.
It nevertheless replaces the complete packed path
`lua_scripts/all_scripted.lua` because ROME II does not support appending to a
packed text file at runtime. Another mod that replaces the same path will
conflict by pack load order.

For compatibility, merge the contents of `source/loader_append.lua` into the
other mod's complete `all_scripted.lua`, then include this mod's battle script
at `ian_bastion_test11/battle.lua`. Campaign-wide
custom-battlefield scripts may also conflict and should be reviewed together.

## Source layout

```text
source/
  loader_append.lua
  manual_fire_defensive_siege_weapons/
    battle.lua
PACK_SHA256.txt
WORKSHOP_DESCRIPTION.txt
README.md
```

`loader_append.lua` intentionally contains only original mod code. It is not a
complete replacement for the vanilla loader.

## Repacking with RPFM

1. Select **ROME II** in RPFM and load the current vanilla dependencies.
2. Export vanilla `lua_scripts/all_scripted.lua` without decoding or editing
   its existing bytes.
3. Append `source/loader_append.lua` to that exported file.
4. Create a new PFH4 pack with type **Mod**.
5. Add the combined loader at `lua_scripts/all_scripted.lua`.
6. Add `source/manual_fire_defensive_siege_weapons/battle.lua` at the internal
   path `ian_bastion_test11/battle.lua`.
7. Save as `manual_fire_defensive_siege_weapons.pack`.
8. Reopen the pack and verify that it contains exactly those two files and that
   the loader begins with an exact copy of the current vanilla loader.

Do not edit `data.pack`, `data_rome2.pack`, or any other vanilla archive.

## Diagnostics and extension points

The release retains direct logs named:

- `manual_fire_defensive_siege_weapons_campaign.log`;
- `manual_fire_defensive_siege_weapons_boot.log`;
- `manual_fire_defensive_siege_weapons_battle.log`.

Useful battle records include `MOUNT_CARD_MAP`, `MOUNT_CARD_SELECTED`,
`SOURCE_RESOLVED`, `TARGET_ASSIGNED`, `ATTACK_LOCATION_ISSUED`,
`TRACK_PREDICTION` and `CONTROL_RELEASED`.

Promising areas for further work include:

- a battle-entry route for main-menu custom/skirmish battles;
- a source-selection method that does not depend on card order;
- AI-controlled emplacement support;
- dynamic lead based on observed firing delay or projectile flight;
- per-weapon prediction multipliers, particularly for rapid-fire Polybolos;
- a shared-loader integration pattern for compatibility with other script mods;
- bounded or optional diagnostic logging for long-running campaigns.

Changes to cadence should be tested conservatively. Controller reacquisition,
not the arithmetic itself, was the expensive behavior in failed high-frequency
experiments.
