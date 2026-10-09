#!/usr/bin/env python3
"""Generate the Journal mosaic item style.

The mosaic is a single horizontal, virtualized row. Items are grouped into columns: the first item of a
column takes the column width in the row, the others pull themselves back under it with a negative left
margin (and give the space back on the right), so their desired width is 0 and they stack in the same
column. The shape of each item depends only on its index (ItemsControl.AlternationIndex), so the layout is
a repeating pattern and virtualization keeps working.

Run after editing PATTERN:  python3 scripts/gen_mosaic.py
"""
from pathlib import Path

UNIT = 200   # px, one cell (1080p reference)
GAP = 12     # px between cells
ROWS = 3

# Each sub-pattern is a list of columns: (column width in cells, [(row, row span), ...]).
PATTERN = [
    [(2, [(0, 2), (2, 1)]), (1, [(0, 2), (2, 1)]), (1, [(0, 1), (1, 1), (2, 1)]), (2, [(0, 1), (1, 2)])],
    [(1, [(0, 2), (2, 1)]), (2, [(0, 1), (1, 1), (2, 1)]), (1, [(0, 1), (1, 2)])],
    [(2, [(0, 1), (1, 2)]), (1, [(0, 1), (1, 1), (2, 1)]), (1, [(0, 2), (2, 1)]), (2, [(0, 2), (2, 1)])],
]

MAIN = Path(__file__).resolve().parent.parent / "themes" / "journal" / "Views" / "Main.xaml"
BEGIN = "<!-- BEGIN GENERATED MOSAIC (scripts/gen_mosaic.py) -->"
END = "<!-- END GENERATED MOSAIC -->"


def span(cells: int) -> int:
    return cells * UNIT + (cells - 1) * GAP


def kind(cols: int, rows: int) -> str:
    if cols == 2:
        return "Big" if rows == 2 else "Wide"
    return "Tall" if rows >= 2 else "Small"


def items():
    for sub in PATTERN:
        for cols, cells in sub:
            col_width = span(cols)
            for i, (row, rows) in enumerate(cells):
                width, height = col_width, span(rows)
                top = row * (UNIT + GAP)
                if i == 0:
                    margin = f"0,{top},{GAP},0"
                else:
                    back = col_width + GAP
                    margin = f"-{back},{top},{back - width},0"
                yield width, height, margin, kind(cols, rows)


def render() -> str:
    entries = list(items())
    out = [BEGIN]
    out.append(f'    <sys:Int32 x:Key="JournalMosaicPeriod">{len(entries)}</sys:Int32>')
    out.append(f'    <sys:Double x:Key="JournalMosaicHeight">{span(ROWS)}</sys:Double>')
    out.append('    <Style x:Key="JournalMosaicItemStyle" TargetType="ListBoxItem" BasedOn="{StaticResource JournalMosaicItemBase}">')
    out.append('        <Style.Triggers>')
    for index, (width, height, margin, k) in enumerate(entries):
        out.append(f'            <Trigger Property="ItemsControl.AlternationIndex" Value="{index}">')
        out.append(f'                <Setter Property="Width" Value="{width}" />')
        out.append(f'                <Setter Property="Height" Value="{height}" />')
        out.append(f'                <Setter Property="Margin" Value="{margin}" />')
        out.append(f'                <Setter Property="Tag" Value="{k}" />')
        out.append('            </Trigger>')
    out.append('        </Style.Triggers>')
    out.append('    </Style>')
    out.append(f'    {END}')
    return "\n".join(out)


def main():
    text = MAIN.read_text(encoding="utf-8")
    start, end = text.index(BEGIN), text.index(END) + len(END)
    MAIN.write_text(text[:start] + render() + text[end:], encoding="utf-8")
    print(f"Wrote {sum(len(c) for sub in PATTERN for _, c in sub)} mosaic positions into {MAIN}")


if __name__ == "__main__":
    main()
