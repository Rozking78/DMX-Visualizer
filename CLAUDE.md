# DMX Visualizer - Claude Context

## CRITICAL RULE

**ALWAYS ASK BEFORE MODIFYING CODE.** Before using Edit, Write, git commands, or any action that changes files:
1. State what you're about to do
2. Ask "Should I proceed?"
3. Wait for explicit yes/no

NO EXCEPTIONS. Do not treat problem descriptions as implicit permission to act.

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

---

## Alpha License System (TODO: Implement for DMG build)

### Overview
Copy protection for alpha distribution with 30-day trial + key file extension.

### Key Generator Tool
- **Location**: `~/Desktop/Backup/DMX_Visualizer/Tools/GeoDrawKeyGen`
- **Source**: `~/Desktop/Backup/DMX_Visualizer/Tools/GeoDrawKeyGen-source.swift`
- **Shared Secret**: `GeoDraw2026AlphaSecret!RocKontrol` (must match in both apps)

### Key File Format
```
GEODRAW-ALPHA-KEY
version:1
tester:[name/email]
expires:[YYYY-MM-DD]
sig:[SHA256 hex]
```
Signature = SHA256("tester|expires|SECRET")

### Implementation Plan for DMX Visualizer

**1. Add LicenseManager.swift** (new file)
```swift
import Foundation
import CryptoKit
import Security

class LicenseManager {
    static let shared = LicenseManager()
    private let SECRET = "GeoDraw2026AlphaSecret!RocKontrol"
    private let keychainService = "com.geodraw.dmxvisualizer"
    private let installDateKey = "installDate"
    private let trialDays = 30

    func checkLicense() -> LicenseStatus {
        // 1. Get or set install date from Keychain
        // 2. Check if within trial period
        // 3. If trial expired, look for key file
        // 4. Validate key signature and expiration
        // Return: .valid, .trial(daysLeft), .expired
    }

    func validateKeyFile(at url: URL) -> Bool {
        // Parse key file, verify signature matches
    }

    private func getInstallDate() -> Date? { ... }
    private func setInstallDate(_ date: Date) { ... }
}

enum LicenseStatus {
    case valid(expiresOn: Date, tester: String)
    case trial(daysRemaining: Int)
    case expired
}
```

**2. Add startup check in main.swift** (in applicationDidFinishLaunching)
```swift
let status = LicenseManager.shared.checkLicense()
switch status {
case .expired:
    showLicenseExpiredAlert()
    NSApp.terminate(nil)
case .trial(let days):
    print("Trial: \(days) days remaining")
case .valid(let expires, let tester):
    print("Licensed to \(tester) until \(expires)")
}
```

**3. Key file locations to check**
- `~/Documents/GeoDraw/` (primary)
- `~/Library/Application Support/GeoDraw/` (alternate)
- App bundle Resources folder (for pre-licensed builds)

**4. User flow**
- First launch: Silent, trial starts
- Day 25: Optional reminder "5 days left"
- Day 30+: Alert with "Enter License Key" button
- User places .key file in ~/Documents/GeoDraw/
- Next launch validates and continues

### Files to Modify
1. **NEW**: `Sources/dmx-visualizer/LicenseManager.swift`
2. **EDIT**: `Sources/dmx-visualizer/main.swift` - Add startup check
3. **EDIT**: `Package.swift` - May need Security framework link

### Testing
- Delete Keychain entry to simulate fresh install
- Use key generator to create expired/valid keys
- Test signature tampering detection
