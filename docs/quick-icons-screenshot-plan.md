# Quick Launch icons and screenshot quality

- Quick Launch must load icons for its own pinned packages after checking the
  active Android user, independently of the last Apps page. Reuse a bounded,
  disposable Caches-directory store across app launches. Scope icons by saved TV,
  Android user and validated package; keep image data out of pin/backup JSON.
- Retain cached icons on transient metadata failures. Cancelled/replaced loads
  must not publish or write stale data, and a changed Android user must invalidate
  the visible icons. Use existing checked/bounded app metadata requests.
- Keep binary-safe `exec:screencap -p` and unchanged PNG export. Reject incomplete
  PNG framing, failed chunk CRCs and unreadable Apple-platform image data. Inspect
  a bounded decoded thumbnail and advise when the returned capture appears blank; do not treat that
  as proof of DRM, automatically change the TV screen, or alter captured pixels.
- User reports black captures mainly during video, including exported PNGs.
  Android secure content can produce blank screenshots; this does not establish
  the cause for a particular TV/player without physical reproduction.
- Add regression coverage for cold icon reload/cache reuse, profile/device
  isolation, cancellation/late results, cache bounds/corruption, PNG framing,
  image decoding and blank/nonblank classification. Validate native builds and
  focused bilingual screenshots; preserve physical/VoiceOver limits.

No new production dependency, pairing change, automatic pin migration, release,
or merge is part of this bug-fix implementation. ImageIO/CoreGraphics are existing
Apple platform frameworks; portable tests cover the non-Apple logic separately.
