# Dev helpers (each is a single-file Swift tool)

Compile one with `swiftc -O tools/dev/<name>.swift -o /tmp/<name>`.

| Tool | Use |
|---|---|
| `dbg` | Sends a command to an Isle started with `--debug-control`: `dbg expand home`, `dbg tab shelf`, `dbg collapse`, `dbg popup`, `dbg banner`, `dbg theme minimal`, `dbg day 1`, `dbg snapshot island:/tmp/x.png` |
| `mv` | Moves the cursor: `mv 864 3` puts it on the notch (screen center x, top edge) |
| `click` | Moves and clicks |
| `cover2` | Opens a gray window behind the notch area so recordings contain nothing personal |
| `fdiff` | Reads a screen recording and prints island height / width / change per frame |
| `frames` | Dumps every frame of a recording to PNGs |
| `montage` | Stacks PNGs into one image |

Recording recipe: `./cover2 &`, then `screencapture -v -V 6 -R564,0,600,260 out.mov &`, move the cursor with `mv`, then `fdiff out.mov`.
Needs Screen Recording permission for your terminal.
