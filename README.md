# Rumi

A Mac app for managing disk space, searching for files, and giving you better control over your storage.

![Rumi's cartridges: a file, a folder, small and narrow ones, an open folder, the small stuff, and what macOS uses](docs/cartridges.png)

## What you can do with it

- See what's taking up space. Bigger cartridge, more space. Each colour is a kind of file.
- See the space macOS uses for itself, which most apps leave out.
- See what grew or shrank since you last looked.
- Clear caches, old downloads and duplicates. Everything goes to the Trash, so you can undo it.
- Search for any file from the menu bar, or press ⌃⌥Space in any app.
- Open photos, videos and code without leaving the app.
- Show only what you haven't touched in months.
- Use the whole map from the keyboard, or with VoiceOver.
- It keeps itself up to date. Opening it doesn't start a scan.
- Plug in a drive and map that too.
- It can warn you when space runs low. Once, not every day.
- Ask what a folder is, and whether it's safe to delete.
- If your disk is filling up steadily, it says roughly when it will be full.

It runs entirely on your Mac. No account, and nothing is sent anywhere.

## Install

Download [Rumi.dmg](../../releases/latest/download/Rumi.dmg), open it, and drag Rumi to Applications.

You need an Apple Silicon Mac on macOS 14 or later.

The first time you open Rumi, macOS will block it, because it isn't signed with a paid Apple developer account. Click Done, then go to System Settings › Privacy & Security, scroll down and click Open Anyway. You only do this once.

Then it asks for Full Disk Access so it can see Mail, Photos and other protected folders.

Closing the window keeps Rumi in the menu bar. ⌘Q quits it. Right-click the menu bar icon to start it at login.

### Or build it yourself

You need Apple's command line tools (`xcode-select --install`). You don't need Xcode.

Download or clone this repo, then run this in its folder:

```sh
scripts/build.sh --install
```

That builds Rumi, copies it to Applications and opens it.

### If you rebuild often

macOS forgets Full Disk Access each time the app is rebuilt, unless it's signed the same way every time. Set `RUMI_SIGN_ID` to a code-signing identity from your keychain (a self-signed one is fine, and `scripts/signing-setup.sh` makes one) and the access sticks.

## The code

- `mac/Sources` is the Swift app: the disk scanner, search, duplicates, and the Trash with undo.
- `web` is the interface. The app shows it in a web view.
- `scripts` is the build, and `scripts/release.sh` makes the download. It's plain `swiftc`, with no Xcode project.

## Status

I built this for my own Mac. It works well there, and you may hit rough edges on yours.

## Licence

MIT. See [LICENSE](LICENSE). The font, M PLUS Rounded 1c, is under the SIL Open Font License (`web/fonts/OFL.txt`).
