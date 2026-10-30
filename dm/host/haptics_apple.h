// Shared Core Haptics output for the Mac and iOS front ends. Configure routes before guest boot.
#pragma once
#import <GameController/GameController.h>
#include "hle_haptics.h"
void dm_haptics_apple_init(void);
void dm_haptics_apple_controller(int player, GCController *controller);
void dm_haptics_apple_shutdown(void);
// nxnative refreshed: each player's rumble as the launcher sets it (input.json, input_map.h): off, its strength, the low (160 Hz) and high (320 Hz) bands' share, the left and right motors swapped,
// and a cutoff below which a controller stays still (the larger of it and DM_RUMBLE_MIN). The defaults ({1, 1, 1, 1, 0, 0}) leave the game's vibration as it is
typedef struct { int on; float gain, low, high, min; int swap; } dm_rumble_cfg;
void dm_haptics_apple_player(int player, dm_rumble_cfg cfg);
