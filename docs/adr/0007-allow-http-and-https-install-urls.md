# Allow HTTP and HTTPS install URLs

## Context

ADB TV needs to install packages from local development servers as well as normal HTTPS hosts. The destination is entered at runtime, so static per-domain App Transport Security exceptions cannot cover the supported workflow.

## Decision

Allow both HTTP and HTTPS install URLs. The iOS target enables `NSAllowsArbitraryLoads` for `URLSession`, always displays the selected source, and shows an explicit warning for HTTP because it provides no transport integrity or confidentiality.

Downloaded bytes must pass structural APK validation before any transfer to a Managed Device. HTTPS remains preferred, but it does not replace package-signature verification performed by Android during installation.

## Consequences

- Local and self-hosted HTTP package servers work without predeclared host exceptions.
- HTTP downloads can be modified in transit; users receive a visible warning before installation.
- The broad ATS exception must be revisited if the project targets App Store distribution or adds unrelated `URLSession` traffic.
