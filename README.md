# 3FDragUnstuck Enhanced Fork

An enhanced fork of 3FDragUnstuck, a lightweight macOS menu bar utility designed to reduce the release delay associated with native Three Finger Drag.

## Original Project

This project is based on the excellent work by **ddugel3**.

A sincere thank you to the original author for the brilliant idea and implementation. The original project solved a very specific macOS usability issue in an elegant and lightweight way, making native Three Finger Drag feel significantly more responsive.

Original repository:

https://github.com/ddugel3/3FDragUnstuck

## What's Included In This Fork

This fork preserves the original functionality while adding several quality of life improvements:

### Features

* Reduced Three Finger Drag release delay
* Menu bar utility with minimal resource usage
* Configurable Override Modifiers

  * Shift
  * Control
  * Option
  * Fn (Globe)
* Hide Menu Bar Icon
* Accessibility Status Indicator
* Persistent settings between launches
* Custom Application Icon
* Additional Icon Designs Included In Repository

### Override Modifiers

The original override functionality has been expanded into a configurable system that lets you select which modifier key suppresses the fast release while it is held.

Available options:

* Shift
* Control
* Option
* Fn (Globe)

This allows users to choose a modifier that best fits their workflow and avoids conflicts with common shortcuts such as screenshot selection. Holding the selected modifier as the drag ends keeps the native release behavior, and your choice is saved between launches.

**Note on Fn (Globe):** Fn (Globe) works best on Apple built-in keyboards and Apple Magic Keyboards. Support on third-party keyboards depends on whether the keyboard exposes the Fn key to macOS; some keyboards handle Fn internally and never report it to the system, so the override cannot trigger.

### Menu Bar Icon

The menu bar icon can be temporarily hidden while the application continues running.

Launching the application again restores the icon without affecting the underlying functionality.

### Accessibility Status

The application displays the current Accessibility permission state directly in the menu, making troubleshooting easier for new users.

## Building

```bash
make build
```

## Verification

```bash
make verify
```

## Requirements

* macOS
* Accessibility permissions enabled for the application

## License

This project remains licensed under the MIT License, consistent with the original project.

## Credits

**Original Author:** ddugel3

**Fork Maintainer:** efilo1

Special thanks again to ddugel3 for creating the original utility and sharing it with the community.
