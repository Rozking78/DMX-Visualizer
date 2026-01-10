--[[
  GeoDraw Layout Plugin - MA3 Lua Plugin

  Calculates and applies layout positions/scales to GeoDraw fixtures.
  Works with the DMX Visualizer for edge-to-edge media pixel mapping.

  Usage:
    Plugin "GeoDraw"                    -- Show help
    Plugin "GeoDraw" "Grid" "4" "4"     -- 4x4 grid layout
    Plugin "GeoDraw" "Grid" "auto"      -- Auto-calculate optimal grid
    Plugin "GeoDraw" "Line" "h"         -- Horizontal line
    Plugin "GeoDraw" "Line" "v"         -- Vertical line
    Plugin "GeoDraw" "Rows" "3"         -- 3 rows layout
    Plugin "GeoDraw" "Perimeter" "4" "4" -- 4x4 perimeter

  Installation:
  1. Copy this file to: MALightingTechnology/gma3_library/datapools/plugins/
  2. In MA3, go to Plugins pool and import this plugin
  3. Select your GeoDraw fixtures
  4. Run the plugin with layout parameters

  Author: Roz
  Version: 1.0.0
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================

local CONFIG = {
    -- Canvas dimensions (must match DMX Visualizer settings)
    canvasWidth = 1920,
    canvasHeight = 1080,

    -- GeoDraw fixture attribute names (from fixture profile)
    attrPosX = "Pan",           -- Position X (mapped to 0-1920)
    attrPosY = "Tilt",          -- Position Y (mapped to 0-1080)
    attrScale = "Zoom",         -- Uniform scale
    attrScaleH = "Focus",       -- Horizontal scale (if available)
    attrScaleV = "Frost1",      -- Vertical scale (if available)

    -- Debug mode
    debug = false,
}

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

local function log(msg)
    Printf("[GeoDraw] " .. tostring(msg))
end

local function logDebug(msg)
    if CONFIG.debug then
        Printf("[GeoDraw DEBUG] " .. tostring(msg))
    end
end

-- Get selected fixtures
local function getSelectedFixtures()
    local selection = SelectionFirst()
    local fixtures = {}

    while selection do
        table.insert(fixtures, selection)
        selection = SelectionNext(selection)
    end

    return fixtures
end

-- Get fixture count from selection
local function getFixtureCount()
    local count = 0
    local selection = SelectionFirst()
    while selection do
        count = count + 1
        selection = SelectionNext(selection)
    end
    return count
end

-- Set attribute value on current selection
local function setAttributeValue(attrName, value, fixtureIndex)
    -- Use At command to set value (value should be 0-100 for most attrs)
    local cmd = string.format('Attribute "%s" At %d', attrName, math.floor(value))
    logDebug("CMD: " .. cmd)
    Cmd(cmd)
end

-- Convert pixel position to DMX value (0-100 range for MA3)
local function pixelToPercent(pixelValue, maxPixel)
    return (pixelValue / maxPixel) * 100
end

-- ============================================================
-- LAYOUT CALCULATIONS
-- (Same math as DMX Visualizer Layout Editor)
-- ============================================================

-- Calculate optimal rows/columns for fixture count
local function autoCalculateGrid(fixtureCount)
    local bestRows = 1
    local bestCols = fixtureCount
    local bestScore = math.huge

    for rows = 1, fixtureCount do
        local cols = math.ceil(fixtureCount / rows)
        if rows * cols >= fixtureCount then
            local cellHeight = CONFIG.canvasHeight / rows
            local squareWidth = cellHeight * cols
            local widthError = math.abs(squareWidth - CONFIG.canvasWidth)
            local emptyCells = rows * cols - fixtureCount
            local score = widthError + emptyCells * 10

            if score < bestScore then
                bestScore = score
                bestRows = rows
                bestCols = cols
            end
        end
    end

    return bestRows, bestCols
end

-- Grid layout: edge-to-edge tiling
local function calculateGrid(fixtureCount, rows, cols, direction)
    local positions = {}

    local cellWidth = CONFIG.canvasWidth / cols
    local cellHeight = CONFIG.canvasHeight / rows

    -- Scale: fixture diameter should fill cell
    -- For GeoDraw, scale is a multiplier where 1.0 = base size (240px diameter)
    -- Scale needed = cell size / 240
    local baseSize = 240  -- baseRadius * 2
    local scaleX = cellWidth / baseSize
    local scaleY = cellHeight / baseSize

    for i = 1, fixtureCount do
        local idx = i - 1  -- 0-indexed for math
        local row, col

        if direction == "across" then
            col = idx % cols
            row = math.floor(idx / cols)
        else  -- down
            row = idx % rows
            col = math.floor(idx / rows)
        end

        -- Position at center of cell
        local x = cellWidth / 2 + col * cellWidth
        local y = cellHeight / 2 + row * cellHeight

        table.insert(positions, {
            x = x,
            y = y,
            scaleX = scaleX,
            scaleY = scaleY,
        })
    end

    return positions
end

-- Line layout: single row or column
local function calculateLine(fixtureCount, orientation)
    local positions = {}

    if orientation == "h" or orientation == "horizontal" then
        local cellWidth = CONFIG.canvasWidth / fixtureCount
        local cellHeight = CONFIG.canvasHeight
        local baseSize = 240
        local scaleX = cellWidth / baseSize
        local scaleY = cellHeight / baseSize

        for i = 1, fixtureCount do
            local x = cellWidth / 2 + (i - 1) * cellWidth
            local y = CONFIG.canvasHeight / 2
            table.insert(positions, {x = x, y = y, scaleX = scaleX, scaleY = scaleY})
        end
    else  -- vertical
        local cellWidth = CONFIG.canvasWidth
        local cellHeight = CONFIG.canvasHeight / fixtureCount
        local baseSize = 240
        local scaleX = cellWidth / baseSize
        local scaleY = cellHeight / baseSize

        for i = 1, fixtureCount do
            local x = CONFIG.canvasWidth / 2
            local y = cellHeight / 2 + (i - 1) * cellHeight
            table.insert(positions, {x = x, y = y, scaleX = scaleX, scaleY = scaleY})
        end
    end

    return positions
end

-- Rows layout: multiple horizontal rows
local function calculateRows(fixtureCount, numRows)
    local fixturesPerRow = math.ceil(fixtureCount / numRows)
    local cellWidth = CONFIG.canvasWidth / fixturesPerRow
    local cellHeight = CONFIG.canvasHeight / numRows
    local baseSize = 240
    local scaleX = cellWidth / baseSize
    local scaleY = cellHeight / baseSize

    local positions = {}
    for i = 1, fixtureCount do
        local idx = i - 1
        local row = math.floor(idx / fixturesPerRow)
        local col = idx % fixturesPerRow

        local x = cellWidth / 2 + col * cellWidth
        local y = cellHeight / 2 + row * cellHeight
        table.insert(positions, {x = x, y = y, scaleX = scaleX, scaleY = scaleY})
    end

    return positions
end

-- Perimeter layout: fixtures around edges
local function calculatePerimeter(fixtureCount, rows, cols)
    local cellWidth = CONFIG.canvasWidth / cols
    local cellHeight = CONFIG.canvasHeight / rows
    local baseSize = 240
    local scaleX = cellWidth / baseSize
    local scaleY = cellHeight / baseSize

    local perimeterPositions = {}

    -- Top edge (left to right)
    for col = 0, cols - 1 do
        local x = cellWidth / 2 + col * cellWidth
        local y = cellHeight / 2
        table.insert(perimeterPositions, {x = x, y = y, scaleX = scaleX, scaleY = scaleY})
    end

    -- Right edge (skip first corner)
    for row = 1, rows - 1 do
        local x = CONFIG.canvasWidth - cellWidth / 2
        local y = cellHeight / 2 + row * cellHeight
        table.insert(perimeterPositions, {x = x, y = y, scaleX = scaleX, scaleY = scaleY})
    end

    -- Bottom edge (right to left, skip first corner)
    for col = cols - 2, 0, -1 do
        local x = cellWidth / 2 + col * cellWidth
        local y = CONFIG.canvasHeight - cellHeight / 2
        table.insert(perimeterPositions, {x = x, y = y, scaleX = scaleX, scaleY = scaleY})
    end

    -- Left edge (skip both corners)
    for row = rows - 2, 1, -1 do
        local x = cellWidth / 2
        local y = cellHeight / 2 + row * cellHeight
        table.insert(perimeterPositions, {x = x, y = y, scaleX = scaleX, scaleY = scaleY})
    end

    -- Assign fixtures to perimeter positions (wrap if needed)
    local positions = {}
    for i = 1, fixtureCount do
        local idx = ((i - 1) % #perimeterPositions) + 1
        table.insert(positions, perimeterPositions[idx])
    end

    return positions
end

-- ============================================================
-- APPLY LAYOUT TO FIXTURES
-- ============================================================

local function applyLayout(positions)
    local fixtures = getSelectedFixtures()

    if #fixtures == 0 then
        log("ERROR: No fixtures selected!")
        return false
    end

    if #fixtures ~= #positions then
        log("WARNING: " .. #fixtures .. " fixtures selected, " .. #positions .. " positions calculated")
    end

    log("Applying layout to " .. math.min(#fixtures, #positions) .. " fixtures...")

    -- Apply positions one fixture at a time
    for i, fixture in ipairs(fixtures) do
        if i <= #positions then
            local pos = positions[i]

            -- Clear selection, select just this fixture
            Cmd("ClearAll")
            Cmd("Fixture " .. fixture.fid)  -- Select by fixture ID

            -- Convert positions to percentages (MA3 attributes typically 0-100)
            local xPercent = pixelToPercent(pos.x, CONFIG.canvasWidth)
            local yPercent = pixelToPercent(pos.y, CONFIG.canvasHeight)

            -- Scale: convert to percentage (scale 1.0 = 100%)
            -- Max scale is typically 6.0 = 600%
            local scalePercent = (pos.scaleX / 6.0) * 100

            logDebug(string.format("Fixture %d: X=%.1f%% Y=%.1f%% Scale=%.1f%%",
                fixture.fid, xPercent, yPercent, scalePercent))

            -- Set attributes
            Cmd(string.format('Attribute "%s" At %.2f', CONFIG.attrPosX, xPercent))
            Cmd(string.format('Attribute "%s" At %.2f', CONFIG.attrPosY, yPercent))
            Cmd(string.format('Attribute "%s" At %.2f', CONFIG.attrScale, scalePercent))
        end
    end

    -- Restore original selection
    Cmd("ClearAll")
    for _, fixture in ipairs(fixtures) do
        Cmd("Fixture " .. fixture.fid .. " +")  -- Add to selection
    end

    log("Layout applied successfully!")
    return true
end

-- ============================================================
-- SHOW HELP
-- ============================================================

local function showHelp()
    log("========================================")
    log("GeoDraw Layout Plugin v1.0.0")
    log("========================================")
    log("")
    log("Usage:")
    log('  Plugin "GeoDraw" "Grid" "4" "4"     -- 4x4 grid')
    log('  Plugin "GeoDraw" "Grid" "auto"      -- Auto grid')
    log('  Plugin "GeoDraw" "Line" "h"         -- Horizontal line')
    log('  Plugin "GeoDraw" "Line" "v"         -- Vertical line')
    log('  Plugin "GeoDraw" "Rows" "3"         -- 3 rows')
    log('  Plugin "GeoDraw" "Perimeter" "4" "4" -- Perimeter')
    log("")
    log("Select fixtures first, then run command.")
    log("========================================")
end

-- ============================================================
-- ENTRY POINT
-- ============================================================

local function main(displayHandle, arguments)
    -- Parse arguments
    if not arguments or #arguments == 0 then
        showHelp()
        return
    end

    local layoutType = arguments[1]:lower()
    local fixtureCount = getFixtureCount()

    if fixtureCount == 0 then
        log("ERROR: No fixtures selected!")
        log("Select GeoDraw fixtures first, then run the plugin.")
        return
    end

    log("Selected fixtures: " .. fixtureCount)

    local positions = nil

    if layoutType == "grid" then
        local rows, cols
        if arguments[2] == "auto" then
            rows, cols = autoCalculateGrid(fixtureCount)
            log("Auto-calculated: " .. rows .. " rows x " .. cols .. " columns")
        else
            rows = tonumber(arguments[2]) or 2
            cols = tonumber(arguments[3]) or 2
        end
        local direction = arguments[4] or "across"
        positions = calculateGrid(fixtureCount, rows, cols, direction)

    elseif layoutType == "line" then
        local orientation = arguments[2] or "h"
        positions = calculateLine(fixtureCount, orientation)

    elseif layoutType == "rows" then
        local numRows = tonumber(arguments[2]) or 2
        positions = calculateRows(fixtureCount, numRows)

    elseif layoutType == "perimeter" then
        local rows = tonumber(arguments[2]) or 4
        local cols = tonumber(arguments[3]) or 4
        positions = calculatePerimeter(fixtureCount, rows, cols)

    elseif layoutType == "help" then
        showHelp()
        return

    else
        log("ERROR: Unknown layout type: " .. layoutType)
        showHelp()
        return
    end

    if positions then
        log("Calculated " .. #positions .. " positions")
        applyLayout(positions)
    end
end

return main
