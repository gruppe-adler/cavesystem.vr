/*
    fn_generateMaze.sqf  --  RSPNCave procedural maze generator

    Builds a fully-connected (perfect, optionally braided) tunnel maze on a
    square grid using the RSPNCave tile set.

    Usage:
        [_origin, _cols, _rows, _params] call CB_fnc_generateMaze;

    Required:
        _origin  : ARRAY  - world pos [x,y,z] of cell (0,0) center.
        _cols    : NUMBER - grid width  (cells along +X / East).
        _rows    : NUMBER - grid height (cells along +Y / North).

    Optional _params (hashmap or namespace of key->value), all defaulted:
        cellSize      : NUMBER - meters per cell. Default: auto-measured from CB_Short.
        seed          : NUMBER - RNG seed for reproducible layouts. Default: random.
        braid         : NUMBER - 0..1, chance to remove a dead-end (adds loops).
                                 0 = perfect maze. Default 0.
        intersectionBias: NUMBER - 0..1, how strongly to favor branching (more
                                 T-junctions) over winding corridors. Default 0.6.
        useLong       : BOOL   - RESERVED. LONG merge disabled under connector-
                                 chaining (Long offsets unmeasured). No-op for now.
        startHeight   : NUMBER - ATL height of the START cell; the cave descends
                                 from here via the tiles' own measured slopes.
                                 May go below terrain. Default: _origin Z.
        append        : BOOL   - keep the previous maze and add to it. Default
                                 false -> the previous maze is wiped first.
        entrance      : BOOL   - place a CB_Entrance02 surface entry. Default true.
        yJunctions    : NUMBER - how many CB_Intersect02 Y-junction hubs to weave
                                 in; arms steer back to maze tunnels (loops). Default 0.

    Returns: ARRAY of all created tile objects (also in CB_MAZE_OBJECTS).

    Depends on fn_mazeHelpers.sqf (must be compiled first).
*/

params [
    ["_origin", objNull],
    ["_cols", 8],
    ["_rows", 8],
    ["_params", createHashMap]
];

if (_origin isEqualType objNull) then {
    _origin = if (isNull player) then { [0,0,0] } else { getPosATL player };
};

// --- read params with defaults ---------------------------------------------
private _fnGet = {
    params ["_key", "_def"];
    if (_params isEqualType createHashMap) then {
        _params getOrDefault [_key, _def]
    } else { _def };
};

// Measured flush spacing between two snapped CB_Short pieces (editor-verified).
// This is the true center-to-center distance for connected tiles -- NOT the
// bbox length (12.01), which overshoots and causes overlaps. Pass cellSize 0
// to auto-measure from the bbox instead.
private _cellSize       = ["cellSize", 11.148]  call _fnGet;
private _seed           = ["seed", floor random 1e9] call _fnGet;
private _braid          = ["braid", 0]          call _fnGet;
// intersectionBias: 0..1, how strongly the generator favors branching (creating
// T-junctions) over extending corridors. 0 = winding corridors, 1 = many
// intersections / bushy maze. Uses a Prim's-style frontier algorithm.
private _intersectionBias = ["intersectionBias", 0.6] call _fnGet;
// _useLong: reserved -- LONG merge is disabled under connector-chaining until
// CB_Long connector offsets are measured. Accepted but currently a no-op.
private _useLong        = ["useLong", false]    call _fnGet;
// startHeight: ATL height of the START cell -- the highest point the cave
// descends from. The cave slopes/descends naturally from here via the tiles'
// own measured opening heights. May go below terrain. Default = origin Z.
// (Accepts the old name "baseHeight" too.)
private _startHeight    = ["startHeight", ["baseHeight", _origin select 2] call _fnGet] call _fnGet;
// append: keep the previous maze and add to it. Default false -> wipe first.
private _append         = ["append", false]     call _fnGet;
// entrance: place a CB_Entrance02 surface entry at the start cell (forced to be
// a dead-end so the single-opening entrance fits). Default true.
private _entrance       = ["entrance", true]    call _fnGet;
// yJunctions: how many CB_Intersect02 Y-junction hubs to weave in. Each hub's 3
// diagonal arms steer (bent Shorts) back to the nearest maze tunnel, forming
// loops so no arm reveals a dead-end. Default 0.
private _yJunctions     = ["yJunctions", 0]     call _fnGet;

