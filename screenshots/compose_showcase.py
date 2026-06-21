from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
RENDERED = ROOT / "rendered"

CANVAS_SIZE = (2400, 1650)
WINDOW_SIZE = (2100, 1390)
WINDOW_ORIGIN = (150, 120)
TITLEBAR_HEIGHT = 58
TOOLBAR_HEIGHT = 82
CHROME_HEIGHT = TITLEBAR_HEIGHT + TOOLBAR_HEIGHT
RADIUS = 24

FONT = "/System/Library/Fonts/SFNS.ttf"
FONT_BOLD = "/System/Library/Fonts/SFNS.ttf"


SHOTS = [
    {
        "source": RENDERED / "index.html.png",
        "output": ROOT / "quartz-home.png",
        "url": "http://quartz.localhost/",
        "title": "Quartz",
        "accent": (37, 95, 211),
        "warm": (216, 155, 37),
    },
    {
        "source": RENDERED / "field-notes.html.png",
        "output": ROOT / "quartz-field-notes.png",
        "url": "http://quartz.localhost/field-notes",
        "title": "Quartz Field Notes",
        "accent": (24, 139, 151),
        "warm": (202, 135, 37),
    },
    {
        "source": RENDERED / "extensions.html.png",
        "output": ROOT / "quartz-extensions.png",
        "url": "http://quartz.localhost/extensions",
        "title": "Quartz Extensions",
        "accent": (62, 150, 95),
        "warm": (217, 95, 118),
    },
]


def font(size):
    return ImageFont.truetype(FONT, size)


def bold(size):
    return ImageFont.truetype(FONT_BOLD, size)


def make_background(accent, warm):
    width, height = CANVAS_SIZE
    image = Image.new("RGB", CANVAS_SIZE)
    pixels = image.load()

    for y in range(height):
        vertical = y / max(height - 1, 1)
        for x in range(width):
            horizontal = x / max(width - 1, 1)
            mix = 0.58 * vertical + 0.42 * horizontal
            base = (
                round(247 - 13 * mix),
                round(250 - 11 * mix),
                round(253 - 8 * mix),
            )
            cool = radial(x, y, width * 0.17, height * 0.22, width * 0.62)
            heat = radial(x, y, width * 0.84, height * 0.82, width * 0.58)
            r = blend_channel(base[0], accent[0], cool * 0.13)
            g = blend_channel(base[1], accent[1], cool * 0.13)
            b = blend_channel(base[2], accent[2], cool * 0.13)
            r = blend_channel(r, warm[0], heat * 0.10)
            g = blend_channel(g, warm[1], heat * 0.10)
            b = blend_channel(b, warm[2], heat * 0.10)
            pixels[x, y] = (r, g, b)

    return image.convert("RGBA")


def radial(x, y, cx, cy, radius):
    dx = x - cx
    dy = y - cy
    distance = (dx * dx + dy * dy) ** 0.5
    return max(0, 1 - distance / radius) ** 2


def blend_channel(base, top, alpha):
    return round(base * (1 - alpha) + top * alpha)


