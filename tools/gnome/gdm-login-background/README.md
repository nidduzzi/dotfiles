# GDM login-screen background (Fedora, GNOME 50)

Stock GDM shows a flat `#222226`. `gdm_login_background.py` adds one image to the
`#lockDialogGroup` rule in `gnome-shell-theme.gresource` and leaves the rest of the
theme byte-for-byte identical. Rotating the picture only replaces the image file.

Tested on Fedora 44 (GNOME Shell 50.6, GDM 50.3). Needs `python3-gobject-base` and
`glib2-devel`.

## Install

```sh
sudo dnf install glib2-devel
/usr/bin/python3 gdm_login_background.py check ~/Pictures/pic.jpg   # builds, changes nothing
sudo install -m 755 gdm_login_background.py /usr/local/sbin/        # keep it root-owned
sudo /usr/local/sbin/gdm_login_background.py install ~/Pictures/pic.jpg
```

## Rotation (optional)

Edit the folder in `gdm-login-background.service` (the `YOUR_USER` placeholder), then:

```sh
sudo install -m 644 gdm-login-background.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gdm-login-background.timer
```

Use a folder of pictures meant for this. Never point it at a folder with private files
(for example screenshots): the image is readable by every local user.

## Undo

```sh
sudo systemctl disable --now gdm-login-background.timer
sudo /usr/local/sbin/gdm_login_background.py restore     # or: sudo dnf reinstall gnome-shell
```

A gnome-shell update puts the stock theme back; run `install` again.

## Tests

```sh
/usr/bin/python3 -m unittest test_gdm_login_background
```
