# Investigation Report: ROME II Defensive Artillery Targeting Failure

## Purpose

This report records the evidence behind **Manual Fire Defensive Siege Weapons**
and, especially, the approaches that did not work. It is intended for modders
who want to improve the workaround without repeating the same experiments.

The investigation concerned wall-mounted Bastion Scorpions, Ballistae and
Onagers in Total War: ROME II. The original theory was that the wall or
battlement blocked the Scorpion's low firing origin. Live testing showed a
broader problem: all three weapon families could finish loading and reach the
ready state, yet refuse to release a shot at a live enemy unit.

This is a condensed report rather than a complete development diary. Temporary
installation paths, local tooling state, experimental hashes and repetitive
packaging notes have been omitted.

## Findings at a glance

The evidence supports these conclusions:

1. The common failure occurs in the building-mounted live-unit target path,
   before projectile creation and the final fire transition.
2. The weapons can physically fire from their emplacements. First-person fire
   and Alt-click location fire both work.
3. Changing projectile trajectory, substituting field weapon/projectile data,
   and even substituting a complete field artillery engine did not repair live
   unit targeting.
4. A scripted `unit_controller:attack_unit()` call reaches the same broken
   path and also fails to produce a shot.
5. A native `unit_controller:attack_location()` order bypasses the failure and
   produces ordinary animations, ammunition use and projectiles.
6. Mountable defensive artillery is exposed separately from ordinary army
   units. It does not emit the ordinary unit-selection callback used during the
   investigation.
7. Script controllers must be released after submitting an order. Otherwise
   the affected emplacement can remain unselectable.
8. Frequent location updates disrupt selection, aiming and reload progress.
   The released four-second sampling and 15-metre movement threshold are a
   stability compromise, not a computational limitation.

The exact internal predicate that rejects the live target remains unknown.
ROME II exposes no result code or packfile field for that validation. The
description "engine-side live-unit targeting failure" is therefore a boundary
established by evidence, not a claim that the relevant engine source has been
inspected.

## Observable failure

The common live behavior was:

1. A Bastion Scorpion, Ballista or Onager was given a valid enemy target.
2. The target was within the displayed firing sector and outside the weapon's
   minimum range where applicable.
3. The weapon aimed or faced the general target direction.
4. Its loading/ready animation completed.
5. It stopped without releasing the shot and retained full ammunition.

Three observations separated this from a universally blocked muzzle or broken
fire animation:

- First-person/manual control released shots successfully.
- Alt-click ground fire released shots successfully.
- A scripted native location order later released shots from every in-range
  defensive weapon in the test settlement.

Manual and location fire exercise the mounted engine, animation, FIRE_POS event
and projectile launch. The common stall therefore happens before those systems
are asked to complete a normal live-unit shot. A Scorpion muzzle may still have
a secondary clearance problem on individual wall assets, but that cannot
explain the shared ready-state stall across all three weapon families.

## Relevant vanilla data

The principal defensive chains are:

| Weapon | Bastion land unit | Battlefield engine | Missile weapon | Projectile | Battle entity |
|---|---|---|---|---|---|
| Scorpion | `Rom_Scorpion_Bastion` | `scorpio_bastion` | `rome_scorpio_bastion` | `bolt_bastion` | `artillery_light` |
| Ballista | `Rom_Ballista_Bastion` | `ballista_medium_bastion` | `rome_ballista_medium_bastion` | `stone_ballista_bastion` | `artillery_ballista_medium` |
| Onager | `Rom_Onager_Bastion` | `onager_bastion` | `rome_onager_bastion` | `rock_bastion` | `artillery_onager` |

Field controls are:

```text
Rom_Scorpion -> scorpio -> rome_scorpio -> bolt
Rom_Ballista -> ballista_medium -> rome_ballista_medium -> stone
Rom_Onager   -> onager -> rome_onager -> rock
```

Relevant tables include:

- `land_units_tables`;
- `battlefield_engines_tables`;
- `missile_weapons_tables`;
- `missile_weapons_to_projectiles_tables`;
- `projectiles_tables`;
- `battle_entities_tables`;
- `mountable_artillery_units_tables`;
- the armed-citizenry and building junction tables that select settlement
  defenders.

The Scorpion bastion and field engines share the engine type, animation table,
model and battle entity. Their engine rows differ principally in key and
missile-weapon reference. Ballista and Onager show the same general pattern,
although their Bastion records use ship-derived models/destruction assets and
are immobile.

