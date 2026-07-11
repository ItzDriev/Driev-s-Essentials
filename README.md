## Driev's Essentials

An addon that is meant to contain, what I concider, essential features for playing / raiding in WoW Classic ERA. Contains features that are similar other addons but with improvements and additional settings for customizability that I felt were lacking.

## Features

### Trinket Tracker & Auto Queue

*   Displays your two worn trinkets with live cooldown swipes, keybind text, and click-feedback — styled to match the classic Blizzard action-button look by default (fully [Masque](https://www.curseforge.com/wow/addons/masque)\-compatible for custom skins).
*   Hover to open a bag menu of your other trinkets for quick manual swapping. Alt+click to hide a trinket from the list; Alt+hover the display to bring hidden ones back.
*   Dock the bag menu to any side/corner of the display frame, or position it freely.
*   **Auto Queue**: set a priority order per trinket slot and let the addon automatically swap in the next available trinket for you — fully combat-safe, and smart enough to never swap a trinket away before it's actually been used and its buff has expired.

### Time-To-Kill Display

*   A clean on-screen TTK estimate for your current target, with configurable font, size, and boss-only mode.
*   Broadcasts updates through [WeakAuras](https://www.curseforge.com/wow/addons/weakauras-2) if installed, or its own lightweight callback event for other addons to hook into.

### Particle Density Control

*   Automatically dials spell-particle density down in raids for better performance, while keeping it up for specific boss encounters where you need to see the mechanics clearly.
*   Per-raid, per-boss checkboxes, plus a class filter so it only runs on the characters you want.

### Raid Frame Manager

*   Freely reposition and rescale Blizzard's default raid frames without touching any other raid-frame addon.

### Raid Cleanup

*   Optionally hides friendly player/pet/guardian/totem nameplate text while in a raid instance, for a cleaner screen during progression.
*   Also able to hide chat bubbles

### Profiles

*   Create, switch between, and delete unlimited profiles — each with its own complete settings and saved positions.
*   Profiles are assigned per character, so different characters or specs can each keep their own setup.
*   Export a profile to a shareable text string and import one from someone else.

### Move Mode

*   A unified "Move UI" mode for repositioning every movable element (TTK display, trinket display/bag menu, raid frames) with instant drag response and a precise X/Y position editor.

### Minimap Button

*   Quick access to the settings panel, with position saved per profile.

## Requirements

*   WeakAuras and Masque are both optional — Works fully standalone without either.

## SavedVariables

`DrievSettingsDB`
