# Dysland

Dysland turns the MacBook notch into a live island for music, timers, alerts and quick controls.

It is a modified version of [Boring Notch](https://github.com/TheBoredTeam/boring.notch), released under the same GPL-3.0 licence.

## Features

- Music controls, with your Apple Music playlists and songs available inside the player
- Synced lyrics, from the closed notch to a full lyrics panel
- A visualizer that follows Apple Music songs without recording your system audio
- Liquid Glass styling that refracts what's behind the notch
- Volume and brightness HUDs that name your output device, such as AirPods or MacBook Pro speakers
- A switcher for choosing which app's media the island controls
- Timers, pop-ups for AirPods, Focus and low battery, and quick search with a calculator (⌃⌥Space)
- Calendar, file shelf with AirDrop, and a camera mirror that can pop out into its own window

## Requirements

Dysland has been tested on one Apple Silicon MacBook Pro with a notch, running macOS 27. Other Macs may work but are untested.

## Permissions

macOS will ask for access as you turn features on:

| Permission | Used for |
| --- | --- |
| Screen Recording | The glass refraction behind the notch |
| Accessibility | Replacing the system volume and brightness HUDs |
| Automation | Reading and controlling Apple Music and Spotify |
| Camera | The mirror |
| Calendars and Reminders | Your events and reminders |
| Bluetooth | AirPods battery level |
| Focus | Focus on and off pop-ups |

Recording system audio for the visualizer is off by default. Turning it on shows macOS's purple recording indicator.

## Online services

- [LRCLIB](https://lrclib.net) supplies lyrics. The song title and artist are sent with each lookup.
- The iTunes Search API supplies a 30-second preview of the Apple Music song you're playing. The preview is analysed on your Mac to drive the visualizer.

## Build from source

You need Xcode 26 or later.

```bash
open boringNotch.xcodeproj
```

Choose your own signing team in Xcode, then build and run the `boringNotch` scheme. The project and code still use the `boringNotch` name internally.

## Changes from Boring Notch

This version was modified from Boring Notch 2.7.3 by Mohnish Singh Rawat, with changes through November 2026. Changes include the features above that Boring Notch doesn't have, a new app name and bundle ID, and removal of the original project's update feed and release tooling. The full list is in the git history.

## Credits

Dysland is built on the work of the Boring Notch team and its contributors. The app icon is still the original Boring Notch icon by [@maxtron95](https://github.com/maxtron95). Boring Notch in turn credits [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) for Now Playing on macOS 15.4 and later, and [NotchDrop](https://github.com/Lakr233/NotchDrop) for the first version of the shelf.

Third-party licences are in [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES).

## Licence

GPL-3.0. See [LICENSE](./LICENSE). This software comes with no warranty.