The Bastion variants are members of `mountable_artillery_units_tables`; field
artillery is not. This is the common classification that survives complete
field-engine substitution. The table itself contains only a unit key and does
not expose target acquisition, fire authorization, line of sight or crew
ownership settings.

Searches of the available schemas and text data found no shared battle-
artillery field for automatic fire, target acquisition or live-unit line-of-
sight validation. Similarly named fields belonged to campaign agents, audio,
or first-person control. In particular, `first_person_engines.auto_target`
must not be interpreted as a switch for ordinary fire-at-will behavior.

## Models, animation metadata and geometry

The active model path is `warscape_animated` / `warscape_animated_lod`, rather
than the legacy artillery model tables. Relevant assets include:

- Scorpion model:
  `rigidmodels/artillery_and_siege/scorpio/scorpio.rigid_model_v2`;
- medium Ballista and ship Ballista models under
  `rigidmodels/artillery_and_siege/ballista30d_50p*`;
- Onager and ship Onager models under
  `rigidmodels/artillery_and_siege/onager*`;
- animation tables `rome_engine_scorpio`,
  `rome_engine_ballista_medium`, and `rome_engine_onager`;
- their corresponding animation fragments and fire metadata.

The active Scorpion FIRE_POS was decoded as approximately
`(0, 1.43623, 1.33903)` metres from its animation root. The medium Ballista
FIRE_POS was approximately `(0.02406, 3.31717, 3.00891)`.

A ray probe against one decoded squared-bastion asset placed the Scorpion
origin close enough to a crenellation for a shallow forward ray to intersect,
while the Ballista origin cleared it. This keeps low Scorpion clearance as a
credible settlement-specific secondary issue. It does not explain why
Ballista and Onager share the live-target stall or why all three can fire at a
location.

## Unit targets and location targets are different paths

ROME II exposes distinct controller calls:

```lua
controller:attack_unit(target, true, true)
controller:attack_location(position)
```

A right-click on an enemy unit requires the engine to validate a live target,
choose an aim point inside its formation, follow movement and continue
authorizing the target. Alt ground fire supplies fixed world coordinates and
does not require that live-unit validation.

This distinction proved decisive. A target can be visibly within the displayed
range sector while still being rejected by the building-mounted live-unit
path. The range overlay establishes geometric range; it does not establish
that the target object passes every engine-side firing test.

## Experiment summary

The following table condenses the diagnostic sequence. Test names are kept
generic; the original private filenames are not needed to reproduce the work.

| Test | Change or question | Result | What it established |
|---:|---|---|---|
| 1 | Change Bastion projectiles from low to high trajectory sight | No firing | Low-angle trajectory selection is not the common authorization gate. |
| 2 | Route Bastion Scorpion and Ballista through their field missile weapons/projectiles | No firing | Separate Bastion projectile records are not the cause. |
| 3 | Give Roman Bastion Ballista the complete field Ballista engine | No firing | The common failure survives replacement of engine, model, weapon and projectile data; mountable emplacement context remains. |
| 4 | Append a command-conversion shim to the assumed battle entry point | Shim did not load | The assumed entry point was not a reliable mod hook. |
| 5 | Append the shim to the correct shared Lua loader | Loader ran, but `empire_battle` was unavailable | Loading ordinary campaign Lua is insufficient; the battle must be entered as a scripted battle. |
| 6 | Register a campaign-wide battle-script override with `add_custom_battlefield()` | Battle API and command events worked; no artillery selection callback | The campaign bridge works, but mounted guns do not use the ordinary unit-selection callback. |
| 7 | Enumerate `mountable_artillery_item()` directly and issue one location to all mounts | All in-range mounts fired; selection was then locked | Native location orders bypass the bug. A script controller retains ownership unless released. |
| 8 | Release the controller through an assumed battle callback | Callback method was unavailable | Controller lifecycle was correct in principle, but the callback owner was wrong. |
| 9 | Schedule release through CA's `battle_manager` wrapper | Weapons fired and became selectable again | A 500 ms delayed `release_control()` preserves the order and returns player control. |
| 10 | Probe UI state and mount `is_idle()` after commands | UI state was not discriminating; non-idle state sometimes included another mount | `is_idle()` alone cannot safely identify the source emplacement. |
| 11 | Map clicked mountable-artillery cards to flattened mount order | Ballista, Onager and Scorpion mapped correctly | Visible card order matches flattened `mountable_artillery_item()` order in the tested battle. |
| 12 | Add one-mount assignments and four-second/15-metre tracking under a new bridge path | Battle script was never entered | The logic was not falsified; the failure was at custom-battlefield handoff/path selection. |
| 13 | Reuse the previously proven bridge key/path | Complete independent targeting worked | Separate mounts could fire, retain separate targets, release control and accept replacement targets. |
| 14 | Track every two seconds after only one metre of movement | Heavy order churn; selection dropped and firing cycles stalled | Controller reacquisition frequency, rather than arithmetic cost, limits tracking responsiveness. |
| 15 | Replace location orders with scripted `attack_unit()` | API accepted calls but weapons did not fire | Scripted live-unit orders reach the same broken authorization path. |
| 16 | Update only after `ammo_left()` showed a completed shot | Onager tracking worked; source gating rejected other mounts | Shot-aware tracking is viable, but ammunition/source availability was not reliable enough for the release. |
| 17 | Resolve the source from each card's `CurrentState` | Selected state was not exposed reliably; release/assignment regressed | Card `CurrentState` is not a dependable source-selection signal in this UI. |
| 18 | Retain Test 13 stability and predict one four-second movement step ahead | All three tested families tracked independently and hit moving units more effectively | Predictive location tracking improved the workaround without the high-frequency regression. |

