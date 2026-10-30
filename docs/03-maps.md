# 3. Maps: floors, floor plan images, and rooms

## Floors are automatic

When you load a level that has no saved map yet, RoNTAK finds the heights where several doors sit together and
creates one floor for each: "Ground" (lowest), "1st", "2nd" and so on. Doors on stairs and landings don't make
floors of their own. With **Floor: auto** selected, the map shows the floor
you're on and switches as you go up and down. Officers on other floors are drawn faded.

Rename the floors in **Calibrate** if needed (for example when the lowest floor is a basement). **Save map**
keeps the names and heights. If a saved map has the wrong floors, delete them in **Calibrate**
(**Delete floor**) and they're worked out again.

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

### Image the wrong size, tilted or squashed

Community maps are not always drawn to scale. In **Calibrate**, once a floor has an image, the **Adjust image**
box lets you fit it to the door markers by hand:

1. Lower **See-through** to about 60 % so you can see the markers through the image.
2. Tick **Drag moves the image**, then drag the image until one door lines up with its marker.
3. Use **Rotate**, **Scale**, and **Stretch width / height** until the other doors line up too. Type a number in
   the box next to a slider for fine steps.
4. Use **Crop** to cut off borders, legends or a neighbouring floor drawn on the same image.
5. Untick **Drag moves the image** (so dragging moves the map again), set **See-through** back up, and press
   **Save map**.

The markers never move; only the image does. **Reset image** undoes all of it. This works with or without door
anchors: if you set anchors first, the adjustment fine-tunes on top of them.

### Several floors

Each floor gets its own image. The floors already exist (see "Floors are automatic").

1. Pick the floor in the **Floor** list at the top (or walk onto it in game with **Floor: auto**).
2. Load that floor's image and line it up with two of **that floor's** doors, as above.
3. Repeat for each floor, then **Save map**.

If a floor switches at the wrong height (for example on a staircase), adjust its **Min height (Z)** /
**Max height (Z)** in Calibrate. The **Your in-game position** box shows your current Z. Pressing **F6** in game
writes the game's own floor heights per building to `Mods\RoNTAK\bridge\mapinfo.json`.

## Cameras: helicopter, drone and CCTV

The map shows what your support assets are looking at. Press **Cams** in the toolbar to hide or show them.

| Asset | On the map | When |
| --- | --- | --- |
| Air unit (helicopter) | Yellow **H**, a dashed sight line, and a circle where its camera points on the ground | While it is in the level. Brighter while you watch its feed |
| Suspects / civilians the air unit tracks | Their marker with a yellow ring and "air unit" | While the helicopter tracks them |
| ...after it loses them | Hollow dashed marker with **?** and "last seen 2m" | At their last known position, until they surrender, are restrained or go down |
| Drone | Green **X** with its view cone | While it is deployed |
| CCTV | Blue camera pins with view cones | Only once the cameras are wired to your tablet |
| The CCTV feed you are watching | Its pin is filled, ringed and labelled **LIVE** | While that feed is on your screen |

Tapping a person the air unit spotted selects **their spot**, not the person: use Move To, Cover Area or Deploy
Grenade there. Restrain and Report become available once they surrender.

No video is copied out of the game: the cones are drawn from the cameras' positions and angles, so they cost
no frame rate.

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
