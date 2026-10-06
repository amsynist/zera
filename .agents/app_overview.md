# Zera App Overview

## What is Zera?
Zera is a native macOS desktop companion app built using Swift and AppKit. She lives on the desktop as a floating interactive buddy ("bubble" or "hover" UI) and assists users with various productivity tasks.

## Core Functionality
- **Claude Code Integration:** Acts as an interactive front-end for Claude Code via activity hooks. It displays current commands, timelines of execution, and prompts the user for manual approval when Claude is blocked.
- **GitHub Integration:** Fetches and displays GitHub Pull Requests, summarizing activity directly on the desktop.
- **In-App Assistant:** Features a built-in Claude file assistant for chatting and analyzing code.
- **File Shelf & Drag-and-Drop:** A "shelf" UI where users can drop files for Zera to store, reference, or act upon.
- **Reminders & Calendar:** Integrates with local macOS calendars and reminders to manage events and daily tasks.

## Technical Architecture & Constraints
- **Frameworks:** Exclusively AppKit (macOS native).
- **Layout System (CRITICAL):** Zera explicitly **REJECTS AutoLayout**. All custom views (e.g., `CardBase`, `DropFilesView`, `ClaudeActivityCard`, `ZeraDropdown`) use strict, predictable **manual coordinate math** inside overridden `layout()` methods.
  - **Constraint Warning:** Mixing AutoLayout/Constraints with the existing manual layout system breaks the UI entirely (causing zero-sized dimensions, overlapping, and clipping). 
- **Design Philosophy:** Premium, neat, native macOS feel. Absolutely zero tolerance for overlapping views, clipped text, or misaligned controls.

## Key Files
- `ZeraController.swift` & `ZeraView.swift`: Managing the floating companion bubble, animations, and mood states.
- `Cards.swift` & `Palette.swift`: Core design system, UI components, typography, and styling colors.
- `ClaudeSessionsView.swift` & `ClaudeActivityCard.swift`: Claude code integration and timeline components.
- `ReminderModels.swift` & `ReminderForms.swift`: The calendar/event creation module.
