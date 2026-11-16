# 5heures for Windows

The Windows version of 5heures: every review by Hugues Dayez and every digression by Rudy Léonet, searchable and
playable from the exact minute the film is discussed. WinUI 3 (Windows App SDK) and C#, in the look of the macOS app.
It reads the very same catalogue (`Resources/Snapshot`), the same 5heures.be API, the same two feeds, and saves its files in
the same format as the Mac app.

## Run

`dist\CinqHeures.exe` is the whole app (it shows up as "5heures"): one file, nothing to install. Copy it anywhere and run it. Needs Windows 10 (1809) or
later, 64-bit. It keeps its catalogue, settings and the episodes played lately in `%LOCALAPPDATA%\CinqHeures`.

## Build

Needs the .NET 10 SDK.

```powershell
dotnet build CinqHeures.sln -p:Platform=x64   # build everything
dotnet test tests/CinqHeures.Core.Tests       # the 75 tests (the macOS app's fixtures and snapshot included)
.\publish.ps1                                 # dist\CinqHeures.exe
```

## Layout

- `src/CinqHeures.Core` — no UI. A port of the Swift `CinqHeuresCore`: the episode and segment models, the 5heures.be and
  podcast-feed clients, search, the home page's shelves and listings, ID3 chapters, TMDB, where to watch.
- `src/CinqHeures.App` — the WinUI 3 app. Pages are built in code; lists are virtualised (`ItemsRepeater`).
  - `AppModel` keeps the catalogue up to date (like the Swift `AppModel`); `Audio/PlayerModel` plays through the system's
    `MediaPlayer`, with the media keys and the media overlay.
  - `Audio/RangeStream` is the Windows `RangeLoader`: 5heures.be's server can take a minute to answer a deep seek in an old
    file, and `MediaPlayer` alone never started playing there, so the file is fed to it through small ranged requests that
    are asked again patiently. `Audio/AudioCache` keeps the last six episodes played on disk, downloaded while they play.
- `tests/CinqHeures.Core.Tests` — xUnit. The Swift tests, ported, on the same real fixtures, plus tests that load the shipped
  snapshot to pin the compatibility with the Mac app (dates, ids, the film keys).

## Differences from the Mac app

Left out: Spotlight, the Dock menu, new-episode notifications, the iPhone, iPad and Apple TV apps. Not done yet: narrowing a
search to the show chosen in the sidebar, and a poster cache of the app's own (posters rely on the system's image cache, so they
are missing offline). The media keys and the system media overlay are wired up (`PlayerModel`) but were not
exercised on every Windows setup.

A cold file on 5heures.be can take a long time to start (a minute or more): the player says so and waits.
Don't rename `CinqHeures.exe`: Windows looks its resources up by that name.

## Debug switch

`CINQHEURES_DATA=<folder>` moves the catalogue, settings and cache: for tests and screenshots.

`CINQHEURES_DEBUG=1` logs what the player and the loader do to `debug.log` there; `CINQHEURES_NODISK=1` plays from the stream only
(no disk cache); `CINQHEURES_AUTOPLAY=<episode id>:<seconds>` starts playing at launch.
