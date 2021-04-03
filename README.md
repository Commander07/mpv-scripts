# dynamic-crop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to "cropping" dynamically, hard-coded black bars with collected metadata for Ultra Wide Screen (21:9) or any screen different from 16:9 (phone/old TV).

## Status

It's now really stable, but can probably be improved for more edge case.

## Usage

Save `dynamic-crop.lua` in `~/.config/.mpv/scripts/` (Linux/macOS) or `%AppData%\mpv\scripts\` (Windows) or `/storage/emulated/0/` (Android SD card). 
Edit your `mpv.conf` file to add `script=<path to the script>`, eg:
```
#Windows mpv-shim:
script=C:\Users\<username>\AppData\Roaming\jellyfin-mpv-shim\scripts\dynamic-crop.lua
#Android mpv-android:
script=/storage/emulated/0/mpv/dynamic-crop.lua
```

## Features

- 5 mode available: 0 disable, 1 on-demand, 2 single-start, 3 auto-manual, 4 auto-start.
- New cropping meta are validate with a known list of aspect ratio and `new_known_ratio_timer`, and without the list with `new_fallback_timer`.
- Correction of random metadata to an already trusted one, this mostly help to get a fast aspect ratio change with dark/ambiguous scene.
- Support Asymmetric offset.
- Auto adjust black threshold (cropdetect=limit).
- Auto pause the script when seeking/loading.
- Option to prevent aspect ratio change during a certain time (in scene changing back and forth in less than X seconds).
- Allow deviation of continuous data required to approve new meta.

## To-Do

- Documentation.

## OS

 - Windows: OK ([mpv](https://mpv.io/) or [mpv-shim](https://github.com/jellyfin/jellyfin-desktop))
 - Linux:   Not tested
 - Android: OK ([mpv-android](https://github.com/mpv-android/mpv-android))
 - Mac:     Not tested
 - iOS:     Not tested

## Shortcut 

SHIFT+C do:

- Mode = 1-2, single cropping on demand, stays active until a valid cropping is apply.
- Mode = 3-4, enable / disable continuous cropping.

## Troubleshooting

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `Available libavfilter filters:`.

Make sure `hwdec=no`(default), if experiencing issue.

## Download on phone

Use the Desktop mode with a navigator on this page to access the button `Code > Download Zip`.
