#!/usr/bin/env python3
"""
MogWatch Windows Viewer
------------------------
A standalone desktop window that listens for the MogWatch UDP status frames
the Windower addon (mogwatch.lua) sends, and displays them live. Meant for
the loopback / same-machine case (default 127.0.0.1:8080), which needs no
pairing or encryption.

Run with a normal Python 3 install (no extra packages required for
PNG/GIF/PPM/PGM maps -- install Pillow with `pip install Pillow` to also
support JPEG/BMP/TIFF/WEBP map images):
    python mogwatch_viewer.py
    python mogwatch_viewer.py --port 9090        (if you changed the port)

Drag the window to your second monitor and leave it open while you play.
Click "Open Map" for a separate window that shows whichever map image(s)
you've supplied for your current zone, from a "Maps" folder next to this
script -- see scan_maps_folder() below for the naming convention. This is a
plain image browser (auto-picks the right file for your zone, zoom/pan) --
it does not show live position.
"""

import argparse
import json
import math
import os
import re
import socket
import struct
import sys
import threading
import time
import queue
import webbrowser
import urllib.request
import urllib.error
from fractions import Fraction
import tkinter as tk
from tkinter import ttk, messagebox

# Bump this with every release. Compared against GitHub's latest release
# tag to check for updates -- see check_for_updates() below.
MOGWATCH_VERSION = '1.0.0'

# Fill in once the repo exists -- e.g. 'yourname/mogwatch'. Update checks
# are skipped entirely (no network call, no error) if this is left as the
# placeholder, so this is safe to ship before the repo is actually live.
GITHUB_REPO = 'YOUR_GITHUB_USERNAME/mogwatch'

try:
    from PIL import Image, ImageTk
    PIL_AVAILABLE = True
except ImportError:
    PIL_AVAILABLE = False

# Formats Tkinter can open natively (no extra libraries needed) vs. formats
# that need Pillow. Both are matched by scan_maps_folder() so a map still
# *shows up* in the dropdown even without Pillow installed -- it just won't
# load until it's either converted to PNG or Pillow is installed (or, once
# this is packaged as a standalone .exe via PyInstaller, Pillow just needs
# to be installed in the environment PyInstaller runs in -- it gets bundled
# into the .exe automatically, no separate install step for end users).
NATIVE_IMAGE_EXTENSIONS = ('png', 'gif', 'ppm', 'pgm')
PILLOW_IMAGE_EXTENSIONS = ('jpg', 'jpeg', 'bmp', 'tiff', 'tif', 'webp')


def app_dir():
    """Directory the script (or, once packaged, the .exe) lives in -- used
    for finding the Maps folder and settings files alongside it. Handles
    both the normal `python mogwatch_viewer.py` case and a PyInstaller
    --onefile .exe, where __file__ points into a temporary extraction
    directory rather than next to the actual .exe on disk."""
    if getattr(sys, 'frozen', False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def bundled_asset_dir():
    """Directory for read-only assets bundled INTO the .exe itself (like
    mogwatch.ico) via PyInstaller's --add-data, as opposed to app_dir()'s
    user-writable files that live next to the portable .exe. PyInstaller
    extracts --add-data files to a temporary folder at runtime, exposed as
    sys._MEIPASS -- NOT the same location as sys.executable, so this is
    deliberately a separate helper from app_dir() rather than reusing it.
    Falls back to app_dir() when not frozen, since running the plain
    script just needs mogwatch.ico sitting next to it."""
    if getattr(sys, 'frozen', False):
        return getattr(sys, '_MEIPASS', app_dir())
    return app_dir()


class ImageLoadError(Exception):
    pass


def load_base_image(path):
    """Returns a tk.PhotoImage for natively-supported formats, or a PIL
    Image for everything else (if Pillow is installed -- bundled
    automatically once this is packaged with PyInstaller). Raises
    ImageLoadError with a clear, actionable message otherwise."""
    ext = os.path.splitext(path)[1].lower().lstrip('.')
    if ext in NATIVE_IMAGE_EXTENSIONS:
        try:
            return tk.PhotoImage(file=path)
        except tk.TclError as exc:
            raise ImageLoadError('Could not open %s: %s' % (path, exc))
    if PIL_AVAILABLE:
        try:
            return Image.open(path).convert('RGB')
        except Exception as exc:
            raise ImageLoadError('Could not open %s: %s' % (path, exc))
    raise ImageLoadError(
        '.%s files need the Pillow library -- Tkinter alone can only open '
        'PNG/GIF/PPM/PGM directly.\n\nEither convert this file to PNG, or '
        'install Pillow once with:\n    pip install Pillow\nand restart '
        'the viewer.' % ext.upper())

PROTOCOL_MAGIC = b'MOG'
TYPE_STATUS = 1
TYPE_COMMAND = 2
TYPE_HELLO = 3

VALUE_NULL = 0
VALUE_FALSE = 1
VALUE_TRUE = 2
VALUE_POS_INT = 3
VALUE_NEG_INT = 4
VALUE_FLOAT = 5
VALUE_STRING = 6
VALUE_LIST = 7
VALUE_MAP = 8

# --- Color palette -----------------------------------------------------
BG = '#14151a'
PANEL_BG = '#1e2027'
PANEL_BORDER = '#2c2f38'
TEXT = '#e8e8ec'
MUTED = '#8a8d97'
HP_COLOR = '#43d17a'        # 75-100% HP (green)
HP_MID_COLOR = '#f5c451'    # 50-74% HP (yellow)
HP_ORANGE_COLOR = '#e8791a' # 25-49% HP (orange, distinct shade from TP's orange)
HP_LOW_COLOR = '#e5484d'    # <25% HP (red), and the "on" state of the <=10% flash
HP_FLASH_DIM_COLOR = '#4a1416'  # the "off" state of the <=10% flash
MP_COLOR = '#3b82f6'        # always blue
TP_COLOR = '#f5842d'        # always orange
TARGET_COLOR = '#e5484d'
ACCENT = '#8b7cf6'
GRID = '#2c2f38'

# Tkinter's default UI font (Segoe UI) has no Japanese glyphs, so Japanese
# text (player names, chat) shows up as empty boxes even though the
# underlying text is valid UTF-8 -- Windower already converts everything
# from Shift-JIS before it reaches an addon. MS Gothic covers both Latin
# and Japanese and ships with every version of Windows since XP, so it's
# used anywhere player/NPC-supplied text (names, chat) might appear.
CJK_FONT = 'MS Gothic'


class DecodeError(Exception):
    pass


def _parse_version(version_string):
    """Parses 'v1.2.3' or '1.2.3' into (1, 2, 3) for proper numeric
    comparison -- a plain string comparison would wrongly say "1.9.0" is
    newer than "1.10.0"."""
    cleaned = version_string.strip().lstrip('vV')
    parts = []
    for part in cleaned.split('.'):
        digits = ''.join(ch for ch in part if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts)


def check_for_updates(timeout=5):
    """Checks GitHub's public releases API for a newer version than
    MOGWATCH_VERSION. Returns (is_newer, latest_version_tag, release_url),
    or (False, None, None) on absolutely any failure -- no repo configured
    yet, no internet, rate-limited, malformed response, whatever. This is
    a background convenience check and must never surface an error or
    interrupt normal use; the whole point is that not being able to check
    is indistinguishable from "no update available" to the rest of the
    app."""
    if '/' not in GITHUB_REPO or GITHUB_REPO.startswith('YOUR_'):
        return False, None, None
    url = 'https://api.github.com/repos/%s/releases/latest' % GITHUB_REPO
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'MogWatch-UpdateCheck'})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            data = json.loads(response.read().decode('utf-8'))
        tag = data.get('tag_name', '')
        release_url = data.get('html_url') or ('https://github.com/%s/releases' % GITHUB_REPO)
        if not tag:
            return False, None, None
        is_newer = _parse_version(tag) > _parse_version(MOGWATCH_VERSION)
        return is_newer, tag, release_url
    except Exception:
        # Deliberately broad: any failure here (network, JSON, timeout,
        # unexpected response shape) should just mean "couldn't check",
        # never a crash or a visible error for what's a background
        # convenience feature.
        return False, None, None


def decode_varuint(data, index):
    value = 0
    multiplier = 1
    while True:
        if index >= len(data):
            raise DecodeError('truncated varuint')
        byte = data[index]
        value += (byte % 128) * multiplier
        index += 1
        if byte < 128:
            return value, index
        multiplier *= 128


def decode_string(data, index):
    length, index = decode_varuint(data, index)
    end = index + length
    if end > len(data):
        raise DecodeError('truncated string')
    return data[index:end].decode('utf-8', errors='replace'), end


def decode_value(data, index):
    if index >= len(data):
        raise DecodeError('truncated value')
    value_type = data[index]
    index += 1

    if value_type == VALUE_NULL:
        return None, index
    if value_type == VALUE_FALSE:
        return False, index
    if value_type == VALUE_TRUE:
        return True, index
    if value_type == VALUE_POS_INT:
        return decode_varuint(data, index)
    if value_type == VALUE_NEG_INT:
        v, index = decode_varuint(data, index)
        return -v, index
    if value_type == VALUE_FLOAT:
        s, index = decode_string(data, index)
        return float(s), index
    if value_type == VALUE_STRING:
        return decode_string(data, index)
    if value_type == VALUE_LIST:
        length, index = decode_varuint(data, index)
        values = []
        for _ in range(length):
            item, index = decode_value(data, index)
            values.append(item)
        return values, index
    if value_type == VALUE_MAP:
        length, index = decode_varuint(data, index)
        values = {}
        for _ in range(length):
            key, index = decode_string(data, index)
            item, index = decode_value(data, index)
            values[key] = item
        return values, index

    raise DecodeError('unknown value type %d' % value_type)


