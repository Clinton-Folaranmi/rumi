// Rumi — "What is this?": what Rumi says about folders whose names mean nothing to most people.
// Written by hand. Each answer is three short lines on Rumi's screen, and every one fits on a single line:
//   what   the folder in plain words, like a name (about 18 letters at most)
//   why    one short sentence: why it's safe, or what to do instead (38 at most)
//   safe   the answer, in the words Clean up uses: safe = "Safe to delete", review = "Check first", keep = "Leave it"
// Nothing is guessed: a folder Rumi has no line for gets no "?".
// A folder is found by where it is (`at`, "~" is Home), by how its name ends (`end`) or by its name wherever it is
// (`name`; with `under`, only inside that folder: a folder called "Logs" in your Documents is yours, not an app's).
// `kids` is what Rumi says about anything inside it that has no line of its own: [safe, what, why].
// "{bin}" is replaced by what this Mac calls the Trash.
const GUIDE = [
  // ---- Home
  { at: "~/Library", safe: "keep", what: "Your apps' data", why: "Apps stop working without it." },
  { at: "~/Downloads", safe: "review", what: "Your downloads", why: "Only you know what to keep." },
  { at: "~/Desktop", safe: "review", what: "Your desktop", why: "It's yours. I won't guess." },
  { at: "~/Documents", safe: "review", what: "Your documents", why: "They're yours. I won't guess." },
  { at: "~/Movies", safe: "review", what: "Your videos", why: "The big ones are in Biggest files." },
  { at: "~/Music", safe: "review", what: "Your music", why: "Songs, and music apps' libraries." },
  { at: "~/Pictures", safe: "review", what: "Your pictures", why: "Your Photos library is in here." },
  { at: "~/Public", safe: "review", what: "Shared folder", why: "For people on your network." },
  { at: "~/Applications", safe: "review", what: "Your own apps", why: "Delete the ones you don't use." },
  { at: "/Applications", safe: "review", what: "Your apps", why: "Delete the ones you don't use." },
  { at: "~/.Trash", safe: "safe", what: "The {bin}", why: "It takes space until you empty it.", kids: ["safe", "In the {bin}", "Empty the {bin} to free the space."] },

  // ---- Library: the big ones
  { at: "~/Library/Caches", safe: "safe", what: "Temporary files", why: "Apps make new ones.", kids: ["safe", "Temporary files", "The app makes new ones."] },
  { at: "~/Library/Application Support", safe: "review", what: "Apps' saved data", why: "Some of it is your work.", kids: ["review", "An app's saved data", "Some of it may be your work."] },
  { at: "~/Library/Containers", safe: "review", what: "App Store data", why: "To clear one, delete its app.", kids: ["review", "An app's own data", "To clear it, delete the app."] },
  { at: "~/Library/Group Containers", safe: "review", what: "Shared app data", why: "Mail accounts and chats can be inside.", kids: ["review", "Shared app data", "Accounts and chats can be inside."] },
  { at: "~/Library/Mobile Documents", safe: "keep", what: "iCloud Drive", why: "Deleting here deletes it everywhere.", kids: ["review", "In iCloud Drive", "Deleting here deletes it everywhere."] },
  { at: "~/Library/CloudStorage", safe: "keep", what: "Cloud drives", why: "Deleting here deletes it in the cloud.", kids: ["review", "In a cloud drive", "Deleting here deletes it in the cloud."] },
  { at: "~/Library/Mail", safe: "keep", what: "Your email", why: "Delete mail in the Mail app.", kids: ["keep", "Part of your email", "Delete mail in the Mail app."] },
  { at: "~/Library/Messages", safe: "keep", what: "Your messages", why: "Delete chats in Messages.", kids: ["keep", "Your messages", "Delete chats in Messages."] },
  { at: "~/Library/Logs", safe: "safe", what: "Error logs", why: "Nothing needs them.", kids: ["safe", "An app's error logs", "Nothing needs them."] },
  { at: "~/Library/Preferences", safe: "keep", what: "App settings", why: "Tiny, and apps need them." },
  { at: "~/Library/Saved Application State", safe: "safe", what: "Window layouts", why: "Apps just open fresh." },
  { at: "~/Library/Keychains", safe: "keep", what: "Your passwords", why: "Never delete this." },
  { at: "~/Library/Safari", safe: "keep", what: "Safari's data", why: "History, bookmarks, reading list." },
  { at: "~/Library/Cookies", safe: "review", what: "Website sign-ins", why: "Delete it and you're signed out." },
  { at: "~/Library/HTTPStorages", safe: "review", what: "App sign-ins", why: "Delete it and you're signed out." },
  { at: "~/Library/WebKit", safe: "review", what: "Apps' website data", why: "Delete it and apps sign you out." },
  { at: "~/Library/Fonts", safe: "review", what: "Your fonts", why: "Remove them in Font Book." },
  { at: "~/Library/Calendars", safe: "keep", what: "Your calendars", why: "Delete events in Calendar." },
  { at: "~/Library/Accounts", safe: "keep", what: "Your accounts", why: "Mail, calendar and other sign-ins." },
  { at: "~/Library/Metadata", safe: "keep", what: "Search index", why: "macOS looks after it." },
  { at: "~/Library/Biome", safe: "keep", what: "Usage history", why: "macOS uses it for suggestions." },
  { at: "~/Library/Suggestions", safe: "keep", what: "Suggestions data", why: "macOS looks after it." },
  { at: "~/Library/IntelligencePlatform", safe: "keep", what: "Suggestions data", why: "macOS looks after it." },
  { at: "~/Library/Trial", safe: "keep", what: "Apple's models", why: "macOS looks after them." },
  { at: "~/Library/Daemon Containers", safe: "keep", what: "System data", why: "macOS looks after it." },
  { at: "~/Library/Application Scripts", safe: "keep", what: "App scripts", why: "Tiny, and apps need them." },
  { at: "~/Library/Python", safe: "review", what: "Python packages", why: "Remove them with pip." },
  { at: "~/Library/pnpm", safe: "review", what: "pnpm's packages", why: "Clear with pnpm. Clean up shows how." },
  { at: "~/Library/Android", safe: "review", what: "Android tools", why: "Remove parts in Android Studio." },
  { at: "~/Library/org.swift.swiftpm", safe: "safe", what: "Swift packages", why: "Swift downloads them again." },

  // ---- Library: inside the big ones
  { at: "~/Library/Application Support/MobileSync", safe: "review", what: "iPhone backups", why: "Delete old ones in Finder." },
  { at: "~/Library/Application Support/MobileSync/Backup", safe: "review", what: "iPhone backups", why: "Delete old ones in Finder.", kids: ["review", "A device backup", "Delete it in Finder."] },
  { at: "~/Library/Application Support/AddressBook", safe: "keep", what: "Your contacts", why: "Delete people in Contacts." },
  { at: "~/Library/Application Support/CloudDocs", safe: "keep", what: "iCloud Drive records", why: "macOS looks after it." },
  { at: "~/Library/Application Support/CrashReporter", safe: "safe", what: "Crash reports", why: "Nothing needs them." },
  { at: "~/Library/Logs/DiagnosticReports", safe: "safe", what: "Crash reports", why: "Nothing needs them." },
  { at: "~/Library/Containers/com.docker.docker", safe: "keep", what: "Docker's disk", why: "Clean up inside Docker instead." },
  { at: "~/Library/Group Containers/group.com.apple.notes", safe: "keep", what: "Your notes", why: "Delete notes in Notes." },
  { at: "~/Library/Group Containers/group.com.apple.VoiceMemos.shared", safe: "keep", what: "Your voice memos", why: "Delete them in Voice Memos." },

  // ---- Xcode
  { at: "~/Library/Developer", safe: "review", what: "Xcode's files", why: "Most of it is in Clean up." },
  { at: "~/Library/Developer/Xcode/DerivedData", safe: "safe", what: "Xcode build files", why: "Xcode builds them again.", kids: ["safe", "A project's builds", "Xcode builds them again."] },
  { at: "~/Library/Developer/Xcode/Archives", safe: "review", what: "Archived apps", why: "Keep ones you may need to debug." },
  { at: "~/Library/Developer/Xcode/iOS DeviceSupport", safe: "safe", what: "iPhone support files", why: "They return when you plug in." },
  { at: "~/Library/Developer/Xcode/DocumentationCache", safe: "safe", what: "Xcode's docs", why: "Xcode downloads them again." },
  { at: "~/Library/Developer/Xcode/UserData", safe: "keep", what: "Xcode settings", why: "Your settings and snippets." },
  { at: "~/Library/Developer/CoreSimulator", safe: "review", what: "Simulators", why: "Remove old ones in Xcode.", kids: ["review", "Part of a simulator", "Remove simulators in Xcode."] },
  { at: "~/Library/Developer/CoreSimulator/Caches", safe: "safe", what: "Simulator caches", why: "They come back." },
  { at: "~/Library/Developer/XCTestDevices", safe: "review", what: "Test simulators", why: "Remove them in Xcode." },
  { at: "~/Library/Developer/XCPGDevices", safe: "review", what: "Preview simulators", why: "Remove them in Xcode." },

  // ---- media
  { at: "~/Music/Music", safe: "review", what: "Your Music library", why: "Remove songs in Music." },
  { at: "~/Music/GarageBand", safe: "review", what: "GarageBand songs", why: "They're your work." },
  { at: "~/Music/Audio Music Apps", safe: "review", what: "Music app sounds", why: "Remove them in the app." },
  { at: "~/Movies/TV", safe: "review", what: "Your TV library", why: "Remove downloads in TV." },
  { end: ".photoslibrary", safe: "keep", what: "Your photos", why: "Delete photos in the Photos app.", kids: ["keep", "Part of your photos", "Never delete pieces of it."] },
  { end: ".imovielibrary", safe: "review", what: "iMovie library", why: "Delete projects in iMovie." },
  { end: ".fcpbundle", safe: "review", what: "Final Cut library", why: "Delete projects in Final Cut." },

  // ---- tools that keep things in Home
  { at: "~/.npm", safe: "safe", what: "npm's downloads", why: "npm downloads what it needs.", kids: ["safe", "npm's downloads", "npm downloads what it needs."] },
  { at: "~/.cache", safe: "safe", what: "Tools' temp files", why: "The tools make new ones.", kids: ["safe", "A tool's temp files", "The tool makes new ones."] },
  { at: "~/.cargo", safe: "review", what: "Rust's packages", why: "Its registry folder is safe." },
  { at: "~/.cargo/registry", safe: "safe", what: "Rust downloads", why: "Cargo downloads them again." },
  { at: "~/.rustup", safe: "keep", what: "Rust itself", why: "Remove it with rustup." },
  { at: "~/.gradle", safe: "review", what: "Gradle's files", why: "Its caches folder is safe." },
  { at: "~/.gradle/caches", safe: "safe", what: "Gradle downloads", why: "Gradle fetches them again." },
  { at: "~/.m2", safe: "safe", what: "Maven downloads", why: "Maven downloads them again." },
  { at: "~/.cocoapods", safe: "safe", what: "CocoaPods cache", why: "They download again." },
  { at: "~/.swiftpm", safe: "safe", what: "Swift packages", why: "Swift downloads them again." },
  { at: "~/.gem", safe: "review", what: "Ruby packages", why: "Remove them with gem." },
  { at: "~/.nvm", safe: "review", what: "Node versions", why: "Remove old ones with nvm." },
  { at: "~/.pyenv", safe: "review", what: "Python versions", why: "Remove old ones with pyenv." },
  { at: "~/.rbenv", safe: "review", what: "Ruby versions", why: "Remove old ones with rbenv." },
  { at: "~/.conda", safe: "review", what: "Conda environments", why: "Remove them with conda." },
  { at: "~/miniconda3", safe: "review", what: "Conda's Python", why: "Remove environments with conda." },
  { at: "~/anaconda3", safe: "review", what: "Conda's Python", why: "Remove environments with conda." },
  { at: "~/go", safe: "review", what: "Go's packages", why: "Clear with Go. Clean up shows how." },
  { at: "~/go/pkg/mod", safe: "review", what: "Go downloads", why: "Clear with Go. Clean up shows how." },
  { at: "~/.android", safe: "review", what: "Android emulators", why: "Remove them in Android Studio." },
  { at: "~/.docker", safe: "keep", what: "Docker settings", why: "Docker needs them." },
  { at: "~/.ssh", safe: "keep", what: "Your server keys", why: "Never delete this." },
  { at: "~/.config", safe: "keep", what: "Tool settings", why: "Command-line tools need them." },
  { at: "~/.local", safe: "review", what: "Installed tools", why: "From the command line. Look first." },
  { at: "~/.vscode", safe: "review", what: "Editor extensions", why: "Remove them in the editor." },
  { at: "~/.zsh_sessions", safe: "safe", what: "Terminal sessions", why: "Terminal makes new ones." },
  { at: "~/Virtual Machines.localized", safe: "review", what: "Virtual machines", why: "Delete unused ones in their app." },
  { at: "~/Parallels", safe: "review", what: "Virtual machines", why: "Delete unused ones in their app." },

  // ---- by name, wherever they are
  { name: "node_modules", safe: "safe", what: "Downloaded code", why: "Comes back when you install.", kids: ["safe", "One package", "Comes back when you install."] },
  { name: ".git", safe: "keep", what: "Project history", why: "Every earlier version is in here.", kids: ["keep", "Project history", "Every earlier version is in here."] },
  { name: ".venv", safe: "safe", what: "Project's Python", why: "You can make it again." },
  { name: "__pycache__", safe: "safe", what: "Python shortcuts", why: "Python makes new ones." },
  { name: ".next", safe: "safe", what: "Website build files", why: "The next build remakes them." },
  { name: ".build", safe: "safe", what: "Swift build files", why: "The next build remakes them." },
  { name: ".gradle", safe: "safe", what: "Gradle build files", why: "The next build remakes them." },
  { name: "DerivedData", safe: "safe", what: "Xcode build files", why: "Xcode builds them again." },
  { name: "Caches", under: "~/Library", safe: "safe", what: "Temporary files", why: "The app makes new ones.", kids: ["safe", "Temporary files", "The app makes new ones."] },
  { name: "Cache", under: "~/Library", safe: "safe", what: "Temporary files", why: "The app makes new ones." },
  { name: "GPUCache", under: "~/Library", safe: "safe", what: "Graphics cache", why: "The app makes it again." },
  { name: "Code Cache", under: "~/Library", safe: "safe", what: "Code cache", why: "The app makes it again." },
  { name: "CachedData", under: "~/Library", safe: "safe", what: "Cached data", why: "The app makes it again." },
  { name: "ShaderCache", under: "~/Library", safe: "safe", what: "Graphics cache", why: "The app makes it again." },
  { name: "Logs", under: "~/Library", safe: "safe", what: "Error logs", why: "Nothing needs them." },
  { name: ".Spotlight-V100", safe: "keep", what: "Search index", why: "macOS looks after it." },
  { name: ".fseventsd", safe: "keep", what: "Change log", why: "macOS looks after it." },
  { name: ".DocumentRevisions-V100", safe: "keep", what: "Document versions", why: "Earlier versions of your documents." },
  { name: ".Trashes", safe: "safe", what: "This disk's {bin}", why: "Empty it to free the space." },
  { name: ".TemporaryItems", safe: "safe", what: "Temporary files", why: "Left over. Nothing needs them." },
];

/// What Rumi says about a folder: { safe, what, why }, or null when it has no line for it. Its own line wins (where it
/// is, then how its name ends, then its name); failing that, what the nearest folder above it says about its insides.
function guideFor(path) {
  if (!path) return null;
  const own = p => { const t = tilde(p), n = base(p); return GUIDE.find(g => g.at === t) || GUIDE.find(g => g.end && n.endsWith(g.end)) || GUIDE.find(g => g.name === n && (!g.under || t.startsWith(g.under + "/"))); };
  const say = (safe, what, why) => ({ safe, what: what.replaceAll("{bin}", BIN), why: why.replaceAll("{bin}", BIN) });
  const g = own(path);
  if (g) return say(g.safe, g.what, g.why);
  for (let p = path.slice(0, path.lastIndexOf("/")); p.length > 1; p = p.slice(0, p.lastIndexOf("/"))) {
    const up = own(p);
    if (up) return up.kids ? say(...up.kids) : null;   // a known folder with nothing to say about its insides ends the search
  }
  return null;
}
