/*
    init.sqf  --  RSPNCave maze generator bootstrap

    Compiles the maze functions so they are available everywhere:
        CB_fnc_generateMaze
        CB_fnc_clearMaze
        (+ helpers, see fn_mazeHelpers.sqf)

    Generation creates objects; run it on the server only.

    --- Quick start (debug console, server exec) -------------------------------
        // 8x8 maze in front of the player, auto cell size:
        [player getPos [12,getDir player], 8, 8] call CB_fnc_generateMaze;

        // braided maze (loops), fixed seed, no long pieces:
        private _p = createHashMapFromArray [["seed",1234],["braid",0.4],["useLong",false]];
        [getPosATL player, 10, 10, _p] call CB_fnc_generateMaze;

        // wipe it:
        call CB_fnc_clearMaze;
    ----------------------------------------------------------------------------
*/

call compile preprocessFileLineNumbers "fn_mazeHelpers.sqf";
CB_fnc_generateMaze = compile preprocessFileLineNumbers "fn_generateMaze.sqf";

diag_log "[CB maze] functions compiled (CB_fnc_generateMaze / CB_fnc_clearMaze)";

// Optional auto-demo: uncomment to spawn a maze at mission start.
// if (isServer) then {
//     private _spawn = if (isNull player) then { [6280,7360,0] } else { getPosATL player };
//     [_spawn, 8, 8] call CB_fnc_generateMaze;
// };