def decode_frame(data):
    if len(data) < 10 or data[0:3] != PROTOCOL_MAGIC:
        raise DecodeError('not a MogWatch frame')
    payload_length = struct.unpack('>I', data[6:10])[0]
    if len(data) != 10 + payload_length:
        raise DecodeError('frame length mismatch')
    message_type = data[4]
    payload, end = decode_value(data, 10)
    if end != len(data):
        raise DecodeError('trailing bytes')
    return message_type, payload


def udp_listener(port, out_queue, stop_event):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', port))
    sock.settimeout(0.5)
    out_queue.put(('status_text', 'Listening on UDP %d ...' % port))
    while not stop_event.is_set():
        try:
            data, _addr = sock.recvfrom(65535)
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            message_type, payload = decode_frame(data)
        except DecodeError as exc:
            out_queue.put(('status_text', 'Bad frame: %s' % exc))
            continue
        except Exception as exc:
            # An unexpected (non-DecodeError) failure here used to be able
            # to kill this entire background thread silently -- no more
            # UDP data would ever be processed again, with nothing visible
            # anywhere to explain why the whole app just stopped updating.
            import traceback
            traceback.print_exc()
            out_queue.put(('status_text', 'Unexpected decode error: %s (see console)' % exc))
            continue
        if message_type == TYPE_STATUS and isinstance(payload, dict):
            out_queue.put(('payload', payload))
    sock.close()


class CommandServer:
    """Lets the viewer send plain text commands (e.g. "//counter reset x")
    back into the game. The addon connects OUT to us as a TCP client (see
    connect_client() in mogwatch.lua) -- we're the server here, accepting
    that connection and writing newline-terminated command lines to it.

    This only implements the loopback/unencrypted case, matching how the
    addon's own receive_commands() falls back to treating each line as a
    plain command when no pairing is required -- the same default setup
    this whole tool is built around. If the addon hasn't connected yet (not
    loaded, mid-reload, etc), send_command() just silently does nothing
    rather than erroring -- there's nothing actionable for the user to do
    about a momentarily-missing connection."""

    def __init__(self, port, status_queue):
        self.port = port
        self.status_queue = status_queue
        self._server_sock = None
        self._client_sock = None
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        with self._lock:
            for sock in (self._client_sock, self._server_sock):
                if sock:
                    try:
                        sock.close()
                    except OSError:
                        pass

    def _run(self):
        try:
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(('0.0.0.0', self.port))
            srv.listen(1)
            srv.settimeout(0.5)
        except OSError as exc:
            self.status_queue.put(
                ('status_text', 'Command server could not start on port %d: %s' % (self.port, exc)))
            return
        self._server_sock = srv
        while not self._stop_event.is_set():
            try:
                conn, _addr = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self._lock:
                if self._client_sock:
                    try:
                        self._client_sock.close()
                    except OSError:
                        pass
                self._client_sock = conn
        try:
            srv.close()
        except OSError:
            pass

    def send_command(self, command_text):
        with self._lock:
            sock = self._client_sock
        if not sock:
            return False
        try:
            sock.sendall((command_text.strip() + '\n').encode('utf-8'))
            return True
        except OSError:
            with self._lock:
                if self._client_sock is sock:
                    self._client_sock = None
            return False


# --- Small drawn widgets (nicer than plain ttk labels/progressbars) ----

class StatBar(tk.Canvas):
    """A rounded, labeled HP/MP/TP-style bar drawn on a canvas.

    Pass dynamic_hp=True for an HP-style bar that changes color by percent
    (51-100% green, 26-50% yellow, 11-25% red, <=10% flashing red) instead
    of a fixed color. MP/TP bars should NOT set this -- they stay whatever
    fixed color they're constructed with."""

    def __init__(self, parent, color, low_color=None, height=20, dynamic_hp=False, **kwargs):
        super().__init__(parent, height=height, bg=PANEL_BG,
                          highlightthickness=0, **kwargs)
        self.color = color
        self.low_color = low_color
        self.dynamic_hp = dynamic_hp
        self.fraction = 0.0
        self.label_text = ''
        self._flash_on = True
        self._flash_job = None
        self.bind('<Configure>', lambda e: self._redraw())
        self.bind('<Destroy>', lambda e: self._stop_flash())

    def set(self, current, maximum, label=None):
        try:
            current = float(current)
            maximum = float(maximum)
            self.fraction = max(0.0, min(1.0, current / maximum)) if maximum > 0 else 0.0
        except (TypeError, ValueError):
            self.fraction = 0.0
        if label is not None:
            self.label_text = label
        else:
            self.label_text = '%s / %s' % (int(current), int(maximum)) if maximum else '--'
        if self.dynamic_hp:
            self._manage_flashing()
        self._redraw()

    def set_fraction(self, fraction, label=''):
        self.fraction = max(0.0, min(1.0, fraction))
        self.label_text = label
        if self.dynamic_hp:
            self._manage_flashing()
        self._redraw()

    def _hp_color_for_fraction(self, fraction):
        pct = fraction * 100
        if pct <= 10:
            return HP_LOW_COLOR if self._flash_on else HP_FLASH_DIM_COLOR
        elif pct < 25:
            return HP_LOW_COLOR
        elif pct < 50:
            return HP_ORANGE_COLOR
        elif pct < 75:
            return HP_MID_COLOR
        else:
            return HP_COLOR

    def _manage_flashing(self):
        is_critical = 0 < self.fraction * 100 <= 10
        if is_critical and self._flash_job is None:
            self._start_flash()
        elif not is_critical and self._flash_job is not None:
            self._stop_flash()

    def _start_flash(self):
        def tick():
            self._flash_on = not self._flash_on
            self._redraw()
            self._flash_job = self.after(400, tick)
        self._flash_job = self.after(400, tick)

    def _stop_flash(self):
        if self._flash_job is not None:
            try:
                self.after_cancel(self._flash_job)
            except Exception:
                pass
            self._flash_job = None
        self._flash_on = True

    def _redraw(self):
        self.delete('all')
        w = self.winfo_width()
        h = self.winfo_height()
        if w <= 1 or h <= 1:
            return
        r = h / 2
        self._round_rect(0, 0, w, h, r, fill=GRID, outline='')
        fill_w = max(h, w * self.fraction) if self.fraction > 0 else 0
        if self.dynamic_hp:
            color = self._hp_color_for_fraction(self.fraction)
        else:
            color = self.color
            if self.low_color and self.fraction <= 0.25:
                color = self.low_color
        if fill_w > 0:
            self._round_rect(0, 0, fill_w, h, r, fill=color, outline='')
        self.create_text(w / 2, h / 2, text=self.label_text, fill=TEXT,
                          font=('Segoe UI', 9))

    def _round_rect(self, x1, y1, x2, y2, r, **kwargs):
        r = min(r, (x2 - x1) / 2, (y2 - y1) / 2)
        if r <= 0:
            self.create_rectangle(x1, y1, x2, y2, **kwargs)
            return
        points = [
            x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r,
            x2, y2 - r, x2, y2, x2 - r, y2, x1 + r, y2,
            x1, y2, x1, y2 - r, x1, y1 + r, x1, y1,
        ]
        self.create_polygon(points, smooth=True, **kwargs)


# --- Map image discovery ------------------------------------------------
#
# Map images live in a "Maps" folder next to this script. Nothing here
# downloads, bundles, or reproduces anyone's map art -- you put files there
# yourself, named to match the in-game zone name:
#
#   Maps/Bastok Markets.png              <- single map, no suffix needed
#   Maps/Beadeaux - Map 1.png            <- first floor/area of a multi-map zone
#   Maps/Beadeaux - Map 2.png            <- second floor/area
#
# The area name must match the zone name MogWatch reports (case and
# whitespace don't matter, everything else does -- e.g. apostrophes in
# names like "Ru'Lude Gardens" must match exactly).

# --- Map image discovery ------------------------------------------------
#
# Map images live in a "Maps" folder next to this script. Nothing here
# downloads, bundles, or reproduces anyone's map art -- you put files there
# yourself, named to match the in-game zone name:
#
#   Maps/Bastok Markets.png                  <- single map, no suffix needed
#   Maps/Beadeaux - Map 1.png                <- multi-map area, first map
#   Maps/Beadeaux - Map 2.png                <- second map
#   Maps/Beadeaux - Map 1 v2.png             <- an alternate version of Map 1
#                                                (e.g. different info drawn on it)
#
# The area name must match the zone you're currently in (case/whitespace
# don't matter, everything else does -- e.g. apostrophes in names like
# "Ru'Lude Gardens" matter).

MAPS_FOLDER = os.path.join(app_dir(), 'Maps')
MAP_FILENAME_RE = re.compile(
    r'^(?P<area>.+?)'
    r'(?:\s*-\s*Map\s*(?P<num>\d+))?'
    r'(?:\s*v(?P<version>\d+))?'
    r'\.(?P<ext>' + '|'.join(NATIVE_IMAGE_EXTENSIONS + PILLOW_IMAGE_EXTENSIONS) + r')$',
    re.IGNORECASE)


def normalize_zone_name(name):
    return ' '.join((name or '').strip().casefold().split())


