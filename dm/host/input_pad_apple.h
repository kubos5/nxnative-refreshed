// A GameController controller's elements as input_map.h's controller codes, for one player's inputs (im_inputs): shared by the Mac front end (front_mac.m), which plays them,
// and the settings window's Test page (dm/mac/launcher_bridge.m), which shows what they give the game. Face buttons by position (pad_apple.h: a Nintendo pad's by its labels).
#pragma once
#import <GameController/GameController.h>
#include "input_map.h"
#include "pad_apple.h"

static inline void im_pad_sample(GCController *c, const im_player *cfg, im_inputs *in) {   // ORs one controller into a player's inputs
    GCExtendedGamepad *g = c.extendedGamepad; if (!g) return;
    GCControllerButtonInput *south = g.buttonA, *east = g.buttonB, *west = g.buttonX, *north = g.buttonY;
    if (dm_pad_labelled(c)) { east = g.buttonA; south = g.buttonB; north = g.buttonX; west = g.buttonY; }   // a Nintendo pad names its buttons by their labels
    GCControllerButtonInput *b[IM_PAD_CODES] = {0};
    b[IM_P_SOUTH] = south; b[IM_P_EAST] = east; b[IM_P_WEST] = west; b[IM_P_NORTH] = north;
    b[IM_P_LB] = g.leftShoulder; b[IM_P_RB] = g.rightShoulder; b[IM_P_LT] = g.leftTrigger; b[IM_P_RT] = g.rightTrigger;
    b[IM_P_LSB] = g.leftThumbstickButton; b[IM_P_RSB] = g.rightThumbstickButton; b[IM_P_MENU] = g.buttonMenu; b[IM_P_OPTIONS] = g.buttonOptions; b[IM_P_HOME] = g.buttonHome;
    b[IM_P_DLEFT] = g.dpad.left; b[IM_P_DUP] = g.dpad.up; b[IM_P_DRIGHT] = g.dpad.right; b[IM_P_DDOWN] = g.dpad.down;
    NSDictionary<NSString *, GCControllerButtonInput *> *all = c.physicalInputProfile.buttons;
    b[IM_P_SHARE] = all[GCInputButtonShare];
    b[IM_P_PADDLE1] = all[GCInputXboxPaddleOne] ?: all[GCInputLeftPaddle]; b[IM_P_PADDLE2] = all[GCInputXboxPaddleTwo] ?: all[GCInputRightPaddle];
    b[IM_P_PADDLE3] = all[GCInputXboxPaddleThree]; b[IM_P_PADDLE4] = all[GCInputXboxPaddleFour]; b[IM_P_TOUCHPAD] = all[GCInputDualShockTouchpadButton];
    for (int i = 0; i < IM_PAD_CODES; i++) if (b[i]) { in->pad[i] = fmaxf(in->pad[i], b[i].value); in->pad_pressed[i] |= b[i].isPressed; }
    float d[4];
    im_stick(&cfg->stick[0], g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value, d);
    for (int i = 0; i < 4; i++) in->pad[IM_P_LS_LEFT + i] = fmaxf(in->pad[IM_P_LS_LEFT + i], d[i]);
    im_stick(&cfg->stick[1], g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value, d);
    for (int i = 0; i < 4; i++) in->pad[IM_P_RS_LEFT + i] = fmaxf(in->pad[IM_P_RS_LEFT + i], d[i]);
}
