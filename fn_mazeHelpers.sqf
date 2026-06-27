/*
    fn_mazeHelpers.sqf  --  RSPNCave maze generator: shared helpers

    Defines:
        CB_fnc_srandSet    - seed the deterministic RNG
        CB_fnc_srand       - next pseudo-random float in [0,1)
        CB_fnc_srandInt    - next pseudo-random int in [0, n)
        CB_fnc_srandPick   - pick a random element of an array
        CB_tileTable       - per-tile geometry/rotation calibration table
        CB_fnc_rotMask     - rotate a direction bitmask by k*90 deg
        CB_fnc_yawForExits - choose tile key + yaw + pivot for a cell's link mask
        CB_fnc_placeTile   - spawn one tile at a cell, track it for cleanup
        CB_fnc_clearMaze   - delete every tile from the last generation

    Direction encoding (bitmask):
        N = 1  (+Y, world yaw   0)
        E = 2  (+X, world yaw  90)
        S = 4  (-Y, world yaw 180)
        W = 8  (-X, world yaw 270)

    Arma convention: setDir 0 faces +Y (North). Positive yaw turns clockwise (toward East).
*/

// ---------------------------------------------------------------------------
// Deterministic RNG  (self-contained LCG -- no native seeding command needed)
// ---------------------------------------------------------------------------
// A classic linear congruential generator. State is held in CB_RNG_STATE so a
// given seed always reproduces the same maze. Constants from Numerical Recipes
// (modulus 2^32). All math stays well within SQF's double precision.

CB_RNG_STATE = 0;

// Debug flag: set CB_MAZE_DEBUG = true; before generating for verbose steer logs.
if (isNil "CB_MAZE_DEBUG") then { CB_MAZE_DEBUG = false; };

CB_fnc_srandSet = {
    params ["_seed"];
    CB_RNG_STATE = (floor (abs _seed)) mod 4294967296;
};

// next float in [0,1)
CB_fnc_srand = {
    CB_RNG_STATE = (CB_RNG_STATE * 1664525 + 1013904223) mod 4294967296;
    CB_RNG_STATE / 4294967296
};

CB_fnc_srandInt = {
    params ["_n"];
    floor ((call CB_fnc_srand) * _n)
};

CB_fnc_srandPick = {
    params ["_arr"];
    _arr select (floor ((call CB_fnc_srand) * (count _arr)))
};

// ---------------------------------------------------------------------------
// Tile calibration table
//   key -> [classname, baseMask, baseYaw, pivotOffset[x,y,z]]
//     baseMask    = directions the tile opens toward at setDir 0 (bitmask).
//     baseYaw     = extra fixed yaw added so the model sits "straight" in cell.
//     pivotOffset = local (x,y,z) offset (in tile space, before yaw) to center
//                   the tile in its cell. Tune in editor if a tile sits off.
//
//   VERIFIED in editor at dir 0 (bitmask N=1 E=2 S=4 W=8):
//     CB_Short      opens E+W       -> 10
//     CB_End02      opens N         ->  1  (small cap; replaces big CB_End01)
//     CB_H90        opens W+N       ->  9
//     CB_Intersect01 opens N+S+W    -> 13  (stem W, crossbar N-S)
// ---------------------------------------------------------------------------
CB_tileTable = createHashMapFromArray [
    ["END",   ["CB_End02",        1,  0, [0,0,0]]],   // opens N (small cap)
    ["ENTRANCE", ["CB_Entrance02", 1, 0, [0,0,0]]],   // opens N (surface entry; maze starts here)
    ["SHORT", ["CB_Short",       10,  0, [0,0,0]]],   // opens E+W
    ["LONG",  ["CB_Long",        10,  0, [0,0,0]]],   // opens E+W, spans 4 cells
    ["BEND",  ["CB_H90",          9,  0, [0,0,0]]],   // opens W+N (90 deg corner)
    ["TEE",   ["CB_Intersect01", 13,  0, [0,0,0]]],   // opens N+S+W (T)
    // CB_H45 at dir 0: one opening E (cardinal), one opening NW (45 deg diagonal).
    // Lives off the cardinal grid, so baseMask is left 0; the diagonal-jog code
    // (CB_fnc_yawForExits step 6) handles its real geometry separately.
    ["H45",   ["CB_H45",          0,  0, [0,0,0]]]    // 45 deg, cosmetic
];