def scan_maps_folder():
    """Returns {normalized_area_name: [{'label', 'path', 'num', 'version'}, ...]},
    each inner list sorted by (map number, version), built by matching every
    image file in MAPS_FOLDER against the naming convention above."""
    found = {}
    if not os.path.isdir(MAPS_FOLDER):
        return found
    for fname in sorted(os.listdir(MAPS_FOLDER)):
        match = MAP_FILENAME_RE.match(fname)
        if not match:
            continue
        area = match.group('area').strip()
        num = int(match.group('num')) if match.group('num') else 1
        version = int(match.group('version')) if match.group('version') else 1
        label = 'Map %d' % num
        if version != 1:
            label += ' (v%d)' % version
        key = normalize_zone_name(area)
        found.setdefault(key, []).append({
            'label': label,
            'path': os.path.join(MAPS_FOLDER, fname),
            'num': num,
            'version': version,
        })
    for key in found:
        found[key].sort(key=lambda e: (e['num'], e['version']))
    return found


def add_topmost_toggle(window):
    """Adds a small 'Stay on top' checkbox to the very top of a window, so
    it can be overlaid on the game and stay visible instead of dropping
    behind it when the game regains focus. Off by default -- normal
    window behavior until explicitly turned on. Works the same way across
    every window in the app (the main viewer and every pop-out), since
    tk.Tk and tk.Toplevel both support the same -topmost attribute."""
    var = tk.BooleanVar(value=False)

    def on_toggle():
        window.attributes('-topmost', var.get())

    row = tk.Frame(window, bg=BG)
    row.pack(fill='x', side='top')
    tk.Checkbutton(
        row, text='Stay on top', variable=var, command=on_toggle,
        bg=BG, fg=MUTED, selectcolor=PANEL_BG, activebackground=BG,
        activeforeground=TEXT, font=('Segoe UI', 8),
    ).pack(side='right', padx=6, pady=(4, 0))
    return var


class MapWindow(tk.Toplevel):
    """A simple map browser: shows whichever image(s) you've supplied for
    the zone you're currently in, auto-matched by name, with zoom and a
    dropdown for zones that have more than one map (or multiple versions
    of the same map). No live position, no calibration -- just the image."""

    def __init__(self, master):
        super().__init__(master)
        self.title('MogWatch Map')
        self.geometry('560x600')
        self.configure(bg=BG)
        add_topmost_toggle(self)
        self.zoom_factor = 1.0
        self.auto_fit = True
        self._map_photo_cache = {}
        self._scaled_photo_cache = {}
        self._current_display_photo = None
        self._last_payload = None
        self._current_zone_key = None
        self._current_zone_name = ''
        self._available_maps = []
        self._maps_by_zone = scan_maps_folder()

        top = tk.Frame(self, bg=BG)
        top.pack(fill='x', padx=8, pady=(8, 4))
        tk.Label(top, text='Map:', bg=BG, fg=MUTED, font=('Segoe UI', 9)).pack(side='left')
        self.variant_var = tk.StringVar(value='')
        self.variant_combo = ttk.Combobox(top, textvariable=self.variant_var,
                                           state='readonly', width=18)
        self.variant_combo.bind('<<ComboboxSelected>>', self._on_variant_selected)
        self.variant_combo.pack(side='left', padx=(6, 6))
        self.map_count_label = tk.Label(top, text='', bg=BG, fg=MUTED, font=('Segoe UI', 8))
        self.map_count_label.pack(side='left', padx=(0, 10))
        self.rescan_btn = ttk.Button(top, text='Rescan Maps Folder', command=self._rescan)
        self.rescan_btn.pack(side='left')

        self.zoom_reset_btn = ttk.Button(top, text='Fit to Window', command=self._zoom_fit)
        self.zoom_in_btn = ttk.Button(top, text='+', width=2, command=self._zoom_in)
        self.zoom_label = tk.Label(top, text='Fit', bg=BG, fg=MUTED, width=5,
                                    font=('Segoe UI', 9))
        self.zoom_out_btn = ttk.Button(top, text='\u2212', width=2, command=self._zoom_out)
        self.zoom_reset_btn.pack(side='right')
        self.zoom_in_btn.pack(side='right')
        self.zoom_label.pack(side='right')
        self.zoom_out_btn.pack(side='right')

        body = tk.Frame(self, bg=BG)
        body.pack(fill='both', expand=True, padx=8, pady=8)
        hbar = tk.Scrollbar(body, orient='horizontal')
        vbar = tk.Scrollbar(body, orient='vertical')
        self.canvas = tk.Canvas(body, bg=PANEL_BG, highlightthickness=0,
                                 xscrollcommand=hbar.set, yscrollcommand=vbar.set)
        hbar.config(command=self.canvas.xview)
        vbar.config(command=self.canvas.yview)
        hbar.pack(side='bottom', fill='x')
        vbar.pack(side='right', fill='y')
        self.canvas.pack(side='left', fill='both', expand=True)
        self.canvas.bind('<Configure>', lambda e: self._draw())
        self.canvas.bind('<Control-MouseWheel>', self._on_mousewheel_zoom)

        self._draw()

    # -- Folder / zone matching ------------------------------------------

    def _rescan(self):
        self._maps_by_zone = scan_maps_folder()
        self._refresh_variant_list()
        self._draw()

    def update_payload(self, payload):
        """Called by the main viewer on every status frame, purely to know
        which zone's maps to show -- no position data is used."""
        self._last_payload = payload
        player = payload.get('player') or {}
        zone_name = player.get('location') or ''
        zone_key = normalize_zone_name(zone_name)
        if zone_key != self._current_zone_key:
            self._current_zone_key = zone_key
            self._current_zone_name = zone_name
            self._refresh_variant_list()
        self._draw()

    def _refresh_variant_list(self):
        self._available_maps = self._maps_by_zone.get(self._current_zone_key, [])
        labels = [m['label'] for m in self._available_maps]
        self.variant_combo.config(values=labels)
        if labels:
            if self.variant_var.get() not in labels:
                self.variant_var.set(labels[0])
            self.map_count_label.config(
                text=('(%d maps found)' % len(labels)) if len(labels) > 1 else '')
        else:
            self.variant_var.set('')
            self.map_count_label.config(text='')

    def _on_variant_selected(self, event=None):
        self._zoom_fit()

    def _current_map_entry(self):
        label = self.variant_var.get()
        for m in self._available_maps:
            if m['label'] == label:
                return m
        return None

    # -- Zoom (manual, and auto-fit-to-window as the default) ------------

    def _zoom_in(self):
        self.auto_fit = False
        self.zoom_factor = min(4.0, self.zoom_factor * 1.25)
        self._draw()

    def _zoom_out(self):
        self.auto_fit = False
        self.zoom_factor = max(0.1, self.zoom_factor / 1.25)
        self._draw()

    def _zoom_fit(self):
        self.auto_fit = True
        self._draw()

    def _on_mousewheel_zoom(self, event):
        if event.delta > 0:
            self._zoom_in()
        else:
            self._zoom_out()

    # -- Drawing -----------------------------------------------------------

    def _message(self, text, color=MUTED):
        w = max(self.canvas.winfo_width(), 1)
        h = max(self.canvas.winfo_height(), 1)
        self.canvas.config(scrollregion=(0, 0, w, h))
        self.canvas.create_text(12, 12, anchor='nw', fill=color, font=('Segoe UI', 10),
                                 width=w - 24 if w > 40 else 420, text=text)

    def _image_size(self, img):
        if PIL_AVAILABLE and isinstance(img, Image.Image):
            return img.size
        return img.width(), img.height()

    def _draw(self):
        self.canvas.delete('all')

        if not self._current_zone_name:
            self._message('Waiting for a status update from the addon...')
            return

        if not self._available_maps:
            self._message(
                'No map image found for "%s".\n\n'
                'Add one to the Maps folder named either:\n'
                '  %s.png\n'
                'or, for multiple maps in this area:\n'
                '  %s - Map 1.png\n'
                '  %s - Map 2.png\n'
                'or, for alternate versions of the same map:\n'
                '  %s - Map 1 v2.png\n\n'
                'Maps folder: %s' % (
                    self._current_zone_name, self._current_zone_name,
                    self._current_zone_name, self._current_zone_name,
                    self._current_zone_name, MAPS_FOLDER))
            return

        entry = self._current_map_entry()
        if entry is None:
            self._message('Select a map from the dropdown above.')
            return

        base_photo = self._map_photo_cache.get(entry['path'])
        if base_photo is None:
            try:
                base_photo = load_base_image(entry['path'])
            except ImageLoadError as exc:
                self._message(str(exc), HP_LOW_COLOR)
                return
            self._map_photo_cache[entry['path']] = base_photo

        bw, bh = self._image_size(base_photo)

        if self.auto_fit:
            cw = max(self.canvas.winfo_width(), 1)
            ch = max(self.canvas.winfo_height(), 1)
            # Fit the whole image to fill the window, preserving aspect
            # ratio (never stretched non-uniformly) -- scales up as well as
            # down. Capped at 4x so a small image in a huge window doesn't
            # get scaled up into a massive intermediate image.
            fit = min(cw / bw, ch / bh) if bw and bh else 1.0
            self.zoom_factor = max(0.1, min(4.0, fit))
            self.zoom_label.config(text='Fit (%d%%)' % round(self.zoom_factor * 100))
        else:
            self.zoom_label.config(text='%d%%' % round(self.zoom_factor * 100))

        display_photo = self._get_display_photo(entry['path'], base_photo)
        self._current_display_photo = display_photo

        dw, dh = self._image_size(display_photo)
        self.canvas.create_image(0, 0, anchor='nw', image=display_photo)
        self.canvas.config(scrollregion=(0, 0, dw, dh))

    def _get_display_photo(self, cache_key, base_photo):
        """Returns a Tk-displayable image at the current zoom level.

        For Pillow-backed images, this resizes to an exact arbitrary ratio
        (much better quality than Tkinter's native approach, and precise
        rather than approximated). For native tk.PhotoImage, Tkinter only
        scales by integer zoom()/subsample() factors, so an arbitrary zoom
        like 1.4x is approximated as a ratio (e.g. 7/5)."""
        target = round(self.zoom_factor, 3)
        full_key = (cache_key, target)
        cached = self._scaled_photo_cache.get(full_key)
        if cached is not None:
            return cached

        if PIL_AVAILABLE and isinstance(base_photo, Image.Image):
            if target == 1.0:
                result = ImageTk.PhotoImage(base_photo)
            else:
                w, h = base_photo.size
                new_w = max(1, round(w * target))
                new_h = max(1, round(h * target))
                resized = base_photo.resize((new_w, new_h), Image.LANCZOS)
                result = ImageTk.PhotoImage(resized)
        elif target == 1.0:
            result = base_photo
        else:
            frac = Fraction(target).limit_denominator(8)
            num, den = frac.numerator, frac.denominator
            result = base_photo
            if num != 1:
                result = result.zoom(num, num)
            if den != 1:
                result = result.subsample(den, den)

        self._scaled_photo_cache[full_key] = result
        if len(self._scaled_photo_cache) > 60:
            self._scaled_photo_cache.clear()
            self._scaled_photo_cache[full_key] = result
        return result

