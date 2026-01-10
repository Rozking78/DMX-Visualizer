#!/usr/bin/env python3
"""Generate curvy flower/star gobos for slots 21-24"""
import math
from PIL import Image, ImageDraw

def create_flower_star(points, size=256):
    """Create a curvy flower star pattern"""
    img = Image.new('L', (size, size), 0)  # Grayscale, black background
    draw = ImageDraw.Draw(img)
    
    center = size // 2
    outer_r = size * 0.45
    inner_r = outer_r * 0.4
    
    # Create flower by drawing curved petals
    num_samples = 360
    polygon = []
    
    for i in range(num_samples):
        angle = (i / num_samples) * 2 * math.pi
        # Sine wave modulation for curvy petals
        segment_angle = math.pi / points
        a = (angle % (2 * segment_angle))
        if a > segment_angle:
            a = 2 * segment_angle - a
        t = a / segment_angle  # 0 at point, 1 at valley
        
        # Use sine for smooth curves
        r = outer_r - (outer_r - inner_r) * math.sin(t * math.pi / 2)
        
        x = center + r * math.cos(angle)
        y = center + r * math.sin(angle)
        polygon.append((x, y))
    
    draw.polygon(polygon, fill=255)
    return img

# Generate 3, 4, 5, 6 pointed flowers for gobo slots 21-24
for i, points in enumerate([3, 4, 5, 6]):
    gobo_id = 21 + i
    img = create_flower_star(points)
    filename = f"/Users/roswellking/Desktop/DMX Visualizer/dmx visualizer/gobos/gobo_{gobo_id:03d}.png"
    img.save(filename)
    print(f"Created gobo_{gobo_id:03d}.png ({points}-pointed flower)")

print("Done! Flower gobos 21-24 created.")
