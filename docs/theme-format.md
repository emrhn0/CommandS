# CommandS theme format

Settings > Appearance > **Import theme…** reads a JSON file in this format.
A theme sets the app's own colours and the SSH terminal's colours, including
its 16 ANSI colours.

```json
{
  "format": "commands-theme",
  "version": 1,
  "name": "Example Ocean",
  "dark": true,
  "ui": {
    "background": "#0F1B26",
    "panel": "#0B151E",
    "panelAlt": "#16273A",
    "border": "#22384D",
    "text": "#D6E4F0",
    "textDim": "#7D93A8",
    "accent": "#4FB3D9"
  },
  "terminal": {
    "background": "#0F1B26",
    "foreground": "#D6E4F0",
    "ansi": [
      "#0B151E", "#E06C75", "#7FC67F", "#E5C07B",
      "#4FB3D9", "#B48EAD", "#5FC9C9", "#D6E4F0",
      "#3B5266", "#FF8A93", "#9FE09F", "#FFD98F",
      "#7FD0F0", "#D4A8CC", "#8FE6E6", "#FFFFFF"
    ]
  }
}
```

## Fields

| Field | Meaning |
|---|---|
| `format` | Always `"commands-theme"`. |
| `version` | Always `1`. |
| `name` | Shown under the theme's card, 1 to 40 characters. Importing a theme with the same name replaces the earlier one. |
| `dark` | `true` for a dark theme, `false` for a light one. |
| `ui.background` | The window behind everything. |
| `ui.panel` | Sidebars, cards and dialogs. |
| `ui.panelAlt` | Raised surfaces: menus, the title bar of a preview. |
| `ui.border` | Hairlines between surfaces. |
| `ui.text` | Normal text. |
| `ui.textDim` | Secondary text and hints. |
| `ui.accent` | Buttons, focus rings and selections. |
| `terminal.background` | SSH terminal background. |
| `terminal.foreground` | SSH terminal text. |
| `terminal.ansi` | Exactly 16 colours: black, red, green, yellow, blue, magenta, cyan, white, then the same eight bright. |

Every colour is `#RRGGBB`. A file that is missing a field, has an unknown
version or a colour in another form is refused with a message saying what is
wrong. Files larger than 64 KB are refused.

## Notes

- Imported themes are stored on this computer only. They are not part of
  connection exports.
- With **Keep my SSH terminal colours** on, choosing a theme changes only the
  app and leaves the terminal colours as they are.
- After choosing a theme, the terminal's background and text colours can still
  be changed by hand under SSH terminal.
