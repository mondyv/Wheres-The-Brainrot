# StarterGui `Blur` — avoid stacking & stuck blur

Paste-style blur setups often collide with **`UIModalBackdrop`** (ref-count push/pop).

## What breaks

1. **`DepthOfFieldEffect` under `Lighting`**  
   Lines like `Instance.new("DepthOfFieldEffect", Lighting)` **never get destroyed** when the menu closes.  
   Each run (or duplicated scripts) adds **another** effect → stronger blur / “layers”.

2. **`Debris:AddItem(script, 0)`**  
   The **LocalScript** is destroyed immediately, but **Lighting effects and `RunService:BindToRenderStep` keep running** with no code left to turn them off.

3. **`neon:BindFrame(script.Parent, …)`**  
   With `blurscript` under **`BlurModule`**, `script.Parent` is only that **rectangle**.  
   For a full-screen frost, bind **`Main`** (the full-size frame under `Blur` ScreenGui) instead—or drop the neon mesh and rely on translucent frames only.

## What to delete or change

- **Delete** the **`DepthOfFieldEffect` block** at the top of the script (recommended).
- **Delete** **`Debris:AddItem(script, 0)`** so the script can be disabled cleanly by **`UIModalBackdrop`** when no modal is open.
- Optionally **remove** the fractality / **`neon`** block entirely if you only need a light milky veil (use **`Main` / BlurModule` transparency** from code or Studio).

If you **must** keep a **persistent** cinematic depth-of-field unrelated to menus, parent it under **Lighting** and set attribute **`KeepDepthOfField = true`** on that instance so **`UIModalBackdrop`** will not strip it.

## Duplicate scripts

You have **`Blur`** (LocalScript under the `Blur` ScreenGui) **and** **`blurscript`** (under **`BlurModule`**). Either merge into one script or delete the duplicate so effects are not created twice.