## Important negative results

Future work should treat the following routes as already tested unless a new
engine hook or materially different hypothesis is available.

### Projectile and balance data

Changing trajectory sight did not restore firing. Routing through field
weapons and projectiles also failed. No evidence supports changing damage,
range, reload, ammunition or accuracy to solve the authorization problem.
Accuracy changes only alter dispersion around the submitted coordinate; they
cannot make a rejected live target valid or correct a stale coordinate.

### Full field-engine substitution

Replacing the Bastion Ballista's engine reference with the complete field
Ballista engine still did not make the mounted unit fire at a live target. This
is stronger than swapping a projectile: model, mobility, missile weapon and
projectile all changed together while the mounted land-unit/emplacement
context remained.

### Accurate spatial-query switch

Changing the executable's exposed accurate spatial-query option did not repair
the unit-target path. Ground fire continued to work during that test. This
reduces the likelihood that the common bug is a simple choice between the two
exposed obstruction-volume tests.

### Scripted live-unit attack

`unit_controller:attack_unit(target, true, true)` returned without an API error
but did not produce a shot. A script-created controller therefore does not
bypass the faulty live-unit validation. Replacing the working location order
with `attack_unit()` merely restores the original bug.

### Very frequent tracking

The two-second/one-metre experiment successfully submitted many orders but
made the guns repeatedly change state, disrupted selection and prevented most
firing cycles from completing. Modern CPU speed does not remove this limit:
the disruptive operation is repeated controller ownership and order
replacement inside the game simulation.

### UI selected-state scanning

Visible artillery cards did not expose a dependable selected state through the
properties tested. Click events and card position were more useful than later
state inspection. Any replacement mapping system should be proven against
multiple card rows, UI scales and allied armies before the positional mapping
is removed.

## Architecture of the released workaround

The released mod contains no DB or balance changes. Its operation is:

1. A complete vanilla `lua_scripts/all_scripted.lua` is packed with a small
   campaign-loader append.
2. On campaign UI creation, the append uses `game_interface` to register a
   script-only custom battlefield across the campaign map. It supplies no map
   or loading-screen override.
3. The battle script loads `Battle_Script_Header`, creates `empire_battle` and
   CA's `battle_manager`, then registers UI, selection and command handlers.
4. Clicking the Mountable Artillery filter causes visible unit cards to be
   ordered by row and horizontal position.
5. The local alliance's artillery is independently flattened from each army's
   `mountable_artillery_item(index)` collection.
6. A clicked card ordinal, confirmed by the mount becoming non-idle when the
   rejected native order arrives, resolves one source emplacement.
7. The enemy target's current position is submitted to a fresh controller that
   contains only that mount.
8. The controller is released after 500 ms.
9. Each mount keeps its own target assignment. Every four seconds, a new order
   is considered after at least 15 metres of movement since the preceding
   order.
10. Once two samples exist, the target is projected one sample interval ahead,
    with horizontal lead capped at 30 metres.

The first shot uses the target's current position because no velocity sample
exists yet. Prediction assumes constant movement across the latest sample; it
is not a ballistic solver. Vanilla defines `muzzle_velocity = -1` for the
relevant Bastion projectiles, leaving final velocity to the engine and
preventing an exact database-derived flight-time solution.

