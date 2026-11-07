# RoNTAK native mod

A small C++ UE4SS mod that gives RoNTAK's Lua mod the things Lua can't do
safely on UE4SS 3.0.1. Calling in reinforcement teams needs it.

| Function | What it does |
| --- | --- |
| `RoNTAK_NativeVersion()` | `"0.3.0"`: shows the native mod is loaded |
| `RoNTAK_BeginSpawn(context, class, x, y, z, yaw, collision, owner)` | starts a deferred spawn through the game's `GameplayStatics` (Lua's `World:SpawnActor` returns a broken object on this game); gives the actor's path |
| `RoNTAK_FinishSpawn(actor, x, y, z, yaw)` | finishes it, after Lua set the actor up |
| `RoNTAK_AppendObject(owner, property, element)` | appends to an object array (`"SwatAI"`, `"SpawnedGear.Grenades"`) with the engine's allocator (a Lua write past the end of an array writes into game memory) |
| `RoNTAK_ArrayCount(owner, property)` | an object array's length |
| `RoNTAK_CreateWidget(class, owner)` | a widget made the game's way (`WidgetBlueprintLibrary::Create`), for RoNTAK's on-screen text |

Objects are passed as object paths, never as raw addresses, and checked.

It must be built against the UE4SS source **of the exact UE4SS version
players run** (currently v3.0.1), and that source pulls in a private
submodule (UEPseudo) that only GitHub accounts linked to an Epic Games
account can download.

## Building with GitHub Actions (recommended)

The workflow `.github/workflows/native.yml` builds on a Windows runner and
uploads `RoNTAKNative.zip` (the mod folder, ready to copy into UE4SS's
`Mods` folder) as a build artifact. It needs one repository secret:

1. Link your GitHub account to an Epic Games account
   (<https://www.unrealengine.com/en-US/ue-on-github>) and accept the
   invitation e-mail to the EpicGames organization.
2. Make an SSH key without a passphrase and add its public half to your
   GitHub account (Settings > SSH and GPG keys).
3. Add the private half as the repository secret `UEPSEUDO_SSH_KEY`
   (repository Settings > Secrets and variables > Actions).
4. Run the workflow (Actions > Native mod > Run workflow) or push a change
   under `native/`.

## Building locally (Windows)

Needs Visual Studio 2022 (C++), CMake, Ninja, Rust and an Epic-linked
GitHub account:

```
git clone --branch v3.0.1 --recurse-submodules git@github.com:UE4SS-RE/RE-UE4SS.git native/RE-UE4SS
cmake -S native -B native/build -G Ninja -DCMAKE_BUILD_TYPE=Game__Shipping__Win64
cmake --build native/build --target RoNTAKNative
```

## Installing

The mod folder goes next to RoNTAK in UE4SS's Mods folder:
`Mods\RoNTAKNative\dlls\main.dll` plus `Mods\RoNTAKNative\enabled.txt`.
RoNTAK's UE4SS console line `native: version 0.3.0` shows it's working.