def draw_window_shadow(canvas, box):
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    x0, y0, x1, y1 = box
    draw.rounded_rectangle((x0, y0, x1, y1), radius=RADIUS, fill=(19, 28, 43, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    canvas.alpha_composite(shadow)

    close_shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    close_draw = ImageDraw.Draw(close_shadow)
    close_draw.rounded_rectangle((x0, y0 + 16, x1, y1 + 22), radius=RADIUS, fill=(19, 28, 43, 32))
    close_shadow = close_shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(close_shadow)


def draw_icon_button(draw, box, kind):
    draw.rounded_rectangle(box, radius=10, fill=(250, 252, 255), outline=(219, 225, 235), width=1)
    x0, y0, x1, y1 = box
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    blue = (32, 103, 230)
    gray = (174, 184, 198)

    if kind == "back":
        draw.line((cx + 5, cy - 10, cx - 5, cy, cx + 5, cy + 10), fill=gray, width=3, joint="curve")
    elif kind == "forward":
        draw.line((cx - 5, cy - 10, cx + 5, cy, cx - 5, cy + 10), fill=gray, width=3, joint="curve")
    elif kind == "reload":
        draw.arc((cx - 11, cy - 11, cx + 11, cy + 11), 38, 320, fill=blue, width=3)
        draw.polygon([(cx + 12, cy - 8), (cx + 12, cy + 2), (cx + 3, cy - 2)], fill=blue)
    elif kind == "home":
        draw.line((cx - 11, cy + 1, cx, cy - 10, cx + 11, cy + 1), fill=blue, width=3)
        draw.rounded_rectangle((cx - 8, cy, cx + 8, cy + 11), radius=2, outline=blue, width=3)
    elif kind == "extension":
        draw.rounded_rectangle((cx - 9, cy - 8, cx + 8, cy + 9), radius=4, outline=blue, width=3)
        draw.ellipse((cx + 3, cy - 15, cx + 13, cy - 5), outline=blue, width=3)
        draw.line((cx - 14, cy, cx - 9, cy), fill=blue, width=3)


def prepare_content(path, size):
    source = Image.open(path).convert("RGB")
    content_width, content_height = size
    scale = content_width / source.width
    resized = source.resize((content_width, round(source.height * scale)), Image.Resampling.LANCZOS)
    return resized.crop((0, 0, content_width, content_height)).convert("RGBA")


def draw_window(shot):
    canvas = make_background(shot["accent"], shot["warm"])
    window_x, window_y = WINDOW_ORIGIN
    window_w, window_h = WINDOW_SIZE
    window_box = (window_x, window_y, window_x + window_w, window_y + window_h)

    draw_window_shadow(canvas, window_box)

    window = Image.new("RGBA", WINDOW_SIZE, (255, 255, 255, 0))
    mask = Image.new("L", WINDOW_SIZE, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, window_w, window_h), radius=RADIUS, fill=255)

    draw = ImageDraw.Draw(window)
    draw.rounded_rectangle((0, 0, window_w, window_h), radius=RADIUS, fill=(248, 250, 252))
    draw.rectangle((0, TITLEBAR_HEIGHT, window_w, window_h), fill=(255, 255, 255))

    draw_titlebar(draw, shot["title"], window_w)
    draw_toolbar(draw, shot["url"], window_w)

    content_size = (window_w, window_h - CHROME_HEIGHT)
    content = prepare_content(shot["source"], content_size)
    window.alpha_composite(content, (0, CHROME_HEIGHT))

    border = Image.new("RGBA", WINDOW_SIZE, (0, 0, 0, 0))
    border_draw = ImageDraw.Draw(border)
    border_draw.rounded_rectangle(
        (0, 0, window_w - 1, window_h - 1),
        radius=RADIUS,
        outline=(198, 207, 219, 210),
        width=2,
    )
    window.alpha_composite(border)

    canvas.alpha_composite(window, WINDOW_ORIGIN)
    shot["output"].parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(shot["output"], quality=96)


def draw_titlebar(draw, title, width):
    draw.rectangle((0, 0, width, TITLEBAR_HEIGHT), fill=(246, 248, 251))
    dot_y = 29
    for index, color in enumerate(((255, 95, 87), (255, 189, 46), (40, 200, 64))):
        x = 34 + index * 28
        draw.ellipse((x - 8, dot_y - 8, x + 8, dot_y + 8), fill=color, outline=(0, 0, 0, 18), width=1)

    draw.text((118, 18), title, fill=(89, 99, 116), font=bold(22))
    draw.line((0, TITLEBAR_HEIGHT - 1, width, TITLEBAR_HEIGHT - 1), fill=(218, 224, 232), width=1)


def draw_toolbar(draw, url, width):
    top = TITLEBAR_HEIGHT
    draw.rectangle((0, top, width, top + TOOLBAR_HEIGHT), fill=(250, 251, 253))
    draw.line((0, top + TOOLBAR_HEIGHT - 1, width, top + TOOLBAR_HEIGHT - 1), fill=(218, 224, 232), width=1)

    x = 26
    y = top + 19
    button_w = 48
    button_h = 44
    gap = 14
    for kind in ("back", "forward", "reload", "home", "extension"):
        draw_icon_button(draw, (x, y, x + button_w, y + button_h), kind)
        x += button_w + gap

    address_x = x + 8
    go_w = 70
    right_pad = 26
    address_w = width - address_x - go_w - right_pad - 14
    address_box = (address_x, y, address_x + address_w, y + button_h)
    draw.rounded_rectangle(address_box, radius=10, fill=(255, 255, 255), outline=(207, 216, 228), width=1)
    draw.text((address_x + 18, y + 11), url, fill=(29, 38, 55), font=font(20))

    go_x = address_x + address_w + 14
    draw.rounded_rectangle((go_x, y, go_x + go_w, y + button_h), radius=10, fill=(239, 242, 247), outline=(207, 216, 228), width=1)
    draw.text((go_x + 22, y + 11), "Go", fill=(32, 40, 54), font=bold(20))


def main():
    for shot in SHOTS:
        draw_window(shot)
        print(f"Wrote {shot['output']}")


if __name__ == "__main__":
    main()
