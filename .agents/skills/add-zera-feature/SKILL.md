---
name: add-zera-feature
description: Guide for safely adding new features to Zera without breaking existing layouts or causing regressions.
---
# Adding Features to Zera

When tasked with adding a new feature, screen, or capability to Zera, adhere strictly to these guidelines:

1. **Understand the App Architecture:**
   Review the [App Overview](../../app_overview.md) to understand Zera's core domain. Zera relies heavily on strict manual layout math in `override func layout()`.

2. **Strict Layout Rules (CRITICAL):**
   - **Do NOT use AutoLayout.** Do not use `NSLayoutConstraint`, `addConstraints`, or anchors on components that reside inside the Zera UI system.
   - Use absolute coordinate positioning (`frame = NSRect(x:y:width:height)`).
   - Recalculate heights dynamically in `layout()` based on the actual subviews.

3. **Preserve Existing Components:**
   - When adding a feature, integrate it by adding new `NSView` subclasses or extending existing ones using predefined `Palette` tokens and components (like `CardBase`, `IconButton`, `ZeraSelect`).
   - Do not randomly alter existing `layout()` logic of unrelated components just to fit a new feature.
   - Ensure you never introduce clipping, overlaps, or misaligned controls.

4. **Integration Testing:**
   - If adding a new card, ensure `cardWidth` and internal metrics conform to the overarching `CardBase` specifications.
   - Verify that compiling (`swift build` or Xcode build) succeeds cleanly without deprecation warnings regarding layout.