// ---------------------------------------------------------------------------
// Connector table (for exact connector-chaining placement)
//   key -> hashmap of  directionBit -> openingOffset[x,y,z]  (local, at dir 0)
//   The opening offset is the world point of that mouth relative to the tile
//   origin when the tile is at setDir 0. Two tiles meet flush when one tile's
//   chosen opening point coincides with the other's (with opposite facings).
//
//   Direction bits use an 8-way compass (cardinals + diagonals):
//     E=2(0deg) NE=16(45) N=1(90) NW=128(135) W=8(180) SW=64(225) S=4(270) SE=32(315)
//   (cardinals keep their original values so existing cardinal code is unaffected.)
//
//   Derived from editor-measured flush Short pairs (see chat calibration).
//   STATUS:
//     SHORT  E,W      measured
//     BEND   W,N      measured
//     TEE    N,S,W    measured
//     END    N        measured  (CB_End02, small cap, opens N)
//     H45    E,NW     measured  (45 deg deflector; NW is diagonal)
//     LONG   E,W      assumed = Short offsets scaled along X (verify)
// ---------------------------------------------------------------------------
CB_connTable = createHashMapFromArray [
    ["SHORT", createHashMapFromArray [
        [2, [ 5.574,  0.0365, -0.536]],   // E
        [8, [-5.574, -0.0365,  0.536]]    // W
    ]],
    ["BEND", createHashMapFromArray [
        [8, [-6.332, -3.0525,  0.239]],   // W
        [1, [ 2.790,  6.105,  -0.413]]    // N
    ]],
    ["TEE", createHashMapFromArray [
        [8, [-6.794, -0.9205, -0.142]],   // W
        [1, [ 1.1595, 7.515,  -0.432]],   // N
        [4, [ 3.5515,-7.521,  -0.457]]    // S
    ]],
    ["END", createHashMapFromArray [
        [1, [-0.204,  7.276, -0.308]]     // N (CB_End02, small cap)
    ]],
    ["ENTRANCE", createHashMapFromArray [
        [1, [-0.883,  7.706,  2.861]]     // N (CB_Entrance02; opening ~2.9m above origin)
    ]],
    ["H45", createHashMapFromArray [
        [2,   [ 4.256, -1.227, -0.031]],  // E  (cardinal opening)
        [128, [-2.053,  2.214, -0.033]]   // NW (diagonal opening)
    ]]
    // LONG pending measurement
];

// CB_Intersect02: a 120deg Y-junction whose 3 arms point at NON-cardinal angles.
// Stored separately (the arms don't map to the 8-compass). Each arm is
// [localOffset[x,y,z], headingDeg] at dir 0, headingDeg = world angle the tunnel
// leaves at (0=E, 90=N, CCW). Measured from flush Short pairs.
CB_yJunction = [
    "CB_Intersect02",
    [
        [[-5.921,  9.891, -0.510], 120.9],   // arm a
        [[ 6.294,  5.873, -0.457],  43.0],   // arm b
        [[-1.497, -10.956,-0.469], -97.8]    // arm c
    ]
];

// rotate a CARDINAL direction bitmask clockwise by _steps * 90 deg (N->E->S->W).
// Used by the cardinal grid logic; cardinal bits only (1/2/4/8).
CB_fnc_rotMask = {
    params ["_mask", "_steps"];
    _steps = _steps mod 4;
    for "_i" from 1 to _steps do {
        private _n = 0;
        if (_mask % 2 >= 1)          then { _n = _n + 2 };   // N->E
        if (floor(_mask/2) % 2 >= 1) then { _n = _n + 4 };   // E->S
        if (floor(_mask/4) % 2 >= 1) then { _n = _n + 8 };   // S->W
        if (floor(_mask/8) % 2 >= 1) then { _n = _n + 1 };   // W->N
        _mask = _n;
    };
    _mask
};

