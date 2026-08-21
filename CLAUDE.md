# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`oit_video_call` — OIT shared Flutter plugin wrapping Stream Video, consumed by the
Dharmayana consumer and Mitra apps.

## Conventions

### Comments

Comment the *why*, not the *what*. A comment earns its place only when the code can't
explain itself — a non-obvious constraint, a workaround and its cause, an ordering
requirement, a platform gotcha.

Do not add: comments restating an obviously-named call, section banner comments,
per-line narration, or doc comments on trivial members. One short line beats three.
Dense comment blocks bury the code they describe.

This applies to comments only — diagnostic/debug logging is wanted, keep it.
