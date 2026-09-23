# Sudi — front-end design system

Neumorphic ("soft UI") design for the two Flutter flavors described in
`sudi/docs/FLUTTER_INTEGRATION_BRIEF.md`. Screens are drawn against the frozen
contract and the two OpenAPI documents; every screen names the call behind it.

**Viewing it.** Open `design/preview.html` in a browser — all 24 screens, grouped,
each row scrolls sideways. The same screens are also on a pan-and-zoom canvas
with clickable prototype links between them (see `artboards/`).

---

## 1. The one rule that shapes everything else

> Depth is carried by shadow. **State is never carried by shadow.**

Neumorphism's whole vocabulary is a 4–8% luminance difference between two
shadows. That vocabulary disappears in direct sunlight, which is exactly where
this app is used — a Mahidharpura doorway at eleven in the morning. So:

- **Shadows say what a thing is**: raised means you can press it, inset means
  you type into it or it is a track, flat means it is switched off.
- **Colour says what state a thing is in**: queued, synced, someone-else,
  needs-you, blocked. Every one of those is a saturated chip whose text clears
  4.5:1 against its own fill, so it survives glare, a cracked screen protector
  and a cheap panel at minimum brightness.

If you ever find yourself reaching for a softer shadow to mean "pending", stop:
that is the chip's job.

---

## 2. Tokens

### 2.1 Ground and elevation — light (default)

| Token | Value |
|---|---|
| `ground` | `#E3E8F0` |
| `groundSunk` | `#DDE3EC` (pressed / selected fills) |
| `shadowDark` | `#C4CCDA` |
| `shadowLight` | `#FFFFFF` |

| Name | CSS | Used for |
|---|---|---|
| `raised` | `6px 6px 14px #C4CCDA, -6px -6px 14px #FFFFFF` | cards, list rows, secondary buttons, tab bar, keypad |
| `raisedSm` | `3px 3px 8px #C6CEDC, -3px -3px 8px #FFFFFF` | chips, small icon buttons, the selected segment thumb |
| `inset` | `inset 5px 5px 11px #C4CCDA, inset -5px -5px 11px #FFFFFF` | text fields, segmented track, status strip, image wells, progress track |
| `insetSm` | `inset 2px 2px 5px #C7CFDD, inset -2px -2px 5px #FFFFFF` | checkbox, radio, selected list row, active tab |
| `accent` | `5px 6px 14px rgba(1,87,155,.32), -4px -4px 10px #FFFFFF` | the one primary action on a screen |
| `flat` | `none`, fill `#DCE1EA`, ink `#79839A` | disabled — and it always carries a reason |

### 2.2 Light only

There is no dark theme, and that is a design decision rather than a gap.
Neumorphism carries depth in a few percent of luminance; on a dark ground that
difference is close to invisible and the surfaces stop reading as raised or
sunk at all. The app is also used outdoors, where the light ground is the
legible one. `ThemeMode.light` is pinned regardless of the phone's setting.

### 2.3 Accents

| Flavor | Accent (fill) | Accent ink (text) | On accent |
|---|---|---|---|
| `field` | `#03A9F4` | `#01579B` — 6.0:1 | `#06283D` — 5.8:1 |
| `customer` | `#0E6F66` | `#0B564F` — 7.4:1 | `#FFFFFF` — 6.0:1 |

**A brand colour needs two tokens, not one.** `#03A9F4` is bright enough to
work as a fill and nowhere near dark enough to be read as type: white on it is
**2.6:1** and the hex itself as 12px text on the ground is **2.1:1**. Both fail
WCAG AA, and the things drawn in the accent here are reference numbers and the
active tab — exactly the text nobody can afford to squint at. So the fill keeps
the brand hex and `accentInk` carries every accent-coloured glyph.


Two accents, same chroma weight. They are how a person can tell at a glance
which of the two binaries is on screen.

### 2.4 Ink

| Token | Light | Min size |
|---|---|---|
| `ink` | `#1A2032` | any |
| `inkMuted` | `#586178` (5.2:1) | `#9BA4B6` (5.7:1) | any |
| `inkFaint` | `#79839A` | 13px+, never for meaning |
| `hairline` | `#D3DAE5` | — |

### 2.5 State vocabulary