class NpcWindow(tk.Toplevel):
    """List of nearby NPCs/mobs -- name, distance, HP% -- filtered and
    capped by the addon (within 50 units, top 15 closest, self and party
    members excluded) to keep frames small. Tracking (which names to pin
    to the top of the list) is purely client-side state here -- the addon
    has no concept of it, this window just re-sorts/highlights whatever
    NPCs it's already been sent."""

    def __init__(self, master):
        super().__init__(master)
        self.title('MogWatch - Nearby NPCs')
        self.geometry('420x600')
        self.configure(bg=BG)
        add_topmost_toggle(self)

        self.tracked_names = set()
        self.sort_mode = tk.StringVar(value='distance')
        self._last_npcs = []

        tk.Label(self, text='NEARBY NPCS', bg=BG, fg=MUTED,
                 font=('Segoe UI', 9, 'bold')).pack(anchor='w', padx=10, pady=(10, 4))

        sort_row = tk.Frame(self, bg=BG)
        sort_row.pack(fill='x', padx=10, pady=(0, 4))
        tk.Label(sort_row, text='Sort by:', bg=BG, fg=MUTED,
                 font=('Segoe UI', 8)).pack(side='left')
        for label, value in (('Distance', 'distance'), ('Name', 'name')):
            tk.Radiobutton(
                sort_row, text=label, variable=self.sort_mode, value=value,
                command=self._render, bg=BG, fg=TEXT, selectcolor=PANEL_BG,
                activebackground=BG, activeforeground=TEXT,
                font=('Segoe UI', 8)).pack(side='left', padx=(6, 0))

        track_row = tk.Frame(self, bg=BG)
        track_row.pack(fill='x', padx=10, pady=(0, 6))
        self.track_entry = tk.Entry(track_row, bg=PANEL_BG, fg=TEXT,
                                     insertbackground=TEXT, relief='flat')
        self.track_entry.pack(side='left', fill='x', expand=True, ipady=3)
        self.track_entry.bind('<Return>', lambda e: self._track_from_entry())
        ttk.Button(track_row, text='Track', command=self._track_from_entry).pack(
            side='left', padx=(4, 0))

        columns = ('name', 'distance', 'hp')
        self.tree = ttk.Treeview(self, columns=columns, show='headings', height=12)
        for col, width, heading in zip(columns, (180, 90, 70), ('Name', 'Distance', 'HP')):
            self.tree.heading(col, text=heading)
            self.tree.column(col, width=width, anchor='center')
        self.tree.tag_configure('low', foreground=HP_LOW_COLOR)
        self.tree.tag_configure('tracked', foreground=ACCENT)
        self.tree.pack(fill='both', expand=True, padx=10, pady=(0, 6))
        self.tree.bind('<Button-1>', self._on_row_click)

        tk.Label(self, text='TRACKED', bg=BG, fg=MUTED,
                 font=('Segoe UI', 9, 'bold')).pack(anchor='w', padx=10, pady=(4, 2))
        tracked_outer = tk.Frame(self, bg=PANEL_BG, highlightbackground=PANEL_BORDER,
                                  highlightthickness=1)
        tracked_outer.pack(fill='both', padx=10, pady=(0, 10))
        self.tracked_list_frame = tk.Frame(tracked_outer, bg=PANEL_BG)
        self.tracked_list_frame.pack(fill='x', padx=6, pady=6)
        self._render()

    def _track_from_entry(self):
        name = self.track_entry.get().strip()
        if not name:
            return
        self.tracked_names.add(name)
        self.track_entry.delete(0, 'end')
        self._render()

    def _track(self, name):
        self.tracked_names.add(name)
        self._render()

    def _untrack(self, name):
        self.tracked_names.discard(name)
        self._render()

    def _on_row_click(self, event):
        row_id = self.tree.identify_row(event.y)
        if not row_id:
            return
        values = self.tree.item(row_id, 'values')
        if not values:
            return
        name = values[0]
        menu = tk.Menu(self, tearoff=0, bg=PANEL_BG, fg=TEXT,
                        activebackground=ACCENT, activeforeground='#14151a')
        if name in self.tracked_names:
            menu.add_command(label='Untrack', command=lambda: self._untrack(name))
        else:
            menu.add_command(label='Track', command=lambda: self._track(name))
        menu.tk_popup(event.x_root, event.y_root)

    def update_payload(self, payload):
        self._last_npcs = [n for n in (payload.get('npcs') or []) if isinstance(n, dict)]
        self._render()

    def _render(self):
        sort_by_name = self.sort_mode.get() == 'name'

        def sort_key(npc):
            is_tracked = npc.get('name') in self.tracked_names
            if sort_by_name:
                value = (npc.get('name') or '').lower()
            else:
                distance = npc.get('distance')
                value = distance if isinstance(distance, (int, float)) else float('inf')
            # Tracked NPCs sort to the top as a group; each group is then
            # ordered by whichever criteria is selected.
            return (0 if is_tracked else 1, value)

        sorted_npcs = sorted(self._last_npcs, key=sort_key)

        self.tree.delete(*self.tree.get_children())
        for npc in sorted_npcs:
            name = npc.get('name', '?')
            distance = npc.get('distance')
            dist_text = ('%.1f' % distance) if isinstance(distance, (int, float)) else '--'
            hpp = npc.get('hpp')
            hp_text = ('%d%%' % hpp) if isinstance(hpp, (int, float)) else '--'
            low = isinstance(hpp, (int, float)) and hpp <= 25
            if name in self.tracked_names:
                tags = ('tracked',)
            elif low:
                tags = ('low',)
            else:
                tags = ()
            self.tree.insert('', 'end', values=(name, dist_text, hp_text), tags=tags)

        for child in self.tracked_list_frame.winfo_children():
            child.destroy()
        if not self.tracked_names:
            tk.Label(self.tracked_list_frame, text='(none -- click an NPC above, or '
                     'type a name and click Track)', bg=PANEL_BG, fg=MUTED,
                     font=('Segoe UI', 8), wraplength=360, justify='left').pack(anchor='w')
        else:
            visible_names = {npc.get('name') for npc in self._last_npcs}
            for name in sorted(self.tracked_names):
                row = tk.Frame(self.tracked_list_frame, bg=PANEL_BG)
                row.pack(fill='x', pady=1)
                # Dimmed if the tracked name isn't currently among the
                # nearby NPCs the addon reported -- lets you tell at a
                # glance whether something you're tracking is actually
                # around right now.
                color = TEXT if name in visible_names else MUTED
                tk.Label(row, text=name, bg=PANEL_BG, fg=color, font=('Segoe UI', 8),
                         anchor='w').pack(side='left', fill='x', expand=True)
                ttk.Button(row, text='Remove', width=8,
                           command=lambda n=name: self._untrack(n)).pack(side='left')


class ChatWindow(tk.Toplevel):
    """Relayed chat log. Best-effort: this rides the same UDP status
    frames as everything else, so a dropped packet means a dropped line --
    fine for a glance-at-it companion display, not a substitute for the
    game's own chat log if you need every line guaranteed."""

    def __init__(self, master):
        super().__init__(master)
        self.title('MogWatch - Chat Log')
        self.geometry('480x420')
        self.configure(bg=BG)
        add_topmost_toggle(self)

        tk.Label(self, text='CHAT LOG (best-effort -- relayed over UDP, a dropped '
                             'packet means a dropped line)',
                 bg=BG, fg=MUTED, font=('Segoe UI', 8), wraplength=460,
                 justify='left').pack(anchor='w', padx=10, pady=(10, 4))

        body = tk.Frame(self, bg=BG)
        body.pack(fill='both', expand=True, padx=10, pady=(0, 10))
        vbar = tk.Scrollbar(body, orient='vertical')
        self.text = tk.Text(body, bg=PANEL_BG, fg=TEXT, wrap='word',
                             yscrollcommand=vbar.set, state='disabled',
                             font=(CJK_FONT, 10), relief='flat')
        vbar.config(command=self.text.yview)
        vbar.pack(side='right', fill='y')
        self.text.pack(side='left', fill='both', expand=True)
        self.text.tag_configure('outgoing', foreground=ACCENT)
        self.text.tag_configure('mode', foreground=MUTED)

    def update_payload(self, payload):
        lines = payload.get('chat') or []
        if not lines:
            return
        self.text.config(state='normal')
        was_at_bottom = self.text.yview()[1] >= 0.999
        for line in lines:
            if not isinstance(line, dict):
                continue
            text = line.get('text', '')
            outgoing = line.get('outgoing', False)
            mode = line.get('mode')
            label = line.get('label')
            if outgoing:
                prefix = 'You: '
            elif label:
                prefix = '%s: ' % label
            elif mode is not None:
                prefix = 'Mode %s: ' % mode
            else:
                prefix = ''
            self.text.insert('end', prefix, ('mode',))
            self.text.insert('end', text + '\n', ('outgoing',) if outgoing else ())
        if was_at_bottom:
            self.text.see('end')
        self.text.config(state='disabled')


