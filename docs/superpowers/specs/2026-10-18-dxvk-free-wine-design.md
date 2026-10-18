# DirectX 11 and Vulkan games on the free Wine runtime

## Goal

A user with the free Wine runtime (`notproton-wine-11.15`) can play DirectX 11 games, and Vulkan
games, without setting anything up by hand. The app fetches the translation layer it needs and
the run script installs it into each game's prefix at launch.

DirectX 12 and DirectX 9 are out of scope (see Scope). CrossOver runs are unchanged.

## Findings that set the scope

Measured on this Mac (Apple M4, macOS 27) with the free Wine 11.15 in a scratch prefix. The probes
are small Direct3D and Vulkan programs; no game was run.

| Probe | Result |
|---|---|
| Vulkan: enumerate devices | Apple M4, Vulkan 1.2.323, through MoltenVK |
| D3D11 device, Wine's own Direct3D (wined3d, OpenGL) | fails: "None of the requested D3D feature levels is supported" |
| D3D11 device, wined3d with `renderer=vulkan` | fails: unsupported formats, state-table errors |
| D3D11 device, DXVK-macOS 1.10.3 native `d3d11.dll` + `d3d10core.dll` | feature level 11_0 created (MoltenVK) |
| D3D12 device at feature level 11_0, Wine's built-in vkd3d | created, with warnings: no geometry shaders, adapter not matched to the Vulkan device |
| D3D12 device at feature level 12_0 | fails, `E_INVALIDARG` |
| DXVK DLLs present in `system32`, no override | still fails: Wine uses its own `d3d11.dll` unless told otherwise |
| Same, with `d3d11,d3d10core=n,b` | succeeds |

So DX11 needs DXVK, Vulkan already works, and DX12 is not reachable with what is available here.

## Scope

In scope:

- DX11 games, 64-bit and 32-bit, through DXVK-macOS 1.10.3 (the `d3d11.dll` and `d3d10core.dll` it
  ships for each architecture).
- Vulkan games, through the runtime's own `winevulkan` and `libMoltenVK.dylib`. No new code, but the
  launch path must be verified to keep it working.
- Automatic setup: the download happens with the free Wine setup, and the install happens at launch.

Out of scope, and stated in the UI and the README:

- DirectX 12. Wine's built-in vkd3d reaches only feature level 11_0 here, and no macOS build of
  vkd3d-proton exists. Apple's Game Porting Toolkit (D3DMetal) would be the route, and it is a
  separate spec.
- DirectX 9. The pinned DXVK build ships no `d3d9.dll`, and Wine's own Direct3D cannot create a
  device here.
- Per-game settings. Every DX11 game on the free runtime gets DXVK.
- Newer DXVK or MoltenVK. The pins stay where they are until a separate change.

## Design

### 1. Pinned download

The pinned archive is `dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz` from
`https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/` (2,793,443 bytes,
SHA-256 `acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477`). Its root directory is
`dxvk-macOS-async-v1.10.3-20230507-repack`. The DLLs that are used, with their SHA-256s:

| File in the archive | SHA-256 |
|---|---|
| `x64/d3d11.dll` | `0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4` |
| `x64/d3d10core.dll` | `0fa08bba860c63e3abeeabfc96d0e7aa327411a975f8f23d2dc63594ef5f796e` |
| `x32/d3d11.dll` | `f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0` |
| `x32/d3d10core.dll` | `2277187a4e13fc2049fe28cb8dd05b34b48c68031c386c3597ba0e18b0c3d327` |

The `dxvk.conf` in the archive is not used. The `-builtin` variant is not used either, because it is
built for placement inside Wine's own directories. The repack variant is the one the probes used.

The app downloads it with `PinnedDownload`, exactly like the Wine archive. Extraction is confined to
a fresh directory, the four DLLs are verified against the table above, and only then do they move
into `~/Library/Application Support/notproton/dxvk/<pin>/`. Nothing is written there partially.

### 2. Launch-time install (run script)

The run script already installs per-prefix files at launch (`install_lsteamclient_trigger`,
`native_vc_runtime`), inside the prefix lock. The DXVK step follows that pattern.

It runs only when `np_stock_wine` is set, so CrossOver runs are not touched. For each DLL:

- compare the prefix copy with the pinned DLL by hash;
- if it differs or is missing, copy the file into place by writing a temporary name and renaming it,
  so a copy that fails part way never leaves a half-written DLL;
- `x64` goes to `drive_c/windows/system32`, `x32` to `drive_c/windows/syswow64`, and the x32 step is
  skipped if `syswow64` does not exist.

Then it appends `d3d11,d3d10core=n,b` to `WINEDLLOVERRIDES`. That override is the switch: the probes
showed the copied DLLs do nothing without it, and leftover copies are harmless once the override is
gone.

If the pinned DXVK is not on disk, the launch continues without the override and shows an alert
that points to the Status pane's repair action, in the same style as the existing "CrossOver is not
set up" alert. A game launched that way will fail the way it does today, so the alert is the
difference.

Templates are not changed. Each prefix gets the DLLs at launch, so the prefix template identity does
not need to include them.

### 3. Status pane and setup

- The free Wine setup (`WineFetcher` and `RunnerSetup`) also fetches the DXVK archive and records
  it as part of the same setup. Its failure is reported like a Wine failure.
- The Wine row in the Status pane shows whether the DirectX 11 layer is on disk, and offers
  **Repair** when it is missing. Repair fetches the archive again.
- The confirmation dialog states the second download, its size (about 3 MB), its source and its
  license, and says that DirectX 12 and DirectX 9 games are not supported on this runtime.

### 4. Vulkan

No change to the Vulkan path is planned. Its verification is part of testing: the same Vulkan probe
has to pass with the environment the run script builds for a game, and the launch must not add
anything that hides the MoltenVK ICD.

## Testing

- **Pin check.** A test that the four pinned hashes match the archive, run with the real download
  (opt-in, like `RealWineTests`).
- **Install check.** The run script's DXVK step, run against a scratch prefix in both layouts (with
  and without `syswow64`), and a stock layout versus a CrossOver layout, extending the existing
  `envcheck` section.
- **Launch-path Vulkan check.** The Vulkan probe run through the run script's environment, not a
  bare `wine` call.
- **Manual.** You run Megabonk (DX11) and any Vulkan game on the free runtime, and report the
  Wine log and the first screen.

## Risks

- DXVK 1.10.3 is old. Some DX11 games may need a newer DXVK or hit a feature MoltenVK lacks.
- Performance and frame pacing are unmeasured. DXVK on MoltenVK is a translation of a translation.
- Replacing `system32` DLLs in a shared prefix. The copies are only ever DXVK's pinned files, and
  they are inert without the override, but a game that loads its own `d3d11.dll` from the game
  folder would still get it.
- DXVK's license needs checking before the archive is pinned in a published build. I believe it is
  zlib, but that is to be confirmed, not assumed.
- Anti-cheat software that inspects loaded DLLs may refuse the translated layer.

## Review focus for the plan

1. The launch step never runs for CrossOver (the `np_stock_wine` guard, and its test).
2. A failed copy never leaves a truncated DLL in a prefix (rename, not overwrite).
3. The archive is verified before any file leaves the cache, and the extraction stays in its own
   directory.
4. The alert appears when the pinned DXVK is missing, and the launch does not hang or loop.
5. The DirectX 12 and DirectX 9 limits are in the dialog, the README and the Status pane, not only
   in this document.