// 8-way compass ring, ordered CLOCKWISE from N by 45 deg.
// setDir is clockwise: yaw +45 advances one slot here.
//   N=1, NE=16, E=2, SE=32, S=4, SW=64, W=8, NW=128
CB_DIR8 = [1, 16, 2, 32, 4, 64, 8, 128];

// rotate a single 8-way direction bit clockwise by _yaw degrees (any 45 mult).
CB_fnc_rotDir8 = {
    params ["_bit", "_yaw"];
    private _i = CB_DIR8 find _bit;
    if (_i < 0) exitWith { _bit };          // unknown bit: leave as-is
    private _steps = round (_yaw / 45);
    CB_DIR8 select ((_i + _steps) mod 8)
};

// opposite of an 8-way direction bit (180 deg)
CB_fnc_oppDir8 = {
    params ["_bit"];
    [_bit, 180] call CB_fnc_rotDir8
};

// ---------------------------------------------------------------------------
// Pick the tile whose rotated base mask exactly matches the cell's link mask.
// Returns [tileKey, yawDeg, pivotOffset] or [] if no tile fits (e.g. 4-way).
// ---------------------------------------------------------------------------
CB_fnc_yawForExits = {
    params ["_mask"];
    private _deg = (_mask % 2) + (floor(_mask/2) % 2) + (floor(_mask/4) % 2) + (floor(_mask/8) % 2);

    // map opening-count -> which tile key handles it
    private _key = switch (_deg) do {
        case 1: { "END" };
        case 2: {
            // collinear (straight) vs perpendicular (corner)?
            if (_mask == 5 || _mask == 10) then { "SHORT" } else { "BEND" }
        };
        case 3: { "TEE" };
        default { "" };   // 0 or 4 openings: not representable
    };
    if (_key == "") exitWith { [] };

    (CB_tileTable get _key) params ["", "_baseMask", "_baseYaw", "_piv"];

    // find the 90-deg rotation that turns baseMask into the target mask
    private _result = [];
    for "_s" from 0 to 3 do {
        if (([_baseMask, _s] call CB_fnc_rotMask) == _mask) exitWith {
            _result = [_key, (_s * 90 + _baseYaw) mod 360, _piv];
        };
    };
    _result
};

// ---------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------
CB_MAZE_OBJECTS = [];

// rotate a local (x,y,z) offset by yaw degrees clockwise into a world delta.
// Arma setDir is clockwise; SQF cos/sin take DEGREES. Matches CB_fnc_rotMask.
CB_fnc_rotOffset = {
    params ["_off", "_yaw"];
    _off params ["_x","_y","_z"];
    private _c = cos _yaw;
    private _s = sin _yaw;
    [_x * _c + _y * _s, -_x * _s + _y * _c, _z]
};

// [tileKey, yawDeg] call CB_fnc_tileOpenings ->
//   hashmap: worldDirBit -> world-space delta from tile origin to that opening.
CB_fnc_tileOpenings = {
    params ["_key", "_yaw"];
    private _conn = CB_connTable getOrDefault [_key, createHashMap];
    private _out = createHashMap;
    {
        // hashmap forEach: _x = key (dir bit, 8-way), _y = value (offset)
        private _worldDir = [_x, _yaw] call CB_fnc_rotDir8;
        private _worldOff = [_y, _yaw] call CB_fnc_rotOffset;
        _out set [_worldDir, _worldOff];
    } forEach _conn;
    _out
};

