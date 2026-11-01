#!/usr/bin/python3
"""Set a custom GDM login-screen background (Fedora, GNOME 50), static or rotating.

    gdm_login_background.py check IMAGE            build and verify only; changes nothing
    sudo gdm_login_background.py install IMAGE     install, all-or-nothing
    sudo gdm_login_background.py set-image IMAGE   swap only the picture
    sudo gdm_login_background.py rotate FOLDER next|newest
                                                   next picture in FOLDER / newest picture
    sudo gdm_login_background.py restore           put the original theme back
    gdm_login_background.py status

Needs the system python (/usr/bin/python3) with GNOME bindings (python3-gobject-base)
and `glib-compile-resources` (Fedora: glib2-devel). Tested on Fedora 44 (GNOME Shell
50.6, GDM 50.3) in a VM, including failures injected at every step.

The login background is the #lockDialogGroup rule in gnome-shell-theme.gresource. This
adds one image to that rule and leaves the rest of the theme byte-for-byte identical.

Safety, in short:
  * Types only hold valid values: an Image is a real JPEG/PNG (symlinks refused), a
    StockTheme is the untouched theme, a BuiltTheme differs from stock by exactly our
    CSS, and the system is either Stock or Customized. Anything else is refused.
  * install is a transaction. Each file is replaced atomically and remembers how to
    undo itself; the theme swap comes last, and any error rolls everything back.
  * A gnome-shell update puts the stock theme back; run install again.
    `sudo dnf reinstall gnome-shell` also resets everything to stock.

Setup:
    sudo install -m 755 gdm_login_background.py /usr/local/sbin/   # root-owned!
    sudo /usr/bin/python3 /usr/local/sbin/gdm_login_background.py install ~/pic.jpg

Rotation or "follow my wallpaper" (edit the folder and mode in the .service first):
    sudo install -m 644 gdm-login-background.{service,timer} /etc/systemd/system/
    sudo systemctl daemon-reload && sudo systemctl enable --now gdm-login-background.timer
  mode `next` cycles through FOLDER; `newest` follows the most recent file in it, e.g.
  ~/.config/fresh-web-wallpaper/cache. The picture is read when the login screen starts.
"""
from __future__ import annotations

import fcntl
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator

from gi.repository import Gio, GLib

PREFIX = "/org/gnome/shell/theme"
EDITED = ("gnome-shell-dark.css", "gnome-shell-light.css")  # high-contrast is left alone
STOCK_RULE = re.compile(r"(#lockDialogGroup \{\n  background-color: #[0-9a-f]{6};)( \}\n)")
SAFE_PATH = re.compile(r"/[A-Za-z0-9_./-]+")
SAFE_NAME = re.compile(r"[A-Za-z0-9_.-]+")
IMAGE_MAGIC = (b"\xff\xd8\xff", b"\x89PNG\r\n\x1a\n")  # JPEG, PNG
MAX_IMAGE_BYTES = 32 * 1024 * 1024


class Refused(Exception):
    """A precondition failed. Nothing was changed."""


class NotStock(Refused):
    """The theme is not the unmodified stock theme."""


# --------------------------------------------------------------------------
# Values that cannot be invalid
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Layout:
    """Where everything lives. Paths are restricted so they can't break the CSS."""
    theme: Path = Path("/usr/share/gnome-shell/gnome-shell-theme.gresource")
    image_dir: Path = Path("/usr/share/backgrounds/gdm-login")
    state_dir: Path = Path("/var/lib/gdm-login-background")

    def __post_init__(self) -> None:
        for path in (self.theme, self.image_dir, self.state_dir):
            if not SAFE_PATH.fullmatch(str(path)):
                raise Refused(f"unsafe path: {path}")

    @property
    def image(self) -> Path:
        return self.image_dir / "login-background"

    @property
    def backup(self) -> Path:
        return self.state_dir / "original.gresource"

    @property
    def css(self) -> str:
        """The text we add to the stock rule."""
        return (f' background-image: url("file://{self.image}");'
                " background-size: cover; background-position: center;")


@dataclass(frozen=True)
class Image:
    """A JPEG or PNG of sane size. Nothing else can be constructed."""
    data: bytes

    def __post_init__(self) -> None:
        if not self.data.startswith(IMAGE_MAGIC):
            raise Refused("the image must be a JPEG or PNG file")
        if len(self.data) > MAX_IMAGE_BYTES:
            raise Refused("the image is larger than 32 MB")

    @staticmethod
    def read(path: str | Path) -> Image:
        """Read an image file. Symlinks and non-regular files are refused."""
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError as error:
            raise Refused(f"cannot read {path}: {error.strerror}") from error
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise Refused(f"not a regular file: {path}")
            return Image(f.read(MAX_IMAGE_BYTES + 1))