if (!_append) then { call CB_fnc_clearMaze; };

[_seed] call CB_fnc_srandSet;

// ---------------------------------------------------------------------------
// 1. Cell size: defaults to the measured flush spacing; auto-measure only if
//    cellSize <= 0 was passed. (End vertical alignment is handled exactly by
//    its measured connector offset, not by a bbox lift.)
// ---------------------------------------------------------------------------
if (_cellSize <= 0) then {
    private _probe = createVehicle ["CB_Short", [0,0,1000], [], 0, "CAN_COLLIDE"];
    private _bb = boundingBoxReal _probe;
    private _len = (_bb select 1 select 1) - (_bb select 0 select 1);
    private _wid = (_bb select 1 select 0) - (_bb select 0 select 0);
    _cellSize = _len max _wid;
    deleteVehicle _probe;
    diag_log format ["[CB maze] auto cellSize = %1", _cellSize];
};
if (_cellSize <= 0) then { _cellSize = 11.148 };  // last-resort fallback

// ---------------------------------------------------------------------------
// 2. Spanning tree via randomized DFS (recursive backtracker), iterative.
//    links.(col,row) = bitmask of directions linked to neighbors.
// ---------------------------------------------------------------------------
private _idx = { params ["_c","_r"]; _r * _cols + _c };  // cell -> flat index
private _links  = [];
private _visited = [];
for "_i" from 0 to (_cols * _rows - 1) do { _links pushBack 0; _visited pushBack false };

// direction helpers: bit -> [dCol,dRow] and opposite bit
private _dDelta = createHashMapFromArray [
    [1, [0, 1]],   // N -> +row
    [2, [1, 0]],   // E -> +col
    [4, [0,-1]],   // S -> -row
    [8, [-1,0]]    // W -> -col
];
private _opp = createHashMapFromArray [[1,4],[2,8],[4,1],[8,2]];

private _degOf = { params ["_mm"]; (_mm % 2)+(floor(_mm/2)%2)+(floor(_mm/4)%2)+(floor(_mm/8)%2) };

// Prim's-style randomized frontier. Frontier entries: [fromCell, bit, toC, toR].
// intersectionBias decides how often we branch off an already-connected cell
// (degree>=1) vs. extend a corridor (degree 0 frontier endpoint = fresh path).
private _startC = [_cols] call CB_fnc_srandInt;
private _startR = [_rows] call CB_fnc_srandInt;
private _startIdx0 = [_startC,_startR] call _idx;
_visited set [_startIdx0, true];

private _frontier = [];
private _addFrontier = {
    params ["_c","_r"];
    {
        _x params ["_bit"];
        (_dDelta get _bit) params ["_dc","_dr"];
        private _nc = _c + _dc; private _nr = _r + _dr;
        if (_nc >= 0 && _nc < _cols && _nr >= 0 && _nr < _rows
            && {!(_visited select ([_nc,_nr] call _idx))}) then {
            _frontier pushBack [[_c,_r] call _idx, _bit, _nc, _nr];
        };
    } forEach [[1],[2],[4],[8]];
};
[_startC,_startR] call _addFrontier;

while {count _frontier > 0} do {
    // partition frontier into "branching" (from-cell already has a link) and
    // "extending" (from-cell degree 0). Bias the choice between the groups.
    private _branch = [];
    private _extend = [];
    {
        _x params ["_fc"];
        if (([_links select _fc] call _degOf) > 0) then { _branch pushBack _x } else { _extend pushBack _x };
    } forEach _frontier;

    private _pool = _extend;
    if (count _branch > 0 && {count _extend == 0 || (call CB_fnc_srand) < _intersectionBias}) then {
        _pool = _branch;
    };
    if (count _pool == 0) then { _pool = _frontier };

    private _pick = [_pool] call CB_fnc_srandPick;
    _pick params ["_fc","_bit","_nc","_nr"];
    private _ni = [_nc,_nr] call _idx;

    // remove this edge from frontier regardless of outcome
    _frontier = _frontier - [_pick];

    // skip if target already visited, or from-cell is full (degree 3 cap)
    if (!(_visited select _ni) && {([_links select _fc] call _degOf) < 3}) then {
        _links set [_fc, (_links select _fc) + _bit];
        _links set [_ni, (_links select _ni) + (_opp get _bit)];
        _visited set [_ni, true];
        [_nc,_nr] call _addFrontier;
    };
};

