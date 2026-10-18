# NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with the stable Steam Client (version 1791918634) as well as the beta Steam Client (version 1791686101) paired with **CrossOver 26.3 or CrossOver [Preview](https://www.codeweavers.com/preview)
20261006 / 20260821 / 20261015**, with more supported versions to come. A free Wine download is also available, see Free Wine below.

**NTFS file systems/drivers are not currently supported.**

CrossOver is the primary, best supported option. Better support for modifying CrossOver (using custom builds of DXMT/patched D3DMetal/MacGameVideoFix) will come in a future update.

Both the FEX and the Rosetta versions are supported. I recommend using the FEX version of the 
Preview 20261006, as it includes both the FEX version as well as the Rosetta one. 

I further recommend going into Steam Settings - Compatibility and selecting the Rosetta version as your default compatibility tool. You can select FEX on a per game basis by right clicking a game in Steam, going into Properties - Compatibility and selecting FEX there.

If a game has a native macOS version as well as a Windows one, Steam will download the macOS version. To override this behavior, right click on the game, select Properties, select Compatibility. Enable 'Force the use of a specific Steam Play compatibility tool'. Select whichever version of CrossOver you want to do use. That will make Steam download the Windows version. Unchecking the 'Force the use...' box or selecting 'No Compatibility Tool' in the drop down list will revert to the macOS version of the game, with the specifics there varying based on your Steam version.

**Free Wine**

If you don't have CrossOver, NotProton can download a free Wine instead: the Gcenx build of wine-devel 11.15, which is free and open source (LGPL). To get it, open the Status pane and press "Download & Set Up" on the Wine row. After you confirm, it downloads about 190 MB from GitHub, then sets itself up like a CrossOver build. If the download or the setup fails, Wine is not usable until you set it up again from the Status pane.

Nobody has run a game on this Wine yet, so treat it as experimental: the Windows user name fix and loading the Steam client bridge (lsteamclient) are untested on it.

It has limits:
- Rosetta only. There is no FEX version.
- No D3DMetal or DXMT, so graphics use Wine's own Direct3D translation (wined3d and vkd3d), and performance and compatibility will be worse than CrossOver.
- Media codecs need GStreamer.framework. NotProton does not install it.

This is an addition in this fork, not something upstream NotProton plans to support. CrossOver stays the better choice.

**Valve Anti-Cheat is not supported.** Proton itself does not support VAC in Valve titles; Valve ships native Linux ports instead. VAC titles will launch in Insecure Mode and will not allow matchmaking. 

**This project now has a brew cask.** For brew users, you can install via ``brew install --cask notprotonnot/notproton/notproton``

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged.

There are many people who worked on similar ideas, similar projects. I did not base NotProton on their work, but I still want to 
give thanks to the people who came before me:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently. 