The opaque legacy custom-battlefield key and internal battle-script path from
the successful bridge experiment are intentionally retained in the release.
Changing the public Lua namespace is safe; changing that proven handoff path
caused the battle script not to run during release testing.

## Validation of the released behavior

The initial predictive test submitted 33 one-mount location orders and logged
33 matching controller releases with no Lua or battle-API errors. Ballista,
Onager and Scorpion all maintained independent assignments. Mean applied leads
were approximately 5.26 m, 5.63 m and 6.08 m respectively during that run.

The final public pack was then tested directly. Its logs recorded:

- three successful battle-script initializations;
- eight player target orders;
- 142 predictive tracking orders;
- 150 matching controller releases;
- no logged errors;
- issued orders for Bastion Ballista, Onager and Scorpion.

This validates the packaged release rather than only an experimental build.

## Polybolos coverage

The script has no weapon-type whitelist. It operates on objects returned by
`mountable_artillery_item()`. Vanilla mountable-artillery data contains
Ballista, Onager, Scorpion and Polybolos families.

The Polybolos chain is:

```text
*_Polybolos_Bastion
  -> polybolos_bastion
  -> rome_polybolos_bastion
  -> arrow_polybolos_bastion
```

Roman, Caesar in Gaul Roman, Greek and Carthaginian Polybolos variants are
present in the mountable table and therefore follow the same script path. They
have not received the same live campaign test, so support is structurally
expected rather than empirically confirmed.

## Known limitations

- The workaround handles explicit player target assignment. It does not repair
  autonomous fire-at-will acquisition.
- AI-controlled defensive artillery is not redirected.
- Main-menu Custom Battle/Skirmish and Historical Battle modes do not pass
  through the campaign bridge.
- Multiplayer and cooperative campaign battles remain untested.
- Source selection depends on the relationship between visible artillery-card
  order and flattened mount order.
- Prediction can miss after sudden stops, turns or routing.
- Vanilla range, minimum range, arc, elevation and obstruction rules still
  apply to the resulting location order.
- The complete vanilla loader path is replaced, so other mods replacing
  `lua_scripts/all_scripted.lua` require a manual merge.

## Useful directions for further work

The most promising improvements are:

1. **A source identity independent of card layout.** Look for a stable UI-to-
   mount identifier, an undocumented selected-mount accessor, or a command
   payload field not exposed by the currently documented wrapper.
2. **A direct entry route for main-menu battles.** The present bridge depends
   on campaign `game_interface:add_custom_battlefield()`.
3. **More informed lead calculation.** Logged firing delay, observed impact
   time, weapon family and target motion could support per-weapon prediction.
   Any change must avoid frequent controller reacquisition.
4. **Polybolos live validation.** Its rapid reload may interact differently
   with the four-second sampling interval.
5. **Optional or bounded diagnostics.** Release logging is useful for support
   but can grow during long campaigns.
6. **Shared-loader compatibility.** A standard merge pattern would reduce
   conflicts with other Rome II script mods that replace `all_scripted.lua`.
7. **Secondary Scorpion clearance testing.** Once a location order is known to
   be issued, compare impacts across wall assets to determine whether the low
   FIRE_POS produces a separate collision problem.

## Reproduction guardrails

When experimenting from the released source:

- keep one behavioral change per test;
- do not change combat statistics when testing command behavior;
- use one mount per controller when testing independent targets;
- always release controller ownership after allowing the order to enter the
  command queue;
- distinguish "the API accepted an order" from "the weapon released a shot";
- distinguish battle-script handoff failures from failures inside the battle
  logic;
- retain a fixed-location control case;
- test Ballista, Onager and Scorpion because a Scorpion-only result cannot
  establish the common failure boundary;
- record whether the weapon fires, consumes ammunition, remains selectable and
  accepts a replacement target.

## External format references

The following projects were useful for checking ROME II formats and active
asset paths:

- [Rusted PackFile Manager](https://github.com/Frodo45127/rpfm)
- [RPFM schemas](https://github.com/Frodo45127/rpfm-schemas)
- [The Asset Editor FIRE_POS definition](https://github.com/donkeyProgramming/TheAssetEditor/blob/master/Shared/GameFiles/AnimationMeta/Definitions/FirePos.cs)
- [The Asset Editor metadata parser](https://github.com/donkeyProgramming/TheAssetEditor/blob/master/Shared/GameFiles/AnimationMeta/Parsing/MetaDataFileParser.cs)

These references describe formats and tools. The diagnosis and workaround in
this project are based on the vanilla data comparisons and live experiments
summarized above.
