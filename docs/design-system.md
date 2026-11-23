# Zipher design system

Short rules for every screen. Tokens and shared widgets are in
`lib/zipher_theme.dart`. Before/after captures are in `docs/design/`.

## Principles

1. **One job per screen, and one primary action.** The primary action is a
   solid cyan button, pinned to the bottom (above the home indicator), never
   scrolled away. Use `ZipherWidgets.bottomActions` on pages, or
   `ReviewActionBar` in the chat.
2. **Essentials first, details on request.** A review shows what you pay, what
   you get, where it goes, the fee and the time. Limits, addresses, slippage and
   provider disclosures go under **Details**. Warnings that change the decision
   (such as a transparent recipient) stay visible.
3. **Calm by default.** Settled items carry no status label. Color appears only
   when something needs attention or has a meaning (see Status colors).
4. **Every icon has one meaning.** If a glyph needs a tooltip to be understood,
   use words instead. The home header has one status pill; details are in the
   Wallet status sheet.
5. **Dark, quiet surfaces.** Cards are defined by a hairline, not a grey or
   blue fill. Neutral near-blacks only. Key figures (an amount to approve)
   stand on the page, not in a box. No gradients on controls. The only glow is the soft
   cyan light behind the home balance. It must never be clipped.

## Color

| Token | Use |
|---|---|
| `bg` `#08090F` | Page background |
| `surface` / `cardBg` `#0F1014` | Cards, sheets, grouped lists: barely lifted from `bg` |
| `surfaceLight` `#1A1B20` | Inputs, selected segment, ghost buttons, dialogs |
| `border` / `borderSubtle` (white 9%) | 0.5 pt outline of cards |
| `separator` (white 7%) | 0.5 pt hairlines inside cards |
| `text90 / 60 / 40 / 20` | Primary, secondary, tertiary, disabled text |
| `cyan` | Actions and brand: primary button, links, selection |
| `positive` (green) | Received, synced, paired |
| `pending` (yellow) | Waiting on the network: confirming, swapping |
| `negative` (red) | Failed, expired, refused, destructive actions |
| `warm` | Privacy warnings |

Do not use cyan to mean a status, and do not use green for buttons.

## Type

The family is Inter, with the system font (SF Pro) where Inter is not bundled.
Use `ZipherType`:

| Style | Size / weight | Use |
|---|---|---|
| `hero` | 46 / 600, tabular | Home balance |
| `largeTitle` | 32 / 700 | Tab titles (More) |
| `amount` | 26 / 600, tabular | Amounts in reviews |
| `title` | 20 / 700 | Sheet titles |
| `headline` | 17 / 600 | Navigation titles, empty states |
| `rowTitle` / `rowValue` | 16 / 500 | List rows; values use tabular figures |
| `subhead` | 14 | Supporting text |
| `footnote` | 13 | Row subtitles, captions |
| `section` | 13 / 600 | Section headers ("Today", "General") |
| `mono` | 13, system mono fallback | Addresses and ids only |

Use sentence case everywhere. Do not use uppercase or letter-spaced labels.
Amounts always carry their unit and direction (`+0.25 ZEC`, `−0.01 ZEC`).

## Space and shape

- Spacing: 4 / 8 / 12 / 16 / 24 / 32 / 48 (`ZipherSpacing`). Page margin is 16
  in lists and 20 on detail pages (`pagePadding`).
- Radius: `control` 14 (buttons, inputs), `card` 20 (cards, grouped lists),
  `sheet` 24 (sheet top corners), `full` for pills and chips.
- Touch targets: at least 44 pt. Buttons are 52 pt tall.
- Borders: 0.5 pt `borderSubtle` around cards, with no shadows.

## Components

- **Buttons**: always `ZipherButton` (or a stock Material button, which the
  theme maps onto the same styles through `ZipherButtonStyle`).

  | Kind | Look | Use |
  |---|---|---|
  | `primary` | Cyan capsule with a soft top sheen | The one main action: Send, Confirm, Approve, Done |
  | `secondary` | Frosted glass: white 8% over a blur, 0.5 pt light edge | Cancel, Not now, Copy, View on explorer |
  | `tinted` | 14% tint of a color with a matching edge | Destructive (red), or a colored action (Shield, Max) |
  | `plain` | Text only, cyan | Links and low-emphasis actions |

  Every button is a capsule. `large` is 52 pt, fills the width, label 17/600;
  it goes at the bottom of a screen or card. `small` is 36 pt, label 15/600,
  for inline actions. Pressing scales to 97% with a light haptic (primary)
  or a selection tick (others). Loading keeps the color and shows a spinner.
  Disabled buttons become a faint glass capsule with grey text. Labels use
  sentence case. Stock Material buttons follow the same colors and capsule
  shape through `ZipherButtonStyle`, but prefer `ZipherButton`.
- **Grouped list**: `ZipherWidgets.group([...rows])` with `ZipherWidgets.row`:
  icon tile, title, optional subtitle, chevron when tappable. Used by More,
  Wallet status and Activity.
- **Segmented control**: `ZipherSegmented` for 2 to 3 peer views inside a
  page, with an optional count badge. Not used on home.
- **Status dot**: `ZipherWidgets.statusDot`, which always comes with a word
  next to it.
- **Sheets**: opaque `surface`, drag handle, a `title` heading, then content.
- **Sub-page header**: iOS back chevron, centered sentence-case `headline`
  title, actions on the right (`ZipherWidgets.pageHeader`, or the same style
  in an `AppBar`).
- **Lighter fill (`surfaceLight`)** is for controls only (inputs, chips, icon
  tiles, ghost buttons, dialogs), never for content cards.

## Patterns

- **Home header**: account switcher on the left (initial, name, chevron) and a
  single status pill on the right (sync dot and word, plus a lock when Zcash
  traffic uses Tor). Tapping it opens **Wallet status**: sync, network route,
  shielding and agent, each explained in one line and tappable.
- **Home switching**: no tab bar. The conversation fills the screen; a round
  Activity button in the header (clock icon, cyan badge with the number of
  items in progress) swaps it for Activity, which has its own title and Done.
- **Chat shortcuts**: one wrapping row of identical glass chips, like
  suggested replies. Send, Receive and Swap get a cyan icon; the rest a
  neutral one. Tapping a chip is the same as typing its word.
- **Activity**: an "In progress" group first, then groups by day (Today,
  Yesterday, a weekday, then dates). Each row has a direction glyph or token
  logo, a title, the time (and memo), and an amount with its sign. A swap shows
  ZEC spent and the quoted amount (`≈`), never as delivered.
- **Review**: a titled header ("Review swap" / "Review payment") with Cancel
  on the right; each side of the exchange in its own panel (label, amount,
  dollar value and network, token logo on the right), joined by a round swap
  badge; then To, Rate, Network fee (and Total for sends) and arrival time
  with values flush right; then **Details**. One full-width Confirm is pinned
  above the composer while the review is open.
- **Agent**: More → Agent and Wallet status → Agent open the same screen. The
  header shows no agent icon; incoming requests open their own approval screen.
