# Releasing Dispatch

The maintainer tags and publishes releases. The contributor guide links here
for the release procedure.

1. On a clean `main` checkout, pull the intended release commit and run
   `scripts/check.sh`.
2. Create and push an annotated version tag, for example:

   ```sh
   git tag -a v1.0.0 -m 'Dispatch v1.0.0'
   git push origin v1.0.0
   ```

3. Check out that tag and run `scripts/bundle.sh` on a Mac with the required
   Swift toolchain. It creates `build/Dispatch.app` and
   `build/Dispatch.app.zip`. The bundle script derives the numeric marketing
   version from the tag and the numeric build number from the Git commit count.
   A source copy without a usable tag falls back to `Resources/Info.plist`.
4. Inspect the packaged values before uploading:

   ```sh
   plutil -extract CFBundleShortVersionString raw -o - build/Dispatch.app/Contents/Info.plist
   plutil -extract CFBundleVersion raw -o - build/Dispatch.app/Contents/Info.plist
   codesign --verify --deep --strict build/Dispatch.app
   ```

5. Create the GitHub release for the tag and attach `build/Dispatch.app.zip`.
   Describe the archive as a build-from-source convenience: it is not
   notarized.

The menu-bar panel displays the packaged marketing version beside “Dispatch”
so users can include it in bug reports. A dirty checkout still produces numeric
bundle versions; make release artifacts only from a clean tagged checkout.

## Distribution

Dispatch is distributed as source, with an unnotarized bundle attached to each
release. A notarized Developer ID download is possible without code changes:
Dispatch does not sandbox, and the hardened runtime already permits `CGEvent`
posting, IOKit HID, and child processes. It would add `xcrun notarytool` and
`xcrun stapler` to `scripts/bundle.sh` and a tag-triggered release job, and
waits until there is demand for it.

The Mac App Store is not an option. App Store apps must enable App Sandbox, and
Dispatch depends on things the sandbox forbids: running `/bin/sh` and
`/usr/bin/ssh` to reach Herdr on other machines; reading
`~/.config/dispatch/`, Herdr's socket, and Herdr's state under `~/.local/state`;
and posting keystrokes to, and activating, other apps. Raw HID access alone
would be allowed with the `com.apple.security.device.usb` entitlement.
