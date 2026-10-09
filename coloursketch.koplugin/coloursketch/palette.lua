-- The colours and brush sizes. Edit freely; nothing else needs to change.
--
-- The Clara Colour's Kaleido 3 filter shows colour at 150 ppi over a 300 ppi
-- black-and-white panel. Fully saturated values (each channel 00, 80 or FF)
-- come out cleanest; pale or mixed colours look muddy. Use "Colour test" in
-- the menu to compare these, and the alternates below, on the real screen.

return {
    colours = {
        { name = "Black",   rgb = 0x000000 },
        { name = "Red",     rgb = 0xFF0000 },
        { name = "Orange",  rgb = 0xFF8000 },
        { name = "Yellow",  rgb = 0xFFFF00 },
        { name = "Green",   rgb = 0x00A000 },
        { name = "Blue",    rgb = 0x0000FF },
        { name = "Purple",  rgb = 0x8000FF },
        { name = "Brown",   rgb = 0x804000 },
        { name = "Cyan",    rgb = 0x00FFFF },
        { name = "Magenta", rgb = 0xFF00FF },
    },

    -- Shown only on the colour test sheet, next to the palette, as candidates.
    alternates = {
        { name = "Red #CC0000",     rgb = 0xCC0000 },
        { name = "Orange #FF6600",  rgb = 0xFF6600 },
        { name = "Yellow #FFCC00",  rgb = 0xFFCC00 },
        { name = "Green #00FF00",   rgb = 0x00FF00 },
        { name = "Green #008000",   rgb = 0x008000 },
        { name = "Blue #0066FF",    rgb = 0x0066FF },
        { name = "Pink #FF0080",    rgb = 0xFF0080 },
        { name = "Brown #663300",   rgb = 0x663300 },
    },

    -- Brush diameters in pixels (300 ppi). Colour resolution is half that,
    -- so very thin coloured lines look faint; the smallest is still 4 px.
    sizes = { 4, 8, 16, 32 },
    default_size = 2,   -- index into sizes
}
