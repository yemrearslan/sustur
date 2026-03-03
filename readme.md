# Sustur (Mute) 🎙️


[![Download Sustur](https://img.shields.io/badge/Download-Sustur.dmg-blue?logo=apple&logoColor=white)](https://github.com/yemrearslan/sustur/releases/latest)
[![CC BY-NC 4.0][cc-by-nc-shield]][cc-by-nc]



[cc-by-nc]: https://creativecommons.org/licenses/by-nc/4.0/
[cc-by-nc-image]: https://licensebuttons.net/l/by-nc/4.0/88x31.png
[cc-by-nc-shield]: https://img.shields.io/badge/License-CC%20BY--NC%204.0-lightgrey.svg


**Sustur** is a lightweight, open-source macOS (Tahoe/Apple Silicon) menu bar utility designed to give you total control over your microphone. It solves the annoying "Dictation" popup issue on macOS while providing advanced features like Push-to-Talk and volume memory.

## ✨ Features

* **F5 Key Remapping:** Intercepts the F5 (Dictation) key to toggle your microphone, preventing the intrusive macOS "Enable Dictation?" system dialog.
* **Volume Memory:** Automatically remembers your last microphone volume level. When unmuted, it restores your previous setting instead of jumping to 100%.
* **Push-to-Talk (PTT):** A dedicated mode where the microphone is only active while holding down the F5 key—perfect for quick interjections in meetings.
* **Visual Feedback:** The menu bar icon changes color (Red for Muted, System Default for Active) to provide instant status awareness.
* **Smart Notifications:** Receive native macOS notifications when your mic status changes (disabled during PTT mode to avoid spam).
* **Contextual Menu:** Left-click to toggle mute; Right-click to access settings and modes.

## 🛠️ How to Build

You don't need Xcode installed; the standard Swift compiler (Command Line Tools) is enough.

### 1. Clone or Save the Files

Ensure `sustur.swift`, `build.sh`, `Info.plist`, and `AppIcon.icns` are in the same directory.

### 2. Run the Build Script

Open your Terminal and run:

* **For a quick binary:**
```bash
bash build.sh
```


* **For a shareable Disk Image (.dmg):**
```bash
bash build.sh --dmg
```



## 🔐 Permissions & Security

Since **Sustur** listens for system-wide key presses (F5), macOS requires specific permissions:

1. **Accessibility:** Go to `System Settings > Privacy & Security > Accessibility`. Add and enable **Sustur.app**.
2. **Notifications:** Upon first launch, allow Sustur to send notifications to see status banners.
3. **Microphone:** The app uses AppleScript to control system volume; no actual audio data is recorded or transmitted.

> **Note:** Because the app is "Ad-hoc" signed during the build process, you may need to right-click the app and select **Open** for the first time to bypass the "Unidentified Developer" warning.

## 🚀 Usage

* **Left-Click** the menu bar icon to toggle Mute/Unmute.
* **Right-Click** the icon to enable **Push-to-Talk** or toggle **Notifications**.
* **Press F5** on your keyboard to toggle mute instantly from any app.

## ⚙️ How to Add to Login Items

To make sure Sustur starts automatically when you turn on your Mac:

1. Open **System Settings**.
2. Go to **General > Login Items & Extentions**.
3. Click the **+** button under "Open at Login".
4. Select **Sustur.app** from your Applications folder.


## ⚠️ Security Note: 
* Since this app is not signed with an Apple Developer certificate, macOS will block it on the first launch.

* To bypass: Right-click Sustur.app in your Applications folder and select Open. Then click Open again in the warning dialog.



## 📝 TODO

* [ ] **CoreAudio Integration:** Replace AppleScript with low-level CoreAudio API calls for "Hardware Mute" support (ensuring 0% leakage on certain USB microphones).
* [ ] **Custom Hotkeys:** Add a preference pane to allow users to record their own shortcut keys instead of being locked to F5.



---



This work is licensed under a
[Creative Commons Attribution-NonCommercial 4.0 International License][cc-by-nc].