def read_files(gresource: bytes) -> dict[str, bytes]:
    """Every file inside a .gresource, by name."""
    try:
        resource = Gio.Resource.new_from_data(GLib.Bytes.new(gresource))
        names = resource.enumerate_children(PREFIX, Gio.ResourceLookupFlags.NONE)
        files = {n: bytes(resource.lookup_data(f"{PREFIX}/{n}", Gio.ResourceLookupFlags.NONE).get_data())
                 for n in names}
    except GLib.Error as error:
        raise Refused(f"not a valid theme resource: {error.message}") from error
    if not all(SAFE_NAME.fullmatch(n) for n in files):
        raise Refused("theme contains an unexpected file name")
    return files


@dataclass(frozen=True)
class StockTheme:
    """The unmodified theme: each file we edit has its stock rule exactly once."""
    gresource: bytes
    files: dict[str, bytes] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        files = read_files(self.gresource)
        for name in EDITED:
            if name not in files or len(STOCK_RULE.findall(files[name].decode())) != 1:
                raise NotStock(f"{name} is not the stock theme")
        object.__setattr__(self, "files", files)


def compile_gresource(files: dict[str, bytes]) -> bytes:
    tool = shutil.which("glib-compile-resources")
    if tool is None:
        raise Refused("glib-compile-resources not found (install glib2-devel)")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for name, data in files.items():
            (work / name).write_bytes(data)
        entries = "".join(f"<file>{name}</file>" for name in sorted(files))
        manifest = work / "theme.xml"
        manifest.write_text(f'<gresources><gresource prefix="{PREFIX}">{entries}</gresource></gresources>')
        subprocess.run([tool, f"--sourcedir={work}", f"--target={work / 'out'}", str(manifest)], check=True)
        return (work / "out").read_bytes()


@dataclass(frozen=True)
class BuiltTheme:
    """A theme that is the stock theme plus our CSS, and nothing else."""
    stock: StockTheme
    layout: Layout
    gresource: bytes

    def __post_init__(self) -> None:
        files = read_files(self.gresource)
        if files.keys() != self.stock.files.keys():
            raise Refused("the theme has a different set of files than stock")
        for name, data in files.items():
            if name in EDITED:
                text = data.decode()
                if self.layout.css not in text:
                    raise Refused(f"{name} does not contain the background rule")
                data = text.replace(self.layout.css, "").encode()
            if data != self.stock.files[name]:
                raise Refused(f"unexpected change in {name}")


def build(stock: StockTheme, layout: Layout) -> BuiltTheme:
    files = dict(stock.files)
    for name in EDITED:
        files[name] = STOCK_RULE.sub(lambda m: m.group(1) + layout.css + m.group(2),
                                     files[name].decode()).encode()
    return BuiltTheme(stock, layout, compile_gresource(files))


@dataclass(frozen=True)
class Stock:
    """The system theme is untouched stock."""
    theme: StockTheme


@dataclass(frozen=True)
class Customized:
    """The system theme is ours; `original` is the saved stock theme it came from."""
    original: StockTheme


def read_state(layout: Layout) -> Stock | Customized:
    """The system is Stock or Customized. Anything else is refused, never overwritten."""
    current = layout.theme.read_bytes()
    try:
        return Stock(StockTheme(current))
    except NotStock:
        pass
    if not layout.backup.is_file():
        raise Refused("the system theme is modified by something else (no saved original). "
                      "Reset it with: sudo dnf reinstall gnome-shell")
    original = StockTheme(layout.backup.read_bytes())
    try:
        BuiltTheme(original, layout, current)
    except Refused as error:
        raise Refused("the system theme is modified by something else. "
                      "Reset it with: sudo dnf reinstall gnome-shell") from error
    return Customized(original)


# --------------------------------------------------------------------------
# Transaction: every change knows how to undo itself
# --------------------------------------------------------------------------

class Transaction:
    """Collects undo actions and runs them, newest first, on rollback."""

    def __init__(self) -> None:
        self._undo: list[Callable[[], None]] = []

    def record(self, undo: Callable[[], None]) -> None:
        self._undo.append(undo)

    def rollback(self) -> None:
        for undo in reversed(self._undo):
            try:
                undo()
            except Exception as error:  # keep undoing the rest
                print(f"rollback step failed: {error}", file=sys.stderr)
        self._undo.clear()
        print("rolled back: nothing was changed", file=sys.stderr)


def copy_selinux_label(source: Path, target: str) -> None:
    try:
        label = os.getxattr(source, "security.selinux")
    except OSError:
        return  # SELinux is off or unsupported here
    os.setxattr(target, "security.selinux", label)


def atomic_write(path: Path, data: bytes, like: Path) -> None:
    """Write to a temp file in the same directory, then rename it into place.
    Readers see the old file or the new one, never a half-written one."""
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        copy_selinux_label(like, tmp)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    dir_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def replace_file(tx: Transaction, path: Path, data: bytes, like: Path) -> None:
    """Replace a file atomically and record how to put it back."""
    previous = path.read_bytes() if path.exists() else None
    atomic_write(path, data, like if like.exists() else path.parent)
    if previous is None:
        tx.record(lambda: path.unlink(missing_ok=True))
    else:
        tx.record(lambda: atomic_write(path, previous, path.parent))