Chip = 5px 10px padding, 11px radius, 11px/800 label.

| State | Fill | Ink | Means |
|---|---|---|---|
| Synced | `#D5E8DE` | `#1B6B48` | the server has it; the office can see it |
| Queued / Retrying | `#F3E2C4` | `#7A4A00` | captured here, not yet sent |
| Someone else | `#E2DEF2` | `#57479B` | a lost race — information, not an error |
| Needs you | `#F3DAD8` | `#8E2A25` | dropped for good; a person must act |
| Blocked / Held | `#D7DCE6` | `#4C5568` | needs a connection, or waiting on a dependency |


### 2.5a The accent and the attention colour are different jobs

The accent is red, and so is the worst state in the app. They are told apart by
**shape and size, never by hue alone**:

| | Brand `#03A9F4` | Attention `#8E2A25` |
|---|---|---|
| Where | one filled pill, full width, bottom of the screen | an 11px chip or a glyph inside a card |
| Says | "do the thing" | "this will not resolve itself" |
| Carries | a verb | an alert triangle, always |

Two consequences that are not optional:

1. **The destructive action is never a filled pill.** "Cancel this pickup" is a
   raised neutral with `#8E2A25` ink and an alert triangle, sitting below the
   primary. One coloured pill per screen means the eye never has to choose
   between two of them under time pressure.
2. **Never put an accent pill and an attention chip in the same card.** If a
   record needs both, the attention chip wins and the action drops to a raised
   neutral.

### 2.6 Type

| Role | Family | Size / weight |
|---|---|---|
| Screen title | Sora | 21–27 / 700, `-0.01em` |
| Section label | Manrope | 13 / 800 |
| Body, list primary | Manrope | 15–17 / 600–700 |
| Body muted | Manrope | 12–14 / 400–600 |
| **References, carats, pieces, hours, timestamps** | IBM Plex Mono | 11–27 / 600 |

Monospace for every figure and identifier is deliberate: `WH/IN/00042`,
`39.92 ct`, `01:24:06` and `±12 m` line up in a column and a wrong digit is
visible. **Never round a carat or piece figure on the device** — display what
the server sends.

### 2.7 Geometry

- Radii: `34` phone/sheet, `22–24` card, `17–20` field / button, `11–13` chip,
  `9` checkbox.
- Side gutter `20px` on list screens, `28px` on focused ones.
- Gap between cards `12–13px`; between sections `14–16px`.
- **Minimum touch target 44×44.** Icon buttons are 44 or 46 square. Neumorphic
  shadows read as part of the shape, so do not count them toward the target.

---

## 3. Component grammar

| Shape | Meaning | Never |
|---|---|---|
| Convex (`raised`) | you can press this | a static label |
| Concave (`inset`) | you type here, or it is a track / well | a button |
| Concave small (`insetSm`) + accent fill | selected, ticked, current tab | — |
| Filled accent pill + `accent` shadow | the single primary action on the screen | two per screen |
| Flat, no shadow, muted ink | disabled | without a reason beside it |

**One primary action per screen.** Everything else is a raised neutral. A
destructive action is a raised neutral with attention-red ink and an alert
triangle — never a filled pill, because the accent is red (§2.5a).

**Disabled is never silent.** `Finish job work` and `Send now` render flat with
a lock or refresh glyph *and* a sentence saying why — "needs a connection". A
greyed-out neumorphic button with no shadow and no explanation is invisible.

---

## 4. The chrome every field screen carries

Four things, always visible, no menu (brief §4.3):

1. **Connection** — a dot (green) or a struck-through signal glyph (grey), in
   the inset status strip. Never a modal, never a full-width red banner.
2. **When it last synced** — "Synced 2 min ago", plain words.
3. **How many intents are queued** — an amber chip, and it is a link.
4. **Per queued intent, why it has not gone** — the queue screen. Retrying with
   the last error and the next attempt; uploading with a progress track; held
   behind its dependency; or a permanent outcome with who won.

---

## 5. Screen inventory

### Field flavor — `/api/field/v1`

