# 5heures — technical notes

Notes for developers: how the app is built and how it reads each show. The main page,
[README.md](../README.md), is for listeners.

## Features in detail

- **Home** (Infuse-style): a hero banner with a random well-rated review you can play at once
  (**Une autre** picks another, never one of the last thirty),
  then poster shelves: *Continuer l'écoute*, *À redécouvrir*, *Il est toujours 5 heures quelque part*
  and Hugues Dayez's reviews (the parts that still get new episodes), *Coups de cœur ★★★★*, *Séries*, *Revenus plusieurs fois*, *Rencontres*, *Critic On Demand Live*, and
  *Explorer par époque* (decade tiles, the archive's stand-in for genres, which it doesn't have).
  The random shelves reshuffle with **Surprenez-moi** (the goat); every shelf has **Tout voir**.
- **Search** stays in the toolbar and shows results as posters (films, series, people) plus episodes
  whose title or summary matches. Accent- and case-insensitive; narrowed by the show picked in the sidebar.
- **Film pages**: a poster, its rating, and every passage about it (a film discussed several times
  lists each one, with show, date and the hosts' own wording), each with **Écouter** at the exact timecode.
- **Ratings**: the sidebar's *Notes des films* lists films by their 0–4 score, and *Sans note* the ones reviewed without one.
- **Episode pages**: every film, series and person in an episode with its timecode; click to jump.
- Player: one compact row of Liquid Glass floating over the bottom of the content (a material panel
  before macOS 26): artwork and title, play with ±15 s, a scrubber with a mark at each film of the
  episode (hover to see which film and when, click or drag to seek), volume (dropped on narrow
  windows), speed 0.8–2×, media keys; resumes where you left an episode; click the now-playing block
  to open its episode. Every page keeps room under its last row so nothing stays hidden behind it.

**5heures › Réinitialiser… (cache : …)** opens a sheet with two checkboxes, in any combination: the
**cache** (catalogue and posters; the app then re-downloads like a first launch) and the **listening
progress** (resume positions and *Continuer l'écoute*).

The window is two panes: the sidebar and a navigation stack (pages push, the back chevron returns).

## iPhone and iPad (in progress)

`iOS/CinqHeures.xcodeproj` (needs Xcode) builds an iPhone/iPad app from the same screens
(`Sources/CinqHeures`, shared through a synchronized folder) and the same engine (the
`CinqHeuresCore` package product). Only `iOS/App/` is iOS-specific (entry point, audio session for
background playback, icon). Platform differences live in `Sources/CinqHeures/UI/Platform.swift` and a
few `#if os(macOS)` blocks: the player becomes two rows on narrow screens and uses the device's
volume buttons, the hero banner drops its poster when space runs out. On iPhone the full player shows
the score of the film being discussed under its title (stars and the hosts' own words); on iPad the
floating bar shows the stars after the show and date, when they fit. The audio session is activated
when play is pressed, not at launch, so opening the app doesn't stop another app's audio. Until then
the AirPlay button is a dimmed icon: with the session inactive, AVKit's route picker handled its own
route notifications in a loop, a third of a core and more on an idle iPad.

```
cd iOS && xcodebuild -scheme 5heures -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Build

macOS 15+, Swift 6, Command Line Tools only (no Xcode).

```
./build.sh            # release → build/5heures.app (Command Line Tools only, no Xcode)
./build.sh universal  # release, Apple silicon + Intel in one binary (macOS 15+)
./build.sh debug
./test.sh             # core tests
```

GitHub Actions (`.github/workflows/apple.yml`, macOS runners with Xcode) builds the Mac app, runs the
core tests and builds the iPhone/iPad app for the simulator on every push. Run it by hand (Actions ›
Apple builds › Run workflow) and it also launches the Mac app (a first launch, then a warm one) and
the app on an iPhone and an iPad simulator (or only some of them, see the run's options), records CPU
and memory every two seconds, samples the call stacks at a few moments (busiest frames, and the call
path to the busiest one) and takes screenshots: tables in the run's summary, files in its artifacts
(`Tools/ci/`). Once the app has run there, the core tests also time searches, the home page rebuild and
a sort by name on the real catalogue.

First launch downloads the catalogue (~40 requests, ~4 MB saved in
`~/Library/Application Support/CinqHeures/catalogue.json`); later launches refresh only the newest
year of each show, at most every 12 hours. `Tools/crawl.sh <folder>` downloads the same raw JSON.

## How it works

5heures.be is a React app over a JSON API: `/api/config`, `/api/podcasts?kind=…&year=…`. Each
episode lists its segments (`movie`, `tv_show`, `person`, …) with `start_second`. The site's own
search only calls `/api/movies`, which is why series never show up there.

### Why the website seeks badly, and what the app does about it

The MP3s come from a Rails app behind Cloudflare. A file that hasn't been requested recently is
served very slowly the first time: the answer to a deep seek can take 60–90 s (Cloudflare gives up
at ~65 s), after which the file is fast. Browsers give up and play from the start.
`RangeLoader` serves AVPlayer through small range requests of its own, retries patiently
(~3 minutes), keeps fetched chunks in memory (so ±15 s is instant), reads only ~12 MB ahead, and
tells the UI when the server is slow. Warm files start in under 3 s; cold ones wait for the server.

The app names itself `CinqHeures/1.0` in its requests.

Unsigned builds: the release zip is ad-hoc signed, not notarized. Besides *Open Anyway* in System
Settings, `xattr -dr com.apple.quarantine /Applications/5heures.app` clears the download flag.

## Hugues Dayez's reviews

RTBF's Auvio lists *Les critiques d'Hugues Dayez* publicly but plays it only to logged-in accounts, so
the app reads Franky's own Audiobookshelf feed of it instead (`FeedClient.dayezFeed`, no login). Each
title names the week's three films in one of several formats; `FeedClient.filmTitles(in:)` reads them
(tests cover every format seen). They become film segments: searchable, listed on the episode page,
and timed by the file's own chapters when it has some (below), else playing from the start of the
~9-minute episode. Interviews and asides are dropped. Feed shows are refreshed by replacing their
episodes, so removed episodes go away.

### Chapters in the files

RTBF's MP3s carry no chapters, but Franky can add them before uploading (ID3v2.3 or 2.4 `CHAP` frames,
as Podcast Chapters, ChapterPod or similar tools write them). The app reads each Dayez file's tag in
the background, one request for its first 64 KB (`ChapterReader`, `ID3Chapters`), and gives each film
the start of its chapter: matched by name (case, accents and punctuation aside), or in order when the
chapters aren't named after the films, an opening "Introduction" aside. Every place that uses a
review's time follows: the marks and the film's name on the bar, the episode's programme, "Écouter la
critique", the film playing on the lock screen. What was found is kept
(`~/Library/Application Support/CinqHeures/chapters.json`); a file is read again after 6 hours when
its episode is under two months old, after a week otherwise, so chapters added or moved later show up.

### Film details from TMDB

Dayez's films get a poster, their French and original titles, the director and a synopsis from
[TMDB](https://www.themoviedb.org) (where 5heures.be's own posters come from). The token stays on a
small PHP proxy on Franky's hosting (`Tools/proxy/tmdb.php`): it only passes search, film and credits
requests, caches answers for 30 days and limits each visitor to 120 requests a minute. The app looks
each film up once, in French around the episode's date then in English, confirms it with the
director or actors named in the episode description, and saves the result
(`~/Library/Application Support/CinqHeures/films.json`). 126 of the first 129 films matched.

To set up the proxy: copy `Tools/proxy/tmdb.php` to the hosting (the app expects
`https://frankynov.ovh/cinqheures/tmdb.php`, see `TMDBClient.proxyURL`), and next to it or in a folder
above it (best: above `www`, out of the web's reach) a `tmdb-config.php` made from `tmdb-config.example.php` with the TMDB read access token.

*This product uses the TMDB API but is not endorsed or certified by TMDB.*

## Il est toujours 5 heures quelque part, by Rudy Léonet

`FeedClient` reads `https://feed.ausha.co/j0n2zsQR3XOG` (found on its Ausha page). The feed has no
tracklist or chapters, so its episodes have no per-song timecodes: they show title, date, length and
cover (400 px version), and the artists named in the feed's per-episode keywords (tags shared by most
episodes, like "Concerts", are dropped). Titles and those names are searchable. Ausha's audio server is
fast, so these episodes play through plain AVPlayer, without the slow-server loader.

## App icon

Redrawn from the official logo's measured geometry by `python3 Tools/make_icon.py` (Pillow + numpy):

- `Resources/Icon/AppIcon.icon` — layered Icon Composer document: background gradient plus
  `bubble` (glass), `details` (stripes, dotted lines) and `marquee` (lettering and bulbs) layers,
  with a dark appearance (deep-blue background, lifted blue bubble). Xcode's `actool` turns it into
  the Liquid Glass icon with light, dark and tinted looks; `build.sh` does that automatically when
  Xcode is installed.
- `Resources/AppIcon.icns` — pre-composed fallback used when `actool` isn't available (Command Line
  Tools only). It has glass lighting drawn in and simplified art at small sizes (no bulbs at 64 px,
  a single "5" at 32 px and below), but only the light look: an `.icns` can't switch to dark or tinted.
- `Resources/Icon/Preview/` — light, dark and a 16–256 px size ladder to judge the design.

The `.icon` document was written by hand to Icon Composer's format and has not been opened in Icon
Composer or compiled, because neither is installed on this Mac.