// ---------------------------------------------------------------------------
// 2b. Orphan rescue: the degree-3 cap can (rarely) leave a cell unvisited.
//     Connect any such cell to a visited neighbor that still has room (<3),
//     preserving full reachability. Repeat until none remain or stuck.
// ---------------------------------------------------------------------------
private _progress = true;
while {_progress} do {
    _progress = false;
    for "_r" from 0 to (_rows - 1) do {
        for "_c" from 0 to (_cols - 1) do {
            private _ci = [_c,_r] call _idx;
            if (_visited select _ci) then { continue };
            // find a visited neighbor with degree < 3
            {
                _x params ["_bit"];
                (_dDelta get _bit) params ["_dc","_dr"];
                private _nc = _c + _dc; private _nr = _r + _dr;
                if (_nc >= 0 && _nc < _cols && _nr >= 0 && _nr < _rows) then {
                    private _ni = [_nc,_nr] call _idx;
                    if ((_visited select _ni) && {([_links select _ni] call _degOf) < 3}) exitWith {
                        _links set [_ci, (_links select _ci) + _bit];
                        _links set [_ni, (_links select _ni) + (_opp get _bit)];
                        _visited set [_ci, true];
                        _progress = true;
                    };
                };
            } forEach [[1],[2],[4],[8]];
        };
    };
};

// ---------------------------------------------------------------------------
// 3. Optional braiding: remove dead-ends by linking to a random valid neighbor.
//    Never creates a 4-way (caps cells at 3 links).
// ---------------------------------------------------------------------------
if (_braid > 0) then {
    for "_r" from 0 to (_rows - 1) do {
        for "_c" from 0 to (_cols - 1) do {
            private _ci = [_c,_r] call _idx;
            private _m = _links select _ci;
            private _deg = (_m % 2) + (floor(_m/2) % 2) + (floor(_m/4) % 2) + (floor(_m/8) % 2);
            if (_deg == 1 && (call CB_fnc_srand) < _braid) then {
                // candidate neighbors not yet linked and themselves < 3 links
                private _opts = [];
                {
                    _x params ["_bit"];
                    if ((_m / _bit) % 2 < 1) then {       // not already linked this way
                        (_dDelta get _bit) params ["_dc","_dr"];
                        private _nc = _c + _dc; private _nr = _r + _dr;
                        if (_nc >= 0 && _nc < _cols && _nr >= 0 && _nr < _rows) then {
                            private _ni = [_nc,_nr] call _idx;
                            private _nm = _links select _ni;
                            private _ndeg = (_nm % 2)+(floor(_nm/2)%2)+(floor(_nm/4)%2)+(floor(_nm/8)%2);
                            if (_ndeg < 3) then { _opts pushBack [_bit,_ni] };
                        };
                    };
                } forEach [[1],[2],[4],[8]];
                if (count _opts > 0) then {
                    ([_opts] call CB_fnc_srandPick) params ["_bit","_ni"];
                    _links set [_ci, (_links select _ci) + _bit];
                    _links set [_ni, (_links select _ni) + (_opp get _bit)];
                };
            };
        };
    };
};

// ---------------------------------------------------------------------------
// 4. Placement via connector-chaining (BFS over the spanning tree)
//    Each tile is positioned so its entry opening exactly meets its parent's
//    exit opening (using measured connector offsets). Tiles drift off the
//    regular grid -- that's expected; flush meets and correct slopes result.
//    NOTE: LONG merge is disabled here (Long connectors not yet measured);
//          chaining places individual SHORTs instead -> same topology.
// ---------------------------------------------------------------------------
private _placed = 0;
private _skipped = 0;
// _opp and _dDelta are already defined above (spanning-tree section), reuse them.

// per-cell stored world opening points (worldDir -> point); empty = not placed
private _cellOpenings = [];
for "_i" from 0 to (_cols * _rows - 1) do { _cellOpenings pushBack createHashMap };

