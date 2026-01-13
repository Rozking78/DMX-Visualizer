import { useEffect, useRef } from 'react';
import { useStore } from '../../utils/store';
import { throttledSendConfig } from '../../utils/websocket';

/**
 * GamepadController - Handle Steam Deck gamepad input for output configuration
 *
 * Control Scheme:
 * - Left Stick: Move position (Position mode) / Move corner (Keystone mode) / Adjust width (Blend mode)
 * - Right Stick: Scale/Rotation (Position) / Fine adjust (Keystone) / Curve/Gamma (Blend)
 * - D-Pad: Navigate outputs / Select corners / Select edges
 * - A: Select/Confirm
 * - B: Back/Cancel
 * - X: Toggle Keystone mode
 * - Y: Toggle Blend mode
 * - LB/RB: Cycle through outputs
 * - LT/RT: Fine adjustment modifier / Reset
 * - Start: Save configuration
 * - Select: Reset current mode
 */

const DEADZONE = 0.15;
const STICK_SENSITIVITY = 0.02;
const FINE_SENSITIVITY = 0.005;

const CORNERS = ['topLeft', 'topMid', 'topRight', 'rightMid', 'bottomRight', 'bottomMid', 'bottomLeft', 'leftMid'];
const EDGES = ['top', 'right', 'bottom', 'left'];