@contextmanager
def locked(layout: Layout) -> Iterator[None]:
    layout.state_dir.mkdir(mode=0o755, parents=True, exist_ok=True)
    with open(layout.state_dir / "lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused("another run is in progress") from None
        yield


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def stock_of(state: Stock | Customized) -> StockTheme:
    return state.theme if isinstance(state, Stock) else state.original


def verify_installed(layout: Layout, built: BuiltTheme) -> None:
    state = read_state(layout)
    if not isinstance(state, Customized) or layout.theme.read_bytes() != built.gresource:
        raise Refused("the installed theme did not verify")


def install(layout: Layout, image: Image) -> None:
    with locked(layout):
        state = read_state(layout)
        built = build(stock_of(state), layout)  # verified before anything is touched
        tx = Transaction()
        try:
            if isinstance(state, Stock):  # first install, or after a gnome-shell update
                replace_file(tx, layout.backup, state.theme.gresource, layout.theme)
            replace_file(tx, layout.image, image.data, layout.image_dir)
            replace_file(tx, layout.theme, built.gresource, layout.theme)  # the commit
            verify_installed(layout, built)
        except BaseException:
            tx.rollback()
            raise


def swap_image(layout: Layout, image: Image) -> None:
    """Replace only the picture (the theme is untouched). Caller holds the lock."""
    if not isinstance(read_state(layout), Customized):
        raise Refused("not installed yet; run install first")
    if layout.image.exists() and layout.image.read_bytes() == image.data:
        return  # already showing this picture
    tx = Transaction()
    try:
        replace_file(tx, layout.image, image.data, layout.image_dir)
    except BaseException:
        tx.rollback()
        raise


def set_image(layout: Layout, image: Image) -> None:
    with locked(layout):
        swap_image(layout, image)


def candidates(folder: Path, mode: str, last: str | None) -> list[str]:
    """File names in the order we should try them."""
    names = sorted(p.name for p in folder.iterdir())
    if mode == "newest":
        return sorted(names, key=lambda n: (folder / n).lstat().st_mtime, reverse=True)
    after = [n for n in names if last is not None and n > last]
    return after + [n for n in names if n not in after]  # wraps around


def rotate(layout: Layout, folder: Path, mode: str) -> str:
    """Show the next image in `folder` ("next") or its newest image ("newest").
    Files that are not valid images are skipped; if none is usable nothing changes."""
    if mode not in ("next", "newest"):
        raise Refused("mode must be 'next' or 'newest'")
    with locked(layout):
        marker = layout.state_dir / "last-rotated"
        last = marker.read_text() if marker.exists() else None
        for name in candidates(folder, mode, last):
            try:
                image = Image.read(folder / name)
            except Refused:
                continue
            swap_image(layout, image)
            atomic_write(marker, name.encode(), layout.state_dir)
            return name
        raise Refused(f"no usable JPEG/PNG images in {folder}")


def restore(layout: Layout) -> None:
    with locked(layout):
        state = read_state(layout)
        if isinstance(state, Stock):
            print("already stock; nothing to do")
            return
        tx = Transaction()
        try:
            replace_file(tx, layout.theme, state.original.gresource, layout.theme)
            if read_state(layout) != Stock(state.original):
                raise Refused("the restored theme did not verify")
        except BaseException:
            tx.rollback()
            raise


def check(layout: Layout, image: Image) -> None:
    state = read_state(layout)
    build(stock_of(state), layout)
    print(f"ok: system is {type(state).__name__}; image {len(image.data)} bytes; "
          f"build verified (only {', '.join(EDITED)} change)")


def status(layout: Layout) -> None:
    state = read_state(layout)
    print(f"system theme: {type(state).__name__}")
    print(f"image: {'present' if layout.image.exists() else 'missing'} ({layout.image})")


def main(argv: list[str]) -> int:
    commands = {"check": check, "install": install, "set-image": set_image}
    try:
        if len(argv) == 3 and argv[1] in commands:
            if argv[1] != "check" and os.geteuid() != 0:
                raise Refused("run with sudo")
            commands[argv[1]](Layout(), Image.read(argv[2]))
        elif len(argv) == 4 and argv[1] == "rotate":
            if os.geteuid() != 0:
                raise Refused("run with sudo")
            print(f"showing {rotate(Layout(), Path(argv[2]), argv[3])}")
        elif len(argv) == 2 and argv[1] == "restore":
            if os.geteuid() != 0:
                raise Refused("run with sudo")
            restore(Layout())
        elif len(argv) == 2 and argv[1] == "status":
            status(Layout())
        else:
            print(__doc__)
            return 2
    except Refused as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