class PartyWindow(tk.Toplevel):
    """Party list pop-out: name, job/subjob, colored HP/MP/TP bars, and
    buffs/debuffs (separated, color-coded) per member. Uses grid with
    weighted rows/columns throughout, so resizing the window resizes
    everything proportionally rather than leaving fixed-size content in a
    bigger/smaller frame."""

    MAX_MEMBERS = 6
    ROW_HEIGHT_ESTIMATE = 80   # rough pixel height of one member's card, for auto-sizing the window
    BASE_HEIGHT = 85           # title label + toggle row + padding, before any member rows

    def __init__(self, master):
        super().__init__(master)
        self.title('MogWatch - Party')
        self.geometry('520x160')
        self.configure(bg=BG)
        add_topmost_toggle(self)
        self._last_member_count = -1  # forces the first update_payload to size correctly

        tk.Label(self, text='PARTY', bg=BG, fg=MUTED,
                 font=('Segoe UI', 9, 'bold')).pack(anchor='w', padx=10, pady=(10, 4))

        self.body = tk.Frame(self, bg=PANEL_BG, highlightbackground=PANEL_BORDER,
                              highlightthickness=1)
        self.body.pack(fill='both', expand=True, padx=10, pady=(0, 10))

        # Rows start with zero weight -- a row only claims a share of the
        # window's resizable space once a real member actually occupies it
        # (set dynamically in update_payload as the party size changes),
        # rather than every one of the 6 possible slots claiming space
        # whether it's used or not.
        self.body.grid_columnconfigure(0, weight=1)

        self.rows = [self._build_row(self.body, i) for i in range(self.MAX_MEMBERS)]

    def _build_row(self, parent, index):
        card = tk.Frame(parent, bg=PANEL_BG, highlightbackground=GRID,
                         highlightthickness=1)
        card.grid(row=index, column=0, sticky='nsew', padx=4, pady=3)
        card.grid_columnconfigure(0, weight=0)  # name
        card.grid_columnconfigure(1, weight=0)  # job
        # HP/MP/TP bars share the remaining width equally and stretch with
        # the window -- this is what makes them actually scale on resize,
        # rather than sitting at a fixed pixel width.
        card.grid_columnconfigure(2, weight=1, uniform='bar')
        card.grid_columnconfigure(3, weight=1, uniform='bar')
        card.grid_columnconfigure(4, weight=1, uniform='bar')
        # Most of any extra vertical space goes to the bars row; the
        # buff/debuff text lines get a little too (helps if they wrap to
        # more than one line) but stay comparatively compact.
        card.grid_rowconfigure(0, weight=3)
        card.grid_rowconfigure(1, weight=1)
        card.grid_rowconfigure(2, weight=1)

        name_var = tk.StringVar(value='')
        job_var = tk.StringVar(value='')
        name_label = tk.Label(card, textvariable=name_var, bg=PANEL_BG, fg=TEXT,
                               font=(CJK_FONT, 9), anchor='w')
        job_label = tk.Label(card, textvariable=job_var, bg=PANEL_BG, fg=MUTED,
                              font=('Segoe UI', 8), anchor='w')
        hp_bar = StatBar(card, HP_COLOR, dynamic_hp=True, height=18)
        mp_bar = StatBar(card, MP_COLOR, height=18)
        tp_bar = StatBar(card, TP_COLOR, height=18)

        name_label.grid(row=0, column=0, sticky='w', padx=(6, 2), pady=(4, 2))
        job_label.grid(row=0, column=1, sticky='w', padx=(0, 4), pady=(4, 2))
        hp_bar.grid(row=0, column=2, sticky='nsew', padx=1, pady=(4, 2))
        mp_bar.grid(row=0, column=3, sticky='nsew', padx=1, pady=(4, 2))
        tp_bar.grid(row=0, column=4, sticky='nsew', padx=1, pady=(4, 2))

        # Buffs and debuffs are separate labeled lines, color-matched to
        # the HP palette (green-ish for buffs, red for debuffs) so they're
        # distinguishable at a glance beyond just the text.
        buffs_var = tk.StringVar(value='Buffs: --')
        debuffs_var = tk.StringVar(value='Debuffs: --')
        buffs_label = tk.Label(card, textvariable=buffs_var, bg=PANEL_BG, fg=HP_COLOR,
                                font=('Segoe UI', 8), anchor='w', justify='left')
        debuffs_label = tk.Label(card, textvariable=debuffs_var, bg=PANEL_BG, fg=HP_LOW_COLOR,
                                  font=('Segoe UI', 8), anchor='w', justify='left')
        buffs_label.grid(row=1, column=0, columnspan=5, sticky='ew', padx=6, pady=(0, 1))
        debuffs_label.grid(row=2, column=0, columnspan=5, sticky='ew', padx=6, pady=(0, 4))

        def on_resize(event, bl=buffs_label, dl=debuffs_label):
            wrap = max(event.width - 12, 50)
            bl.config(wraplength=wrap)
            dl.config(wraplength=wrap)
        card.bind('<Configure>', on_resize)

        return {
            'card': card, 'name_var': name_var, 'job_var': job_var,
            'hp_bar': hp_bar, 'mp_bar': mp_bar, 'tp_bar': tp_bar,
            'buffs_var': buffs_var, 'debuffs_var': debuffs_var,
        }

    def update_payload(self, payload):
        members = [m for m in (payload.get('partyMembers') or []) if isinstance(m, dict)]
        count = len(members)

        if count != self._last_member_count:
            self._last_member_count = count
            for i in range(self.MAX_MEMBERS):
                # Only rows actually holding a member claim a share of the
                # window's resizable space -- unused rows get weight 0, so
                # they don't stretch into blank space when the party is
                # smaller than a full 6.
                self.body.grid_rowconfigure(i, weight=1 if i < count else 0)

            try:
                current_width = self.winfo_width()
                if current_width <= 1:
                    current_width = 520
            except tk.TclError:
                current_width = 520
            new_height = self.BASE_HEIGHT + max(1, count) * self.ROW_HEIGHT_ESTIMATE
            # Setting geometry here only changes the CURRENT size -- the
            # window remains freely resizable by the user afterward, same
            # as always. This just makes the default size track the
            # party's actual size instead of always reserving room for 6.
            self.geometry('%dx%d' % (current_width, new_height))

        for i, row in enumerate(self.rows):
            if i >= len(members):
                row['card'].grid_remove()
                continue
            member = members[i]
            row['card'].grid()

            name = member.get('name', '?')
            job = member.get('job', '') or ''
            subjob = member.get('subjob', '') or ''
            job_text = job
            if subjob:
                job_text += '/' + subjob
            row['name_var'].set(name)
            row['job_var'].set(job_text or '--')

            current_hp = member.get('currentHp', 0) or 0
            max_hp = member.get('maxHp', 0) or 0
            row['hp_bar'].set(current_hp, max_hp or 1)

            current_mp = member.get('currentMp', 0) or 0
            max_mp = member.get('maxMp', 0) or 0
            row['mp_bar'].set(current_mp, max_mp or 1)

            tp = member.get('tp', 0) or 0
            row['tp_bar'].set(tp, 3000, label=str(tp))

            buff_names = []
            debuff_names = []
            for b in (member.get('activeBuffs') or []):
                if not isinstance(b, dict):
                    continue
                label = b.get('name') or ('#%s' % b.get('id'))
                remaining = b.get('secondsRemaining')
                if isinstance(remaining, (int, float)):
                    minutes, secs = divmod(int(remaining), 60)
                    label = '%s (%d:%02d)' % (label, minutes, secs)
                if b.get('harmful'):
                    debuff_names.append(label)
                else:
                    buff_names.append(label)
            row['buffs_var'].set('Buffs: ' + (', '.join(buff_names) if buff_names else '--'))
            row['debuffs_var'].set('Debuffs: ' + (', '.join(debuff_names) if debuff_names else '--'))