export default function GamepadController() {
  const {
    mode, setMode,
    selectedCorner, setSelectedCorner, moveSelectedCorner,
    selectedEdge, setSelectedEdge, updateBlend, blend,
    movePosition, updatePosition, position,
    outputs, selectedOutputId, setSelectedOutputId,
    resetKeystone, resetPosition, resetBlend,
    setGamepadConnected,
    sendConfig,
  } = useStore();

  const lastButtonStates = useRef({});
  const animationFrameId = useRef(null);

  const applyDeadzone = (value) => {
    if (Math.abs(value) < DEADZONE) return 0;
    return (value - Math.sign(value) * DEADZONE) / (1 - DEADZONE);
  };

  const handleButtonPress = (buttonIndex, triggerValue = 1) => {
    const fineMode = triggerValue > 0.5;

    switch (buttonIndex) {
      case 0: // A - Select/Confirm
        sendConfig();
        break;

      case 1: // B - Back/Cancel
        // Could implement modal closing or navigation
        break;

      case 2: // X - Keystone mode
        setMode(mode === 'keystone' ? 'position' : 'keystone');
        break;

      case 3: // Y - Blend mode
        setMode(mode === 'blend' ? 'position' : 'blend');
        break;

      case 4: // LB - Previous output
        cycleOutput(-1);
        break;

      case 5: // RB - Next output
        cycleOutput(1);
        break;

      case 8: // Select - Reset current mode
        if (mode === 'keystone') resetKeystone();
        else if (mode === 'blend') resetBlend();
        else resetPosition();
        throttledSendConfig();
        break;

      case 9: // Start - Save
        sendConfig();
        break;

      case 12: // D-Pad Up
        handleDPad('up');
        break;

      case 13: // D-Pad Down
        handleDPad('down');
        break;

      case 14: // D-Pad Left
        handleDPad('left');
        break;

      case 15: // D-Pad Right
        handleDPad('right');
        break;
    }
  };

  const cycleOutput = (direction) => {
    if (outputs.length === 0) return;
    const currentIndex = outputs.findIndex(o => o.id === selectedOutputId);
    let newIndex = currentIndex + direction;
    if (newIndex < 0) newIndex = outputs.length - 1;
    if (newIndex >= outputs.length) newIndex = 0;
    setSelectedOutputId(outputs[newIndex].id);
  };

  const handleDPad = (direction) => {
    if (mode === 'keystone') {
      // Cycle through corners
      const currentIndex = CORNERS.indexOf(selectedCorner);
      let newIndex;
      if (direction === 'right') newIndex = (currentIndex + 1) % CORNERS.length;
      else if (direction === 'left') newIndex = (currentIndex - 1 + CORNERS.length) % CORNERS.length;
      else if (direction === 'up') {
        // Jump to top corners
        if (currentIndex >= 4) newIndex = currentIndex - 4;
        else newIndex = currentIndex;
      } else if (direction === 'down') {
        // Jump to bottom corners
        if (currentIndex < 4) newIndex = (currentIndex + 4) % CORNERS.length;
        else newIndex = currentIndex;
      }
      if (newIndex !== undefined) setSelectedCorner(CORNERS[newIndex]);
    } else if (mode === 'blend') {
      // Cycle through edges
      const currentIndex = EDGES.indexOf(selectedEdge);
      let newIndex;
      if (direction === 'right') newIndex = (currentIndex + 1) % EDGES.length;
      else if (direction === 'left') newIndex = (currentIndex - 1 + EDGES.length) % EDGES.length;
      else if (direction === 'up') newIndex = 0; // top
      else if (direction === 'down') newIndex = 2; // bottom
      if (newIndex !== undefined) setSelectedEdge(EDGES[newIndex]);
    } else {
      // Position mode - cycle outputs
      if (direction === 'left' || direction === 'up') cycleOutput(-1);
      else cycleOutput(1);
    }
  };

  const handleAnalogSticks = (gamepad) => {
    const leftX = applyDeadzone(gamepad.axes[0]);
    const leftY = applyDeadzone(gamepad.axes[1]);
    const rightX = applyDeadzone(gamepad.axes[2]);
    const rightY = applyDeadzone(gamepad.axes[3]);

    // LT and RT for fine control
    const lt = gamepad.buttons[6]?.value || 0;
    const rt = gamepad.buttons[7]?.value || 0;
    const fineMode = lt > 0.3;
    const sensitivity = fineMode ? FINE_SENSITIVITY : STICK_SENSITIVITY;

    if (mode === 'position') {
      // Left stick: move X/Y
      if (leftX !== 0 || leftY !== 0) {
        movePosition(leftX * sensitivity * 100, leftY * sensitivity * 100);
        throttledSendConfig();
      }
      // Right stick: scale (Y) and rotation (X)
      if (rightY !== 0) {
        const scaleChange = -rightY * sensitivity;
        updatePosition({ scale: Math.max(0.1, Math.min(3, position.scale + scaleChange)) });
        throttledSendConfig();
      }
      if (rightX !== 0) {
        const rotChange = rightX * sensitivity * 180;
        updatePosition({ rotation: position.rotation + rotChange });
        throttledSendConfig();
      }
    } else if (mode === 'keystone') {
      // Left stick: move selected corner
      if (leftX !== 0 || leftY !== 0) {
        moveSelectedCorner(leftX * sensitivity, leftY * sensitivity);
        throttledSendConfig();
      }
    } else if (mode === 'blend') {
      // Left stick X: blend width
      if (leftX !== 0) {
        const currentBlend = blend[selectedEdge];
        const newWidth = Math.max(0, Math.min(0.5, currentBlend.width + leftX * sensitivity));
        updateBlend(selectedEdge, { width: newWidth, enabled: newWidth > 0 });
        throttledSendConfig();
      }
      // Right stick: curve (X) and gamma (Y)
      if (rightX !== 0) {
        const currentBlend = blend[selectedEdge];
        const newCurve = Math.max(0, Math.min(1, currentBlend.curve + rightX * sensitivity));
        updateBlend(selectedEdge, { curve: newCurve });
        throttledSendConfig();
      }
      if (rightY !== 0) {
        const currentBlend = blend[selectedEdge];
        const newGamma = Math.max(0.1, Math.min(3, currentBlend.gamma - rightY * sensitivity));
        updateBlend(selectedEdge, { gamma: newGamma });
        throttledSendConfig();
      }
    }
  };

  const pollGamepad = () => {
    const gamepads = navigator.getGamepads();
    const gamepad = gamepads[0] || gamepads[1] || gamepads[2] || gamepads[3];

    if (!gamepad) {
      setGamepadConnected(false, null);
      animationFrameId.current = requestAnimationFrame(pollGamepad);
      return;
    }

    setGamepadConnected(true, gamepad.id);

    // Check button presses (rising edge)
    gamepad.buttons.forEach((button, index) => {
      const wasPressed = lastButtonStates.current[index];
      const isPressed = button.pressed;

      if (isPressed && !wasPressed) {
        handleButtonPress(index, button.value);
      }

      lastButtonStates.current[index] = isPressed;
    });

    // Handle analog sticks (continuous)
    handleAnalogSticks(gamepad);

    animationFrameId.current = requestAnimationFrame(pollGamepad);
  };

  useEffect(() => {
    animationFrameId.current = requestAnimationFrame(pollGamepad);

    return () => {
      if (animationFrameId.current) {
        cancelAnimationFrame(animationFrameId.current);
      }
    };
  }, [mode, selectedCorner, selectedEdge, position, blend]);

  return null; // This is a logic-only component
}
