---
name: deploy
description: Build and deploy the Secretary app to the connected iPhone. Use when the user says "deploy", "deploy to phone", "install on device", "push to phone", or similar.
user_invocable: true
---

Build the Secretary iOS app for device and install it on the connected iPhone.

## Steps

1. Build for device:
```bash
cd /Users/christopherfretz/git/ios-secretary/Secretary && xcodebuild -project Secretary.xcodeproj -scheme Secretary -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath /tmp/secretary-build CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=44KC9KSGZQ 2>&1 | tail -15
```

2. If the build fails, show the errors and stop. Do NOT proceed to install.

3. If the build succeeds, install on device:
```bash
xcrun devicectl device install app --device 00008150-0002456A0C47801C /tmp/secretary-build/Build/Products/Debug-iphoneos/Secretary.app
```

4. Launch the app:
```bash
xcrun devicectl device process launch --device 00008150-0002456A0C47801C com.secretary.ios
```

5. Report success or failure to the user.

## Important
- Device UDID: 00008150-0002456A0C47801C
- Dev Team: 44KC9KSGZQ
- Bundle ID: com.secretary.ios
- If project.yml has changed, run `xcodegen generate` first before building.
