-- Transitional bridge for the 1.1.0 folder rename.
--
-- WoW names each addon's SavedVariables file after its FOLDER, so renaming
-- "Driev's Essentials" -> "DrievsEssentials" left the old settings file
-- (.../SavedVariables/Driev's Essentials.lua) with no addon to load it — which
-- is why profiles appeared to vanish on update. Addons have no file access, so
-- the data cannot be recovered from Lua any other way.
--
-- This addon exists ONLY to keep that filename alive. Declaring the same
-- SavedVariables global makes WoW load the old file for us; we then stash it
-- under a separate global so the renamed addon can adopt it (see
-- migrateLegacyDB in Core.lua). It registers no events and touches nothing else.
--
-- This folder sorts before "DrievsEssentials" alphabetically, so it always
-- loads first and the stash is ready before core starts.
--
-- Once your profiles are back, this folder can be safely deleted.
if type(DrievSettingsDB) == "table" and type(DrievSettingsDB.profiles) == "table" then
    _G.DrievEssentialsLegacyDB = DrievSettingsDB
end
