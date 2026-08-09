# AI Codebase Guide: Murim Ascent

This document is the absolute source of truth for the codebase of **Murim Ascent**. AI assistants must read, internalize, and strictly adhere to these rules before writing or modifying any code. Do not hallucinate systems, do not suggest standalone scripts, and do not write unoptimized code.

## 1. Project Identity & Scope
**Murim Ascent** is a hardcore, permadeath open-world MMORPG on Roblox, built with Rojo. 
* **Theme:** Murim / Manhwa cultivation (Mount Hua Sect, Demonic Cult).
* **Combat:** Deepwoken/Type Soul inspired. Heavily parry-based, posture systems, M1-canceling/feints, and tight visual telegraphs.
* **Movement:** "Qinggong" (Lightness Skill) featuring high-speed momentum retention, wall-running, and double jumps.
* **Rigs:** The game exclusively uses standard R6 rigs to guarantee identical hitbox fairness. Do not write code accommodating R15 or custom rigs.

## 2. Global Architectural Rules
* **Single-Entry Point:** The codebase uses strict `ClientBootstrap.luau` and `ServiceBootstrap.luau` initialization. Never write rogue `LocalScripts` or `Scripts` placed randomly in the Explorer.
* **Finite State Machines (FSM):** All combat and movement states are strictly governed by decoupled FSMs using `LemonSignal`. 
* **Strict Pub/Sub Decoupling:** Cross-controller dependencies are forbidden. Controllers must subscribe to central state modules. 
* **Data-Driven Design (Zero Magic Numbers):** Hardcoding numerical values (like impulse vectors, durations, or fall speeds) inside functional scripts is strictly prohibited. All stats, cooldowns, and movement metrics must be routed to centralized data modules (e.g., `MovementConstants.luau`).

## 3. The "Bouncer" Philosophy (Security & Anti-Exploit)
The client is a liar. Roblox physics and network replication default to a trust-the-client model, which must be aggressively overridden.
* **Client Prediction, Server Authority:** The client predicts visuals (movement, parry animations) immediately for responsiveness, but the server must always validate the math, cooldowns, and state transitions.
* **Server-Side FSM Mirroring:** The server (e.g., `MovementValidationService`, `CombatValidationService`) must maintain a lightweight mirror of the player's FSM state. If an illegal state transition is requested, reject it and rubberband the player.
* **Server-Side Cooldowns:** Never trust client-side cooldowns or closures for limits (e.g., `lastDashTime`). Cooldowns must be tracked in server-side player profiles.
* **Sanity Raycasts:** For complex spatial states (WallLeaping, LedgeVaulting, WallRunning), the server must perform a lightweight validation raycast near the character's server-position to ensure the geometry actually exists before replicating the state.

## 4. Performance & Memory Management (Critical)
* **No Deprecated Timers:** Never use `tick()`. It is deprecated and subject to local timezone shifts. Use `os.clock()` exclusively for all cooldowns, timestamps, and benchmarking.
* **Throttle RunService Raycasts:** Do not execute dense raycasting (e.g., environmental parkour checks) blindly every single frame via `RenderStepped`. Implement delta-time accumulators to throttle physics queries (e.g., checking ~30 times a second).
* **Aggressive Memory Cleanup:** When a character dies or respawns, a new FSM is created. You *must* track and explicitly `:Disconnect()` all event listeners (like `fsm.StateChanged`) on `humanoid.Died` or cleanup phases to prevent catastrophic memory leaks.
* **Garbage Collection (GC) Defense:** Avoid rapid-fire anonymous functions inside `task.delay()`. Track active task threads using a registry (e.g., `activeTasks`) and explicitly call `task.cancel()` when states override each other to prevent GC spikes from input spam.

## 5. Lua/Luau Style & Syntax Guidelines
* **Strict Typing:** Use Luau strict typing (`--!strict`) where applicable to ensure type safety across the FSM.
* **Naming Conventions:**
    * `PascalCase`: Classes, Services, Controllers, Enums.
    * `camelCase`: Local variables, functions.
    * `LOUD_SNAKE_CASE`: Constants inside data modules.
    * `_prefix`: Private members within tables.
* **Formatting:** No semicolons. Indent with tabs. Maximum line length of 100 columns.
* **Iteration:** Do not mix list and dictionary keys. Use `ipairs` for sequential arrays, `pairs` for dictionaries.
* **Yielding & Errors:** Never yield the main thread. Wrap in `task.spawn`, `task.defer`, or use Promises. Use `pcall` for functions that can throw, or prefer returning `success, result`.

## 6. GUI & Persistence
* **GUI Creation:** Never create `ScreenGui`s or GUI elements via code. Every GUI is hand-built in Studio; scripts only `WaitForChild` into existing GUI instances to control logic.
* **Data Saving:** All player data must be session-locked on join. Permadeath wiping must be an atomic, fail-safe operation to prevent combat-logging or wipe evasion.