[Gio](https://github.com/giodotblue) was working enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself. 
I would have done things differently had I been aware of that. 

Thanks to everyone who has positively contributed to macOS gaming. 

## Development

### Source layout

The macOS app is in `app`. The core logic is in `dylib`. `lsteamclient` is a macOS port of Valve's
lsteamclient. `steam-shim` is a port of Valve's steam-helper from Proton 9.0. `ntdll-patch` builds the
patches that the app applies to the copy of the Wine runtime it makes in
`~/Library/Application Support/notproton/runners/`, so that lsteamclient is loaded. `bridge` builds the Wine
trees that lsteamclient and steam-shim are compiled against. `docs/superpowers` holds design notes.

### What you need

- An Apple silicon Mac. The app targets macOS 15 and later.
- **Full Xcode**, not just the Command Line Tools. The app uses SwiftUI's macros, Swift Testing and
  `xcstringstool`, none of which ship in the Command Line Tools. CI uses Xcode 27. Open Xcode once and accept the
  license (`sudo xcodebuild -license accept`) and install its components (`sudo xcodebuild -runFirstLaunch`).
  Without that last step `make app` stops at the icon with "A required plugin failed to load". If `xcode-select -p` still points at the Command Line Tools, either
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` or
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in your shell.
- Homebrew packages: `brew install mingw-w64 bison flex cmake`. The fonts need `brew install fontforge gpatch` and
  a Python venv with `pip install afdko==4.0.3 fonttools==4.66.1` on your `PATH`. Linting the scripts needs
  `brew install shellcheck` (CI pins 0.11.0).
- Dobby, which is not tracked in the repo. Fetch it at the pinned revision (see `vendor/README.md`):

      git clone https://github.com/jmpews/Dobby.git vendor/dobby
      git -C vendor/dobby checkout 5dfc8546954ce3b3198132ab13fddb89ee92cdd7

### Building the app

This is the same sequence CI runs (`.github/workflows/app.yml`). Run it from the repository root:

    make dobby                 # Dobby, the inline hooking library
    make all                   # notproton.dylib
    make overlay-shim iconmaker appinfo
    make bridge                # clones and builds Wine 11.15 twice, then lsteamclient and steam-shim
    make fonts
    make app-payload           # stages everything the app carries into app/Sources/NotProtonApp/Resources/payload
    make app                   # builds out/NotProton.app

`make bridge` is the slow step. It builds two Wine trees under `scratch/` and needs several GB of disk, but it
only has to run again when `bridge/` changes. `make app-zip` packages the app, and `make clean` removes the build
output.

To run it, open `out/NotProton.app`.

### Faster iteration on the app

Once the payload is staged you can skip the bundle and build just the Swift package:

    cd app
    swift build
    DYLD_FRAMEWORK_PATH="$(swift build --show-bin-path)" "$(swift build --show-bin-path)/NotProtonApp"

Run the binary directly. `nohup`, `env` and other system tools strip `DYLD_` variables, and without it the app
cannot find Sparkle. Without a staged payload the app still starts, but the Status pane says "This build of NotProton
carries no components" and its install buttons stay disabled.

### Tests

    make app-tests             # the Swift tests, with swift test --no-parallel

Some of these tests exercise the installer, the appinfo helper and the payload itself, so they fail with "carries no
components" until `make app-payload` has run. That is expected on a fresh checkout. With the payload staged, all of
them pass.

Three tests are opt-in, because they use the real thing:

- `NOTPROTON_TEST_WINE=1` runs the prefix tests against a real runner and prefix.
- `NOTPROTON_TEST_WINE_DOWNLOAD=1` downloads the free Wine (about 190 MB) from GitHub, installs and patches it in
  a scratch directory, and runs its loader with `--version`.
- `NP_WINE_ROOT=<path>` points the ntdll patch test at an extracted Wine's `Contents/Resources/wine`. It checks that
  the patcher turns the real clean ntdll files into the pinned patched ones.

The C and shell suites do not need Steam or Wine. `make scriptcheck runcheck` lints the shell scripts. CI also runs
`sigcheck`, `callscheck`, `compatcheck`, `compatsvc-check`, `shortcutcheck`, `envcheck`, `buildcheck`, `settingscheck`,
`routecheck`, `bridgecheck`, `gamedrivecheck`, `launchercheck`, `seedcheck`, `activatecheck`, `mincheck` and
`l10ncheck`. The full list is in `.github/workflows/app.yml`.

### The ntdll patches

`ntdll-patch/resolve.py` reads the hook site out of a Wine `ntdll.dll`. It needs `pip install capstone`. Give it a
CrossOver bundle, a Wine directory, or one `ntdll.dll`. For a build it knows, it also checks itself against the pinned
values. `python3 ntdll-patch/test_resolve.py` tests its stack-slot checks.

`ntdll-patch/build-ntdll.sh` builds the detour payloads with the mingw cross compilers and checks that applying them
gives the pinned patched hashes. Set `CX_ROOT` to the runtime's root and `FLAVOR` if it cannot tell which build it is.

Adding a Wine build means, in order:

1. Run `resolve.py` on its `x86_64-windows` and `i386-windows` `ntdll.dll`. It stops with a message if it cannot find a
   safe hook site.
2. Build the payloads (`ntdll-patch/build.sh` and `build32.sh` take the ntdll and a variant name), apply them with
   `apply.py`, and note the payload and patched hashes.
3. Pin it: add the clean hashes to `PAYLOAD_BY_CLEAN_SHA` in `apply.py`, add `PINNED` entries in `resolve.py`, and add a
   flavor to `build-ntdll.sh`. Run it and check that it reproduces the patched hashes.
4. Copy the `.bin` payloads into `app/Sources/NotProtonApp/Resources/` and list them in `app/Package.swift`.
5. Add the build to `SupportedRunners` in `SupportedRunner.swift` and its patch table to `NtdllPatcher.swift`, using the
   values from step 2. The tests that loop over every build check the rest.
