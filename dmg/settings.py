# dmgbuild settings for the styled crterm disk image.
# Invoked by Scripts/release.sh as:
#   dmgbuild -s dmg/settings.py -D app=<path/to/crterm.app> -D bg=<abs/background.tiff> \
#            "crterm" <output.dmg>
# Window/icon geometry matches dmg/background.html (a 760×472 canvas with the
# app icon and Applications alias flanking the centre arrow).
import os.path

app = defines["app"]
appname = os.path.basename(app)

# --- volume ---------------------------------------------------------------
format = "UDZO"                      # compressed, read-only
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [appname]

# --- window ---------------------------------------------------------------
background = defines["bg"]
window_rect = ((140, 140), (760, 472))   # ((screen x, y), (content w, h))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13

# Icon centres in content coordinates (0,0 = top-left, y down), flanking the
# arrow drawn at x=380. Vertically aligned with the arrow row.
icon_locations = {
    appname: (223, 200),
    "Applications": (537, 200),
}
