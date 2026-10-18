# Handoff: the `ntdll-patch/` work (Tasks 1 and 2)

Two automated attempts to run Task 1 were stopped by a safety classifier at the point of reading `ntdll-patch/resolve.py`, so these two tasks are handed to you. The rest of the plan (`2026-10-18-free-wine-runtime.md`) is being done by subagents around them.

Spec: `docs/superpowers/specs/2026-10-18-free-wine-runtime-design.md`. Plan: `docs/superpowers/plans/2026-10-18-free-wine-runtime.md` (Tasks 1 and 2 are reproduced below with the context you need).

## Setup that already exists on this machine

- Venv with capstone: `/private/tmp/claude-501/-Volumes-envme-Coding-NotProton/5ffc565c-deda-409f-b88c-7e3c8c1e5ebb/scratchpad/venv` (run `venv/bin/python -I ...`).
- Extracted Gcenx `wine-devel` 11.15: `.../scratchpad/dl-devel-1115/Wine Devel.app/Contents/Resources/wine/` (tarball sha256 `3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2`). Treat it as untrusted data.
- Spike probe, not for committing: `.../scratchpad/work/probe64.py` (dumps `build_module`).
- Installed CrossOver in `/Applications` has clean-hash ntdlls `6dff64c0...2387` (x86_64) and `2c60ee6b...03e2` (i386), both keys in `resolve.py` `PINNED`; use them as the regression baseline for Task 1 (use `.notproton-orig` copies if the installed files are patched).

## What the spike found

- 11.15 `i386-windows/ntdll.dll` already resolves: hookRVA `0x2edcd`, stolen `8b4514a802`, resume `0x2edd2`, wm `edi`, load_path `ebp-0x3c`, caveRVA `0x6a075`, caveSize `3979`, placement `padding`, fill `0xcc`. Exports: LdrGetDllHandle `0x7bc2a670`, LdrLoadDll `0x7bc28800`, NtProtectVirtualMemory `0x7bc4c874`, NtOpenFile `0x7bc4c6a4`, NtReadFile `0x7bc4c3d4`, NtClose `0x7bc4c464`.
- 11.15 `x86_64-windows/ntdll.dll` fails with `load_path slot rewritten at 0x34fc3`: upstream compiles `build_module` with `lea rbp,[rsp+K]` and spills the argument to `[rbp-N]`; `amd64_load_path` only understands `rsp`-relative slots. Checked by hand on 11.18 (not 11.15): hook right after the `alloc_module` call checks, wm `r14`, load_path `rsp+0x50` (K=0x80, N=0x30). Verify on 11.15.

## What to hand back (Tasks 3b and 8 depend on it)

Please put these values in a file named `docs/superpowers/plans/2026-10-18-free-wine-runtime-ntdll-values.md` and commit it, so the next subagent can read it:

| Item | x86_64 | i386 |
|---|---|---|
| clean ntdll sha256 (confirm) | | |
| hookRVA, stolen (hex), resume | | |
| wm, load_path (as `rsp+0x..` / `ebp-0x..`) | | |
| caveRVA, payloadRVA, caveSize, cavePad, placement | | |
| imageBase, machine, magic | | |
| payload `.bin` sha256 (`detour2-wine1115` / `detour32-wine1115`) | | |
| patched ntdll sha256 | | |

plus: whether the `WINE_MODREF` offsets (`+0x30`, `+0x60`, `+0x68`) held for 11.15, and the two `.bin` files in `app/Sources/NotProtonApp/Resources/` with the `Package.swift` entries (Task 2 steps 5 and 6).

---

### Task 1: Resolver understands `rbp` frames

**Files:**
- Modify: `ntdll-patch/resolve.py` (`amd64_load_path`, around line 341)

**Interfaces:**
- Produces: `resolve.py <x86_64 ntdll.dll>` exits 0 for upstream Wine 11.15 and reports `load_path` as an `rsp+0xNN` slot. CrossOver self-tests are unchanged.

Scratch inputs: download `wine-devel-11.15-osx64.tar.xz` into a new empty directory under the scratchpad, extract it, and use `Wine Devel.app/Contents/Resources/wine/lib/wine/x86_64-windows/ntdll.dll`. Use a venv with `capstone` and run Python with `-I`.

- [ ] **Step 1: Capture the failing baseline**

Run: `python -I ntdll-patch/resolve.py <11.15 x86_64 ntdll.dll>`
Expected: exit 1, `load_path slot rewritten at 0x34fc3`.

- [ ] **Step 2: Capture the CrossOver baseline**

