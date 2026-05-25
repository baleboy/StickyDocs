# dmgbuild settings for StickyDocs.
# Invoked by scripts/make-dmg.sh; the app path is passed via the
# APP_PATH environment variable.

import os

app_path = os.environ["APP_PATH"]
app_name = os.path.basename(app_path)

# Volume layout
format = "UDZO"
size = None  # auto-size

files = [app_path]
symlinks = {"Applications": "/Applications"}

icon_locations = {
    app_name: (150, 180),
    "Applications": (450, 180),
}

# Window
window_rect = ((200, 120), (600, 360))
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Icon view options
icon_size = 128
text_size = 12
