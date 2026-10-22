# UI accessibility and connection polish

Implement the four UI issues found in the 2026-10-22 snapshot review of
`89426befae53ab0cd58e1e355fe7d095ab96374f` before adding Quick Launch.

1. Keep remote labels and symbols inside their controls at large Dynamic Type
   sizes. Stack saved connection labels and values at accessibility sizes.
2. Preserve the green identity with separate light/dark text accents and a
   consistently readable white-on-green fill for prominent actions.
3. Put connection feedback and recovery above the remote. Avoid moving the
   controls for routine key acknowledgements. Distinguish failed app loading
   from empty lists and searches; preserve cached rows after refresh failures.
4. Give empty libraries a direct connection action, explain the two Android
   wireless-debugging ports, and add persistent form labels, appropriate
   keyboards, and predictable field submission.

Keep the current navigation and verified connection/action paths. Add no
production dependencies. Quick Launch and unrelated file/app features remain
separate work.

Validate state transitions and color asset contrast with tests, parse all Swift
UI sources locally, and run the existing SwiftPM/iOS build checks. Extend the
snapshot workflow with focused empty/error/form previews and inspect the
iPhone/iPad light/dark and largest-text results. Static previews do not replace
physical TV, VoiceOver, gesture, or external-keyboard acceptance.

Local verification: 338 portable Swift tests pass, including app-list recovery
and contrast regressions. All app/UI and app-test Swift files parse with
Swift 6.2.4. Apple framework type checking, full SwiftPM tests, iOS build, and
the expanded 132-image snapshot matrix are required before PR completion.
