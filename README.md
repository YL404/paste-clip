# PasteClip

A minimal clipboard history app for macOS. It lives in the menu bar, keeps a text and image history, and pastes the clip you pick into the frontmost app.

Requires macOS 26.

## Features

- Records plain-text and image copies; when a copy has both, the text wins. History has no size limit.
- Opens a Liquid Glass panel at the mouse position with a global shortcut (default ⇧⌘V, configurable in Settings).
- Full-text search, including Chinese.
- Shows a thumbnail for web links and the cover for YouTube links.
- Keeps the original image as PNG; GIFs keep only their first frame. Image rows show a thumbnail and `图片 宽×高`, which is searchable.
- Deleted clips go to a trash and are removed for good after 30 days.
- Image files are removed when their last clip is deleted for good.
- Skips clips marked as concealed or transient by password managers.

## Keyboard

| Key | Action |
| --- | --- |
| Type | Search |
| ↑ ↓ | Select |
| Return | Paste the selected clip |
| ⌘1 – ⌘9 | Paste one of the first 9 clips |
| ⌫ (empty search) / ⌘⌫ | Delete the selected clip |
| ⌘T | Switch between history and trash |
| Return (in trash) | Restore the clip to the top of history |
| Esc / click outside | Close |

The menu bar menu has an item to empty the trash. The interface is in Chinese.

## Build

```sh
scripts/bundle.sh          # release build -> build/PasteClip.app
scripts/bundle.sh debug    # debug build
```

The script signs the app with your first Apple Development certificate, or with `SIGN_IDENTITY` if set. Without a certificate it falls back to an ad-hoc signature, and macOS then asks for Accessibility access again after every rebuild.

## Permissions

- **Accessibility:** needed to send ⌘V to the frontmost app.
- **Pasteboard access:** if macOS restricts clipboard reads, PasteClip shows a notice instead of failing silently.

## License

[MIT](LICENSE)
