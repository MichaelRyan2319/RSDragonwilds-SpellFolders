-- Spell Folders - settings. Edit, then restart the game.

return {
    -- How many folders the Spellbook offers (1 to 24).
    Folders = 8,

    -- The bottom slot (7) of an open folder is a Back button to your own spells.
    -- false gives every folder 12 spells and no button.
    BackButton = true,

    -- Picture for the Back button (a texture path).
    BackIcon = "/Game/Art/UI/MainMenu/CharacterSelect/T_Arrow_L",

    -- Name of the Spellbook category that lists the folders.
    CategoryName = "SPELL FOLDERS",

    -- Icon for that category (a texture path). Empty = the Magic skill's icon.
    CategoryIcon = "",

    -- Write extra detail to ue4ss/UE4SS.log.
    DebugLogging = false,
}
