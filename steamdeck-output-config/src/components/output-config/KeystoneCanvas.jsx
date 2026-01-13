import React, { useRef, useEffect, useState } from 'react';
import { useStore } from '../../utils/store';
import { throttledSendConfig } from '../../utils/websocket';

/**
 * KeystoneCanvas - 8-point keystone/warping visual editor
 *
 * Displays a preview with draggable corner points for perspective correction
 */

const CORNER_LABELS = {
  topLeft: 'TL',
  topMid: 'T',
  topRight: 'TR',
  rightMid: 'R',
  bottomRight: 'BR',
  bottomMid: 'B',
  bottomLeft: 'BL',
  leftMid: 'L',
};

export default function KeystoneCanvas() {
  const canvasRef = useRef(null);
  const containerRef = useRef(null);
  const [dimensions, setDimensions] = useState({ width: 800, height: 450 });
  const [dragging, setDragging] = useState(null);

  const {
    keystone,
    selectedCorner,
    setSelectedCorner,
    updateCorner,
    mode,
  } = useStore();

  // Update dimensions on resize
  useEffect(() => {
    const updateDimensions = () => {
      if (containerRef.current) {
        const rect = containerRef.current.getBoundingClientRect();
        setDimensions({ width: rect.width, height: rect.height });
      }
    };

    updateDimensions();
    window.addEventListener('resize', updateDimensions);
    return () => window.removeEventListener('resize', updateDimensions);
  }, []);

  // Draw canvas
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    const { width, height } = dimensions;

    // Clear
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, width, height);

    // Draw grid
    ctx.strokeStyle = '#333';
    ctx.lineWidth = 1;
    const gridSize = 40;
    for (let x = 0; x <= width; x += gridSize) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
      ctx.stroke();
    }
    for (let y = 0; y <= height; y += gridSize) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
      ctx.stroke();
    }

    // Convert normalized coords to canvas coords
    const toCanvas = (point) => ({
      x: point.x * width,
      y: point.y * height,
    });

    // Draw warped quad outline
    const corners = [
      toCanvas(keystone.topLeft),
      toCanvas(keystone.topMid),
      toCanvas(keystone.topRight),
      toCanvas(keystone.rightMid),
      toCanvas(keystone.bottomRight),
      toCanvas(keystone.bottomMid),
      toCanvas(keystone.bottomLeft),
      toCanvas(keystone.leftMid),
    ];

    // Draw filled quad (with transparency)
    ctx.fillStyle = 'rgba(233, 69, 96, 0.15)';
    ctx.beginPath();
    ctx.moveTo(corners[0].x, corners[0].y);
    corners.forEach((corner, i) => {
      if (i > 0) ctx.lineTo(corner.x, corner.y);
    });
    ctx.closePath();
    ctx.fill();

    // Draw quad outline
    ctx.strokeStyle = '#e94560';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(corners[0].x, corners[0].y);
    corners.forEach((corner, i) => {
      if (i > 0) ctx.lineTo(corner.x, corner.y);
    });
    ctx.closePath();
    ctx.stroke();

    // Draw corner points
    Object.entries(keystone).forEach(([key, point]) => {
      const pos = toCanvas(point);
      const isSelected = key === selectedCorner && mode === 'keystone';
      const isMidPoint = key.includes('Mid');

      // Outer circle
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, isSelected ? 16 : (isMidPoint ? 10 : 12), 0, Math.PI * 2);
      ctx.fillStyle = isSelected ? '#e94560' : (isMidPoint ? '#0f3460' : '#16213e');
      ctx.fill();
      ctx.strokeStyle = isSelected ? '#ff6b6b' : '#e94560';
      ctx.lineWidth = isSelected ? 3 : 2;
      ctx.stroke();

      // Label
      ctx.fillStyle = '#fff';
      ctx.font = `${isSelected ? 'bold ' : ''}${isMidPoint ? '10' : '12'}px sans-serif`;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(CORNER_LABELS[key], pos.x, pos.y);
    });

    // Draw crosshair at center
    const centerX = width / 2;
    const centerY = height / 2;
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.3)';
    ctx.lineWidth = 1;
    ctx.setLineDash([5, 5]);
    ctx.beginPath();
    ctx.moveTo(centerX - 30, centerY);
    ctx.lineTo(centerX + 30, centerY);
    ctx.moveTo(centerX, centerY - 30);
    ctx.lineTo(centerX, centerY + 30);
    ctx.stroke();
    ctx.setLineDash([]);

  }, [keystone, selectedCorner, mode, dimensions]);

  // Handle mouse/touch events
  const getPointerPos = (e) => {
    const rect = canvasRef.current.getBoundingClientRect();
    const clientX = e.touches ? e.touches[0].clientX : e.clientX;
    const clientY = e.touches ? e.touches[0].clientY : e.clientY;
    return {
      x: (clientX - rect.left) / dimensions.width,
      y: (clientY - rect.top) / dimensions.height,
    };
  };

  const findNearestCorner = (pos) => {
    let nearest = null;
    let minDist = Infinity;

    Object.entries(keystone).forEach(([key, point]) => {
      const dist = Math.hypot(pos.x - point.x, pos.y - point.y);
      if (dist < minDist && dist < 0.1) { // Within 10% of canvas
        minDist = dist;
        nearest = key;
      }
    });

    return nearest;
  };

  const handlePointerDown = (e) => {
    if (mode !== 'keystone') return;
    const pos = getPointerPos(e);
    const corner = findNearestCorner(pos);
    if (corner) {
      setSelectedCorner(corner);
      setDragging(corner);
    }
  };

  const handlePointerMove = (e) => {
    if (!dragging || mode !== 'keystone') return;
    const pos = getPointerPos(e);
    updateCorner(dragging, pos.x, pos.y);
    throttledSendConfig();
  };

  const handlePointerUp = () => {
    setDragging(null);
  };

  return (
    <div
      ref={containerRef}
      className="keystone-canvas-container"
      style={{
        width: '100%',
        height: '100%',
        position: 'relative',
        cursor: mode === 'keystone' ? 'crosshair' : 'default',
      }}
    >
      <canvas
        ref={canvasRef}
        width={dimensions.width}
        height={dimensions.height}
        onMouseDown={handlePointerDown}
        onMouseMove={handlePointerMove}
        onMouseUp={handlePointerUp}
        onMouseLeave={handlePointerUp}
        onTouchStart={handlePointerDown}
        onTouchMove={handlePointerMove}
        onTouchEnd={handlePointerUp}
        style={{ width: '100%', height: '100%' }}
      />

      {/* Corner info overlay */}
      {mode === 'keystone' && (
        <div
          style={{
            position: 'absolute',
            top: 10,
            left: 10,
            background: 'rgba(0,0,0,0.8)',
            padding: '8px 12px',
            borderRadius: 6,
            fontSize: 13,
          }}
        >
          <div style={{ marginBottom: 4, fontWeight: 600 }}>
            Selected: {CORNER_LABELS[selectedCorner]} ({selectedCorner})
          </div>
          <div style={{ color: '#aaa' }}>
            X: {(keystone[selectedCorner].x * 100).toFixed(1)}% |
            Y: {(keystone[selectedCorner].y * 100).toFixed(1)}%
          </div>
        </div>
      )}
    </div>
  );
}
