# RSPNCave Maze Generator (Arma 3 / SQF)

Procedurally builds a fully-connected tunnel maze at runtime from the **RSPNCave**
addon tiles (by Liv2Die). Tiles are positioned by exact **connector-chaining**, so
tunnels meet flush and the cave descends naturally with the tiles' built-in slope.

## Files
- `fn_mazeHelpers.sqf` — RNG, tile/connector tables, rotation + placement helpers,
  `CB_fnc_clearMaze`, Y-junction helpers.
- `fn_generateMaze.sqf` — `CB_fnc_generateMaze` (the main generator).
- `init.sqf` — compiles both into `CB_fnc_generateMaze` / `CB_fnc_clearMaze`.

## Quick start
```sqf
// 10x10 maze in front of the player, starting 30m up (cave descends from there)
[player getPos [40, getDir player], 10, 10,
    createHashMapFromArray [["startHeight", 30], ["intersectionBias", 0.7]]
] call CB_fnc_generateMaze;

call CB_fnc_clearMaze;     // wipe it
```

## `CB_fnc_generateMaze`
`[_origin, _cols, _rows, _params] call CB_fnc_generateMaze`

- `_origin` — world pos of grid cell (0,0). Defaults to player pos.
- `_cols`, `_rows` — grid dimensions (overall size).
- `_params` — hashmap, all optional:

| key | default | meaning |
|-----|---------|---------|
| `cellSize` | 11.148 | meters/cell (measured flush spacing). Pass 0 to auto-measure bbox. |
| `seed` | random | reproducible layout (self-contained LCG). |
| `braid` | 0 | 0..1 chance to remove a dead-end (adds loops). 0 = perfect maze. |
| `intersectionBias` | 0.6 | 0..1 favor branching (more T-junctions). Prim's frontier. |
| `startHeight` | origin Z | ATL height of start cell; cave descends from here. May go below terrain. |
| `append` | false | keep previous maze and add to it (default wipes first). |
| `entrance` | true | place a CB_Entrance02 surface entry at a perimeter dead-end. |
| `yJunctions` | 0 | EXPERIMENTAL. number of CB_Intersect02 Y-junction hubs; arms steer back to maze tunnels (loops). Off by default — arms tend to clip near-level tunnels in dense mazes. |

## How it works
1. **Spanning tree** via Prim's-style randomized frontier (degree capped at 3 — no
   4-way tile exists). Orphan-rescue guarantees every cell is reachable.
2. **Connector-chaining BFS**: each tile is placed so its entry opening lands exactly
   on its parent's exit opening, using measured per-opening offsets. Tiles drift off
   the regular grid; this is what makes connections flush and slopes correct.
3. **Caps**: every dead-end gets a small `CB_End02` cap. The root is a `CB_Entrance02`.

## Tile data (editor-measured, in `fn_mazeHelpers.sqf`)
Direction bits: cardinals `N=1 E=2 S=4 W=8`; diagonals `NE=16 SE=32 SW=64 NW=128`.

| key | class | openings at dir 0 |
|-----|-------|-------------------|
| SHORT | CB_Short | E + W |
| BEND | CB_H90 | W + N |
| TEE | CB_Intersect01 | N + S + W |
| END | CB_End02 | N (small cap) |
| ENTRANCE | CB_Entrance02 | N (opening ~2.9m above origin) |
| H45 | CB_H45 | E + NW (45° deflector; diagonal) |
| LONG | CB_Long | E + W (assumed; merge disabled) |

`CB_connTable` holds each opening's exact local offset. `CB_yJunction` holds
`CB_Intersect02`, a 120° Y-junction whose 3 arms point at non-cardinal angles.

## Y-junction (EXPERIMENTAL — off by default)
`CB_Intersect02` is a 120° Y-junction. `yJunctions` weaves hubs into a maze; each arm
steers (bent Shorts) back toward the nearest tunnel to form a loop. **It works but tends
to clip near-level tunnels in dense mazes** (the descending cave puts crossing tunnels
close-but-not-equal in height, which the collision check tolerates). Left in the code but
defaulted off. For a clean isolated hub, use:
```sqf
call CB_fnc_testYJunction;   // drops a hub + 3 steered arms at player pos (open space)
```
Helpers kept for future work: `CB_fnc_placeYJunction`, `CB_fnc_steerToCardinal`,
`CB_fnc_steerToTarget` (greedy pursuit + bbox collision avoidance), `CB_fnc_placeShortSteer`
(`_overlap` closes wedge gaps on bends).

## Notes / decisions
- **No in-grid 45° jogs**: the H45's real geometry can't return a jog to the grid
  (exit lands ~4.8m off). H45 is reserved for the Y-junction's diagonal arms.
- **No 4-way junctions**: no tile exists; generator caps cell degree at 3.
- **LONG merge disabled**: CB_Long connectors not yet measured.
- HashMap `forEach` convention here: `_x` = key, `_y` = value.
- Rotation: `setDir` is clockwise from North (+Y). Math headings (0=E, CCW) map to
  `setDir = -heading`.