class CounterWindow(tk.Toplevel):
    """Shows Counter's tracked state as a MogWatch tab. Counter is merged
    directly into mogwatch.lua now (no separate addon file), reporting its
    state as part of the same regular status payload as player/target/
    party data. Interactive controls here send plain "counter ..."
    commands back through the viewer's CommandServer, which relays them
    into the game's chat input via windower.chat.input() -- FFXI then
    routes "//counter ..." to the merged command handler exactly as if
    typed directly, so this window itself contains no tracking/detection
    logic of its own."""

    FLASH_DURATION = 5.0  # seconds, matching the original addon's own timing

    def __init__(self, master, command_server):
        super().__init__(master)
        self.command_server = command_server
        self.title('MogWatch - Counter')
        self.geometry('480x620')
        self.configure(bg=BG)
        add_topmost_toggle(self)

        # Flash-on-change state, tracked independently of the row widgets
        # themselves (which get destroyed and rebuilt on every update) --
        # keyed by (category, item_name) -> last known numeric value, and
        # (category, item_name) -> (color, expiry_time) for anything
        # currently flashing. Checked fresh against the wall clock each
        # time a row is rendered, rather than using a scheduled timer.
        self._last_values = {}
        self._flash_state = {}
        self._last_item_snapshot = None
        self._has_rendered_once = False
        self._last_payload = {}

        header = tk.Frame(self, bg=BG)
        header.pack(fill='x', padx=10, pady=(10, 4))
        tk.Label(header, text='COUNTER', bg=BG, fg=MUTED,
                 font=('Segoe UI', 9, 'bold')).pack(side='left')
        self.player_var = tk.StringVar(value='')
        tk.Label(header, textvariable=self.player_var, bg=BG, fg=MUTED,
                 font=('Segoe UI', 8)).pack(side='left', padx=(8, 0))

        # Add-item row
        add_row = tk.Frame(self, bg=BG)
        add_row.pack(fill='x', padx=10, pady=(0, 4))
        self.add_entry = tk.Entry(add_row, bg=PANEL_BG, fg=TEXT, insertbackground=TEXT,
                                   relief='flat')
        self.add_entry.pack(side='left', fill='x', expand=True, ipady=3)
        self.add_entry.bind('<Return>', lambda e: self._add_item())
        ttk.Button(add_row, text='Add', command=self._add_item).pack(side='left', padx=(4, 0))

        # Toggle row: auto-add categories + quiet mode
        toggle_row = tk.Frame(self, bg=BG)
        toggle_row.pack(fill='x', padx=10, pady=(0, 6))
        self.toggle_buttons = {}
        self.toggle_labels = {}
        for key, label in (('drop', 'Drop'), ('personal', 'Personal'),
                            ('usable', 'Usable'), ('gil', 'Gil'), ('quiet', 'Quiet')):
            btn = tk.Button(toggle_row, text=label, relief='flat',
                             command=lambda k=key: self._toggle_auto(k))
            btn.pack(side='left', padx=(0, 4))
            self.toggle_buttons[key] = btn
            self.toggle_labels[key] = label
        ttk.Button(toggle_row, text='Clear All', command=self._clear_all).pack(side='left', padx=(4, 0))

        # Scrollable body for the item sections
        outer = tk.Frame(self, bg=PANEL_BG, highlightbackground=PANEL_BORDER,
                          highlightthickness=1)
        outer.pack(fill='both', expand=True, padx=10, pady=(0, 6))
        canvas = tk.Canvas(outer, bg=PANEL_BG, highlightthickness=0)
        vbar = tk.Scrollbar(outer, orient='vertical', command=canvas.yview)
        canvas.configure(yscrollcommand=vbar.set)
        vbar.pack(side='right', fill='y')
        canvas.pack(side='left', fill='both', expand=True)
        self.body = tk.Frame(canvas, bg=PANEL_BG)
        body_window = canvas.create_window((0, 0), window=self.body, anchor='nw')
        self.body.bind('<Configure>', lambda e: canvas.configure(scrollregion=canvas.bbox('all')))
        canvas.bind('<Configure>', lambda e: canvas.itemconfig(body_window, width=e.width))
        canvas.bind_all('<MouseWheel>', lambda e: canvas.yview_scroll(int(-e.delta / 60), 'units'))

        self.gil_var = tk.StringVar(value='Gil: 0')
        self.gil_label = tk.Label(self.body, textvariable=self.gil_var, bg=PANEL_BG, fg=TP_COLOR,
                                   font=('Segoe UI', 10, 'bold'))
        # Not packed here -- only shown once gil > 0, same as the item
        # categories.

        self.section_frames = {}
        self.section_headers = {}
        for key, title in (('dropItems', 'Item Drops'), ('personalItems', 'Personal Drops'),
                            ('usableItems', 'Usable Items'), ('ammoItems', 'Equipped Ammo'),
                            ('keyItems', 'Key Items')):
            header_label = tk.Label(self.body, text=title, bg=PANEL_BG, fg=MUTED,
                                     font=('Segoe UI', 9, 'bold'))
            frame = tk.Frame(self.body, bg=PANEL_BG)
            # Not packed here -- starts hidden. _render_section() packs a
            # category's header+frame the first time it actually has an
            # item, and unpacks it again if it becomes empty.
            self.section_frames[key] = frame
            self.section_headers[key] = header_label

        # Sets management
        sets_row = tk.Frame(self, bg=BG)
        sets_row.pack(fill='x', padx=10, pady=(0, 4))
        tk.Label(sets_row, text='Sets:', bg=BG, fg=MUTED, font=('Segoe UI', 8)).pack(side='left')
        self.sets_var = tk.StringVar(value='')
        self.sets_combo = ttk.Combobox(sets_row, textvariable=self.sets_var, state='readonly', width=14)
        self.sets_combo.pack(side='left', padx=(4, 4))
        ttk.Button(sets_row, text='Load', command=self._load_set).pack(side='left')
        ttk.Button(sets_row, text='Save As...', command=self._save_set).pack(side='left', padx=(4, 0))
        ttk.Button(sets_row, text='Delete', command=self._delete_set).pack(side='left', padx=(4, 0))

        # Focus item
        focus_row = tk.Frame(self, bg=BG)
        focus_row.pack(fill='x', padx=10, pady=(0, 10))
        tk.Label(focus_row, text='Focus:', bg=BG, fg=MUTED, font=('Segoe UI', 8)).pack(side='left')
        self.focus_var = tk.StringVar(value='(none)')
        tk.Label(focus_row, textvariable=self.focus_var, bg=BG, fg=TEXT,
                 font=('Segoe UI', 8)).pack(side='left', padx=(4, 8))
        ttk.Button(focus_row, text='Clear Focus', command=self._clear_focus).pack(side='left')

        self.after(1000, self._flash_expiry_tick)

    # -- Command helpers ---------------------------------------------------

    def _send(self, command_text):
        # queue_game_command() on the addon side passes this straight to
        # windower.chat_input() with no prefix added -- without the
        # leading "//" here, the text gets typed as a normal chat message
        # instead of being recognized as an addon command at all.
        if not self.command_server.send_command('//' + command_text):
            self.player_var.set('(not connected to game -- reload the addon?)')

    def _add_item(self):
        name = self.add_entry.get().strip()
        if not name:
            return
        self._send('counter add %s' % name)
        self.add_entry.delete(0, 'end')

    def _toggle_auto(self, key):
        current = {
            'drop': self._last_payload.get('autoAddDrop'),
            'personal': self._last_payload.get('autoAddPersonal'),
            'usable': self._last_payload.get('autoAddUsable'),
            'gil': self._last_payload.get('autoAddGil'),
            'quiet': self._last_payload.get('quietMode'),
        }.get(key)
        if key == 'quiet':
            self._send('counter quiet')
            return
        new_value = 'off' if current else 'on'
        self._send('counter auto %s %s' % (key, new_value))

    def _load_set(self):
        name = self.sets_var.get().strip()
        if name:
            self._send('counter set %s' % name)

    def _save_set(self):
        name = self.add_entry.get().strip()
        if not name:
            return
        self._send('counter addset %s' % name)
        self.add_entry.delete(0, 'end')

    def _delete_set(self):
        name = self.sets_var.get().strip()
        if name:
            self._send('counter deleteset %s' % name)

    def _clear_focus(self):
        self._send('counter unfocus')

    def _clear_all(self):
        if messagebox.askyesno(
                'Clear All Tracking',
                'This clears Item Drops, Personal Drops, Usable Items, and '
                'Key Items entirely (only Equipped Ammo is unaffected, '
                'since it auto-tracks from what you have equipped). '
                'This cannot be undone. Continue?'):
            self._send('counter clear')

    # -- Data update --------------------------------------------------------

    def update_payload(self, counter_data):
        if not isinstance(counter_data, dict):
            return
        self._last_payload = counter_data

        player_name = counter_data.get('playerName') or ''
        self.player_var.set(player_name)

        gil = counter_data.get('gil', 0)
        if gil:
            self.gil_var.set('Gil: %s' % gil)
            if not self.gil_label.winfo_ismapped():
                self.gil_label.pack(anchor='w', padx=8, pady=(8, 6))
        else:
            self.gil_label.pack_forget()

        for key, is_on in (('drop', counter_data.get('autoAddDrop')),
                            ('personal', counter_data.get('autoAddPersonal')),
                            ('usable', counter_data.get('autoAddUsable')),
                            ('gil', counter_data.get('autoAddGil')),
                            ('quiet', counter_data.get('quietMode'))):
            btn = self.toggle_buttons.get(key)
            if btn is not None:
                base_label = self.toggle_labels.get(key, key)
                # Windows' native button theming frequently ignores a plain
                # tk.Button's bg= color entirely, so relying on color alone
                # (as this used to) can silently show no visible state
                # change at all. The label text itself always renders
                # correctly regardless of platform/theme, so state is
                # spelled out there; color is kept as a secondary cue where
                # the platform happens to honor it.
                state_word = 'ON' if is_on else 'OFF'
                btn.configure(text='%s: %s' % (base_label, state_word),
                              bg=(HP_COLOR if is_on else HP_LOW_COLOR), fg='#14151a')

        self.sets_combo.config(values=counter_data.get('savedSets') or [])

        focus_name = counter_data.get('focusItemName') or ''
        self.focus_var.set(focus_name if focus_name else '(none)')

        item_snapshot = (
            counter_data.get('dropItems'), counter_data.get('personalItems'),
            counter_data.get('usableItems'), counter_data.get('ammoItems'),
            counter_data.get('keyItems'),
        )
        if item_snapshot != self._last_item_snapshot:
            self._last_item_snapshot = item_snapshot
            self._render_all_sections()

    def _render_all_sections(self):
        counter_data = self._last_payload
        # Unpack everything first, so _render_section's repacking below
        # always establishes the correct category order (Item Drops,
        # Personal, Usable, Ammo, Key), regardless of which categories
        # happened to receive their first item first.
        for key in ('dropItems', 'personalItems', 'usableItems', 'ammoItems', 'keyItems'):
            self.section_headers[key].pack_forget()
            self.section_frames[key].pack_forget()

        self._render_section('dropItems', counter_data.get('dropItems') or [],
                              show_count=True, removable=True, resettable=True)
        self._render_section('personalItems', counter_data.get('personalItems') or [],
                              show_count=True, removable=True, resettable=True)
        self._render_section('usableItems', counter_data.get('usableItems') or [],
                              show_inventory=True, removable=True)
        self._render_section('ammoItems', counter_data.get('ammoItems') or [],
                              show_inventory=True, removable=False)
        self._render_section('keyItems', counter_data.get('keyItems') or [],
                              removable=False)

        self._has_rendered_once = True

    def _flash_expiry_tick(self):
        # Rebuilding on every single incoming payload (up to ~5x/second)
        # caused visible flicker even when nothing had actually changed --
        # update_payload() now skips rebuilding unless the item data
        # itself changed. But a flash still needs to fade back to normal
        # after its 5-second window even if no new data arrives in the
        # meantime, so this runs independently, on its own much slower
        # 1-second timer, purely to catch expired flashes.
        if self._flash_state and self._last_payload:
            self._render_all_sections()
        self.after(1000, self._flash_expiry_tick)

    def _render_section(self, key, items, show_count=False, show_inventory=False,
                         removable=False, resettable=False):
        frame = self.section_frames[key]
        header_label = self.section_headers.get(key)
        for child in frame.winfo_children():
            child.destroy()

        if not items:
            # Hide the whole category (header included) rather than showing
            # an empty "(none)" section -- only appears once you've
            # actually received something in it.
            frame.pack_forget()
            if header_label is not None:
                header_label.pack_forget()
            return

        if header_label is not None and not header_label.winfo_ismapped():
            header_label.pack(anchor='w', padx=8, pady=(6, 2))
        if not frame.winfo_ismapped():
            frame.pack(fill='x', padx=8)

        for item in items:
            if not isinstance(item, dict):
                continue
            name = item.get('name', '?')
            display_name = item.get('displayName') or name
            row = tk.Frame(frame, bg=PANEL_BG)
            row.pack(fill='x', pady=1)

            text = display_name
            tracked_value = None
            if show_count:
                session_count = item.get('sessionCount', 0)
                lifetime_count = item.get('count', 0)
                text += '  %s [%s]' % (session_count, lifetime_count)
                tracked_value = lifetime_count
            elif show_inventory:
                inv_count = item.get('inventoryCount', 0)
                text += '  (Inv: %s)' % inv_count
                tracked_value = inv_count

            fg_color = TEXT
            if tracked_value is not None:
                fg_color = self._check_flash(key, name, tracked_value)

            label = tk.Label(row, text=text, bg=PANEL_BG, fg=fg_color, font=('Segoe UI', 9),
                              anchor='w', cursor='hand2' if (removable or resettable) else '')
            label.pack(side='left', fill='x', expand=True)

            if removable or resettable:
                label.bind('<Button-1>',
                            lambda e, n=name: self._open_item_menu(e, n, resettable, removable))

    def _check_flash(self, category, item_name, current_value):
        """Compares current_value against what was last seen for this item
        and starts a flash if it changed (green for an increase, red for a
        decrease) -- including the item's very first appearance on the
        list (also green), UNLESS this is the first render ever (right
        when the window opens), where everything already present would
        otherwise incorrectly flash as "just added". Returns the color
        this row should currently render as -- either an active flash
        color, or the normal text color once the flash has expired. State
        is looked up by (category, item_name) rather than tied to any
        widget, since rows are destroyed and rebuilt on every update."""
        state_key = (category, item_name)
        last_value = self._last_values.get(state_key)

        if last_value is None:
            if self._has_rendered_once:
                # Genuinely new to the list, not just "window just opened
                # and this is the first time we've looked" -- flash green.
                self._flash_state[state_key] = (HP_COLOR, time.time() + self.FLASH_DURATION)
        elif current_value != last_value:
            color = HP_COLOR if current_value > last_value else HP_LOW_COLOR
            self._flash_state[state_key] = (color, time.time() + self.FLASH_DURATION)

        self._last_values[state_key] = current_value

        flash = self._flash_state.get(state_key)
        if flash is not None:
            color, expires_at = flash
            if time.time() < expires_at:
                return color
            del self._flash_state[state_key]

        return TEXT

    def _open_item_menu(self, event, item_name, resettable, removable):
        menu = tk.Menu(self, tearoff=0, bg=PANEL_BG, fg=TEXT,
                        activebackground=ACCENT, activeforeground='#14151a')
        if resettable:
            menu.add_command(label='Reset Count',
                              command=lambda: self._send('counter resetitem %s' % item_name))
        if removable:
            menu.add_command(label='Remove',
                              command=lambda: self._send('counter remove %s' % item_name))
        menu.tk_popup(event.x_root, event.y_root)