// helper: choose tile key + yaw for a cell mask; place it anchored so its
// opening facing _entryDir lands at _entryPoint. Root passes _entryDir = 0.
private _placeCell = {
    params ["_cIdx", "_mask", "_entryDir", "_entryPoint", ["_asEntrance", false]];
    private _sel = [_mask] call CB_fnc_yawForExits;
    if (count _sel == 0) exitWith {
        _skipped = _skipped + 1;
        diag_log format ["[CB maze] WARN cell idx %1 mask %2 not representable", _cIdx, _mask];
        createHashMap
    };
    _sel params ["_key","_yaw"];
    // entrance root: swap the dead-end's tile (END) for the ENTRANCE, keeping the
    // same orientation (both open N at dir 0, so the yaw from yawForExits fits).
    if (_asEntrance) then { _key = "ENTRANCE"; };
    (CB_tileTable get _key) params ["_cls"];

    private _res = if (_entryDir == 0) then {
        // root: place origin at _entryPoint directly
        private _obj = createVehicle [_cls, _entryPoint, [], 0, "CAN_COLLIDE"];
        _obj setDir _yaw;
        _obj setPosATL _entryPoint;
        _obj setVectorUp [0,0,1];
        CB_MAZE_OBJECTS pushBack _obj;
        private _opensRel = [_key, _yaw] call CB_fnc_tileOpenings;
        private _wpts = createHashMap;
        // hashmap forEach: _x = key (dir bit), _y = value (offset)
        { _wpts set [_x, _entryPoint vectorAdd _y]; } forEach _opensRel;
        [_obj, _wpts]
    } else {
        [_key, _cls, _yaw, _entryDir, _entryPoint] call CB_fnc_placeChained
    };
    _res params ["_o","_wpts"];
    // CB_End02 is a small cap that stays within ~1 cell, so it doesn't plough
    // through neighbors like the old End01 did -- every dead-end gets capped.
    _placed = _placed + 1;
    _cellOpenings set [_cIdx, _wpts];
    _wpts
};

// If an entrance is wanted, root the BFS at a degree-1 cell (the entrance has a
// single opening). Prefer a perimeter dead-end so the entry faces outward.
if (_entrance) then {
    private _best = -1; private _bestPerim = false;
    for "_r" from 0 to (_rows - 1) do {
        for "_c" from 0 to (_cols - 1) do {
            private _ci = [_c,_r] call _idx;
            if (([_links select _ci] call _degOf) == 1) then {
                private _perim = (_c == 0 || _c == _cols-1 || _r == 0 || _r == _rows-1);
                if (_best < 0 || (_perim && !_bestPerim)) then {
                    _best = _ci; _bestPerim = _perim;
                    _startC = _c; _startR = _r;
                };
            };
        };
    };
};

// BFS from the start cell
private _startIdx = [_startC, _startR] call _idx;
private _startPos = [(_origin select 0) + _startC * _cellSize, (_origin select 1) + _startR * _cellSize, _startHeight];
// root uses ENTRANCE tile when enabled (and the cell is a clean dead-end)
private _rootEntrance = _entrance && {([_links select _startIdx] call _degOf) == 1};
[_startIdx, _links select _startIdx, 0, _startPos, _rootEntrance] call _placeCell;

private _queue = [[_startC, _startR]];
private _done = [];
for "_i" from 0 to (_cols * _rows - 1) do { _done pushBack false };
_done set [_startIdx, true];

while {count _queue > 0} do {
    (_queue deleteAt 0) params ["_c","_r"];
    private _ci = [_c,_r] call _idx;
    private _myOpenings = _cellOpenings select _ci;
    private _mask = _links select _ci;

    // expand each linked neighbor not yet placed
    {
        _x params ["_bit"];
        if ((_mask / _bit) % 2 >= 1) then {       // linked this direction
            (_dDelta get _bit) params ["_dc","_dr"];
            private _nc = _c + _dc; private _nr = _r + _dr;
            if (_nc >= 0 && _nc < _cols && _nr >= 0 && _nr < _rows) then {
                private _ni = [_nc,_nr] call _idx;
                if (!(_done select _ni)) then {
                    _done set [_ni, true];
                    // parent's opening facing _bit is where the child attaches
                    private _attachPt = _myOpenings getOrDefault [_bit, _startPos];
                    private _childEntry = _opp get _bit;   // child opening faces back
                    [_ni, _links select _ni, _childEntry, _attachPt] call _placeCell;
                    _queue pushBack [_nc,_nr];
                };
            };
        };
    } forEach [[1],[2],[4],[8]];
};

