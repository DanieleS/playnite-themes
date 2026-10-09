#!/usr/bin/env python3
"""Validate, package and release-manifest the Playnite Fullscreen themes in themes/.

  python3 scripts/build.py validate [--loc-source LocSource.xaml]
  python3 scripts/build.py build [theme ...] [--out dist]
  python3 scripts/build.py version <theme>
  python3 scripts/build.py installer-entry <theme> --url URL [--changelog TEXT ...]

No third-party dependencies: runs on any Python 3.9+.
"""
import argparse
import datetime
import re
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
THEMES = ROOT / "themes"

# Playnite only loads theme XAML files that mirror a file of the built-in Default theme (Themes.cs,
# "acceptableXamls"), plus Localization/*.xaml. Anything else in a theme is silently ignored.
ALLOWED_XAML = {
    "Constants.xaml", "Media.xaml",
    "CustomControls/FilterDbItemtSelection.xaml", "CustomControls/FilterEnumListSelection.xaml",
    "CustomControls/FilterPresetSelector.xaml", "CustomControls/FilterStringListSelection.xaml",
    "DefaultControls/Button.xaml", "DefaultControls/CheckBox.xaml", "DefaultControls/ComboBox.xaml",
    "DefaultControls/ProgressBar.xaml", "DefaultControls/ScrollViewer.xaml", "DefaultControls/Slider.xaml",
    "DefaultControls/TextBox.xaml", "DefaultControls/ToggleButton.xaml", "DefaultControls/ToolTip.xaml",
    "DerivedStyles/ButtonBottomMenu.xaml", "DerivedStyles/ButtonTopMenu.xaml",
    "DerivedStyles/ListGameItemStyle.xaml", "DerivedStyles/ListGameItemTemplate.xaml",
    "Images/ButtonPrompts/PlayStation/PlayStation.xaml", "Images/ButtonPrompts/Xbox/Xbox.xaml",
    "Views/CustomMenus.xaml", "Views/FiltersAdditional.xaml", "Views/FiltersView.xaml", "Views/GameDetails.xaml",
    "Views/GameMenu.xaml", "Views/GameStatus.xaml", "Views/HelpMenu.xaml", "Views/ItemSelection.xaml",
    "Views/Main.xaml", "Views/MainMenu.xaml", "Views/MessageBox.xaml", "Views/NotificationsMenu.xaml",
    "Views/SettingsMenus.xaml", "Views/TextInput.xaml",
}
FULLSCREEN_API = (2, 10, 0)
# Files that live in a theme folder but must not end up in the package.
PACKAGE_EXCLUDE = {"installer.yaml", "CHANGELOG.md", "README.md"}
XAML_NS = "{http://schemas.microsoft.com/winfx/2006/xaml}"


class Problem(Exception):
    pass


def theme_dirs(names=None):
    dirs = sorted(p for p in THEMES.iterdir() if (p / "theme.yaml").is_file())
    if names:
        wanted = set(names)
        unknown = wanted - {d.name for d in dirs}
        if unknown:
            raise Problem(f"Unknown theme(s): {', '.join(sorted(unknown))}")
        dirs = [d for d in dirs if d.name in wanted]
    return dirs


def read_manifest(theme: Path) -> dict:
    data = {}
    for line in (theme / "theme.yaml").read_text(encoding="utf-8-sig").splitlines():
        if ":" in line and not line.lstrip().startswith("#"):
            key, value = line.split(":", 1)
            data[key.strip()] = value.strip()
    return data


def parse_version(text: str):
    if not re.fullmatch(r"\d+\.\d+\.\d+", text or ""):
        raise Problem(f"version '{text}' is not MAJOR.MINOR.PATCH")
    return tuple(int(p) for p in text.split("."))


def loc_keys(path: Path) -> dict:
    root = ET.parse(path).getroot()
    return {el.get(XAML_NS + "Key"): (el.text or "") for el in root}


def used_loc_keys(theme: Path):
    keys = set()
    for xaml in theme.rglob("*.xaml"):
        if "Localization" in xaml.parts:
            continue
        keys |= set(re.findall(r"\bLOC[A-Za-z0-9_]+\b", xaml.read_text(encoding="utf-8")))
    return keys


def validate_theme(theme: Path, playnite_keys):
    errors = []
    m = read_manifest(theme)
    for field in ("Id", "Name", "Author", "Version", "Mode", "ThemeApiVersion"):
        if not m.get(field):
            errors.append(f"theme.yaml: missing {field}")
    if m.get("Mode") != "Fullscreen":
        errors.append("theme.yaml: Mode must be Fullscreen")
    try:
        parse_version(m.get("Version"))
    except Problem as e:
        errors.append(f"theme.yaml: {e}")
    try:
        api = parse_version(m.get("ThemeApiVersion"))
        if api[0] != FULLSCREEN_API[0] or api > FULLSCREEN_API:
            errors.append(f"theme.yaml: ThemeApiVersion {m.get('ThemeApiVersion')} not supported (max 2.10.0)")
    except Problem as e:
        errors.append(f"theme.yaml: ThemeApiVersion {e}")

    for xaml in sorted(theme.rglob("*.xaml")):
        rel = xaml.relative_to(theme).as_posix()
        try:
            ET.parse(xaml)
        except ET.ParseError as e:
            errors.append(f"{rel}: invalid XML ({e})")
            continue
        if not rel.startswith("Localization/") and rel not in ALLOWED_XAML:
            errors.append(f"{rel}: Playnite ignores this file (not a Default theme file name)")

    used = used_loc_keys(theme)
    custom = {k for k in used if k.startswith("LOCDS_")}
    loc_dir = theme / "Localization"
    if custom and not (loc_dir / "en_US.xaml").is_file():
        errors.append("Localization/en_US.xaml missing but custom strings are used")
    if loc_dir.is_dir():
        langs = {p.stem: loc_keys(p) for p in loc_dir.glob("*.xaml")}
        base = set(langs.get("en_US", {}))
        for key in sorted(custom - base):
            errors.append(f"string {key} is used but not defined in Localization/en_US.xaml")
        for key in sorted(base - custom):
            errors.append(f"string {key} is defined but never used")
        for lang, keys in sorted(langs.items()):
            for key in sorted(base - set(keys)):
                errors.append(f"Localization/{lang}.xaml: missing {key}")
            for key, value in keys.items():
                if not value.strip():
                    errors.append(f"Localization/{lang}.xaml: {key} is empty")
    if playnite_keys is not None:
        for key in sorted(used - custom - playnite_keys):
            errors.append(f"string {key} does not exist in Playnite's localization")
    return errors


