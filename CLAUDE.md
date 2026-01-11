# DMX Visualizer - Claude Context

## Before Starting Work

Read the ecosystem documentation:
1. `~/Documents/GeoDraw-Ecosystem/ECOSYSTEM.md` - All projects overview
2. `~/Documents/GeoDraw-Ecosystem/DECISIONS.md` - Why things are built this way
3. `~/Documents/GeoDraw-Ecosystem/PROBLEMS_SOLVED.md` - Solutions to hard problems
4. `.claude/architecture.md` - This project's architecture

## This Project

- **Name**: DMX Visualizer
- **GitHub**: https://github.com/Rozking78/DMX-Visualizer
- **Purpose**: Real-time DMX-controlled video/gobo projection
- **Build**: `swift build -c release`
- **Run**: `.build/release/dmx-visualizer`
- **Web Control**: http://localhost:8082

## Related Projects

- **GoboCreator**: Generates gobo textures → `~/Documents/GoboCreator/Library/`
- **Video Engine**: Reference implementation (Electron-based)

## Before Ending Session

1. Run `swift build -c release` to verify no errors
2. Commit and push changes: `git add . && git commit -m "..." && git push`
3. Update DECISIONS.md if architectural choices were made
4. Update PROBLEMS_SOLVED.md if hard problems were solved
