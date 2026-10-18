# 3. Floor plans and rooms

Without a floor plan, the ATAK map shows markers on a dark grid. You can still give orders, but adding the
real building layout makes it far more useful. You do this once per level, and once per floor.

Map files are saved in `companion\maps\<LevelName>\`. The level name is shown at the top of the ATAK screen.

## Step 1: Get a floor plan image

Pick one:

- **Extract it from the game (best look).** Use [FModel](https://fmodel.app/) to open the game's `.pak`
  files (`ReadyOrNot\Content\Paks`). Set it up for the game's Unreal Engine version. Browse the level's
  folder for map, layout, or minimap textures and export them as PNG.
- **Screenshot it.** If the game shows a map of the level in the briefing or on the tablet, take a
  screenshot and crop it to the building.
- **Draw it.** Any top-down sketch works, as long as it's roughly to scale.

You need one image per floor.

## Step 2: Calibrate (line up the image with the game)

1. Start the companion and load into the level in game.
2. On the ATAK screen, press **Calibrate**.
3. Set the **floor name**, and press **Floor plan image** to load your image.
4. In game, walk to a spot that's easy to find on the image, such as a doorway, a corner, or a pillar.
5. On the ATAK screen, **tap that exact spot** on the image. Anchor 1 appears.
6. Walk to a second spot, **far** from the first (opposite side of the building), and tap it. Anchor 2.
7. Press **Calibrate** again to go back to the map and walk around. Your arrow should follow you on the plan.
8. Press **Save map**.

If your marker moves the wrong way (mirrored) or drifts, add a 3rd and 4th anchor in different corners. With
3 or more anchors, RoNTAK corrects mirrored or stretched images. Delete a bad anchor with ✕.

### Several floors

1. Press **Add floor**, load that floor's image, and calibrate it the same way while standing on that floor.
2. Set **Min height (Z)** and **Max height (Z)** for each floor. The **Your in-game position** box shows your
   current Z. Example: ground floor Z ≈ 0 and upstairs Z ≈ 350 → ground floor `-1000` to `200`,
   upstairs `200` to `1000`.
3. With **Floor: auto** selected, the map switches floors as you go up and down. Officers on other floors are
   drawn faded.

## Step 3: Draw rooms

Rooms let you tap anywhere inside a room and order "Breach & Clear the kitchen". RoNTAK picks the room's door
nearest the selected team, or you choose with the **Entry** buttons.

1. Press **Rooms**.
2. Tap the corners of a room, in order around the room.
3. Press **Finish room** and type a name. Doors on its walls are linked automatically. The list shows how
   many were found.
4. Repeat for each room, then press **Save map**.

If a room shows **0 door(s)**, draw its outline closer to the walls, so the door markers sit on the outline.
