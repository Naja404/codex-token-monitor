from pathlib import Path

application = defines["app"]
files = [application]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
compression_level = 9
background = defines["background"]
icon = str(Path(application) / "Contents/Resources/AppIcon.icns")
icon_locations = {Path(application).name: (190, 240), "Applications": (530, 240)}
window_rect = ((100, 100), (720, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 96
text_size = 13
label_pos = "bottom"
