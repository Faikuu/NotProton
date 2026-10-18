# DirectX 11 and 12 through Apple's Game Porting Toolkit, beside the free runtime

## Goal

On this personal fork, a user who has downloaded Apple's Game Porting Toolkit 3.0 can run DirectX 11
and DirectX 12 games through Apple's D3DMetal. The app sets the toolkit up from the Status pane. The
free Wine 11.15 runtime stays as it is, and keeps Vulkan and DirectX 11 through DXVK. The two runtimes
appear as two Steam compatibility tools, and the user picks one per game.

This is for personal use only. The app neither downloads nor includes Apple's toolkit, and nothing in
this design is meant for a shipped build.

## Findings that set the scope

Measured on an Apple M4 under macOS 27, with device-creation probes only. No game was run.

| Probe | Result |
|---|---|
| GPTK 3.0-3 Wine (reports itself as `wine-7.7`), D3D11 device | feature level 11_1, through D3DMetal |
| GPTK 3.0-3 Wine, D3D12 device | feature level 12_0 |
| Free 11.15 runtime with Apple's D3D DLLs copied in | DX11 and DX12 probes crash with an unhandled page fault inside one macOS library (NULL read for DX11, write to `0x8E8` for DX12) |
| GPTK 3.0-3 Wine, Vulkan | not working. Its `winemac.drv` was built without Vulkan (earlier probe) |
| Free 11.15 runtime, Vulkan | device enumerated through MoltenVK |

So Direct3D through Apple's DLLs does not work on the 11.15 build, and Vulkan does not work on the
GPTK build. Both runtimes are needed.

## Approaches

1. **Two runtimes, one Steam compatibility tool each (chosen).** Each game picks its tool. Costs: a
   second runtime on disk, a second prefix per game, and the Steam bridge question in the section
   below.
2. **One runtime on GPTK for everything.** Rejected: Vulkan does not work there.
3. **One runtime on 11.15 with Apple's DLLs.** Rejected for now: the crash above. Revisit only if the
   crash is diagnosed.
4. **One tool that picks the runtime per launch from the game's imported DLLs.** Deferred. It adds
   routing that can be wrong, and it still needs both runtimes. It can be built on top of approach 1
   later.

## Scope

In:

- The GPTK 3.0 runtime, unpacked from the `game-porting-toolkit-3.0-3.tar.xz` archive the user
  downloads from Apple.
- A second Steam compatibility tool backed by that runtime.
- Launch-script branching by runtime kind.
- A Status pane row to set up, repair and remove the runtime.

Out:

- Downloading or bundling Apple's toolkit.
- Automatic routing by graphics API.
- DirectX 9.
- Vulkan through the GPTK runtime.
- Any change to the free runtime's pins.

## Design

### 1. Runtime kind

Each compatibility tool records its runtime kind in a `kind` file beside its `build` file. The kinds
are `crossover`, `free-wine` and `gptk`.

The run script stops inferring the kind from the absence of `bin/cxbottle`. GPTK's Wine has no
`cxbottle`, so the old test would treat it as the free runtime and copy DXVK over D3DMetal's
`d3d11.dll`.

A tool without a `kind` file keeps the old inference, so existing free-runtime tools keep working with
no migration.

- Ruling: an absent `kind` means "infer as before". Cost if wrong: a tool made before this change
  keeps the old inference until it is set up again.

`gptk` takes the stock-Wine branch for the user name (`USER=steamuser`), and skips the DXVK step.

### 2. Runtime location and validation

The runtime lives in `runners/gptk-3.0-3/`, not `runners/crossover-*`. `RunnerStore` and
`RunnerPatcher.verify` treat every `crossover-*` directory as a free runtime to verify.

- Ruling: the `gptk-` prefix keeps the runtime out of the free runtime's checks. Cost if wrong: one
  more name pattern for `RunnerStore.clonedBuilds` to skip.

The Wine root is `Game Porting Toolkit.app/Contents/Resources/wine` inside the archive. Setup refuses,
and writes nothing into the Steam tool, unless all of these are present:

- `bin/wine64` and `bin/wineserver`;
- the Direct3D DLLs and unix bridge libraries the probes loaded, under `lib/wine/`;
- `lib/external/libd3dshared.dylib`;
- `Contents/Info.plist`, which gives the version (`3.0-3`) that the Status pane shows.

Setup extracts into a fresh directory under `runners/`, then swaps it into place, as the DXVK layer
does. Afterwards it removes the quarantine attribute and ad-hoc re-signs the tree. Re-signing uses
no hardened-runtime option, because the hardened runtime made the probes' `ntdll.so` fail to load.

Free space needed is measured before the plan is written, and the plan sets the requirement.

### 3. Steam compatibility tool

