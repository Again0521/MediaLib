<div align="center">

<h1>
  <img src="./assets/icon.png" width="38" alt="MediaLIB icon" />
  MediaLIB
</h1>

<p><strong>A clean, natural local media library made for macOS.</strong></p>

<p>
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/Media-Library-blue" alt="Media Library" />
  <img src="https://img.shields.io/badge/Local%20First-Privacy%20Friendly-green" alt="Local First" />
</p>

</div>

<p align="center">
  <a href="./README.md">中文</a> ·
  <a href="./README.en.md">English</a> ·
  <a href="./README.ja.md">日本語</a>
</p>

MediaLIB brings together movies, TV shows, anime, documentaries, variety shows, and music scattered across your local drive, external drives, NAS, SMB/FTP folders, and Emby, Jellyfin, or Plex servers. You can browse, search, favorite, continue watching, and play everything from one unified place.

It does not take over your folders, and it will not move or change your media files without permission. Think of MediaLIB as a polished “media index center”: your files stay exactly where they are, while categories, artwork, watch history, favorites, playlists, offline cache, and metadata fixes are stored locally inside the app.

<div align="center">
  <img src="./assets/home-overview.png" alt="MediaLIB home overview" width="86%" />
</div>

## Who it is for

- Your videos or music are spread across a Mac, external drive, NAS, or home server, and you usually dig through Finder folder by folder.
- You want movies, TV shows, anime, and music in one app instead of several separate places.
- You already use Emby, Jellyfin, or Plex, but still keep plenty of local files.
- You prefer a quiet, clean media library that feels at home on macOS.
- You have private folders that should stay locked, with paths, file names, and playback traces hidden.

## Main features

### Manage all your media in one place

MediaLIB supports local folders, network devices, Emby, Jellyfin, and Plex. To add a media source, choose where it comes from, finish the connection, then confirm the category and scan mode.

<div align="center">
  <img src="./assets/add-source.png" alt="Add media source" width="78%" />
</div>

Local folders and mounted network folders can be categorized as movies, TV shows, anime, documentaries, variety shows, music, other, or vault. When you are not sure, you can use auto detection. Remote media servers appear as separate entries, so they will not be mixed directly into your local videos or music.

### Movies, shows, and anime

MediaLIB scans folders recursively, recognizes common video files, and tries to understand the content type from file names and folder structure. Episodes are grouped by series, then sorted by season and episode number. Common naming styles such as `S01E01`, `第01季 第02集`, and `EP01` are supported.

<div align="center">
  <img src="./assets/movie-library.png" alt="Video library" width="86%" />
</div>

You can mark items as favorite, want to watch, watched, unwatched, or currently watching, and add your own 1 to 5 star rating. MediaLIB lets you browse by title, year, score, personal rating, recently added, play count, and more.

For content you want to organize by hand, you can create manual collections. If you want the app to do the filtering for you, smart collections can build lists by type, watch status, year, score, source, and other rules. Frequently used collections can also be shown on the home page.

<div align="center">
  <img src="./assets/series-detail.png" alt="Series detail" width="86%" />
</div>

### Music library and playlists

Music has its own library alongside video. MediaLIB reads audio tags and tries to identify the title, artist, album, track number, year, duration, embedded artwork, and lyrics.

<div align="center">
  <img src="./assets/music-library.png" alt="Music library" width="86%" />
</div>

You can browse by songs, albums, artists, playlists, and recently played items. Favorited songs appear in a pinned favorites playlist. You can also create your own playlists or save the current play queue as a playlist. Playlists only store MediaLIB’s internal index and order; they do not move, copy, or rename your music files.

### A more immersive music player

The music player has two states: a bottom mini player and a full expanded view. Double-clicking a song opens the mini player first. Clicking the track information expands it into the full player. The expanded page draws colors from the album cover and presents the cover, controls, queue, and lyrics card together.

<div align="center">
  <img src="./assets/music-player.png" alt="Music player" width="78%" />
</div>