| # | Screen | Call |
|---|---|---|
| 01 | Sign in | `POST /auth/login` — the only screen that requires a connection |
| 02 | Unlock | local PIN / biometric over the encrypted DB; never reaches the server |
| 03 | Pickups, online | `GET /sync/pull` scope `pickup` |
| 04 | Pickups, offline | cache + outbox; the collected tail with optimistic rows |
| 05 | Receipt and jangad | `GET /pickups/{id}/jangad/{page}`, page dots |
| 06 | Confirm pickup | `POST /uploads` per page, then `POST /pickups/{id}/confirm` |
| 07 | Cannot collect | `POST /pickups/{id}/cancel` |
| 08 | Take parcels out | `POST /deliveries/take` — multi-select, partial results normal |
| 09 | Proof of delivery | `POST /deliveries/{id}/deliver` — receiver name + signature, both required |
| 10 | Lost the race | 409 `ALREADY_TAKEN` rendered on the record |
| 11 | Job work and timer | `POST /jobwork/{id}/timer` |
| 12 | Move department | `POST /jobwork/{id}/department` |
| 13 | Finish needs a signal | `POST /jobwork/{id}/finish` — **online only** |
| 14 | The queue | the outbox: serial per record, parallel across records |
| 15 | Needs attention | `STALE_INTENT`, `CLOCK_SKEW`, device list |
| 16 | Wiped by the office | 401 `DEVICE_REVOKED` — the remote-wipe screen |

### Customer flavor — `/api/customer/v1`

| # | Screen | Call |
|---|---|---|
| 01 | Mobile number | `POST /auth/otp/request` — the copy says WhatsApp, not SMS |
| 02 | WhatsApp code | `POST /auth/otp/verify`, resend driven by `resend_after` |
| 03 | Name and GST | `POST /auth/register`, `POST /gst`, `POST /gst/skip` |
| 04 | Jangad pages | `POST /uploads` per page, in page order |
| 05 | Collect from | `GET /addresses`, or a typed address |
| 06 | Reference | the result of `POST /jangad` — the whole acknowledgement |

There is no receipt list, no timeline and no invoice screen: those endpoints do
not exist (brief §13).

---

## 6. Two things the screens had to solve that the brief only implies

**Offline submission has no reference.** `POST /jangad` is what mints
`WH/IN/00042`, so a jangad captured in a basement has no reference until it
flushes. Screen 06 shows the acknowledged one in full and the queued one as a
second card that says plainly it gets its reference the moment it arrives —
rather than inventing a placeholder the customer might quote at the office.

**A queued intent never gets a plain tick.** Collected rows on screen 04 show a
tick *and* an amber "Sends when you are back online" strip. An operator who sees
a bare green tick will assume the office can see it.

---

## 7. Implementation notes for Flutter

- **Inset shadows do not exist in `BoxDecoration`.** `BoxShadow` has no `inset`,
  and inset is load-bearing here (every field, every track, the status strip,
  the selected tab). Pick one approach up front and use it everywhere:
  a `CustomPainter` that draws the two inner shadows, or a package that extends
  `BoxDecoration` with `inset: true`. Do not approximate it with a border.
- Build one `NeuBox` widget taking a `NeuStyle` enum
  (`raised / raisedSm / inset / insetSm / accent / flat`) plus a radius, and
  never write a raw `boxShadow` at a call site. That is what keeps 24 screens
  looking like one app.
- Neumorphic surfaces must be **the same colour as their parent**. There is no
  "card colour". A `NeuBox` on anything other than `ground` will look wrong, so
  sheets and dialogs keep the same ground rather than going white.
- Fonts: Sora, Manrope, IBM Plex Mono — all on Google Fonts. Bundle them rather
  than fetching at runtime; the field app opens with no radio.
- Figures use `FontFeature.tabularFigures()` wherever a column of them appears.
- Both flavors share every widget here. Only the accent, the app id, the icon
  and `lib/features/` differ.

---

## 8. Still to decide

1. **Language.** The design is English (assumption A6). Gujarati or Hindi for
   the field app changes type sizes and some button copy — cheap now, awkward
   later.
2. **Field app ownership of the photo.** Screen 06 shows pages captured at the
   confirm step. If operators would rather shoot pages as they go and confirm
   at the end, the capture moves to the receipt screen.
3. **Timer display.** Screen 11 shows a live `HH:MM:SS`. If the office only
   cares about booked hours, a simpler running/stopped state saves a repaint
   loop on a field phone's battery.