def check_generated():
    """The Journal mosaic block must match scripts/gen_mosaic.py."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import gen_mosaic  # noqa: E402
    text = gen_mosaic.MAIN.read_text(encoding="utf-8")
    start = text.index(gen_mosaic.BEGIN)
    end = text.index(gen_mosaic.END) + len(gen_mosaic.END)
    if text[start:end] != gen_mosaic.render():
        return ["themes/journal/Views/Main.xaml: mosaic block is stale, run python3 scripts/gen_mosaic.py"]
    return []


def cmd_validate(args):
    playnite_keys = set(loc_keys(Path(args.loc_source))) if args.loc_source else None
    failed = False
    for theme in theme_dirs():
        errors = validate_theme(theme, playnite_keys)
        print(f"{'FAIL' if errors else 'ok  '} {theme.name}")
        for e in errors:
            print(f"     - {e}")
        failed |= bool(errors)
    for e in check_generated():
        print(f"FAIL {e}")
        failed = True
    if playnite_keys is None:
        print("note: Playnite string keys not checked (pass --loc-source)")
    return 1 if failed else 0


def package_name(theme: Path) -> str:
    m = read_manifest(theme)
    safe_id = re.sub(r"[^A-Za-z0-9_.-]", "_", m["Id"])
    return f"{safe_id}_{m['Version'].replace('.', '_')}.pthm"


def build_theme(theme: Path, out: Path) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    target = out / package_name(theme)
    # Fixed timestamps so the same sources always produce the same archive.
    stamp = (2020, 1, 1, 0, 0, 0)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(theme.rglob("*")):
            if path.is_dir():
                continue
            rel = path.relative_to(theme).as_posix()
            if rel in PACKAGE_EXCLUDE:
                continue
            info = zipfile.ZipInfo(rel, date_time=stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, path.read_bytes())
    return target


def cmd_build(args):
    for theme in theme_dirs(args.themes):
        errors = validate_theme(theme, None)
        if errors:
            raise Problem(f"{theme.name} is not valid, run 'validate' first:\n  " + "\n  ".join(errors))
        print(build_theme(theme, Path(args.out)))
    return 0


def cmd_version(args):
    print(read_manifest(theme_dirs([args.theme])[0])["Version"])
    return 0


def cmd_installer_entry(args):
    """Prepend a package to themes/<theme>/installer.yaml (Playnite add-on installer manifest)."""
    theme = theme_dirs([args.theme])[0]
    m = read_manifest(theme)
    path = theme / "installer.yaml"
    packages = path.read_text(encoding="utf-8").split("Packages:", 1)[1] if path.is_file() else ""
    if re.search(rf"^\s*-\s*Version:\s*{re.escape(m['Version'])}\s*$", packages, re.M):
        raise Problem(f"installer.yaml already lists version {m['Version']}")
    changelog = args.changelog or ["See the release notes on GitHub."]
    entry = [
        f"  - Version: {m['Version']}",
        f"    RequiredApiVersion: {m['ThemeApiVersion']}",
        f"    ReleaseDate: {datetime.date.today().isoformat()}",
        f"    PackageUrl: {args.url}",
        "    Changelog:",
        *[f"      - {line}" for line in changelog],
    ]
    text = f"AddonId: {m['Id']}\nPackages:\n" + "\n".join(entry) + "\n" + packages.lstrip("\n")
    path.write_text(text, encoding="utf-8")
    print(f"Updated {path.relative_to(ROOT)}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("validate")
    p.add_argument("--loc-source", help="Playnite's Localization/LocSource.xaml, to check built-in string keys")
    p.set_defaults(fn=cmd_validate)
    p = sub.add_parser("build")
    p.add_argument("themes", nargs="*")
    p.add_argument("--out", default=str(ROOT / "dist"))
    p.set_defaults(fn=cmd_build)
    p = sub.add_parser("version")
    p.add_argument("theme")
    p.set_defaults(fn=cmd_version)
    p = sub.add_parser("installer-entry")
    p.add_argument("theme")
    p.add_argument("--url", required=True)
    p.add_argument("--changelog", action="append")
    p.set_defaults(fn=cmd_installer_entry)
    args = parser.parse_args()
    try:
        return args.fn(args)
    except Problem as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
