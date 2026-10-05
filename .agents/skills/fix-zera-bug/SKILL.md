---
name: fix-zera-bug
description: Guide for fixing bugs in Zera without introducing regressions or messing up other existing features and designs.
---
# Fixing Bugs in Zera

When tasked with fixing a bug (especially layout or logic bugs) in Zera, adhere strictly to these guidelines:

1. **Isolate the Bug:**
   - Check the [App Overview](../../app_overview.md) to locate the domain of the bug (e.g., is it in Claude Session handling, GitHub API, or Card Layouts?).
   - Pinpoint the exact `layout()` override or logical state transition causing the issue.

2. **Do Not Rewrite Working Code:**
   - The primary directive is to **ensure the bug is fixed without creating new bugs or messing up other features**.
   - Resist the urge to refactor or rewrite large portions of a file. Only change the precise lines causing the anomaly.
   - **Never** replace manual layout math with AutoLayout to "fix" a bug. Fix the underlying coordinate math (`frame.origin`, `frame.size`) instead. Mixing constraints into the existing stack will break it.

3. **Design Integrity Verification:**
   - A bug fix is a failure if it breaks Zera's premium, neat aesthetic.
   - Check that bounds calculations (especially in dynamic lists or expanding cards like `ClaudeActivityCard`) correctly accumulate `y` offsets and apply padding.

4. **Testing the Fix:**
   - Ensure compilation is successful using `swift build` or Xcode.
   - Validate that unrelated modules imported or adjacent UI elements remain untouched.
