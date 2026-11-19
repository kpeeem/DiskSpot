import json
import os
import random
import sys
import time
import uuid
from pathlib import Path

MB = 1 << 20
DAY = 86_400
CHUNK = bytes(4 * MB)

home = Path(sys.argv[1])
lang = sys.argv[2] if len(sys.argv) > 2 else "en"
rng = random.Random(7)
now = time.time()
sizes: dict[str, int] = {}


def write(relative: str, size: int, age: float = 3) -> None:
    path = home / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as file:
        left = max(size, 1)
        while left > 0:
            file.write(CHUNK[: min(left, len(CHUNK))])
            left -= len(CHUNK)
    stamp = now - age * DAY
    os.utime(path, (stamp, stamp))
    parts = Path(relative).parts
    for depth in range(1, len(parts) + 1):
        key = "/".join(parts[:depth])
        sizes[key] = sizes.get(key, 0) + size


def many(folder: str, count: int, low: float, high: float, names, age: float = 3) -> None:
    for index in range(count):
        write(f"{folder}/{names(index)}", int(rng.uniform(low, high) * MB), age)


many("Developer/weather-app/src", 40, 0.005, 0.03, lambda i: f"view{i}.tsx")
write("Developer/weather-app/package.json", 2_000)
write("Developer/weather-app/dist/bundle.js", 3 * MB)
for package in range(160):
    many(f"Developer/weather-app/node_modules/pkg-{package}", rng.randint(2, 6), 0.02, 0.9, lambda i: f"index{i}.js")
write("Developer/swift-cli/Package.swift", 1_000)
many("Developer/swift-cli/Sources/CLI", 15, 0.004, 0.02, lambda i: f"Command{i}.swift")
many("Developer/swift-cli/.build/arm64-apple-macosx/debug", 110, 0.5, 4, lambda i: f"Module{i}.o")
many("Developer/ml-notebooks", 5, 0.5, 2, lambda i: f"experiment-{i}.ipynb")
many("Developer/ml-notebooks/data", 5, 70, 150, lambda i: f"events-2025-{i + 1:02}.parquet")
write("Developer/ml-notebooks/.venv/pyvenv.cfg", 200)
for package in range(70):
    many(f"Developer/ml-notebooks/.venv/lib/python3.12/site-packages/lib{package}", 3, 0.2, 6, lambda i: f"core{i}.so")
write("Developer/rust-tool/Cargo.toml", 600)
many("Developer/rust-tool/src", 12, 0.003, 0.02, lambda i: f"mod{i}.rs")
many("Developer/rust-tool/target/debug/deps", 90, 0.5, 4, lambda i: f"libdep{i}.rlib")

write("Downloads/dataset-2025.zip", 310 * MB, 240)
write("Downloads/Blender-4.3-arm64.dmg", 210 * MB, 200)
write("Downloads/node-v24-installer.pkg", 45 * MB, 120)
write("Downloads/lecture-notes.pdf", 14 * MB, 30)
write("Downloads/screenshots.zip", 60 * MB, 300)
write("Movies/Iceland trip.mov", 700 * MB, 420)
write("Movies/Screen Recording 2026-10-02.mov", 170 * MB, 48)
many("Movies/Drone", 6, 40, 80, lambda i: f"DJI_{i + 120:04}.mp4", 380)
many("Pictures/Photos 2025", 160, 1.2, 3.2, lambda i: f"IMG_{4100 + i}.heic", 200)
many("Pictures/Wallpapers", 18, 1, 4, lambda i: f"wallpaper-{i}.jpg", 90)
many("Music/Samples", 60, 2, 6, lambda i: f"kick-{i:02}.wav", 500)
many("Music/Podcasts", 12, 8, 30, lambda i: f"episode-{i + 40}.m4a", 60)
many("Documents/Invoices", 30, 0.1, 0.4, lambda i: f"invoice-{i + 1:03}.pdf", 100)
many("Documents/Presentations", 3, 30, 60, lambda i: f"talk-{i + 1}.key", 160)
many("Documents/Notes", 40, 0.002, 0.03, lambda i: f"note-{i}.md", 20)
many("Desktop", 22, 0.8, 2.5, lambda i: f"Screenshot 2026-11-{i % 18 + 1:02} at 10.{i:02}.png", 5)
many("Library/Caches/com.example.Browser/Cache_Data", 300, 0.3, 2.2, lambda i: f"f_{i:06x}", 1)
many("Library/Caches/Homebrew/downloads", 14, 4, 22, lambda i: f"bottle-{i}.tar.gz", 40)
many("Library/Caches/pip/http", 120, 0.2, 2, lambda i: f"{i:08x}", 30)
many("Library/Caches/org.example.Editor", 50, 0.2, 3, lambda i: f"index-{i}.db", 2)
many("Library/Developer/Xcode/DerivedData/WeatherApp-dkqzvhtrfuxl/Build/Intermediates.noindex", 80, 1, 7, lambda i: f"Target{i}.o", 10)
many("Library/Developer/CoreSimulator/Devices/5C2E1A90-7D4B-4F7E-9B1A-2E8F3C6D0A11/data/Containers", 40, 2, 9, lambda i: f"app-{i}.dat", 25)
many("Library/Logs/DiagnosticReports", 30, 0.05, 0.6, lambda i: f"WeatherApp-2026-11-{i % 18 + 1:02}.ips", 15)
(home / "Library/Mobile Documents/com~apple~CloudDocs").mkdir(parents=True, exist_ok=True)
many(".cache/uv/wheels", 60, 1, 6, lambda i: f"wheel-{i}.whl", 20)
many(".npm/_cacache/content-v2", 150, 0.1, 2, lambda i: f"{i:010x}", 20)
many(".ollama/models/blobs", 2, 280, 360, lambda i: f"sha256-{i}a9f", 230)
write(".Trash/old-backup.zip", 150 * MB, 10)


