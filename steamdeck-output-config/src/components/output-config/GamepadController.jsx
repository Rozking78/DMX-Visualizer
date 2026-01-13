import { useEffect, useRef } from 'react';
import { useStore } from '../../utils/store';

/**
 * GamepadController - Handle Steam Deck gamepad input for DMX Visualizer control
 *
 * Control Scheme:
 * - LB/RB: Switch between main tabs (Status, Outputs, Gobos, Media, NDI)
 * - D-Pad: Navigate within current view
 * - A: Select/Confirm
 * - B: Back/Cancel/Close Modal
 * - X: Context action 1 (Refresh in NDI, etc.)
 * - Y: Context action 2
 * - Left Stick: Navigate lists / Adjust values
 * - Right Stick: Fine adjustment
 * - LT/RT: Page up/down in lists
 * - Start: Save/Apply
 * - Select: Reset/Refresh
 */

const DEADZONE = 0.2;
const REPEAT_DELAY = 300; // ms before repeat starts
const REPEAT_RATE = 100; // ms between repeats

export default function GamepadController() {
  const {
    activeTab,
    nextTab,
    prevTab,
    settingsModalOpen,
    closeSettingsModal,
    focusedIndex,
    setFocusedIndex,
    setGamepadConnected,
    // Gobos
    selectedGoboSlot,
    setSelectedGoboSlot,
    // Media
    selectedMediaSlot,
    setSelectedMediaSlot,
  } = useStore();

  const lastButtonStates = useRef({});
  const repeatTimers = useRef({});
  const animationFrameId = useRef(null);

  const applyDeadzone = (value) => {
    if (Math.abs(value) < DEADZONE) return 0;
    return (value - Math.sign(value) * DEADZONE) / (1 - DEADZONE);
  };

  const handleButtonPress = (buttonIndex) => {
    switch (buttonIndex) {
      case 0: // A - Select/Confirm
        // Trigger click on focused element
        document.querySelector('.gamepad-focused')?.click();
        break;

      case 1: // B - Back/Cancel
        if (settingsModalOpen) {
          closeSettingsModal();
        }
        break;

      case 2: // X - Context action (Refresh)
        // Could trigger refresh in NDI view, etc.
        document.querySelector('.btn-primary')?.click();
        break;

      case 3: // Y - Context action 2
        break;

      case 4: // LB - Previous tab
        prevTab();
        break;

      case 5: // RB - Next tab
        nextTab();
        break;

      case 8: // Select - Refresh
        document.querySelector('.btn-primary')?.click();
        break;

      case 9: // Start - Save
        document.querySelector('.btn-success')?.click();
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

  const handleDPad = (direction) => {
    // Navigation varies by tab
    if (activeTab === 'gobos') {
      // Navigate gobo grid (10 columns)
      let newSlot = selectedGoboSlot;
      if (direction === 'up') newSlot = Math.max(21, selectedGoboSlot - 10);
      else if (direction === 'down') newSlot = Math.min(200, selectedGoboSlot + 10);
      else if (direction === 'left') newSlot = Math.max(21, selectedGoboSlot - 1);
      else if (direction === 'right') newSlot = Math.min(200, selectedGoboSlot + 1);
      setSelectedGoboSlot(newSlot);
    } else if (activeTab === 'media') {
      // Navigate media slots
      let newSlot = selectedMediaSlot;
      if (direction === 'up') newSlot = Math.max(201, selectedMediaSlot - 1);
      else if (direction === 'down') newSlot = Math.min(255, selectedMediaSlot + 1);
      setSelectedMediaSlot(newSlot);
    } else {
      // Generic list navigation
      const items = document.querySelectorAll('.output-item, .source-item, .display-item');
      if (items.length === 0) return;

      let newIndex = focusedIndex;
      if (direction === 'up') newIndex = Math.max(0, focusedIndex - 1);
      else if (direction === 'down') newIndex = Math.min(items.length - 1, focusedIndex + 1);

      // Update focus styling
      items.forEach((item, i) => {
        item.classList.toggle('gamepad-focused', i === newIndex);
      });
      setFocusedIndex(newIndex);
    }
  };

  const handleAnalogSticks = (gamepad) => {
    const leftY = applyDeadzone(gamepad.axes[1]);

    // Left stick Y for scrolling lists
    if (Math.abs(leftY) > 0.5) {
      const direction = leftY > 0 ? 'down' : 'up';
      handleDPad(direction);
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
        handleButtonPress(index);
      }

      lastButtonStates.current[index] = isPressed;
    });

    // Handle analog sticks (throttled)
    handleAnalogSticks(gamepad);

    animationFrameId.current = requestAnimationFrame(pollGamepad);
  };

  useEffect(() => {
    animationFrameId.current = requestAnimationFrame(pollGamepad);

    return () => {
      if (animationFrameId.current) {
        cancelAnimationFrame(animationFrameId.current);
      }
      // Clear any repeat timers
      Object.values(repeatTimers.current).forEach(clearTimeout);
    };
  }, [activeTab, focusedIndex, selectedGoboSlot, selectedMediaSlot, settingsModalOpen]);

  return null; // This is a logic-only component
}
