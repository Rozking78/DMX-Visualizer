# DMX Visualizer - Issues & Notes

## Patching Workflow Issues

### Issue: Bulk Patching Multiple Modes is Tedious

**User Story:**
Want to patch: 16 fixtures at 33ch + 16 fixtures at 23ch + 100 fixtures at 10ch

**Current Limitation:**
- Have to add fixtures one mode at a time
- No way to specify "add X fixtures of mode Y" in a single action
- Workflow requires multiple steps:
  1. Set mode to 33ch, add 16 fixtures
  2. Set mode to 23ch, add 16 more
  3. Set mode to 10ch, add 100 more

**Proposed Solutions (Post-Beta):**
1. **Batch Add Dialog**: "Add X fixtures of mode Y starting at address Z"
2. **Import from CSV/Text**: Define patch in spreadsheet format
3. **Quick Patch Presets**: Save/recall common patch configurations

---

## Other Known Issues

### Per-Fixture Mode UI
- Mode dropdown in table works but requires clicking each row
- "Set Selected" popup helps but requires multi-selecting first

### Address Editing
- No direct editing of universe/address per fixture in table
- Would be useful for custom patching scenarios

---

*Last updated: 2024-12-21*