Lyrics are loaded first from embedded lyrics or matching `.lrc` / `.txt` files. Timestamped LRC lyrics can scroll automatically, and enhanced LRC supports per-word or segmented highlighting. When exact word timing is unavailable, MediaLIB estimates in-line progress from the rhythm of the lyrics, so the text still follows the music in a more natural way.

### Built-in video player

Videos can be played with the built-in player, or with the system player when you prefer. The built-in player supports common video containers, subtitle and audio track switching, external subtitles, playback speed, volume, full screen, always-on-top window mode, resume playback, screenshots, chapters, bookmarks, A-B loop, and skipping intros or outros.

<div align="center">
  <img src="./assets/video-player.png" alt="Video player" width="86%" />
</div>

For remote videos, MediaLIB also supports quality selection and local caching. It is useful when the network is unstable, or when you want to prepare something for temporary offline viewing.

### Vault

The vault is designed for private content. The first time you enter, you can set a 4 to 8 digit passcode. After that, it can be unlocked with Touch ID or the passcode.

<div align="center">
  <img src="./assets/vault.png" alt="Vault" width="86%" />
</div>

When locked, MediaLIB will not show vault content, media source paths, private file names during scans, or vault items on the home page, continue watching, watched, favorites, or want-to-watch sections. Once unlocked, vault content can be browsed, played, favorited, marked, and cleared from watch history like normal.

### Library health and task center

Library health can check for offline media sources, invalid local paths, missing remote playback paths, possible duplicates, missing artwork, missing years, and similar issues. Every cleanup action asks for confirmation, and it only removes MediaLIB’s internal index. Your original media files are not deleted.

<div align="center">
  <img src="./assets/task-center.png" alt="Task center" width="86%" />
</div>

The task center records background tasks such as scans, incremental scans, remote sync, artwork preheating, metadata updates, video caching, chapter thumbnails, and one-click cleanup. When a failed task can be rebuilt, a retry button will be shown.

## Quick start

1. Open `MediaLIB.app`.
2. Go to “Media Sources” and click “Add Media Source…”.
3. Choose a local folder, network device, Emby, Jellyfin, or Plex.
4. For local or network folders, choose a category; use “Auto Detect” when unsure.
5. Click “Scan All”, or scan one media source.
6. After scanning, open “Home”, “Video”, or “Music” from the sidebar.
7. To enrich information online, configure the related data sources in “Settings > Metadata & Matching”.

For first-time use, it is better to try a small folder first. Once the category and artwork results look right, add your full media library.

## Installation

If you received `MediaLib.dmg`:

1. Open the DMG.
2. Drag `MediaLIB.app` into “Applications”.
3. On first launch, macOS may block unsigned builds. Right-click `MediaLIB.app`, choose “Open”, then confirm once more.

Requirements:

- macOS 13 Ventura or later.
- Local scanning and playback do not require an account.
- TMDB, music metadata, remote servers, subtitle downloads, Trakt, Last.fm, and similar features require a network connection and the corresponding account or API key.

## Data safety

MediaLIB follows one basic rule: it does not change your media files on its own.

- Scanning only creates an index.
- Re-categorizing only changes MediaLIB’s internal category.
- Favorites, want-to-watch, ratings, watch history, and playlists are stored in the local index.
- Cleaning invalid indexes does not delete original files.
- Deleting offline cache only removes cache copies created by MediaLIB.
- When the vault is locked, paths, file names, and content are hidden.
- Database backup and restore only handle MediaLIB’s own internal data. They do not copy or replace files in your media sources.

## Project status

MediaLIB is still being polished. The current focus is making the library, players, remote sync, music experience, offline cache, and interface performance more stable and easier to use.

If you run into problems, feel free to report them through Issues. It helps a lot if you include the page, steps, screenshots, and logs, so the problem can be found more quickly.

## License

This repository is currently for personal learning and use. Third-party components shipped with or used by the app, such as libmpv and ffmpeg, follow their own open-source licenses. If you plan to redistribute or use it commercially, please check the relevant license requirements first.