class ViewerApp:
    def __init__(self, root, port):
        self.root = root
        self.port = port
        self.queue = queue.Queue()
        self.stop_event = threading.Event()
        self.map_window = None
        self.npc_window = None
        self.chat_window = None
        self.party_window = None
        self.counter_window = None

        root.title('MogWatch Viewer')
        root.geometry('440x680')
        root.configure(bg=BG)
        self._set_window_icon(root)
        self._setup_style()
        add_topmost_toggle(root)

        main_container = tk.Frame(root, bg=BG)
        main_container.pack(fill='both', expand=True)

        # Vertical nav column on the left -- stacked buttons don't get
        # squeezed off-screen the way a horizontal row does when the
        # window is narrowed, unlike the previous top-row layout.
        nav_column = tk.Frame(main_container, bg=BG)
        nav_column.pack(side='left', fill='y', padx=(10, 4), pady=10)
        for text, cmd in (
            ('Open Map', self.open_map),
            ('Chat Log', self.open_chat),
            ('Nearby NPCs', self.open_npcs),
            ('Party', self.open_party),
            ('Counter', self.open_counter),
        ):
            ttk.Button(nav_column, text=text, command=cmd).pack(fill='x', pady=(0, 4))

        # Main content area, to the right of the nav column.
        self.content_area = tk.Frame(main_container, bg=BG)
        self.content_area.pack(side='left', fill='both', expand=True, pady=10, padx=(0, 10))

        status_row = tk.Frame(self.content_area, bg=BG)
        status_row.pack(fill='x')
        self.status_var = tk.StringVar(value='Starting...')
        tk.Label(status_row, textvariable=self.status_var, bg=BG, fg=MUTED,
                 font=('Segoe UI', 9)).pack(side='left')

        self._build_player_panel()
        self._build_target_panel()

        self.thread = threading.Thread(
            target=udp_listener, args=(self.port, self.queue, self.stop_event),
            daemon=True)
        self.thread.start()

        self.command_server = CommandServer(self.port, self.queue)
        self.command_server.start()

        root.protocol('WM_DELETE_WINDOW', self.on_close)
        self.root.after(50, self.poll_queue)
        # A couple seconds after startup, not blocking initial UI setup --
        # this is a background convenience check, not something that
        # should hold up the app appearing.
        self.root.after(2000, self._start_update_check)

    def _start_update_check(self):
        def worker():
            is_newer, latest_version, release_url = check_for_updates()
            if is_newer:
                self.queue.put(('update_available', (latest_version, release_url)))
        threading.Thread(target=worker, daemon=True).start()

    def _show_update_notice(self, latest_version, release_url):
        notice = tk.Frame(self.content_area, bg=ACCENT)
        existing_children = self.content_area.winfo_children()
        if existing_children:
            notice.pack(fill='x', pady=(0, 8), before=existing_children[0])
        else:
            notice.pack(fill='x', pady=(0, 8))
        label = tk.Label(
            notice, bg=ACCENT, fg='#14151a', font=('Segoe UI', 9, 'bold'),
            text='MogWatch %s is available (you have %s) -- click to download' % (
                latest_version, MOGWATCH_VERSION),
            cursor='hand2')
        label.pack(fill='x', padx=8, pady=6)
        label.bind('<Button-1>', lambda e: webbrowser.open(release_url))

    def _set_window_icon(self, root):
        # mogwatch.ico either sits next to the plain script, or (once
        # packaged) is bundled INTO the .exe via --add-data and extracted
        # to a temp folder at runtime -- bundled_asset_dir() resolves
        # correctly for both. iconbitmap with a .ico is Windows-specific;
        # harmless no-op (caught) on any other platform or if missing.
        icon_path = os.path.join(bundled_asset_dir(), 'mogwatch.ico')
        try:
            root.iconbitmap(icon_path)
        except tk.TclError:
            pass

    def _setup_style(self):
        style = ttk.Style()
        try:
            style.theme_use('clam')
        except tk.TclError:
            pass
        style.configure('TFrame', background=BG)
        style.configure('Panel.TFrame', background=PANEL_BG)
        style.configure('TLabel', background=BG, foreground=TEXT)
        style.configure('Panel.TLabel', background=PANEL_BG, foreground=TEXT)
        style.configure('Muted.TLabel', background=PANEL_BG, foreground=MUTED)
        style.configure('TButton', background=PANEL_BG, foreground=TEXT)
        style.configure('Treeview', background=PANEL_BG, fieldbackground=PANEL_BG,
                         foreground=TEXT, borderwidth=0, rowheight=24, font=(CJK_FONT, 9))
        style.configure('Treeview.Heading', background=BG, foreground=MUTED,
                         borderwidth=0)
        style.map('Treeview', background=[('selected', '#33364a')])
        style.configure('TRadiobutton', background=BG, foreground=TEXT)

    def _panel(self, title):
        outer = tk.Frame(self.content_area, bg=BG)
        outer.pack(fill='x', pady=8)
        card = tk.Frame(outer, bg=PANEL_BG, highlightbackground=PANEL_BORDER,
                         highlightthickness=1)
        card.pack(fill='both', expand=True)
        ttk.Label(card, text=title, style='Muted.TLabel',
                  font=('Segoe UI', 9, 'bold')).pack(anchor='w', padx=10, pady=(8, 0))
        return card

    def _build_player_panel(self):
        card = self._panel('PLAYER')

        name_row = tk.Frame(card, bg=PANEL_BG)
        name_row.pack(fill='x', padx=10, pady=(4, 6))
        self.name_var = tk.StringVar(value='--')
        self.job_var = tk.StringVar(value='--')
        ttk.Label(name_row, textvariable=self.name_var, style='Panel.TLabel',
                  font=(CJK_FONT, 13, 'bold')).pack(side='left')
        ttk.Label(name_row, textvariable=self.job_var, style='Muted.TLabel',
                  font=('Segoe UI', 10)).pack(side='left', padx=(8, 0))

        bars = tk.Frame(card, bg=PANEL_BG)
        bars.pack(fill='x', padx=10, pady=(0, 8))
        self.hp_bar = StatBar(bars, HP_COLOR, dynamic_hp=True)
        self.hp_bar.pack(fill='x', pady=2)
        self.mp_bar = StatBar(bars, MP_COLOR)
        self.mp_bar.pack(fill='x', pady=2)
        self.tp_bar = StatBar(bars, TP_COLOR)
        self.tp_bar.pack(fill='x', pady=2)

        info_row = tk.Frame(card, bg=PANEL_BG)
        info_row.pack(fill='x', padx=10, pady=(0, 6))
        self.zone_var = tk.StringVar(value='--')
        ttk.Label(info_row, text='Zone:', style='Muted.TLabel').pack(side='left')
        ttk.Label(info_row, textvariable=self.zone_var, style='Panel.TLabel').pack(
            side='left', padx=(4, 0))

        ttk.Label(card, text='Buffs', style='Muted.TLabel').pack(
            anchor='w', padx=10, pady=(2, 0))
        self.buffs_var = tk.StringVar(value='(none)')
        tk.Label(card, textvariable=self.buffs_var, bg=PANEL_BG, fg=HP_COLOR,
                 font=('Segoe UI', 9), wraplength=400, justify='left').pack(
            anchor='w', padx=10, pady=(0, 4))

        ttk.Label(card, text='Debuffs', style='Muted.TLabel').pack(
            anchor='w', padx=10, pady=(0, 0))
        self.debuffs_var = tk.StringVar(value='(none)')
        tk.Label(card, textvariable=self.debuffs_var, bg=PANEL_BG, fg=HP_LOW_COLOR,
                 font=('Segoe UI', 9), wraplength=400, justify='left').pack(
            anchor='w', padx=10, pady=(0, 10))

    def _build_target_panel(self):
        card = self._panel('TARGET')
        self.target_card = card

        row = tk.Frame(card, bg=PANEL_BG)
        row.pack(fill='x', padx=10, pady=(4, 4))
        self.target_name_var = tk.StringVar(value='(no target)')
        ttk.Label(row, textvariable=self.target_name_var, style='Panel.TLabel',
                  font=(CJK_FONT, 11, 'bold')).pack(side='left')
        self.target_distance_var = tk.StringVar(value='')
        ttk.Label(row, textvariable=self.target_distance_var, style='Muted.TLabel').pack(
            side='right')

        self.target_hp_bar = StatBar(card, TARGET_COLOR)
        self.target_hp_bar.pack(fill='x', padx=10, pady=(0, 10))

    def open_map(self):
        if self.map_window is not None and self.map_window.winfo_exists():
            self.map_window.lift()
            return
        self.map_window = MapWindow(self.root)

    def open_npcs(self):
        if self.npc_window is not None and self.npc_window.winfo_exists():
            self.npc_window.lift()
            return
        self.npc_window = NpcWindow(self.root)

    def open_chat(self):
        if self.chat_window is not None and self.chat_window.winfo_exists():
            self.chat_window.lift()
            return
        self.chat_window = ChatWindow(self.root)

    def open_party(self):
        if self.party_window is not None and self.party_window.winfo_exists():
            self.party_window.lift()
            return
        self.party_window = PartyWindow(self.root)

    def open_counter(self):
        if self.counter_window is not None and self.counter_window.winfo_exists():
            self.counter_window.lift()
            return
        self.counter_window = CounterWindow(self.root, self.command_server)

    def poll_queue(self):
        try:
            while True:
                kind, value = self.queue.get_nowait()
                try:
                    if kind == 'status_text':
                        self.status_var.set(value)
                    elif kind == 'payload':
                        self.apply_payload(value)
                    elif kind == 'update_available':
                        self._show_update_notice(*value)
                except Exception:
                    # Whatever this was, don't let it kill the polling loop
                    # permanently -- that used to happen silently (the
                    # `self.root.after(...)` reschedule below would simply
                    # never run again), which looked exactly like "nothing
                    # is updating anymore" with no error visible anywhere.
                    import traceback
                    traceback.print_exc()
                    self.status_var.set(
                        'Error applying an update (see console) -- still listening.')
        except queue.Empty:
            pass
        self.root.after(50, self.poll_queue)

    def apply_payload(self, payload):
        # Counter is now merged directly into mogwatch.lua (a single
        # addon), so its state arrives as part of the SAME regular status
        # payload as player/target/party data -- routed to the
        # CounterWindow in addition to the normal processing below, not
        # instead of it.
        if 'counter' in payload:
            if self.counter_window is not None and self.counter_window.winfo_exists():
                self.counter_window.update_payload(payload.get('counter') or {})

        player = payload.get('player') or {}

        self.name_var.set(player.get('name', '--') or '--')

        job = player.get('job', '') or ''
        subjob = player.get('subjob', '') or ''
        level = player.get('level', '')
        job_text = job
        if subjob:
            job_text += '/' + subjob
        if level:
            job_text += '  Lv.%s' % level
        self.job_var.set(job_text or '--')

        self.hp_bar.set(player.get('currentHp', 0), player.get('maxHp', 0) or 1)
        self.mp_bar.set(player.get('currentMp', 0), player.get('maxMp', 0) or 1)
        tp = player.get('tp', 0) or 0
        # TP caps out at 3000 in FFXI (100% -> Skillchain/WS ready range).
        self.tp_bar.set(tp, 3000, label='TP %s' % tp)
        self.zone_var.set(player.get('location', '--') or '--')

        buffs = player.get('activeBuffs') or []
        def format_buff(b):
            label = b.get('name') or ('#%s' % b.get('id'))
            remaining = b.get('secondsRemaining')
            if isinstance(remaining, (int, float)):
                minutes, secs = divmod(int(remaining), 60)
                label = '%s (%d:%02d)' % (label, minutes, secs)
            return label
        buff_names = [format_buff(b) for b in buffs if isinstance(b, dict) and not b.get('harmful')]
        debuff_names = [format_buff(b) for b in buffs if isinstance(b, dict) and b.get('harmful')]
        self.buffs_var.set(', '.join(buff_names) if buff_names else '(none)')
        self.debuffs_var.set(', '.join(debuff_names) if debuff_names else '(none)')

        target = payload.get('target')
        if target:
            self.target_name_var.set(target.get('name', '?'))
            hpp = target.get('hpp', 0) or 0
            self.target_hp_bar.set_fraction(hpp / 100.0, label='%s%%' % hpp)
            distance = target.get('distance')
            self.target_distance_var.set(
                '%.1f\u2019' % distance if isinstance(distance, (int, float)) else '')
        else:
            self.target_name_var.set('(no target)')
            self.target_hp_bar.set_fraction(0, label='')
            self.target_distance_var.set('')

        if self.party_window is not None and self.party_window.winfo_exists():
            self.party_window.update_payload(payload)

        if self.map_window is not None and self.map_window.winfo_exists():
            self.map_window.update_payload(payload)

        if self.npc_window is not None and self.npc_window.winfo_exists():
            self.npc_window.update_payload(payload)

        if self.chat_window is not None and self.chat_window.winfo_exists():
            self.chat_window.update_payload(payload)

        self.status_var.set('Receiving status updates on UDP %d' % self.port)

    def on_close(self):
        self.stop_event.set()
        self.command_server.stop()
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description='MogWatch Windows Viewer')
    parser.add_argument('--port', type=int, default=8080,
                         help='UDP port to listen on (must match //mogwatch '
                              'port on the addon side). Default 8080.')
    args = parser.parse_args()

    root = tk.Tk()
    ViewerApp(root, args.port)
    root.mainloop()


if __name__ == '__main__':
    main()
