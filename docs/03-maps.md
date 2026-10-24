# 3. Maps: floors, floor plan images, and rooms

## Floors are automatic

When you load a level that has no saved map yet, RoNTAK groups the level's doors by height and creates one
floor per group: "Floor 1" (lowest), "Floor 2" and so on. With **Floor: auto** selected, the map shows the floor
you're on and switches as you go up and down. Officers on other floors are drawn faded.

Rename the floors in **Calibrate** (for example "Basement", "Ground", "Upstairs"). **Save map** keeps the
names and heights.

## Rooms

The game only knows its rooms by number ("Room 5"), and their outlines are rough, so they're hidden by default.
You name rooms yourself on top of a floor plan image (see "Drawing rooms" below).

To see the game's rooms as a rough guide while drawing, press **Rooms** and tick **Show the game's room
outlines**. With it on, doors are also labelled with the game's room numbers on each side.

## Add a floor plan image (optional)

Any top-down image of the level works. Community-made maps are usually the best; screenshots or your own
sketches also work. You do this once per level (and once per floor). It's saved in
`companion\maps\<LevelName>\`, using the level name shown at the top of the ATAK screen.

1. Load into the level in game, with the companion running.
2. On the ATAK screen, press **Calibrate**.
3. Press **Floor plan image** and pick the image file.
4. The door markers and room outlines are laid roughly over the image. **Tap a door marker**, then **tap
   the same door on the image**.
5. Do the same with a second door, as far from the first as possible. The markers and room outlines snap
   onto the image.
6. Press **Calibrate** again to leave calibration and check: your arrow and the officers should move on the
   image as they move in game.
7. Press **Save map**.

If things look mirrored or stretched, add a 3rd door anchor in a different corner. With 3 or more anchors,
RoNTAK corrects mirrored or stretched images. Delete a wrong anchor with ✕.

No door near a landmark you want to use? Tap the spot on the image instead; RoNTAK offers to use where you're
standing in game.

### Several floors

Each floor gets its own image. The floors already exist (see "Floors are automatic").

1. Pick the floor in the **Floor** list at the top (or walk onto it in game with **Floor: auto**).
2. Load that floor's image and line it up with two of **that floor's** doors, as above.
3. Repeat for each floor, then **Save map**.

If a floor switches at the wrong height (for example on a staircase), adjust its **Min height (Z)** /
**Max height (Z)** in Calibrate. The **Your in-game position** box shows your current Z. Pressing **F6** in game
writes the game's own floor heights per building to `Mods\RoNTAK\bridge\mapinfo.json`.

## Drawing rooms

Name rooms once you have a floor plan image lined up:

1. Press **Rooms**, tap the corners of a room in order, and press **Finish room**.
2. Name it, for example "Kitchen". Doors on its walls are linked automatically.
3. Repeat for each room, then press **Save map**.

Tap inside a named room to target it. "Breach & Clear the Kitchen" uses the Kitchen door nearest the selected
team, or pick one with the **Entry** buttons.

## Where maps are saved, and sharing them

Everything for a level (image, calibration, floors, rooms) is saved in `companion\maps\<LevelName>\` on your
PC. It is **not** uploaded anywhere automatically. To include a map in the RoNTAK repository, commit that folder,
or send its files to whoever maintains the repository.

Community-made maps belong to their creators. Only add one to the public repository if the creator allows it,
or its license allows sharing, and credit the creator (for example in a `CREDITS.txt` in the level's folder).
