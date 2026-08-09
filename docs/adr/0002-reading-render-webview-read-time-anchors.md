# Reading renders the managed artifact through WKWebView with read-time anchor injection

The reading view must display the immutable, script-free HTML package captured by Document Import and let outline nodes jump to the matching content. We decided that a WKWebView loads the managed artifact through a custom URL scheme (WKURLSchemeHandler) and that anchor positions are established at read time: an injected script assigns anchors to rendered elements in Source Block order, and outline navigation scrolls to those anchors. The import chain, artifact bytes, and Content Fingerprint remain untouched.

## Considered Options

- Writing deterministic block ids into the artifact HTML at render time: rejected for the reading tracer bullet because it changes artifact generation, leaves every already-published document without ids (forcing regeneration or dual paths), and gains nothing until durable annotations need persistent anchors.
- Using the existing web Source Evidence locators to locate content: rejected because locators describe the original page's DOM, while the artifact is a re-rendered, sanitized composition; the paths do not survive extraction.
- Loading the artifact over file://: rejected because a custom scheme gives controlled access, path confinement to the managed artifact tree, and a clean interception point for external links and future annotation bridges.

## Consequences

- Anchor identity in the reading view is positional (block order), not durable; persistent annotations must later introduce stable artifact-side anchors, at which point this decision is revisited.
- Injected scripts run despite the artifact's `script-src 'none'` CSP, and no script originating from the artifact itself ever executes.
- The scheme handler must refuse any path outside the managed artifact tree and hand external http(s) links to the default browser instead of navigating.
