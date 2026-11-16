# Settings

The **Settings** tab has four sub-tabs: **Theme**, **Layout**, **Other**, and **Debug**.

## Theme

Appearance of the CleanBot window:

- **Theme** — **Blizzard** (default) uses the standard WoW window art: the gold dialog border,
  grey Interface-Options-style boxes, and Options-style tabs. **Flat (ElvUI)** is the original
  CleanBot look: it matches your ElvUI skin when ElvUI is installed, otherwise flat panels tinted
  by the Accent Color. Changing the theme needs a UI reload — after **Apply**, CleanBot offers to
  reload for you.
- **Scale** — overall size.
- **Transparency** — background opacity.
- **Accent Color** — the border tint (Flat (ElvUI) theme only; the Blizzard theme keeps the stock
  border colors, so this option is hidden there).

If you use **ElvUI** and want CleanBot to match it, pick the **Flat (ElvUI)** theme. CleanBot's
tabs on the vendor and Dungeon Finder windows always match ElvUI when it is installed.

## Layout

Fine-grained spacing controls (the padding and margins around panels, headers, buttons, and
other widgets), with a **Show Sample Layout** preview. Changes apply live. This is purely
cosmetic — leave it alone unless you want to tweak the spacing.

## Other

### Behavior

- **Enable Bot Emotes** — a bot waves when you switch to its tab.
- **Auto-Enable Self as Bot** — run your own character as a bot each time you log in.
- **Enable Item Glow** — rarity-colored glow on uncommon-or-better items (shown unless CleanBot is
  using the ElvUI skin, which has its own quality borders).
- **Hide Bot Chatter** — keeps CleanBot's own command whispers, the bot replies it requests, and
  the server output it triggers out of your chat window. Turn it **off** if you want to see the
  raw traffic.

### Dungeon Finder

- **Show Recruiter Tab** — attaches a bot-recruiter tab to the Dungeon Finder window for summoning
  a level-matched bot by role and class. See
  [Managing Bots](managing-bots.md#recruit-from-the-dungeon-finder).

### Action Bar

- **Show Action Bar** and **Action Bar Edit Mode** — same toggles as the minimap right-click.
- **Customize** — show/hide individual bar buttons and flyout options. See
  [Action Bar](action-bar.md).

## Debug

Hidden by default. Type `/cbdebug enable` to reveal it. These are developer diagnostics
(bridge override, simulate mode, timing, the icon browser) — see [Debug Tools](debug-tools.md).
