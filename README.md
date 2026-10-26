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
