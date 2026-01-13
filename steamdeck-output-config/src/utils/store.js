import { create } from 'zustand';

export const useStore = create((set, get) => ({
  // Connection state
  connected: false,
  connecting: false,
  serverUrl: 'http://localhost:8082',

  // Current tab: 'status' | 'outputs' | 'gobos' | 'media' | 'ndi'
  activeTab: 'status',

  // Status
  status: {
    version: '-',
    fixtures: 0,
    resolution: '-',
    outputCount: 0,
  },

  // Outputs
  outputs: [],
  displays: [],
  selectedOutputId: null,

  // Output Settings Modal
  settingsModalOpen: false,
  settingsTab: 'position', // 'position' | 'edgeblend' | 'warp' | 'lens' | 'dmx'
  currentSettings: {
    position: { x: 0, y: 0, width: 1920, height: 1080, intensity: 1 },
    edgeBlend: { left: 0, right: 0, top: 0, bottom: 0, gamma: 2.2 },
    warp: {
      topLeft: { x: 0, y: 0 }, topMid: { x: 0, y: 0 }, topRight: { x: 0, y: 0 },
      midLeft: { x: 0, y: 0 }, midRight: { x: 0, y: 0 },
      bottomLeft: { x: 0, y: 0 }, bottomMid: { x: 0, y: 0 }, bottomRight: { x: 0, y: 0 },
      curvature: 0,
    },
    lens: { k1: 0, k2: 0, centerX: 0.5, centerY: 0.5 },
    dmx: { universe: 1, address: 1 },
  },

  // Gobos
  gobos: [],
  selectedGoboSlot: 21,

  // Media Slots
  mediaSlots: [],
  videos: [],
  images: [],
  selectedMediaSlot: 201,

  // NDI Sources
  ndiSources: [],

  // Gamepad state
  gamepadConnected: false,
  gamepadId: null,

  // UI Navigation
  focusedIndex: 0,

  // Actions
  setServerUrl: (url) => set({ serverUrl: url }),
  setConnected: (connected) => set({ connected }),
  setConnecting: (connecting) => set({ connecting }),

  // Tab navigation
  setActiveTab: (tab) => set({ activeTab: tab, focusedIndex: 0 }),
  nextTab: () => {
    const tabs = ['status', 'outputs', 'gobos', 'media', 'ndi'];
    const currentIndex = tabs.indexOf(get().activeTab);
    const nextIndex = (currentIndex + 1) % tabs.length;
    set({ activeTab: tabs[nextIndex], focusedIndex: 0 });
  },
  prevTab: () => {
    const tabs = ['status', 'outputs', 'gobos', 'media', 'ndi'];
    const currentIndex = tabs.indexOf(get().activeTab);
    const prevIndex = (currentIndex - 1 + tabs.length) % tabs.length;
    set({ activeTab: tabs[prevIndex], focusedIndex: 0 });
  },

  // Status
  setStatus: (status) => set({ status }),

  // Outputs
  setOutputs: (outputs) => set({ outputs }),
  setDisplays: (displays) => set({ displays }),
  setSelectedOutputId: (id) => set({ selectedOutputId: id }),

  // Output Settings Modal
  openSettingsModal: (output) => {
    const settings = output.settings || {};
    set({
      settingsModalOpen: true,
      selectedOutputId: output.id,
      settingsTab: 'position',
      currentSettings: {
        position: {
          x: settings.x ?? 0,
          y: settings.y ?? 0,
          width: settings.width ?? 1920,
          height: settings.height ?? 1080,
          intensity: settings.intensity ?? 1,
        },
        edgeBlend: {
          left: settings.edgeBlendLeft ?? 0,
          right: settings.edgeBlendRight ?? 0,
          top: settings.edgeBlendTop ?? 0,
          bottom: settings.edgeBlendBottom ?? 0,
          gamma: settings.edgeBlendGamma ?? 2.2,
        },
        warp: {
          topLeft: { x: settings.warpTLX ?? 0, y: settings.warpTLY ?? 0 },
          topMid: { x: settings.warpTMX ?? 0, y: settings.warpTMY ?? 0 },
          topRight: { x: settings.warpTRX ?? 0, y: settings.warpTRY ?? 0 },
          midLeft: { x: settings.warpMLX ?? 0, y: settings.warpMLY ?? 0 },
          midRight: { x: settings.warpMRX ?? 0, y: settings.warpMRY ?? 0 },
          bottomLeft: { x: settings.warpBLX ?? 0, y: settings.warpBLY ?? 0 },
          bottomMid: { x: settings.warpBMX ?? 0, y: settings.warpBMY ?? 0 },
          bottomRight: { x: settings.warpBRX ?? 0, y: settings.warpBRY ?? 0 },
          curvature: settings.warpCurvature ?? 0,
        },
        lens: {
          k1: settings.lensK1 ?? 0,
          k2: settings.lensK2 ?? 0,
          centerX: settings.lensCenterX ?? 0.5,
          centerY: settings.lensCenterY ?? 0.5,
        },
        dmx: {
          universe: settings.dmxUniverse ?? 1,
          address: settings.dmxAddress ?? 1,
        },
      },
    });
  },
  closeSettingsModal: () => set({ settingsModalOpen: false }),
  setSettingsTab: (tab) => set({ settingsTab: tab }),

  updatePositionSetting: (key, value) => set((state) => ({
    currentSettings: {
      ...state.currentSettings,
      position: { ...state.currentSettings.position, [key]: value },
    },
  })),

  updateEdgeBlendSetting: (key, value) => set((state) => ({
    currentSettings: {
      ...state.currentSettings,
      edgeBlend: { ...state.currentSettings.edgeBlend, [key]: value },
    },
  })),

  updateWarpSetting: (corner, axis, value) => set((state) => ({
    currentSettings: {
      ...state.currentSettings,
      warp: {
        ...state.currentSettings.warp,
        [corner]: { ...state.currentSettings.warp[corner], [axis]: value },
      },
    },
  })),

  updateWarpCurvature: (value) => set((state) => ({
    currentSettings: {
      ...state.currentSettings,
      warp: { ...state.currentSettings.warp, curvature: value },
    },
  })),

  updateLensSetting: (key, value) => set((state) => ({
    currentSettings: {
      ...state.currentSettings,
      lens: { ...state.currentSettings.lens, [key]: value },
    },
  })),

  // Build settings object for API
  buildSettingsPayload: () => {
    const { currentSettings } = get();
    return {
      x: currentSettings.position.x,
      y: currentSettings.position.y,
      width: currentSettings.position.width,
      height: currentSettings.position.height,
      intensity: currentSettings.position.intensity,
      edgeBlendLeft: currentSettings.edgeBlend.left,
      edgeBlendRight: currentSettings.edgeBlend.right,
      edgeBlendTop: currentSettings.edgeBlend.top,
      edgeBlendBottom: currentSettings.edgeBlend.bottom,
      edgeBlendGamma: currentSettings.edgeBlend.gamma,
      warpTLX: currentSettings.warp.topLeft.x,
      warpTLY: currentSettings.warp.topLeft.y,
      warpTMX: currentSettings.warp.topMid.x,
      warpTMY: currentSettings.warp.topMid.y,
      warpTRX: currentSettings.warp.topRight.x,
      warpTRY: currentSettings.warp.topRight.y,
      warpMLX: currentSettings.warp.midLeft.x,
      warpMLY: currentSettings.warp.midLeft.y,
      warpMRX: currentSettings.warp.midRight.x,
      warpMRY: currentSettings.warp.midRight.y,
      warpBLX: currentSettings.warp.bottomLeft.x,
      warpBLY: currentSettings.warp.bottomLeft.y,
      warpBMX: currentSettings.warp.bottomMid.x,
      warpBMY: currentSettings.warp.bottomMid.y,
      warpBRX: currentSettings.warp.bottomRight.x,
      warpBRY: currentSettings.warp.bottomRight.y,
      warpCurvature: currentSettings.warp.curvature,
      lensK1: currentSettings.lens.k1,
      lensK2: currentSettings.lens.k2,
      lensCenterX: currentSettings.lens.centerX,
      lensCenterY: currentSettings.lens.centerY,
    };
  },

  // Gobos
  setGobos: (gobos) => set({ gobos }),
  setSelectedGoboSlot: (slot) => set({ selectedGoboSlot: slot }),

  // Media
  setMediaSlots: (mediaSlots) => set({ mediaSlots }),
  setVideos: (videos) => set({ videos }),
  setImages: (images) => set({ images }),
  setSelectedMediaSlot: (slot) => set({ selectedMediaSlot: slot }),

  // NDI
  setNDISources: (ndiSources) => set({ ndiSources }),

  // Gamepad
  setGamepadConnected: (connected, id = null) => set({
    gamepadConnected: connected,
    gamepadId: id,
  }),

  // Navigation
  setFocusedIndex: (index) => set({ focusedIndex: index }),
}));
