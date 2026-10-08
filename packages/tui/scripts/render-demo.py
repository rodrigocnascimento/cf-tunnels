#!/usr/bin/env python3
"""Render captured Ink frames as a PNG and a looping GIF (requires Pillow)."""

import argparse
import json
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("frames", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--font", type=Path, default=Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"))
args = parser.parse_args()
data = json.loads(args.frames.read_text())
if data.get("schema_version") != 1 or data.get("sample_data") is not True or not data.get("frames"):
    parser.error("expected captured sample-data frames with schema_version 1")

font = ImageFont.truetype(str(args.font), 16)
cell_width = round(font.getlength("M"))
line_height = 22
padding = 28
top = 100
ansi = re.compile(r"\x1b\[([0-?]*)([ -/]*)([@-~])")
palette = ["#101827", "#ef8793", "#85d29b", "#e6c36d", "#89aef0", "#c4a0eb", "#7ed1db", "#e0e6ef"]
background = "#101827"
foreground = "#e0e6ef"
rows = max(len(ansi.sub("", frame["terminal"]).splitlines()) for frame in data["frames"])
width = data["columns"] * cell_width + padding * 2
height = top + rows * line_height + padding


def render(frame):
    image = Image.new("RGB", (width, height), background)
    draw = ImageDraw.Draw(image)
    draw.text((padding, 18), f"cftunnel tui · v{data['application_version']} · SAMPLE DATA", font=font, fill="#7ed1db")
    draw.text((padding, 48), frame["title"], font=font, fill=foreground)
    draw.line((padding, 80, width - padding, 80), fill="#334155")
    fg, bg, dim, inverse = foreground, background, False, False
    x, y = padding, top
    index = 0
    text = frame["terminal"]
    while index < len(text):
        escape = ansi.match(text, index)
        if escape:
            if escape[3] == "m":
                for code in [int(value or 0) for value in escape[1].split(";")]:
                    if code == 0:
                        fg, bg, dim, inverse = foreground, background, False, False
                    elif code == 2:
                        dim = True
                    elif code == 22:
                        dim = False
                    elif code == 7:
                        inverse = True
                    elif code == 27:
                        inverse = False
                    elif 30 <= code <= 37:
                        fg = palette[code - 30]
                    elif code == 39:
                        fg = foreground
                    elif 40 <= code <= 47:
                        bg = palette[code - 40]
                    elif code == 49:
                        bg = background
                    elif code == 90:
                        fg = "#94a3b8"
                    elif 91 <= code <= 97:
                        fg = palette[code - 90]
            index = escape.end()
            continue
        char = text[index]
        index += 1
        if char == "\n":
            x, y = padding, y + line_height
            continue
        if char == "\r":
            x = padding
            continue
        color, fill = (bg, fg) if inverse else (fg, bg)
        if dim and not inverse:
            channels = [int(color[i:i + 2], 16) for i in (1, 3, 5)]
            base = [int(background[i:i + 2], 16) for i in (1, 3, 5)]
            color = tuple(round(a * 0.7 + b * 0.3) for a, b in zip(channels, base))
        if fill != background:
            draw.rectangle((x, y, x + cell_width, y + line_height), fill=fill)
        draw.text((x, y), char, font=font, fill=color)
        x += cell_width
    return image


images = [render(frame) for frame in data["frames"]]
args.output.mkdir(parents=True, exist_ok=True)
first_rows = len(ansi.sub("", data["frames"][0]["terminal"]).rstrip().splitlines())
images[0].crop((0, 0, width, top + first_rows * line_height + padding)).save(args.output / "cftunnel-tui.png", optimize=True)
images[0].save(args.output / "cftunnel-demo.gif", save_all=True, append_images=images[1:], duration=[frame["duration_ms"] for frame in data["frames"]], loop=0, optimize=True)
print(f"Rendered {len(images)} frames ({width}×{height}) to {args.output}")