def size(relative: str) -> int:
    return sizes.get(relative, 0)


def item(relative, verdict, reason, title=None, status="pending", action=None, argument=None, bytes_=None):
    key = action or relative
    entry = {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"demo/{key}")).upper(),
        "path": str(home / relative) if relative else "",
        "size": bytes_ if bytes_ is not None else size(relative),
        "verdict": verdict,
        "reason": reason,
        "status": status,
        "createdAt": "2026-11-19T09:40:00Z",
    }
    if status != "pending":
        entry["statusAt"] = "2026-11-19T09:52:00Z"
    if title:
        entry["label"] = title
    if action:
        entry["action"] = action
    if argument:
        entry["argument"] = argument
    return entry


texts = {
    "en": {
        "title": "What fills the disk and what can go",
        "summary": "About 6 GB of this home folder is caches, build output and installers that rebuild or download again. Two items need your call: the old dataset archive and the local AI models.",
        "items": [
            item("Library/Caches/com.example.Browser", "safe", "Browser cache. The browser rebuilds it as you browse; nothing you saved is in here."),
            item("Library/Developer/Xcode/DerivedData/WeatherApp-dkqzvhtrfuxl", "regenerable", "Xcode build output for WeatherApp. The next build recreates it and takes a few minutes longer."),
            item("Developer/weather-app/node_modules", "regenerable", "npm packages. Run npm install to get them back."),
            item("Developer/ml-notebooks/.venv", "regenerable", "Python virtual environment. Recreate it with uv sync; the notebooks stay."),
            item("", "review", "Old versions and cached bottles. Installed formulae and casks stay.", "Homebrew: old versions and downloads", action="brew-cleanup", bytes_=1_240_000_000),
            item("", "review", "Only one simulator still uses iOS 17.5 and it has not started since spring. Xcode can download the runtime again.", "Simulator runtime iOS 17.5", action="simctl-runtime-delete", argument="4C1B2E9A-17D5-4F21-9A7E-5B3C2D1E0F17", bytes_=7_900_000_000),
            item("Downloads/dataset-2025.zip", "review", "The unpacked copy is already in ml-notebooks/data. Keep the zip only if you need the original."),
            item(".ollama/models", "review", "Two local models, last used eight months ago. Ollama can pull them again."),
            item("Movies/Iceland trip.mov", "keep", "Original footage with no other copy on this Mac."),
            item("Library/Caches/pip", "safe", "pip download cache.", status="trashed"),
        ],
    },
    "ru": {
        "title": "Чем забит диск и что можно убрать",
        "summary": "Около 6 ГБ в домашней папке занимают кэши, результаты сборок и установщики: всё это восстановится или скачается заново. Решить нужно про два пункта: старый архив с данными и локальные модели.",
        "items": [
            item("Library/Caches/com.example.Browser", "safe", "Кэш браузера. Браузер соберёт его заново, сохранённого здесь ничего нет."),
            item("Library/Developer/Xcode/DerivedData/WeatherApp-dkqzvhtrfuxl", "regenerable", "Результат сборки WeatherApp. Следующая сборка создаст его заново и пройдёт на пару минут дольше."),
            item("Developer/weather-app/node_modules", "regenerable", "Пакеты npm, возвращаются командой npm install."),
            item("Developer/ml-notebooks/.venv", "regenerable", "Виртуальное окружение Python, пересоздаётся через uv sync; ноутбуки останутся."),
            item("", "review", "Старые версии и скачанные архивы. Установленные пакеты остаются.", "Homebrew: старые версии и загрузки", action="brew-cleanup", bytes_=1_240_000_000),
            item("", "review", "iOS 17.5 нужна только одному симулятору, его не запускали с весны. Xcode скачает среду заново.", "Среда симулятора iOS 17.5", action="simctl-runtime-delete", argument="4C1B2E9A-17D5-4F21-9A7E-5B3C2D1E0F17", bytes_=7_900_000_000),
            item("Downloads/dataset-2025.zip", "review", "Распакованная копия уже лежит в ml-notebooks/data. Архив нужен, только если важен оригинал."),
            item(".ollama/models", "review", "Две локальные модели, последний раз запускались восемь месяцев назад. Ollama скачает их снова."),
            item("Movies/Iceland trip.mov", "keep", "Исходное видео, другой копии на Mac нет."),
            item("Library/Caches/pip", "safe", "Кэш загрузок pip.", status="trashed"),
        ],
    },
}[lang]

advice = home / "Library/Application Support/DiskAdvice"
advice.mkdir(parents=True, exist_ok=True)
sheet = {"title": texts["title"], "summary": texts["summary"], "author": "Claude", "updatedAt": "2026-11-19T09:40:00Z", "items": texts["items"]}
(advice / "advice.json").write_text(json.dumps(sheet, ensure_ascii=False, indent=2))
print(f"{sum(v for k, v in sizes.items() if '/' not in k) / 1e9:.1f} GB in {home}")