// ---------------------------------------------------------------------------
// 5. Y-junction hubs: weave in CB_Intersect02 hubs whose 3 diagonal arms steer
//    back to the nearest maze tunnel, forming loops (no dead-end tell).
// ---------------------------------------------------------------------------
if (_yJunctions > 0) then {
    // collect a target point per placed cell (use its first opening, else center)
    private _targets = [];
    for "_r" from 0 to (_rows - 1) do {
        for "_c" from 0 to (_cols - 1) do {
            private _ci = [_c,_r] call _idx;
            private _ops = _cellOpenings select _ci;
            if (count _ops > 0) then {
                private _pt = (values _ops) select 0;
                _targets pushBack [_pt, _ci, _c, _r];
            };
        };
    };

    // obstacles to avoid = every maze tile placed before the hubs
    private _avoid = +CB_MAZE_OBJECTS;

    private _hubsPlaced = 0;
    for "_h" from 1 to _yJunctions do {
        if (count _targets == 0) exitWith {};
        // pick a random interior cell as the hub spot
        private _spot = selectRandom _targets;
        _spot params ["_hubPt","_hubCi","_hc","_hr"];
        private _hubPos = [(_origin select 0) + _hc * _cellSize,
                           (_origin select 1) + _hr * _cellSize,
                           _hubPt select 2];
        private _yaw = 90 * (floor random 4);
        private _ports = [_hubPos, _yaw, 15] call CB_fnc_placeYJunction;

        // steer each arm toward the nearest tunnel within a TIGHT forward cone,
        // avoiding other tunnels en route. If it can't reach, cap the stub so it
        // looks like any other maze dead-end (no tell).
        {
            _x params ["_armPt","_armHead"];
            private _hx = cos _armHead; private _hy = sin _armHead;
            private _best = []; private _bestD = 1e9;
            {
                _x params ["_tp","_tci"];
                if (_tci != _hubCi) then {
                    private _dx = (_tp select 0) - (_armPt select 0);
                    private _dy = (_tp select 1) - (_armPt select 1);
                    private _d = sqrt (_dx*_dx + _dy*_dy);
                    if (_d > 12 && _d < 60) then {
                        private _cosA = (_dx*_hx + _dy*_hy) / _d;
                        if (_cosA > 0.85 && _d < _bestD) then { _bestD = _d; _best = _tp; };
                    };
                };
            } forEach _targets;

            private _endPt = _armPt; private _endHead = _armHead; private _reached = false;
            if (count _best > 0) then {
                ([_armPt, _armHead, _best, 12, _avoid] call CB_fnc_steerToTarget)
                    params ["_ep","_eh","_rch"];
                _endPt = _ep; _endHead = _eh; _reached = _rch;
            };
            // if the arm didn't merge into a tunnel, cap it like a normal dead-end.
            // End (CB_End02) opens N at dir0 with offset ~[0,7.3]; we want that
            // opening to sit at _endPt facing back along the arm. setDir = -_endHead
            // points the End's local +Y (its opening side) along the arm heading;
            // add 180 so the mouth faces back toward the incoming tunnel.
            if (!_reached) then {
                [_endPt, "CB_End02", ((- _endHead) + 180) mod 360,
                    [-0.204, 7.276, -0.308]] call CB_fnc_placeTile;
            };
        } forEach _ports;
        _hubsPlaced = _hubsPlaced + 1;
    };
    diag_log format ["[CB maze] placed %1 Y-junction hub(s)", _hubsPlaced];
};

diag_log format ["[CB maze] done: %1 tiles placed, %2 skipped, seed %3, %4x%5 cell %6m (connector-chained)",
    _placed, _skipped, _seed, _cols, _rows, _cellSize];

CB_MAZE_OBJECTS
