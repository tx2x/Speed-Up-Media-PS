# Speed-Up Media PS

A small PowerShell 5.1+ helper that speeds up audio and video files with [FFmpeg](https://ffmpeg.org/). It combines the old 1.5x and 2x batch files into one script, with a simple default workflow, a file-selection parser, live progress, and detailed logs.

## Console display

The script uses PowerShell's native `Write-Progress` renderer for separate overall-queue and current-file progress indicators. It does not set a custom color palette; the terminal uses its standard theme and colors.

## Features

- **Two prompts by default:** choose `1.5x` or `2x` (default), then choose all files (default) or select files.
- **Flexible selection:** enter individual numbers and ranges, for example `1, 3, 6-11` or `1-4, 8`.
- **Readable live progress:** current file and overall queue progress, elapsed time, FFmpeg speed, and estimated time remaining. The status displays the FFmpeg processing speed between the file counter and the percentage, for example `FILE 2/10 | 9.1x | 43.0%`. PowerShell renders the current-file and overall queue progress using its native progress display and the terminal's default colors.
- **Audio and video:** supports audio-only files, video-only files, and videos with audio. Each ordinary video stream and audio stream is processed.
- **Speed-specific filenames:** by default, output files are named `name_1.5x.mp4` or `name_2x.mp4`, so both versions can coexist.
- **Quality presets:** Compact, Balanced, and High, available from Advanced Settings.
- **Subtitle timing:** embedded subtitle packet timestamps are scaled when FFmpeg supports the `setts` bitstream filter. Matching external `.srt`, `.vtt`, `.ass`, and `.ssa` sidecars are also scaled and written next to the output media file.
- **Chapter timing:** chapter timestamps are scaled and remuxed through FFmpeg metadata when chapter data is present.
- **Artwork and attachments:** attached-picture streams are copied where possible; Matroska attachments are preserved for `.mkv` and `.mka` files.
- **Optional recursive mode:** process subfolders while preserving their folder structure under `output`.
- **Safer output handling:** FFmpeg writes to a temporary file first. The final output is replaced only after FFmpeg completes successfully.
- **Reliable cancellation:** press `Q`, `Esc`, or `Ctrl+C` during conversion to stop the active FFmpeg process and cancel the remaining queue. FFmpeg is placed in a Windows Job Object configured to terminate its processes when the PowerShell process closes, so closing the terminal window also stops the conversion.
- **Logs:** creates `Logs` automatically and saves a timestamped run log, including FFmpeg warnings and errors.
- **Skip existing outputs:** optional Advanced Setting for avoiding re-encoding files that already have an output.
- **No unnecessary setup questions:** the normal workflow asks only for speed and file selection. Extra options are available through **Advanced Settings** (`A`) at either main prompt.

## Requirements

- Windows and **Windows PowerShell 5.1 or later**. All console prompts, status messages, and menus are in English.
- `ffmpeg.exe` and `ffprobe.exe` from an FFmpeg build.
  - Put FFmpeg's `bin` directory on `PATH`, **or** place both executables in the same folder as `Speed-Up-Media.ps1`.
  - A build that includes the encoders used by your chosen media formats is required. Embedded subtitle timestamp scaling uses FFmpeg's [`setts` bitstream filter](https://ffmpeg.org/ffmpeg-bitstream-filters.html).

Check your installation in PowerShell:

```powershell
ffmpeg -version
ffprobe -version
```

## Quick start

1. Download `Speed-Up-Media.ps1`.
2. Place it in the folder containing the media files you want to process.
3. Run it from PowerShell:

   ```powershell
   .\Speed-Up-Media.ps1
   ```

4. At the first prompt, press **Enter** for `2x`, or enter `1` for `1.5x`.
5. At the second prompt, press **Enter** to process every supported media file in the script folder. Enter `S` to choose specific files.

The script creates these folders next to itself. The `output` and `Logs` folders are excluded from input discovery, including in recursive mode:

```text
Your-Folder/
├── Speed-Up-Media.ps1
├── video.mp4
├── podcast.mp3
├── output/
│   ├── video_2x.mp4
│   └── podcast_2x.mp3
└── Logs/
    └── Speed-Up-Media_YYYY-MM-DD_HH-mm-ss-fff.log
```

## Selecting specific files

Choose `S` at the file-selection prompt. The script displays a numbered list. Enter one or more numbers separated by commas, with optional ranges:

```text
1, 3, 6-11
1-4, 8
2, 5-7, 12
```

Spaces are allowed. Overlapping selections are de-duplicated automatically. Ranges must be ascending and within the displayed list.

## Advanced Settings

Enter `A` at either main prompt to open Advanced Settings. Changing settings does not add any prompts to the normal run.

| Setting | Default | Description |
|---|---|---|
| Encoding quality | Balanced | Compact prioritizes smaller files; High prioritizes visual quality and can take longer. |
| Include subfolders | Off | Searches recursively and mirrors the source subfolder structure under `output`. |
| Add speed to filenames | On | Adds `_1.5x` or `_2x` before the extension. |
| Skip existing outputs | Off | Skips a file if its final output already exists. |
| Scale subtitle timings | On | Adjusts embedded subtitle timestamps and external SRT/VTT/ASS/SSA sidecars. If disabled, subtitle streams and matching sidecars are preserved without timing changes. |
| Scale chapter timestamps | On | Adjusts embedded chapter positions for the new duration. If disabled, original chapter timestamps are preserved. |
| Preserve artwork/attachments | On | Copies attached-picture streams and supported Matroska attachments. |
| Open output folder at end | Off | Opens `output` in Windows Explorer after the run. |

### Quality presets

The presets select an encoder and settings based on the output container. For common MP4/MOV/MKV-style video, they use H.264 CRF values of approximately 28 (Compact), 23 (Balanced), and 18 (High). Other containers use compatible encoders and their corresponding quality or bitrate controls where available. Audio bitrate is typically 128, 192, or 256 kb/s for lossy formats. FLAC and PCM remain lossless; their preset differences primarily affect encoding options, not lossless audio fidelity.

Actual output size and quality vary with the input, codec, encoder implementation, and container. High quality can produce larger files and take longer. A codec may be unavailable in a particular FFmpeg build.

## Output names and overwrite behavior

With the default suffix option enabled:

- `Lecture.mp4` at 1.5x becomes `output/Lecture_1.5x.mp4`.
- `Lecture.mp4` at 2x becomes `output/Lecture_2x.mp4`.

The two speed versions can coexist. If the same target name already exists, the default behavior is to re-create it after a successful conversion. Enable **Skip existing outputs** in Advanced Settings to avoid re-encoding existing results.

The original source files are never modified. Failed conversions leave no partially written final output; FFmpeg temporary files are removed when possible.

## Progress and logs

The console shows two linked native PowerShell progress indicators:

- **Overall queue:** percentage, file position (for example, `2/10`), total elapsed time, and overall ETA.
- **Current file:** file counter, live FFmpeg speed between `FILE x/y` and the percentage, elapsed time, remaining time, filename, and per-file progress bar.

The progress UI is rendered by PowerShell instead of manually positioning console cursor rows. This avoids the missing overall bar and stale/empty per-file bars that can occur when direct console writes are mixed with PowerShell output. FFmpeg progress records are consumed internally; diagnostic warnings and errors go to the log instead of repeatedly flooding the screen.

A timestamped log is written to `Logs/` for each run. FFmpeg diagnostic output is saved there instead of flooding the console with repeated `frame=...` status lines. Keep the log when reporting a failed conversion.

## Cancelling a conversion

You can cancel the current conversion at any time while FFmpeg is running:

- Press **`Q`** or **`Esc`** in the console to stop the current file and stop the remaining queue.
- Press **`Ctrl+C`** to request cancellation. The script attempts to stop FFmpeg and report the cancellation in the summary. If the host interrupts the PowerShell pipeline before the summary can be printed, the active FFmpeg process is still covered by the automatic process cleanup mechanism.
- Close the PowerShell window or Windows Terminal tab to terminate the running script. FFmpeg is assigned to a Windows Job Object using `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; Windows terminates the child process when the script's job handle is closed.

The script does not start a conversion unless it can create the cleanup Job Object, and it stops a newly started FFmpeg process if assigning it to the Job Object fails. This fail-safe behavior is intentional: it avoids knowingly running a conversion that could be left behind.

On a normal cancellation, the incomplete temporary output is removed and the existing final output is left untouched. If the terminal is forcibly closed, Windows stops FFmpeg, but PowerShell may not get a chance to remove its temporary file. Such files have names containing `.speedtmp_` inside `output/`; they are incomplete and can be deleted manually.

## Supported inputs and caveats

The script discovers common audio and video extensions such as MP4, MKV, MOV, AVI, WebM, WMV, FLV, MP3, M4A, FLAC, WAV, OGG, Opus, and AAC. An extension being listed does not guarantee every possible codec/container combination can be re-encoded by every FFmpeg build; rare or legacy formats may fail. The corresponding error is recorded in `Logs/`.

- **External subtitles:** sidecars must share the media filename stem, optionally followed by a language suffix, for example `Film.en.srt` beside `Film.mp4`. SRT/VTT timestamps are rescaled; ASS/SSA dialogue start and end times are rescaled. Text encoding is detected where possible, including UTF-8 and common BOM-marked Unicode files; legacy no-BOM text falls back to the Windows ANSI code page. Unsupported sidecar formats are not transformed.
- **Embedded subtitles:** timestamps are rescaled with FFmpeg's `setts` bitstream filter while subtitle packets are copied. Some subtitle codecs or containers may not support timestamp rewriting; disable subtitle timestamp scaling in Advanced Settings if a particular file fails.
- **Chapters:** chapter times are rewritten in a generated FFmetadata input and mapped to the output. If chapter rescaling is disabled or cannot be prepared, original chapter metadata is retained when available.
- **Artwork:** attached pictures and Matroska attachments are copied, not accelerated. Some output containers do not support every stream from the source.
- **Video quality:** video is re-encoded because timing changes. Re-encoding is lossy for common formats, so choose a preset appropriate for your needs.
- **Variable frame rate:** the source's frame timing is compressed using `setpts`. FFmpeg may drop or duplicate frames depending on output frame-rate behavior; this is normal for many constant-frame-rate outputs at a higher playback speed.

## Troubleshooting

### `ffmpeg.exe` or `ffprobe.exe` not found

Add FFmpeg's `bin` folder to the Windows `PATH`, reopen PowerShell, and verify `ffmpeg -version` / `ffprobe -version`. Alternatively, put both executable files beside the script.

### PowerShell says scripts are disabled

You may run the script for the current PowerShell process without permanently changing the machine policy:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Speed-Up-Media.ps1
```

Use your organization's policy where applicable; do not change a system-wide execution policy unnecessarily.

### A file fails to convert

Open the latest log under `Logs/`. Common causes include unsupported encoders, damaged source media, a container that cannot hold one of the mapped streams, a protected/DRM source, or a codec missing from the installed FFmpeg build. Try disabling subtitle timestamp scaling or artwork preservation in Advanced Settings to isolate stream compatibility problems. Subtitle streams are still copied when timestamp scaling is disabled.

### Output is unexpectedly large or conversion is slow

Choose Compact in Advanced Settings. H.264 encoding speed also depends on the selected preset and your CPU. A higher-quality preset may need more processing time and produce a larger file.

## Credits
The code was written using web version of ChatGPT 😁.

## License

[MIT](LICENSE)

## Acknowledgements

- [FFmpeg](https://ffmpeg.org/) — media probing, filtering, encoding, and remuxing.
