# OpenMatrix

OpenMatrix is a lightweight iOS app for sending a still image to an iDotMatrix
display over Bluetooth LE. It currently encodes images as 32 × 32 RGB frames.

## Use

1. Install the app on your iPhone and tap **Scan**. On the first scan, iOS
   should ask to allow Bluetooth access; approve the prompt.
2. Turn on the iDotMatrix display, tap **Scan**, and select it. The scan lists
   nearby BLE devices even when the display does not advertise an iDotMatrix
   name.
3. Choose an image and tap **Send to Display**.
4. To use Shortcuts, add **Send Image to Display** and provide an image. The
   action uses the display selected in OpenMatrix; it can run without opening
   the app after that initial setup.
5. Adjust saturation, contrast, sharpness, orientation, or horizontal mirroring
   in **Image adjustments**. The numeric fields accept values outside the
   slider range; all adjustments are saved and also apply to Shortcuts images.
6. Enter a Last.fm API key and username, select **Sync Now Playing Cover Art**,
   or add that action in Shortcuts to send the current track's cover to the
   display.

OpenMatrix checks Last.fm for track changes every 30 seconds while it is open.
It also requests an iOS background app refresh after the app is backgrounded.
iOS chooses when (or whether) to run that refresh, so background cover updates
are best-effort, not immediate or continuous. Last.fm must report a track as
currently playing and provide cover art for it.

OpenMatrix waits for a Bluetooth write acknowledgement when the display
supports acknowledged writes. The display does not report whether an image was
successfully rendered, so an acknowledged transfer is not proof that the screen
updated.

The app's background Bluetooth capability allows Shortcuts to attempt the send
without presenting the app. iOS may still limit background execution or Bluetooth
connectivity depending on device state and system policy.

If Bluetooth access was previously denied, enable it for OpenMatrix in
**Settings > Privacy & Security > Bluetooth**, then return to the app and scan
again. The app shows Bluetooth startup, permission, and scan status below the
display list.

## Unsigned IPA from GitHub Actions

Every push builds an unsigned iOS archive, packages `OpenMatrix.ipa`, and uploads
it as the `OpenMatrix-unsigned-ipa` workflow artifact. The workflow can also be
started manually with **Build unsigned iOS IPA** under the Actions tab. Download
the artifact from the completed workflow run. The IPA is not App Store-signed;
installing it requires a compatible sideloading/signing workflow.

The Xcode project is generated from `project.yml` using
[XcodeGen](https://github.com/yonaskolb/XcodeGen).
