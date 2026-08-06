# Remote Control Support

clubTivi supports remote control input across all platforms — physical remotes, keyboards, gamepads, and a built-in web-based companion remote.

---

## 🎮 Supported Input Methods

| Input Method | Android TV | Android Phone/Tablet | macOS | Windows | Linux |
|---|---|---|---|---|---|
| IR Remote (TV remote) | ✅ | — | — | — | — |
| Bluetooth Remote | ✅ | ✅ | ✅ | ✅ | ✅ |
| CEC (HDMI-CEC) | ✅ | — | — | — | — |
| Keyboard | ✅ | ✅ | ✅ | ✅ | ✅ |
| Gamepad / Controller | ✅ | ✅ | ✅ | ✅ | ✅ |
| Web Companion Remote | ✅ | ✅ | ✅ | ✅ | ✅ |
| Mouse / Trackpad | — | ✅ | ✅ | ✅ | ✅ |

---

## 📺 Physical Remotes

### Android TV (Onn, Fire TV Stick, NVIDIA Shield, Chromecast, etc.)

clubTivi maps standard Android TV remote buttons out of the box:

| Remote Button | Action |
|---|---|
| **D-pad Up/Down** | Navigate lists, Channel Up/Down (during playback) |
| **D-pad Left/Right** | Navigate, Volume Up/Down (during playback) |
| **Center/Select** | Open/Select, Toggle play/pause (during playback) |
| **Back** | Go back, Close overlay, Exit fullscreen |
| **Home** | Return to Android TV launcher |
| **Play/Pause** | Toggle playback |
| **Fast Forward / Rewind** | Seek ±30s (configurable) |
| **Channel Up/Down** | Next/Previous channel |
| **Volume Up/Down** | System volume |
| **Number keys (0-9)** | Direct channel number entry |
| **Guide/EPG button** | Open program guide |
| **Info** | Show channel/program info overlay |
| **Menu** | Open context menu |
| **Colored buttons (Red/Green/Yellow/Blue)** | Configurable quick actions |

#### Amazon Fire TV Specifics
Fire TV remotes send standard Android key events. Additional mappings:

| Fire TV Button | Action |
|---|---|
| **Alexa / Mic button** | No action (system-level) |
| **App buttons (Netflix, etc.)** | No action (system-level) |
| **Hamburger (☰)** | Open settings |
| **Recent apps** | System-level |

#### Onn / Chromecast Remote Specifics
| Button | Action |
|---|---|
| **YouTube / Netflix buttons** | No action (system-level) |
| **Google Assistant** | No action (system-level) |
| **Input/Source** | No action (system-level) |
| **Live** | Jump to last live channel |
| **Mute** | Toggle mute |

### HDMI-CEC
If your TV supports CEC, your TV's own remote can control clubTivi through the Android TV device. clubTivi receives CEC inputs as standard Android key events — no special configuration needed.

---

## ⌨️ Keyboard Shortcuts

Works on all platforms (desktop + Android with keyboard attached):

### Playback
| Key | Action |
|---|---|
| `Space` | Play / Pause |
| `Enter` | Select / Confirm |
| `Escape` / `Backspace` | Back / Close overlay |
| `F` / `F11` | Toggle fullscreen |
| `M` | Mute / Unmute |
| `↑` / `↓` | Channel Up / Down |
| `←` / `→` | Volume Down / Up |
| `Page Up` / `Page Down` | Channel Up / Down (alternative) |
| `+` / `-` | Volume Up / Down (alternative) |
| `0-9` | Direct channel number entry |
| `Shift + ←` / `Shift + →` | Seek back / forward 30s |
| `Ctrl + ←` / `Ctrl + →` | Seek back / forward 5 min |

### Subtitles
| Key | Action |
|---|---|
| `C` | Toggle subtitles on / off |
| `Shift + C` | Subtitle menu — tracks, load file, appearance |
| `Z` / `X` | Shift subtitle timing 0.5s earlier / later |

### Navigation
| Key | Action |
|---|---|
| `G` | Open EPG Guide |
| `I` | Show info overlay |
| `S` | Open search |
| `Ctrl + ,` | Open settings |
| `Ctrl + P` | Open provider manager |
| `Ctrl + E` | Open EPG mapping manager |
| `Tab` | Cycle focus areas |
| `Ctrl + F` | Find channel by name |
| `H` | Toggle channel list sidebar |
| `R` | Refresh current playlist |
| `A` | Toggle aspect ratio (16:9, 4:3, fit, fill) |
| `T` | Toggle subtitles |
| `L` | Cycle audio tracks |

### Quick Actions
| Key | Action |
|---|---|
| `Ctrl + 1-9` | Switch to favorite group 1-9 |
| `Ctrl + R` | Force reconnect stream |
| `Ctrl + Shift + F` | Toggle failover mode (cold/warm/off) |

---

## 🎮 Gamepad / Controller

Xbox, PlayStation, and generic USB/Bluetooth controllers:

| Button | Action |
|---|---|
| **D-pad** | Navigate |
| **A / Cross (✕)** | Select / Confirm |
| **B / Circle (○)** | Back |
| **X / Square (□)** | Toggle info overlay |
| **Y / Triangle (△)** | Open EPG guide |
| **Left Bumper (LB/L1)** | Channel Down |
| **Right Bumper (RB/R1)** | Channel Up |
| **Left Trigger (LT/L2)** | Volume Down |
| **Right Trigger (RT/R2)** | Volume Up |
| **Left Stick** | Navigate (analog) |
| **Right Stick** | Seek (horizontal) |
| **Start / Options** | Open settings |
| **Select / Share** | Toggle channel list |

---

## 📱 Web Companion Remote

clubTivi includes a built-in lightweight web server that serves a remote control interface. Any device on the same network can control clubTivi by opening a URL in a browser — **no app install required**.

### How It Works

```
┌─────────────────┐         WebSocket          ┌──────────────────┐
│   Phone/Tablet   │◄─────────────────────────►│  clubTivi Player  │
│  (any browser)   │    LAN (mDNS discovery)   │  (TV or Desktop)  │
│                  │                            │                   │
│  ┌────────────┐  │   Commands:               │  Receives:        │
│  │  D-pad     │  │   • navigate(up/down/...) │  • Key events     │
│  │  Vol/Ch    │  │   • channel(+/-)          │  • Channel switch  │
│  │  Play/Pause│  │   • volume(+/-)           │  • Volume control  │
│  │  Guide     │  │   • playback(play/pause)  │  • EPG commands    │
│  │  Numbers   │  │   • epg(open/close)       │  • Search/input    │
│  └────────────┘  │   • search(query)         │                   │
└─────────────────┘                            └──────────────────┘
```

### Setup

1. In clubTivi, go to **Settings → Remote Control → Enable Web Remote**
2. clubTivi displays a URL and QR code, e.g.:
   ```
   http://192.168.1.42:8090/remote
   ```
3. On your phone, scan the QR code or type the URL in any browser
4. The remote interface loads — start controlling!

### Features

- **D-pad navigation** — touch-friendly directional pad
- **Channel Up/Down** — swipe up/down gestures
- **Volume Up/Down** — swipe left/right or slider
- **Number pad** — for direct channel entry
- **Play/Pause/Stop** — transport controls
- **EPG** — open guide, browse programs
- **Search** — type channel names using phone keyboard
- **Touchpad mode** — use phone screen as a trackpad
- **Now Playing** — shows current channel name and program info
- **Quick channel switch** — shows favorite channels for one-tap switching

### Technical Details

- **Discovery**: clubTivi advertises via mDNS (`_clubtivi._tcp`) so companion devices can auto-discover it
- **Protocol**: WebSocket (low latency, bidirectional)
- **Security**: PIN pairing on first connection (displayed on TV/desktop screen)
- **Port**: `8090` by default (configurable in Settings)
- **No internet required** — pure LAN communication

### Multiple Instances

If you have multiple clubTivi players on the network (e.g., living room TV + bedroom TV), the web remote shows a device picker on launch. Each instance advertises its own name (configurable in Settings).

---

## ⚙️ Custom Button Mapping

All remote inputs can be remapped in **Settings → Remote Control → Button Mapping**.

### Mapping Options

Every physical or virtual button can be assigned to any action:

**Available Actions:**
- Channel Up / Down
- Volume Up / Down
- Mute
- Play / Pause / Stop
- Seek Forward / Back (configurable interval)
- Open EPG Guide
- Open Search
- Open Settings
- Toggle Fullscreen
- Toggle Aspect Ratio
- Toggle Subtitles
- Cycle Audio Track
- Open Favorites
- Open Provider Manager
- Switch to Channel (specific number)
- Toggle Failover Mode
- Reconnect Stream
- Picture-in-Picture

### Per-Device Profiles

clubTivi stores separate mapping profiles per input device. If you have both an Onn remote and a Bluetooth keyboard, each can have its own custom mappings.

### Import / Export

Button mappings can be exported as JSON and shared:

```json
{
  "profile": "Onn Remote - Living Room",
  "platform": "android_tv",
  "mappings": {
    "KEYCODE_PROG_RED": "toggle_failover_mode",
    "KEYCODE_PROG_GREEN": "open_epg_guide",
    "KEYCODE_PROG_YELLOW": "open_favorites",
    "KEYCODE_PROG_BLUE": "toggle_aspect_ratio"
  }
}
```

---

## 🔑 Key Event Processing Pipeline

```
Physical Input (IR/BT/USB/CEC)
        │
        ▼
Platform Key Event (Android KeyEvent / macOS NSEvent / Linux GDK / Windows WM_KEYDOWN)
        │
        ▼
Flutter RawKeyboardListener / HardwareKeyboard
        │
        ▼
clubTivi Input Manager
  ├── Check custom button mapping
  ├── Check current context (playback? navigation? text input?)
  ├── Apply context-specific action
  └── Dispatch to appropriate handler
        │
        ▼
Action executed (channel switch, volume, navigate, etc.)
```

The Input Manager ensures that:
- Text input fields capture keys normally (no shortcut interception)
- Context matters: `↑` navigates in menus but changes channel during playback
- Long-press detection works for repeating actions (volume hold, seek hold)
- Simultaneous inputs from multiple devices work correctly
