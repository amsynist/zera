# Themes

Zera comes with seven themes: **Zera** (the default), **Tokyo Night**, **Dracula**, **Catppuccin Mocha**,
**Nord**, **Rosé Pine** and **Gruvbox**. Pick one in **Settings → Appearance**. The notch island, the Claude
wings, Tasks and the app opener all follow it. Zera herself and her speech bubble keep their own look.

## Your own themes

A custom theme is a `.json` file in `~/Library/Application Support/Zera/Themes/`. **Settings → Appearance →
New custom theme** writes one for you, copying the theme you're using, and opens it. **Open themes folder**
shows you where they live.

A theme starts from a built-in one (`base`) and changes only the colours it names, so a small tweak is a
single line:

```json
{
  "name": "Night Owl",
  "base": "tokyo-night",
  "colors": {
    "accent": "#82AAFF",
    "highlight": "#C792EA"
  }
}
```

Save the file and Zera repaints straight away. If a file can't be read, Settings → Appearance says which one
and why. A colour that isn't valid falls back to the base theme's colour.

Base ids: `zera`, `tokyo-night`, `dracula`, `catppuccin-mocha`, `nord`, `rose-pine`, `gruvbox`.

Colours are `#RRGGBB`, or `#RRGGBBAA` to add transparency.

| Key | What it colours |
| --- | --- |
| `glassTop`, `glassBottom` | The island and the wings, as a top-to-bottom gradient |
| `edge` | The island's outline and the soft glow around it |
| `surface`, `surfaceHover`, `surfaceStrong` | Chips, secondary buttons, segmented controls; their hover and pressed states |
| `row` | List rows and tiles |
| `field` | Text fields and search boxes |
| `border`, `divider` | Hairline edges and separator lines |
| `text`, `textSecondary`, `textTertiary` | Main text, then metadata, then hints and placeholders |
| `accent`, `accentDeep` | Main actions, the selected tab, toggles and progress; the gradient runs from `accent` to `accentDeep` |
| `highlight` | A second colour, shown in the theme's preview in Settings |
| `onAccent` | Text on a filled accent badge |
| `success`, `warning`, `danger`, `info` | Done / approve, waiting / attention, stop / reject / delete, links and info |

The island is always dark, so themes work best with a dark `glassTop` and `glassBottom` and light `text`.