// Place a tile so the opening facing _entryWorldDir lands exactly at _entryPoint.
// [tileKey, classname, yawDeg, entryWorldDir, entryPoint] call CB_fnc_placeChained
//   -> [object, openingsWorldPointsHashMap]   (worldDirBit -> world point)
CB_fnc_placeChained = {
    params ["_key", "_class", "_yaw", "_entryDir", "_entryPoint"];
    private _openings = [_key, _yaw] call CB_fnc_tileOpenings;
    // origin so that origin + entryOffset == entryPoint
    private _entryOff = _openings getOrDefault [_entryDir, [0,0,0]];
    private _origin = _entryPoint vectorDiff _entryOff;
    private _obj = createVehicle [_class, _origin, [], 0, "CAN_COLLIDE"];
    _obj setDir _yaw;
    _obj setPosATL _origin;
    _obj setVectorUp [0,0,1];
    CB_MAZE_OBJECTS pushBack _obj;
    // world points of all openings (hashmap forEach: _x=key dir, _y=value off)
    private _worldPts = createHashMap;
    { _worldPts set [_x, _origin vectorAdd _y]; } forEach _openings;
    [_obj, _worldPts]
};

// Place a Short heading at math-angle _head (deg, 0=E, 90=N, CCW) so its entry
// (W) opening lands at _pt; the E opening then points along _head.
// Returns [exitPoint, _head]. (setDir is clockwise-from-N, so setDir = -_head.)
//   Short.W local = [-5.574,-0.0365,0.536], Short.E local = [5.574,0.0365,-0.536].
// _overlap (m, default 1.5): the reported exit point is pulled back along the
// heading so the NEXT piece starts inside this one, closing the wedge gap on the
// outer side of bends (the tube bodies interpenetrate at each seam).
CB_fnc_placeShortSteer = {
    params ["_pt", "_head", ["_overlap", 1.5]];
    private _yaw = (- _head);                 // math heading -> setDir
    private _wOff = [[-5.574,-0.0365,0.536], _yaw] call CB_fnc_rotOffset;
    private _eOff = [[ 5.574, 0.0365,-0.536], _yaw] call CB_fnc_rotOffset;
    private _origin = _pt vectorDiff _wOff;
    (CB_tileTable get "SHORT") params ["_cls"];
    private _obj = createVehicle [_cls, _origin, [], 0, "CAN_COLLIDE"];
    _obj setDir _yaw;
    _obj setPosATL _origin;
    _obj setVectorUp [0,0,1];
    CB_MAZE_OBJECTS pushBack _obj;
    // forward unit vector (math heading) -> pull exit back by _overlap
    private _fwd = [cos _head, sin _head, 0];
    [(_origin vectorAdd _eOff) vectorDiff (_fwd vectorMultiply _overlap), _head, _obj]
};

// Steer a tunnel from _pt heading _h0 (deg, 0=E CCW) onto the nearest cardinal
// heading using bent Shorts (<= _maxBend deg each). Returns [endPoint, cardDeg].
// [startPoint, startHeading, maxBendDeg] call CB_fnc_steerToCardinal
CB_fnc_steerToCardinal = {
    params ["_pt", "_h0", ["_maxBend", 15]];
    // nearest cardinal in degrees (0=E, 90=N, 180=W, 270=S)
    private _hc = 90 * round (_h0 / 90);
    private _cur = _h0;
    private _p = _pt;
    private _guard = 0;
    while {(abs (_hc - _cur)) > 0.5 && _guard < 32} do {
        private _delta = _hc - _cur;
        if (_delta >  _maxBend) then { _delta =  _maxBend };
        if (_delta < (-_maxBend)) then { _delta = -_maxBend };
        _cur = _cur + _delta;
        ([_p, _cur] call CB_fnc_placeShortSteer) params ["_np","_nh"];
        _p = _np;
        _guard = _guard + 1;
    };
    [_p, (_hc mod 360 + 360) mod 360]
};

