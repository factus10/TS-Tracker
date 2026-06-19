# Producing Screenshots from TAP Files with ZEsarUX

This document explains how to use ZEsarUX and its remote protocol (ZRCP) from
a Claude Code session to load TAP files, interact with the emulated machine,
and capture screenshots programmatically.

## Prerequisites

- ZEsarUX installed at `/Applications/zesarux.app/`
- Binary path: `/Applications/zesarux.app/Contents/MacOS/zesarux`
- Python 3 (for ZRCP scripting)
- `nc` (netcat) for quick ZRCP commands

## Quick Start

### 1. Launch ZEsarUX with remote protocol

```bash
nohup /Applications/zesarux.app/Contents/MacOS/zesarux \
  --machine TS2068 \
  --enable-remoteprotocol \
  --noconfigfile \
  > /tmp/zesarux.log 2>&1 &
sleep 5
```

Machine options: `Spectrum48`, `Spectrum128`, `TS2068`, `TC2068`, `ZX80`, `ZX81`, etc.

### 2. Connect and verify

```bash
echo "get-version" | nc -w 2 localhost 10000
```

### 3. Load a TAP file

```bash
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', 10000))
s.settimeout(3)
try: s.recv(4096)
except: pass
s.sendall(b'smartload /full/path/to/file.tap\n')
time.sleep(1)
print(s.recv(4096).decode())
s.close()
"
```

### 4. Wait and take screenshot

```bash
python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', 10000))
s.settimeout(3)
try: s.recv(4096)
except: pass
time.sleep(5)  # wait for program to load/run
s.sendall(b'save-screen /tmp/screenshot.bmp\n')
time.sleep(0.5)
print(s.recv(4096).decode())
s.close()
"
```

### 5. Shut down

```bash
echo "exit-emulator" | nc -w 2 localhost 10000
# or: pkill -f zesarux
```

## ZRCP Reference (Key Commands)

All commands are sent as text lines to TCP port 10000 (default).

### Machine Control

| Command | Description |
|---------|-------------|
| `set-machine NAME` | Change machine (e.g., `Spectrum48`, `TS2068`) |
| `hard-reset-cpu` | Hard reset |
| `smartload FILE` | Smart-load a file (TAP, SNA, Z80, etc.) |
| `exit-emulator` | Quit ZEsarUX |
| `exit-after N` | Auto-quit after N seconds |

### Screenshots

| Command | Description |
|---------|-------------|
| `save-screen FILE` | Save screenshot. Formats: `.bmp`, `.pbm`, `.scr` |

BMP gives a standard bitmap. PBM is a simple portable bitmap format. SCR saves the raw Spectrum screen memory (6912 bytes).

### Memory Access

| Command | Description |
|---------|-------------|
| `read-memory ADDR LEN` | Read LEN bytes from ADDR (returns hex string) |
| `write-memory-raw ADDR HEXBYTES` | Write hex bytes to ADDR |
| `save-binary FILE ADDR LEN` | Save memory region to file |

### CPU Control

| Command | Description |
|---------|-------------|
| `get-registers` | Show all CPU registers |
| `set-register REG=VALUE` | Set a register (e.g., `PC=8000h`) |
| `enter-cpu-step` | Enter single-step mode |
| `cpu-step` | Execute one instruction (must be in step mode) |
| `cpu-step-over` | Step over CALL (must be in step mode) |
| `exit-cpu-step` | Leave step mode, resume execution |
| `run` | Resume execution (after breakpoint or step mode) |

### Breakpoints

| Command | Description |
|---------|-------------|
| `enable-breakpoints` | Enable breakpoint system |
| `disable-breakpoints` | Disable breakpoint system |
| `set-breakpoint N CONDITION` | Set breakpoint N (1-100). Example: `PC=8000h` |
| `set-breakpoint N none` | Clear breakpoint N |
| `get-breakpoints` | List all breakpoints |

### Keyboard Input

| Command | Description |
|---------|-------------|
| `send-keys-string TIME STRING` | Type a string with TIME ms between keys |

Example: `send-keys-string 100 LOAD ""` sends keystrokes with 100ms gaps.

Note: Special keys need Spectrum key names. For ENTER use the newline approach below.

### Snapshots

| Command | Description |
|---------|-------------|
| `snapshot-save FILE` | Save emulator state to .zsf file |
| `snapshot-load FILE` | Load emulator state from .zsf file |

## Python Helper Functions

```python
import socket, time

def zrcp_connect():
    """Connect to ZEsarUX ZRCP and return socket."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('localhost', 10000))
    s.settimeout(3)
    try: s.recv(4096)  # eat welcome message
    except: pass
    return s

def zrcp_cmd(s, cmd):
    """Send a command and return the response."""
    s.sendall((cmd + '\n').encode())
    time.sleep(0.3)
    try:
        return s.recv(8192).decode().replace('command> ', '').strip()
    except:
        return ''

def zrcp_close(s):
    s.close()
```

## Complete Example: Load TAP, Wait, Screenshot, Exit

```python
import socket, time, subprocess

# Launch ZEsarUX
proc = subprocess.Popen([
    '/Applications/zesarux.app/Contents/MacOS/zesarux',
    '--machine', 'TS2068',
    '--enable-remoteprotocol',
    '--noconfigfile',
    '--exit-after', '30',
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(5)

# Connect
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', 10000))
s.settimeout(3)
try: s.recv(4096)
except: pass

def cmd(c):
    s.sendall((c + '\n').encode())
    time.sleep(0.5)
    try: return s.recv(8192).decode()
    except: return ''

# Load TAP
cmd('smartload /full/path/to/file.tap')
time.sleep(10)  # wait for tape to load and program to run

# Take screenshot
cmd('save-screen /tmp/output.bmp')

# Clean up
cmd('exit-emulator')
s.close()
proc.wait()
```

## Loading Binary Directly into RAM (No TAP)

For programs that need to be poked into memory rather than loaded from tape:

```python
# Load binary file into RAM at address $8000
with open('program.bin', 'rb') as f:
    code = f.read()

for offset in range(0, len(code), 128):
    chunk = code[offset:offset+128]
    hexstr = ''.join(f'{b:02x}' for b in chunk)
    addr = 0x8000 + offset
    cmd(f'write-memory-raw {addr} {hexstr}')

# Jump to it
cmd('set-register PC=8000h')
```

## Sending Typed Input

To simulate typing on the emulated keyboard:

```python
# Type a BASIC command (100ms between keys)
cmd('send-keys-string 100 LOAD ""')
time.sleep(1)
# Press ENTER (send newline character)
cmd('send-keys-string 100 \\n')
```

## Tips

- Always use `--noconfigfile` to avoid ZEsarUX loading saved state
- Use `--exit-after N` as a safety timeout for automated scripts
- `smartload` auto-detects file type and triggers tape playback
- Screenshots are of the emulated display only (no ZEsarUX UI chrome)
- BMP files can be converted to PNG with: `sips -s format png input.bmp --out output.png` (macOS)
- ZRCP port default is 10000; change with `--remoteprotocol-port N`
- Multiple connections are OK but commands are serialized
- After a breakpoint fires, the emulator is paused; use `run` to resume
- `write-memory-raw` works while the CPU is running (no need to pause)