A second tool directory, `notproton-gptk-3.0-3`, sits in `compatibilitytools.d`. It holds:

- `build` = `gptk-3.0-3`;
- `kind` = `gptk`;
- a display name of "NotProton GPTK 3.0".

The name starts with `notproton`, so `SupportPaths.notprotonTools` finds it. Steam lists both tools,
and the user chooses one per game under Properties → Compatibility.

### 4. Prefixes

Each kind has its own prefix:

- `free-wine` and `crossover` keep `$STEAM_COMPAT_DATA_PATH/pfx`;
- `gptk` uses `$STEAM_COMPAT_DATA_PATH/pfx-gptk`.

- Ruling: separate prefixes. A prefix made by one Wine should not be opened by the other, because
  7.7 and 11.15 differ. Cost if wrong: a game's first GPTK launch starts with an empty prefix, and
  any save data kept inside the prefix is not carried over.

### 5. Steam bridge (open, and gated by a spike)

The Steam bridge (`lsteamclient`) is loaded into the 11.15 runtime by the ntdll patch in
`NtdllPatcher`, which is pinned per build. GPTK's Wine is 7.7. The patch does not exist for it, and
the bridge is not among its Windows DLLs. It is not known whether a game starts under the GPTK tool
without the bridge.

Before any implementation, run a spike. Launch a test program and Megabonk (DX11) through the GPTK
tool, using the environment of the working probe (`scratchpad/gptk-run.sh`), with no bridge. Record
whether the game starts, whether Steam's API initialises, and what the log says.

The spike decides the next step:

- If the game starts without the bridge, the GPTK tool ships without it, and the README says so.
- If it needs the bridge, the plan adds 7.7 pins to `NtdllPatcher` and `resolve.py`, and rebuilds the
  bridge against 7.7 sources. Whether those sources are available is not yet checked. The design
  stops at that point until the answer is known.

### 6. Launch environment

The GPTK environment is taken from the working probe (`scratchpad/gptk-run.sh`). The plan copies that
environment and does not write a new one. `CX_APPLEGPTK_LIBD3DSHARED_PATH` points at
`lib/external/libd3dshared.dylib` in the GPTK tree, not at the CrossOver path `lib64/apple_gptk`.
Vulkan is not expected to work under this tool.

### 7. Status pane

A row "Game Porting Toolkit" shows one of three states.

- **Not set up.** Offers **Choose…**, a file picker for the `.tar.xz`. If
  `~/Downloads/game-porting-toolkit-*.tar.xz` exists, it is offered as the default.
- **Set up.** Shows `3.0-3`, with **Repair** and **Remove**.
- **Problem** (a missing file, or failed signing). Shows the reason, with **Repair**.

Dialog copy: "NotProton does not download or include Apple's Game Porting Toolkit. You download it
from Apple, and NotProton unpacks the copy you choose into its own folder."

**Remove** deletes the runtime and the Steam tool. It leaves every prefix alone, because prefixes hold
the user's game data.

## Testing

- **Swift unit tests.** A missing `kind` is inferred as before. Validation refuses each missing
  required file. `RunnerStore.clonedBuilds` never lists the GPTK runtime. `notprotonTools` finds the
  GPTK tool. The crossover ntdll patch never verifies a `gptk-` directory.
- **Shell checks (`envcheck`).** The DXVK step is skipped for `kind=gptk` and runs for `free-wine`.
  The GPTK prefix is `pfx-gptk`. A missing `kind` behaves as it does now.
- **Manual.** You run Megabonk (DX11) and one DX12 game through the GPTK tool, and one Vulkan game
  through the free tool. Report the Wine log and the first screen of each.

## Risks

- The Steam bridge on 7.7 (the spike above). It could block games that use the Steam API.
- Personal use only. Apple's terms cover evaluating and testing video games, and this build is not
  shipped.
- Re-signing Apple's binaries ad hoc changes their signatures. This is the same deviation the free
  runtime already makes.
- Disk use: two runtimes, plus the unpacked GPTK tree.
- A later GPTK release may change the layout. Validation fails closed rather than guessing.

## Rulings made for this spec

These are decisions I made without asking. Each can be changed at review.

1. Per-game tool choice in Steam, not automatic routing.
2. A `kind` file, with an absent `kind` falling back to the old inference.
3. A separate prefix for each kind.
4. Only the `.tar.xz` archive is accepted in this version.
5. Remove deletes the runtime and the tool, and leaves prefixes.

## Review focus for the plan

1. The GPTK tool never runs the DXVK step. A DXVK copy over D3DMetal would change DX11 behaviour without
   any sign.
2. A GPTK tree missing any required file is refused before a Steam tool is written.
3. A game launched with the GPTK tool never opens a prefix made by the free runtime.
4. Remove never deletes a prefix.
