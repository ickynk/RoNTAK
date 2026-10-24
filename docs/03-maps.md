# 3. Maps: game rooms and floor plan images

## Rooms come from the game (automatic)

When you load into a mission, RoNTAK reads the level's rooms from the game itself. The AI uses these same
rooms when it clears. Within a few seconds of loading in, the ATAK map shows:

- **Room names and dashed outlines.** The outline is drawn around the points the AI checks inside each room,
  so it sits slightly inside the walls.
- **Door labels with the rooms on both sides**, for example "Kitchen / Hallway door".

Tap inside a room to target it. "Breach & Clear the Kitchen" uses the Kitchen door nearest the selected
team, or pick one with the **Entry** buttons.

This works on every level with no setup. The rooms are written to `Mods\RoNTAK\bridge\rooms.json` if you
want to look at them.

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

1. Press **Add floor**, load that floor's image, and calibrate it the same way using that floor's doors.
2. Set **Min height (Z)** and **Max height (Z)** for each floor. The **Your in-game position** box shows your
   current Z. Example: ground floor Z ≈ 0 and upstairs Z ≈ 350 → ground floor `-1000` to `200`,
   upstairs `200` to `1000`.
   Pressing **F6** in game writes the game's own floor heights for each building to
   `Mods\RoNTAK\bridge\mapinfo.json`, if you want exact numbers.
3. With **Floor: auto** selected, the map switches floors as you go up and down. Officers on other floors are
   drawn faded.

## Drawing your own rooms (optional)

If a game room is missing or its outline is too rough, draw it yourself:

1. Press **Rooms**, tap the corners of the room in order, and press **Finish room**.
2. Name it. Give it the **same name** as the game room to replace that one.
3. Press **Save map**.