// Steer a tunnel from _pt heading _h0 toward goal point _goal using bent Shorts
// (<= _maxBend deg each). Greedy pursuit with COLLISION AVOIDANCE: probes the
// next piece's spot; if an obstacle (a maze tile that existed before this run,
// in _avoid) blocks it -- and we're not basically at the goal -- it stops early
// (the caller caps the stub). Avoids ploughing through other tunnels.
// Returns [endPoint, endHeadingDeg, reachedBool, placedObjs].
// [startPt, startHeading, goalPt, maxBend, avoidObjs] call CB_fnc_steerToTarget
CB_fnc_steerToTarget = {
    params ["_pt", "_h0", "_goal", ["_maxBend", 12], ["_avoid", []]];
    private _cur = _h0;
    private _p = _pt;
    private _guard = 0;
    private _reached = false;
    private _prevDist = 1e9;
    private _stall = 0;
    private _placed = [];
    while {_guard < 24} do {
        private _dx = (_goal select 0) - (_p select 0);
        private _dy = (_goal select 1) - (_p select 1);
        private _dist = sqrt (_dx*_dx + _dy*_dy);
        if (_dist < 7) exitWith { _reached = true };
        if (_dist >= _prevDist - 0.5) then { _stall = _stall + 1 } else { _stall = 0 };
        if (_stall >= 3) exitWith {};
        _prevDist = _dist;
        private _bearing = (_dy atan2 _dx);
        private _diff = _bearing - _cur;
        while {_diff > 180} do { _diff = _diff - 360 };
        while {_diff < -180} do { _diff = _diff + 360 };
        if (_diff >  _maxBend) then { _diff =  _maxBend };
        if (_diff < (-_maxBend)) then { _diff = -_maxBend };
        _cur = _cur + _diff;
        // collision: bounding-box test of the next piece's body against nearby
        // avoid-tiles. Robust to tile origin offsets and LOD quirks. The probe is
        // the next Short's body center; check if it falls inside any avoid-tile's
        // world bounding box (expanded a bit). Tunnels at a different DEPTH won't
        // match (Z is included), so over/under crossings are allowed.
        private _fwd2 = [cos _cur, sin _cur, 0];
        private _probe = _p vectorAdd (_fwd2 vectorMultiply 6);   // next body center
        private _blocked = false;
        {
            if (_x in _avoid && {((getPosATL _x) distance _goal) > 9}) then {
                // is _probe inside _x's bounding box (model space)?
                private _rel = _x worldToModel _probe;
                private _bb = boundingBoxReal _x;
                (_bb select 0) params ["_x0","_y0","_z0"];
                (_bb select 1) params ["_x1","_y1","_z1"];
                private _pad = 1.0;
                if ((_rel select 0) > _x0-_pad && (_rel select 0) < _x1+_pad
                 && (_rel select 1) > _y0-_pad && (_rel select 1) < _y1+_pad
                 && (_rel select 2) > _z0-_pad && (_rel select 2) < _z1+_pad) exitWith { _blocked = true };
            };
        } forEach (_probe nearObjects 14);
        if (_blocked) exitWith {};                     // stop; caller caps the stub
        ([_p, _cur] call CB_fnc_placeShortSteer) params ["_np","","_o"];
        _placed pushBack _o;
        _p = _np;
        _guard = _guard + 1;
    };
    [_p, (_cur mod 360 + 360) mod 360, _reached, _placed]
};

// Find a yaw (mult of 45) whose rotated openings include ALL required dir bits.
// [tileKey, [dirBit,...]] call CB_fnc_findYaw -> yawDeg or -1 if none.
CB_fnc_findYaw = {
    params ["_key", "_need"];
    private _result = -1;
    for "_s" from 0 to 7 do {
        private _yaw = _s * 45;
        private _ops = [_key, _yaw] call CB_fnc_tileOpenings;
        private _ok = true;
        { if !(_x in (keys _ops)) exitWith { _ok = false }; } forEach _need;
        if (_ok) exitWith { _result = _yaw };
    };
    _result
};

