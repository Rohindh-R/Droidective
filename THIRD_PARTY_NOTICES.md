# Third-party notices

## scrcpy-server

`App/Resources/scrcpy-server` is the device-side server from
[scrcpy](https://github.com/Genymobile/scrcpy) (v4.0), bundled and pushed to the
device so the in-app screen mirror works without a separate scrcpy install.

- Project: scrcpy — Copyright (C) 2018 Genymobile / Romain Vimont
- License: Apache License 2.0 — https://github.com/Genymobile/scrcpy/blob/master/LICENSE

The binary is redistributed unmodified under the terms of the Apache License 2.0.
Droidective speaks scrcpy's protocol with its own client; only the server payload
is bundled.

## ffmpeg

`App/Resources/ffmpeg` is a static build of [ffmpeg](https://ffmpeg.org) (v8.1.1,
macOS arm64), bundled and run on the Mac to power the video editor's exports
(trim/crop/rotate/scale/speed and mp4/mov/mkv/webm/gif encoding) without a
separate ffmpeg install.

- Project: FFmpeg — https://ffmpeg.org
- License: **GNU General Public License v3** (this build is configured with
  `--enable-gpl --enable-version3`, which includes GPL components such as
  libx264/libx265). The full license text is at https://www.gnu.org/licenses/gpl-3.0.html
- Build source: https://ffmpeg.martin-riedl.de (macOS arm64, "release")
- The binary is redistributed unmodified. FFmpeg's source is available from
  https://ffmpeg.org/download.html and https://git.ffmpeg.org/ffmpeg.git

Because this ffmpeg build is GPLv3, distributing the app bundle with it included
carries GPLv3 obligations for the combined distribution.
