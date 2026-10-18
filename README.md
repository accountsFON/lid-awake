# Lid Awake

Close your MacBook and keep working. Lid Awake is a tiny menu bar app that keeps your Mac running with the lid shut, so a long AI agent run, a big build, or a download finishes while the laptop sits closed on your desk. When you open it back up, the Mac is locked and waiting for your password or Touch ID.

Built for anyone who runs AI agents like Claude on a Mac and wants to close the lid without stopping the work.

## Features

- **Keeps running with the lid closed:** stay awake until you turn it off, or for 1, 2, 4, or 8 hours.
- **Locks on close:** the Mac locks the moment the lid shuts, and work keeps going behind the lock screen.
- **Mutes on close:** sound goes quiet while the lid is shut and comes back when you open it.
- **Dark screen:** the built-in screen's backlight turns off behind the lid, and your brightness comes back on open.
- **Master Power Mode:** a virtual monitor appears while the lid is closed, so AI computer use (an agent clicking around your apps) keeps working. The Mac locks the moment you open the lid.
- **Built-in safety:** normal sleep comes back by itself when the timer ends, when the battery drops to 15% unplugged, or when the app quits.
- **Help built in:** a Help window in the menu explains every option.

## Compatibility

| Requirement | Details |
|---|---|
| **macOS** | 13 Ventura or newer |
| **Chips** | Apple Silicon (M1 and later) and Intel, in one universal app |
| **Best on** | MacBooks. On a Mac mini, iMac, or Mac Studio there's no lid, so it simply keeps the Mac awake |
| **Account** | An admin account. Turning it on changes a system power setting, so macOS asks for an admin password |
| **Tested on** | MacBook Pro 16-inch, M4 Max, macOS 26.5.1 (October 2026) |

A few things to know before you install:

- **Intel Macs:** the app is built for Intel too, but so far it has only been tested on Apple Silicon. Reports from Intel owners are welcome in [Issues](https://github.com/accountsFON/lid-awake/issues).
- **Work or school Macs:** Lid Awake needs an admin password to turn on. If your company manages your Mac and you don't have admin rights, ask your IT team first.
- **Master Power Mode and future macOS updates:** the virtual monitor and the instant lock use private Apple system features that apps like DeskPad and BetterDisplay also rely on. A future macOS update could change them. The core features (staying awake, timers, safety) use standard system tools.
- **Unsigned download:** the app is free and isn't notarized by Apple, so macOS warns about an unidentified developer when you download it by hand. The one-line install below avoids the warning.

## Install

Open Terminal and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/accountsFON/lid-awake/main/scripts/install.sh | sh
```

That downloads the latest release into Applications and opens it. Look for the moon icon in your menu bar. Run the same line again any time to update.

**Prefer to download it yourself?** Grab `LidAwake.zip` from the [latest release](https://github.com/accountsFON/lid-awake/releases/latest), unzip it, and drag **Lid Awake** into Applications.

The app is free and open source with no paid Apple notarization, so the first time you open it, right-click the app and choose **Open**, then confirm.

## Use It

1. Click the moon icon.
2. Pick **Turn On (no timer)**, or **Turn On for…** and choose how long.
3. Enter your Mac password once. The icon turns into a sun.
4. Close the lid. The Mac locks, mutes, darkens the screen, and keeps working.
5. Open the lid, sign in, and click **Turn Off** when you're done.

Optional extras in the menu: **Open at Login** keeps the icon there every time you start your Mac, and **Help…** explains every option.

### Skip the Password Prompt

Turning Lid Awake on changes a system power setting, so macOS asks for your password each time. To skip that for good, paste this in Terminal once:

```bash
echo '%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' > /tmp/lid-awake.sudoers && sudo visudo -cf /tmp/lid-awake.sudoers && sudo install -m 440 -o root -g wheel /tmp/lid-awake.sudoers /etc/sudoers.d/lid-awake && rm /tmp/lid-awake.sudoers
```

The rule covers exactly two commands, sleep off and sleep on. Everything else still asks for your password. The `visudo -cf` step checks the rule before installing it. To remove it: `sudo rm /etc/sudoers.d/lid-awake`

## Master Power Mode

AI computer use needs a screen to see and a Mac with no lock screen up. With the lid closed, the built-in screen powers off. Master Power Mode handles both:

- **Lid closes:** sound mutes and Lid Awake adds a virtual 1920 by 1080 monitor. The agent keeps seeing and clicking.
- **Lid opens:** the Mac locks in under half a second, and the virtual monitor goes away so your windows come back.

It's off by default. While the lid is closed in this mode, there's no lock screen, so a keyboard or mouse plugged into the Mac could control it. Use it where the laptop stays with you or somewhere you trust. For everything else, the regular lock on close is the safer choice.

## Good to Know

- **Never put it in a bag while it's on:** a closed laptop working hard with no airflow can overheat. On a desk with the lid shut is fine.
- **Screen-clicking tasks pause while locked:** terminal, code, and background work keep going behind the lock screen. Turn on Master Power Mode for computer use.
- **External monitor:** with a real monitor plugged in, Lid Awake skips the lock, mute, and dimming, since a closed lid at a desk is normal use.

## How It Works

Lid Awake switches off lid-close sleep with `pmset -a disablesleep 1`. A small helper script ([Resources/watchdog.sh](Resources/watchdog.sh)) watches for the stop conditions and switches normal sleep back on. The lock uses the same system call as Ctrl+Cmd+Q, and Master Power Mode's virtual monitor uses the CoreGraphics virtual display API declared in [Sources/LidAwake/VirtualDisplay.h](Sources/LidAwake/VirtualDisplay.h).

## Build From Source

You need the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/accountsFON/lid-awake.git
cd lid-awake
sh scripts/build.sh
sh scripts/install.sh
```

`scripts/build.sh` makes a universal app at `dist/LidAwake.zip`, and `scripts/install.sh` installs that local build. Releases are built automatically by GitHub Actions when a version tag like `v1.9.0` is pushed. See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

```
lid-awake/
├── Sources/LidAwake/    app code (main.swift, VirtualDisplay.h)
├── Resources/           helper script bundled into the app
├── scripts/             build.sh and install.sh
├── .github/workflows/   automated build and release
├── CHANGELOG.md
├── LICENSE
└── VERSION
```

## Made by Five One Nine Marketing

Lid Awake was built by **Caleb Cody**, founder and CEO of [Five One Nine Marketing](https://www.fonmarketing.com). Five One Nine is a growth partner for businesses that want a clear marketing strategy, the systems to run it, and AI built into how the work gets done. We build tools like this in-house so a small team can punch well above its weight.

**The team:** Caleb Cody, Founder and CEO · Mollie Huebner, Operations Manager and Creative Director · Julio Aleman, Lead Developer and AI Engineer

**Recognition:** Best of Georgia Regional Winner, North Metro Atlanta Region

**From a client, Zach Goodfellow:**

> "You'll have a hard time finding people more passionate about helping you build your business than Five One Nine."

Your strategy. Your system. Your growth partner. **[Let's talk](https://www.fonmarketing.com/contact)**

## License

[MIT](LICENSE). Free to use, change, and share.