// Place a CB_Intersect02 Y-junction at _pos with world yaw _yaw, then steer each
// of its 3 diagonal arms onto a cardinal heading with bent Shorts.
// [pos, yawDeg, maxBendDeg] call CB_fnc_placeYJunction
//   -> array of 3 ports: [[endPoint, cardHeadingDeg], ...]
CB_fnc_placeYJunction = {
    params ["_pos", ["_yaw", 0], ["_maxBend", 15]];
    CB_yJunction params ["_cls", "_arms"];
    private _obj = createVehicle [_cls, _pos, [], 0, "CAN_COLLIDE"];
    _obj setDir _yaw;
    _obj setPosATL _pos;
    _obj setVectorUp [0,0,1];
    CB_MAZE_OBJECTS pushBack _obj;

    private _ports = [];
    {
        _x params ["_localOff", "_headDeg"];
        // arm opening world point (rotate local offset by junction yaw)
        private _armPt = _pos vectorAdd ([_localOff, _yaw] call CB_fnc_rotOffset);
        // arm departure heading: math angle; junction setDir is clockwise so it
        // SUBTRACTS from the math heading.
        private _armHead = (_headDeg - _yaw) mod 360;
        // steer this arm onto a cardinal heading
        private _port = [_armPt, _armHead, _maxBend] call CB_fnc_steerToCardinal;
        _ports pushBack _port;
    } forEach _arms;
    _ports
};

// [worldPos, classname, yawDeg, pivotOffset] call CB_fnc_placeTile -> object
CB_fnc_placeTile = {
    params ["_pos", "_class", "_yaw", ["_pivot", [0,0,0]]];
    private _obj = createVehicle [_class, _pos, [], 0, "CAN_COLLIDE"];
    _obj setDir _yaw;
    // rotate the (x,y) pivot offset by the tile yaw, keep z, then snap to target.
    private _rot = [[_pivot select 0, _pivot select 1], _yaw] call BIS_fnc_rotateVector2D;
    private _wp = _pos vectorAdd [_rot select 0, _rot select 1, _pivot select 2];
    _obj setPosATL _wp;
    _obj setVectorUp [0,0,1];
    CB_MAZE_OBJECTS pushBack _obj;
    _obj
};

// [worldPos, targetMask] call CB_fnc_placeLong -> object
// Places a CB_Long oriented so its openings match targetMask (5=N+S or 10=E+W).
CB_fnc_placeLong = {
    params ["_pos", "_targetMask"];
    (CB_tileTable get "LONG") params ["_cls", "_baseMask", "_baseYaw", "_piv"];
    private _yaw = 0;
    for "_s" from 0 to 3 do {
        if (([_baseMask, _s] call CB_fnc_rotMask) == _targetMask) exitWith {
            _yaw = (_s * 90 + _baseYaw) mod 360;
        };
    };
    [_pos, _cls, _yaw, _piv] call CB_fnc_placeTile
};

CB_fnc_clearMaze = {
    {
        if (!isNull _x) then { deleteVehicle _x };
    } forEach CB_MAZE_OBJECTS;
    CB_MAZE_OBJECTS = [];
    diag_log "[CB maze] cleared";
};

// Quick test: place a Y-junction + steered arms and cap each arm port.
// [pos] call CB_fnc_testYJunction
CB_fnc_testYJunction = {
    params [["_pos", getPosATL player]];
    call CB_fnc_clearMaze;
    private _ports = [_pos, 0, 15] call CB_fnc_placeYJunction;
    {
        _x params ["_pt","_card"];
        diag_log format ["[CB maze] Y arm port: pt %1 heading %2", _pt, _card];
        // cap the port with an End facing back toward the junction
        // (End opens N=1 at dir0; we just drop a Short stub so the port is visible)
        [_pt, _card] call CB_fnc_placeShortSteer;
    } forEach _ports;
    diag_log format ["[CB maze] Y-junction test placed %1 objects", count CB_MAZE_OBJECTS];
    _ports
};

diag_log "[CB maze] helpers loaded";