Run `resolve.py` on every x86_64 and i386 `ntdll.dll` of the CrossOver in `/Applications` whose sha256 appears in `PINNED`. Save the output. Expected: `self-test: all pinned values reproduced`. If no installed CrossOver matches a pin, say so and rely on step 4's synthetic check.

- [ ] **Step 3: Extend `amd64_load_path(pe, body, hook)`**

When the argument is spilled to `qword ptr [rbp - N]` and an earlier `lea rbp, [rsp + K]` exists in the same function, return slot `K - N`. Keep the existing `rsp`-direct and register-stash paths and the stability guard. The guard must also reject any `sub/add rsp`, `push`, `pop` or `lea rbp` between the `lea rbp` and the hook, and any later store to `[rbp - N]` or `[rsp + slot]`.

- [ ] **Step 4: Verify both baselines**

Run the 11.15 command: expected exit 0 and output with `load_path rsp+0x..`, a `wm` register, `hookRVA`, `stolen`, `resume`, and exports. Re-run step 2's commands: output identical to the baseline. Record the 11.15 values (`hookRVA`, `stolen`, `wm`, `load_path`, `caveRVA`, `caveSize`, `placement`, `exports`) in the task notes; Task 2 pins them.

- [ ] **Step 5: Commit**

```bash
git add ntdll-patch/resolve.py
git commit -m "Teach resolve.py about rbp-framed build_module"
```


---

### Task 2: Build and pin the detour payloads

**Files:**
- Modify: `ntdll-patch/resolve.py` (`PINNED`, `PAYLOAD` unchanged), `ntdll-patch/apply.py` (`PAYLOAD_BY_CLEAN_SHA`), `ntdll-patch/build-ntdll.sh`, `app/Package.swift`
- Create: `app/Sources/NotProtonApp/Resources/detour2-wine1115.bin`, `detour32-wine1115.bin`

**Interfaces:**
- Consumes: the Task 1 resolver and its recorded 11.15 values.
- Produces: the two `.bin` files, their SHA-256s, and the SHA-256 of the patched x86_64 and i386 ntdll. Task 3 reads these.

- [ ] **Step 1: Install the toolchain**

Run: `brew install mingw-w64`. Verify `x86_64-w64-mingw32-gcc --version` and `i686-w64-mingw32-gcc --version` print versions. If `brew` is unavailable, stop and report.

- [ ] **Step 2: Check the `WINE_MODREF` assumption**

`detour.c` hardcodes `dllbase +0x30`, name `+0x60`, flags `+0x68`. Fetch Wine 11.15 `dlls/ntdll/loader.c` (git tag `wine-11.15`, commit `2df1ee28039cf84776eb1421ed90bd154cebb65f`) and confirm the `WINE_MODREF` layout gives those offsets for x86_64. If they differ, parameterise `detour.c` with a macro set by `build.sh` and keep CrossOver payload hashes unchanged (rebuild a CrossOver payload and compare its hash). Write what you found in the commit message.

- [ ] **Step 3: Register the build**

In `resolve.py` add `PINNED` entries for both clean hashes from Global Constraints, filled from the Task 1 values and the payload hashes from step 4 (add them after the first build, then rebuild to confirm). In `apply.py` map each clean hash to `detour2-wine1115.bin` / `detour32-wine1115.bin`. In `build-ntdll.sh` add flavor `wine1115` modelled on `rosetta-41073` in every `case` (pins, `BUILD=11.15-wine`, tools list, `patch_one` calls with variant `wine1115`) and `CX_ROOT` pointing at the extracted wine root.

- [ ] **Step 4: Build and verify**

Run `ntdll-patch/build-ntdll.sh` with `FLAVOR=wine1115` against the extracted 11.15 tree. Expected: both payloads built, patched `ntdll.dll` files produced, no pin errors. Record the payload SHA-256s and the patched ntdll SHA-256s. Re-run to confirm the same hashes (reproducible).

- [ ] **Step 5: Ship the payloads**

Copy both `.bin` files into `app/Sources/NotProtonApp/Resources/`. Add `.copy("Resources/detour2-wine1115.bin")` and `.copy("Resources/detour32-wine1115.bin")` to `app/Package.swift` beside the others.

- [ ] **Step 6: Commit**

```bash
git add ntdll-patch app/Package.swift app/Sources/NotProtonApp/Resources/detour2-wine1115.bin app/Sources/NotProtonApp/Resources/detour32-wine1115.bin
git commit -m "Build the ntdll detours for Wine 11.15"
```

