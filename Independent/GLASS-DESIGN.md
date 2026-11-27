# Glass controls for t3rm on iPhone X

## Start with the session bar

Give the scrolling session tabs one capsule and the adjacent workspace actions a second capsule. A filled selection inside the first capsule should make the active tab obvious in both Midnight and Paper. Keep the existing 46-point toolbar, 44-point action targets, and compact overflow menu. The keyboard already takes a large share of the display in a split session. A fixed toolbar above the terminal preserves the first and last lines of each pane. [Workspace](App/Workspace.swift) · [Workspace bar](App/WorkspaceBar.swift)

## What to borrow from Liquid Glass

Apple uses glass for controls that sit above content. The material refracts its backdrop near the edges, adjusts contrast as the backdrop changes, and can respond to a press near the point of contact. Related controls share a surface. The regular material provides more separation for text and symbols. That makes it the better reference for a terminal toolbar. [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/) · [Materials guidelines](https://developer.apple.com/design/human-interface-guidelines/materials)

Apple introduced native glass in iOS 26. On iOS 15, prototype the frosted appearance with a UIKit system material, a theme-colored outline, and a simple press highlight. The header has a flat backdrop, so compare that prototype with a plain tinted fill on the phone. If they look alike, choose the fill. Keep the terminal canvas opaque so ANSI colors, the cursor, and selection remain legible. Use solid capsule backgrounds for Reduce Transparency, stronger outlines for Increase Contrast, and immediate press feedback for Reduce Motion. [UIKit glass](https://developer.apple.com/documentation/uikit/uiglasseffect) · [UIKit system material](https://developer.apple.com/documentation/uikit/uiblureffect/style/systemmaterial) · [Terminal palette](App/Appearance.swift)

## Check on the phone

Compare the prototype with release r4 on the same iPhone X, in both themes and orientations. In a split, tap the inactive pane to select it, tap the selected pane to type, and pull across the keyboard to dismiss it. Verify the focus outline and divider stay visible through the transition. Check horizontal accessory-key scrolling, Shift, dictation, and long-press text selection. Record an Animation Hitches trace while scrolling terminal output and compare it alongside the device harness’s input latency and memory measurements. [Interaction tests](UITests/InteractionTests.swift) · [Device harness](DeviceQA/README.md) · [Apple’s guide to hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
