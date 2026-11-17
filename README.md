# CleanBot

A clean interface to manage Playerbots on WotLK 3.3.5a Servers. No more complex trees of buttons!

⚠️Requires the latest version of [Playerbots](https://github.com/mod-playerbots/mod-playerbots) installed on your server⚠️

- Fully Skinned for the default WoW UI or [ElvUI](https://github.com/ElvUI-WotLK/ElvUI/tree/master)
    - Choose the **Blizzard** (default) or **Flat (ElvUI)** theme in Settings
- Compatible Optional Extras:
    - [Multibot Bridge Server Module](https://github.com/Wishmaster117/mod-multibot-bridge) - Removes some of the whisper spam and speeds up query/action time
    - [Talented](https://warperia.com/addon-wotlk/talented/) - Opens the large three panel talent tree for bots

# Manage Tab
- Invite/Uninvite, Login/Logout bots
- Group Revive, Release, Eat/Drink, Maintenence, Summon
- Create Custom Presets, Invite All From Preset
- Link an Account for Altbot Usage
    - Invite Linked Account, Unlink Account
- Alt Army: log your account's alts in or out as bots, one at a time or as a list
- Fully Collapsable Sections

<img width="300" alt="Manage tab" src="docs/images/manage.png" />
<img width="300" alt="Altbots and Alt Army sections" src="docs/images/alt-army.png" />

# Individual Tab
- Manage Individual Bots Within Your Party or Raid
- Set Combat, Non-Combat, and Class Specific Strategies
- Target Party/Raid Members to Swap to Them
- Manage gear through drag and drop or context menus
    - View Gold and Items in an intuitive and familiar interface
    - Open Bank (if nearby a banker) or Sell Grays (if near a vendor)

<img width="500" alt="Individual tab" src="docs/images/individual.png" />
<img width="300" alt="Bot inventory" src="docs/images/inventory.png" />

## Quest Log
- Check Failed, Incomplete, and Completed Quests
    - Read quest text and requirements directly for any quest you both share
- Abandon Bot Quests

<img width="700" alt="Bot quest log" src="docs/images/quest-log.png" />

# Group Tab
- Multiselect groups and bots using the standard windows shortcuts
    - CTRL + Click to add/remove selection
    - Shift + Click for range selection
- Add groups, rename them,
- Add bots to the group via name or by current target
- Dynamic default groups for class and role
    - With multiselect, these groups may be all you need to perfectly manage your next raid

<img width="700" alt="Group tab" src="docs/images/group.png" />

# Mini Action Bar
- Freely Movable, Snappable, Disableable, and Reorderable
- Revive/Release
- Follow/Stay/Runaway
- Toggle Passive
- Pull and Attack
- Summon

<img width="300" alt="image" src="https://github.com/user-attachments/assets/30a522cf-69bc-4505-8c6c-29e0e81ea82f" />

# Settings Tab
- Change Theme, Transparency, Scale, Accent Color, and Layout Values
- Enable or Disable a /wave from the bot when selecting them in the UI

<img width="250" alt="Settings - Theme" src="docs/images/settings-theme.png" />
<img width="250" alt="Settings - Layout" src="docs/images/settings-layout.png" />
<img width="250" alt="Settings - Other" src="docs/images/settings-other.png" />

# Automatic Actions
- Open Bot Inventory on Trade
    - Drag and Drop Items to Trade
    - Right Click Items to Remove

# Support
- **Download:** grab the zip from the [latest release](https://github.com/masterdownload/CleanBot/releases/latest) and extract it into `Interface\AddOns` (you should end up with `Interface\AddOns\CleanBot\CleanBot.toc`).
- **Found a bug?** [Open a bug report](https://github.com/masterdownload/CleanBot/issues/new?template=bug_report.yml). Include your CleanBot version, any Lua errors (`/console scriptErrors 1`), and the output of `/cbdebug`.
- **Have an idea?** [Request a feature](https://github.com/masterdownload/CleanBot/issues/new?template=feature_request.yml).
- **Bots misbehaving on the server** (combat AI, pathing, strategies ignored even when typed in chat)? That's usually [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots/issues).
- More help: see the [docs](docs/).

This is a fork of [bennybroseph/CleanBot](https://github.com/bennybroseph/CleanBot) with extra features (Blizzard theme, Alt Army, BridgeRpc). Please report issues with this version here.
