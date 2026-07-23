# LockMic localizations

One folder per language (`xx.lproj/Localizable.strings`).

| Code | Language |
|------|----------|
| `en` | English (source / fallback) |
| `cs` | Czech |
| `da` | Danish |
| `de` | German |
| `el` | Greek |
| `es` | Spanish |
| `fi` | Finnish |
| `fr` | French |
| `hu` | Hungarian |
| `it` | Italian |
| `ja` | Japanese |
| `ko` | Korean |
| `nb` | Norwegian (Bokmål) |
| `nl` | Dutch |
| `pl` | Polish |
| `pt` | Portuguese |
| `ro` | Romanian |
| `ru` | Russian |
| `sr` | Serbian (Latinica) |
| `sv` | Swedish |
| `tr` | Turkish |
| `uk` | Ukrainian |
| `zh-Hans` | Chinese (Simplified) |

## Format

```
"key.path" = "Translated text";
```

Use `%@` for format placeholders (same order as English).

## After edits

Rebuild:

```bash
./Scripts/build_homebrew.sh
```

Keys are referenced from `Sources/LockMic/Util/L10n.swift`.
