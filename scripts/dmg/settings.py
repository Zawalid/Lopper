# dmgbuild settings for the Lopper installer window. Run through scripts/make-dmg.sh.
# The window is 660x420 points; icon positions are the icon centers and line up with scripts/dmg/background.html.
import os

root = os.environ["LOPPER_ROOT"]
app = os.path.join(root, "build/Lopper.app")

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = os.path.join(root, "scripts/dmg/background.tiff")

# 448 high: the Finder title bar (22 to 32 points by macOS version) sits on top of the 420 point artwork.
window_rect = ((240, 160), (660, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    "Lopper.app": (170, 205),
    "Applications": (490, 205),
}
